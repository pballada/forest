import AppKit
import GhosttyKit
import UniformTypeIdentifiers

/// Colours and font for embedded terminals, supplied by the host app's theme.
public struct TerminalAppearance: Equatable, Sendable {
    public var background: String
    public var foreground: String
    public var cursor: String
    public var selectionBackground: String
    public var selectionForeground: String?
    /// ANSI colours 0–15, as `#rrggbb`.
    public var palette: [String]
    public var isDark: Bool
    /// nil keeps the font from the user's Ghostty config (or Ghostty's default).
    public var fontFamily: String?
    public var fontSize: Double?

    public init(background: String, foreground: String, cursor: String, selectionBackground: String,
                selectionForeground: String? = nil, palette: [String], isDark: Bool,
                fontFamily: String? = nil, fontSize: Double? = nil) {
        self.background = background
        self.foreground = foreground
        self.cursor = cursor
        self.selectionBackground = selectionBackground
        self.selectionForeground = selectionForeground
        self.palette = palette
        self.isDark = isDark
        self.fontFamily = fontFamily
        self.fontSize = fontSize
    }
}

/// The single libghostty app instance shared by every terminal in Forest.
/// All calls into libghostty go through this target; the rest of Forest never imports GhosttyKit.
@MainActor
public final class GhosttyRuntime {
    public static let shared = GhosttyRuntime()

    private(set) var app: ghostty_app_t?
    private var config: ghostty_config_t?
    private var tickScheduled = false
    public private(set) var failure: String?

    /// When true, the user's own Ghostty config decides colours too; Forest only removes keybinds it needs.
    public var usesOwnGhosttyColors = false { didSet { reloadConfig() } }
    public var appearance: TerminalAppearance? { didSet { if appearance != oldValue { reloadConfig() } } }

    public var isAvailable: Bool { app != nil }

    private init() {
        Self.configureResources()
        if ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) != GHOSTTY_SUCCESS {
            failure = "libghostty failed to initialise"
            return
        }
        guard let config = makeConfig() else {
            failure = "Could not load the terminal configuration"
            return
        }
        self.config = config

        var runtime = ghostty_runtime_config_s(
            userdata: nil,
            supports_selection_clipboard: true,
            wakeup_cb: { _ in DispatchQueue.main.async { MainActor.assumeIsolated { GhosttyRuntime.shared.scheduleTick() } } },
            action_cb: { app, target, action in
                MainActor.assumeIsolated { GhosttyRuntime.shared.handle(action, target: target) }
            },
            read_clipboard_cb: { userdata, location, state, mimes, count, list in
                MainActor.assumeIsolated {
                    GhosttyRuntime.readClipboard(userdata, location: location, state: state, mimes: mimes, count: count, list: list)
                }
            },
            confirm_read_clipboard_cb: { userdata, confirm, state, request in
                MainActor.assumeIsolated { GhosttyRuntime.confirmReadClipboard(userdata, confirm: confirm, state: state, request: request) }
            },
            write_clipboard_cb: { userdata, location, content, count, confirm in
                MainActor.assumeIsolated {
                    GhosttyRuntime.writeClipboard(userdata, location: location, content: content, count: count, confirm: confirm)
                }
            },
            close_surface_cb: { userdata, processAlive in
                MainActor.assumeIsolated {
                    TerminalSurfaceView.from(userdata)?.session?.surfaceDidClose(processAlive: processAlive)
                }
            }
        )
        guard let app = ghostty_app_new(&runtime, config) else {
            failure = "libghostty could not create its app"
            return
        }
        self.app = app
        ghostty_app_set_focus(app, NSApp.isActive)
        let center = NotificationCenter.default
        center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { if let app = GhosttyRuntime.shared.app { ghostty_app_set_focus(app, true) } }
        }
        center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { if let app = GhosttyRuntime.shared.app { ghostty_app_set_focus(app, false) } }
        }
        center.addObserver(forName: NSTextInputContext.keyboardSelectionDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { if let app = GhosttyRuntime.shared.app { ghostty_app_keyboard_changed(app) } }
        }
    }

    // MARK: Tick

    /// libghostty asks to be ticked from any thread; coalesce into one main-thread tick.
    func scheduleTick() {
        guard !tickScheduled else { return }
        tickScheduled = true
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.tickScheduled = false
                if let app = self.app { ghostty_app_tick(app) }
            }
        }
    }

    // MARK: Config

    /// Builds the config: the user's Ghostty files (fonts, keybinds), then Forest's overrides.
    private func makeConfig() -> ghostty_config_t? {
        guard let config = ghostty_config_new() else { return nil }
        ghostty_config_load_default_files(config)
        ghostty_config_load_recursive_files(config)
        if let overrides = writeOverrides() {
            overrides.path.withCString { ghostty_config_load_file(config, $0) }
        }
        ghostty_config_finalize(config)
        return config
    }

    private func reloadConfig() {
        guard let app, let config = makeConfig() else { return }
        ghostty_app_update_config(app, config)
        if let old = self.config { ghostty_config_free(old) }
        self.config = config
        if let appearance {
            ghostty_app_set_color_scheme(app, appearance.isDark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT)
        }
    }

    /// Keys Forest's own menus use. Ghostty would otherwise claim them (tabs, splits, windows) before the menu sees them.
    static let reservedKeybinds = [
        "super+t", "super+n", "super+shift+n", "super+w", "super+shift+w", "super+alt+w", "super+d", "super+shift+d",
        "super+k", "super+comma", "super+shift+comma", "super+enter", "super+shift+enter", "ctrl+tab", "ctrl+shift+tab",
        "super+shift+left_bracket", "super+shift+right_bracket", "super+alt+left", "super+alt+right",
        "super+alt+up", "super+alt+down", "super+alt+i", "super+shift+t",
    ] + (1...9).map { "super+\($0)" } + (1...3).map { "super+alt+\($0)" }

    private func writeOverrides() -> URL? {
        var lines = Self.reservedKeybinds.map { "keybind = \($0)=unbind" }
        lines += [
            "window-padding-x = 10",
            "window-padding-y = 8",
            "window-padding-balance = true",
            "confirm-close-surface = false",
            "quit-after-last-window-closed = false",
            "shell-integration-features = cursor,title,sudo",
            "macos-option-as-alt = false",
            "cursor-style-blink = true",
            "mouse-hide-while-typing = true",
        ]
        if let appearance, !usesOwnGhosttyColors {
            lines += [
                "background = \(appearance.background)",
                "foreground = \(appearance.foreground)",
                "cursor-color = \(appearance.cursor)",
                "selection-background = \(appearance.selectionBackground)",
                "background-opacity = 1",
                "theme = ",
            ]
            if let fg = appearance.selectionForeground { lines.append("selection-foreground = \(fg)") }
            lines += appearance.palette.prefix(16).enumerated().map { "palette = \($0.offset)=\($0.element)" }
        }
        if let family = appearance?.fontFamily, !family.isEmpty {
            lines += ["font-family = ", "font-family = \(family)"]
        }
        if let size = appearance?.fontSize { lines.append("font-size = \(size)") }

        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Forest", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("ghostty-overrides.conf")
        do {
            try lines.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    /// Points libghostty at the bundled shell integration and terminfo (`<dir>/ghostty`, `<dir>/terminfo`).
    private static func configureResources() {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let resources = Bundle.main.resourceURL { candidates.append(resources.appendingPathComponent("ghostty")) }
        // `swift run`: the repository's Vendor folder, next to Sources.
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        candidates.append(repo.appendingPathComponent("Vendor/ghostty-resources/ghostty"))
        if let dir = candidates.first(where: { fm.fileExists(atPath: $0.appendingPathComponent("shell-integration").path) }) {
            setenv("GHOSTTY_RESOURCES_DIR", dir.path, 1)
        }
    }

    // MARK: Actions

    private func handle(_ action: ghostty_action_s, target: ghostty_target_s) -> Bool {
        let view: TerminalSurfaceView? = target.tag == GHOSTTY_TARGET_SURFACE
            ? TerminalSurfaceView.from(ghostty_surface_userdata(target.target.surface)) : nil
        let session = view?.session
        switch action.tag {
        case GHOSTTY_ACTION_SET_TITLE:
            session?.title = Self.string(action.action.set_title.title) ?? ""
            return true
        case GHOSTTY_ACTION_PWD:
            session?.currentDirectory = Self.string(action.action.pwd.pwd)
            return true
        case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
            let note = action.action.desktop_notification
            session?.receivedNotification(title: Self.string(note.title) ?? "", body: Self.string(note.body) ?? "")
            return true
        case GHOSTTY_ACTION_RING_BELL:
            session?.receivedBell()
            return true
        case GHOSTTY_ACTION_PROGRESS_REPORT:
            let report = action.action.progress_report
            session?.progressChanged(active: report.state != GHOSTTY_PROGRESS_STATE_REMOVE,
                                     percent: report.progress >= 0 ? Int(report.progress) : nil)
            return true
        case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
            session?.childExited()
            return false
        case GHOSTTY_ACTION_COMMAND_FINISHED:
            session?.commandFinished()
            return true
        case GHOSTTY_ACTION_OPEN_URL:
            let payload = action.action.open_url
            if let pointer = payload.url {
                let data = Data(bytes: pointer, count: Int(payload.len))
                if let string = String(data: data, encoding: .utf8) {
                    let url = URL(string: string) ?? URL(fileURLWithPath: string)
                    NSWorkspace.shared.open(url)
                }
            }
            return true
        case GHOSTTY_ACTION_MOUSE_SHAPE:
            view?.setCursorShape(action.action.mouse_shape)
            return true
        case GHOSTTY_ACTION_MOUSE_VISIBILITY:
            if action.action.mouse_visibility == GHOSTTY_MOUSE_HIDDEN { NSCursor.setHiddenUntilMouseMoves(true) }
            return true
        case GHOSTTY_ACTION_CELL_SIZE:
            let size = action.action.cell_size
            view?.cellSize = NSSize(width: Double(size.width) / (view?.backingScale ?? 2), height: Double(size.height) / (view?.backingScale ?? 2))
            return true
        case GHOSTTY_ACTION_CLOSE_WINDOW, GHOSTTY_ACTION_CLOSE_TAB:
            session?.surfaceDidClose(processAlive: false)
            return true
        case GHOSTTY_ACTION_RELOAD_CONFIG:
            reloadConfig()
            return true
        case GHOSTTY_ACTION_COLOR_CHANGE, GHOSTTY_ACTION_CONFIG_CHANGE, GHOSTTY_ACTION_RENDERER_HEALTH,
             GHOSTTY_ACTION_INITIAL_SIZE, GHOSTTY_ACTION_SIZE_LIMIT, GHOSTTY_ACTION_SCROLLBAR,
             GHOSTTY_ACTION_SELECTION_CHANGED, GHOSTTY_ACTION_MOUSE_OVER_LINK, GHOSTTY_ACTION_RENDER:
            return true
        default:
            // Tabs, splits, windows, inspector…: Forest owns its layout, so let the key reach the program instead.
            return false
        }
    }

    static func string(_ pointer: UnsafePointer<CChar>?) -> String? {
        guard let pointer else { return nil }
        return String(validatingCString: pointer)
    }

    // MARK: Clipboard

    static let selectionPasteboard = NSPasteboard(name: .init("com.pballada.forest.selection"))

    private static func pasteboard(_ location: ghostty_clipboard_e) -> NSPasteboard? {
        switch location {
        case GHOSTTY_CLIPBOARD_STANDARD: .general
        case GHOSTTY_CLIPBOARD_SELECTION, GHOSTTY_CLIPBOARD_PRIMARY: selectionPasteboard
        default: nil
        }
    }

    private static func pasteboardType(forMime mime: String) -> NSPasteboard.PasteboardType? {
        if mime == "text/plain" || mime.hasPrefix("text/plain;") { return .string }
        return UTType(mimeType: mime).map { NSPasteboard.PasteboardType($0.identifier) }
    }

    private static func data(_ pasteboard: NSPasteboard, mime: String) -> Data? {
        guard let type = pasteboardType(forMime: mime) else { return nil }
        if type == .string { return pasteboard.string(forType: .string).map { Data($0.utf8) } }
        return pasteboard.data(forType: type)
    }

    private static func availableMimes(_ pasteboard: NSPasteboard) -> [String] {
        (pasteboard.types ?? []).compactMap { type in
            type == .string ? "text/plain" : UTType(type.rawValue)?.preferredMIMEType
        }
    }

    private static func readClipboard(_ userdata: UnsafeMutableRawPointer?, location: ghostty_clipboard_e, state: UnsafeMutableRawPointer?,
                                      mimes: UnsafePointer<UnsafePointer<CChar>?>?, count: Int, list: Bool) -> ghostty_clipboard_read_result_e {
        guard let surface = TerminalSurfaceView.from(userdata)?.surface, let pasteboard = pasteboard(location) else {
            return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED
        }
        var contents: [(String, Data)] = []
        if let mimes {
            for index in 0..<count {
                guard let pointer = mimes[index] else { continue }
                let mime = String(cString: pointer)
                if contents.contains(where: { $0.0 == mime }) { continue }
                if let data = data(pasteboard, mime: mime) { contents.append((mime, data)) }
            }
        }
        let available = list ? availableMimes(pasteboard) : []
        if contents.isEmpty && !list { return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE }
        complete(surface, contents: contents, available: available, state: state)
        return GHOSTTY_CLIPBOARD_READ_STARTED
    }

    /// Ghostty asks before pasting text that could run commands (newlines) or before a program reads the clipboard.
    private static func confirmReadClipboard(_ userdata: UnsafeMutableRawPointer?, confirm: UnsafePointer<ghostty_clipboard_confirm_s>?,
                                             state: UnsafeMutableRawPointer?, request: ghostty_clipboard_request_e) {
        guard let view = TerminalSurfaceView.from(userdata), let surface = view.surface, let confirm = confirm?.pointee else { return }
        var contents: [(String, Data)] = []
        for index in 0..<confirm.contents_len {
            let item = confirm.contents[index]
            guard let mime = item.mime.flatMap({ String(validatingCString: $0) }), let bytes = item.data else { continue }
            contents.append((mime, Data(bytes: bytes, count: item.len)))
        }
        let available = (0..<confirm.available_len).compactMap { confirm.available[$0].flatMap { String(validatingCString: $0) } }
        let preview = contents.first { $0.0.hasPrefix("text/plain") }.flatMap { String(data: $0.1, encoding: .utf8) } ?? ""

        let alert = NSAlert()
        if request == GHOSTTY_CLIPBOARD_REQUEST_PASTE {
            alert.messageText = "Paste text that could run commands?"
            alert.informativeText = String(preview.prefix(600))
        } else {
            alert.messageText = "Allow the program in this terminal to read your clipboard?"
            alert.informativeText = String(preview.prefix(300))
        }
        alert.addButton(withTitle: request == GHOSTTY_CLIPBOARD_REQUEST_PASTE ? "Paste" : "Allow")
        alert.addButton(withTitle: "Cancel")
        let confirmed = alert.runModal() == .alertFirstButtonReturn
        if confirmed {
            complete(surface, contents: contents, available: available, state: state, confirmed: true)
        } else {
            ghostty_surface_deny_clipboard_request(surface, state)
        }
    }

    private static func complete(_ surface: ghostty_surface_t, contents: [(String, Data)], available: [String],
                                 state: UnsafeMutableRawPointer?, confirmed: Bool = false) {
        var strings: [UnsafeMutablePointer<CChar>] = []
        var buffers: [UnsafeMutableRawPointer] = []
        defer {
            strings.forEach { free($0) }
            buffers.forEach { $0.deallocate() }
        }
        var cContents: [ghostty_clipboard_content_s] = []
        for (mime, data) in contents {
            guard let cMime = strdup(mime) else { continue }
            strings.append(cMime)
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: max(data.count, 1), alignment: 1)
            buffers.append(buffer)
            data.withUnsafeBytes { if let base = $0.baseAddress { buffer.copyMemory(from: base, byteCount: $0.count) } }
            cContents.append(ghostty_clipboard_content_s(mime: cMime, data: buffer.assumingMemoryBound(to: CChar.self), len: data.count))
        }
        var cAvailable: [UnsafePointer<CChar>?] = []
        for mime in available {
            guard let string = strdup(mime) else { continue }
            strings.append(string)
            cAvailable.append(UnsafePointer(string))
        }
        cContents.withUnsafeBufferPointer { contentsBuffer in
            cAvailable.withUnsafeBufferPointer { availableBuffer in
                var payload = ghostty_clipboard_complete_s(contents: contentsBuffer.baseAddress, contents_len: contentsBuffer.count,
                                                           available: availableBuffer.baseAddress, available_len: availableBuffer.count,
                                                           confirmed: confirmed, remember: false)
                ghostty_surface_complete_clipboard_request(surface, &payload, state)
            }
        }
    }

    private static func writeClipboard(_ userdata: UnsafeMutableRawPointer?, location: ghostty_clipboard_e,
                                       content: UnsafePointer<ghostty_clipboard_content_s>?, count: Int, confirm: Bool) {
        guard let pasteboard = pasteboard(location), let content, count > 0 else { return }
        var items: [(NSPasteboard.PasteboardType, Data)] = []
        for index in 0..<count {
            let item = content[index]
            guard let mime = item.mime.flatMap({ String(validatingCString: $0) }), let type = pasteboardType(forMime: mime),
                  let bytes = item.data else { continue }
            items.append((type, Data(bytes: bytes, count: item.len)))
        }
        guard !items.isEmpty else { return }
        if confirm {
            // A program asked to set the clipboard (OSC 52): ask first.
            let alert = NSAlert()
            alert.messageText = "Allow the program in this terminal to set your clipboard?"
            if let text = items.first(where: { $0.0 == .string }).flatMap({ String(data: $0.1, encoding: .utf8) }) {
                alert.informativeText = String(text.prefix(300))
            }
            alert.addButton(withTitle: "Allow")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        pasteboard.declareTypes(items.map(\.0), owner: nil)
        for (type, data) in items { pasteboard.setData(data, forType: type) }
    }
}
