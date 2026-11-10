import AppKit
import ForestCore
import SwiftUI

@main
struct ForestApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Forest", id: "main") {
            WorkspaceWindow()
        }
        .defaultSize(width: 1440, height: 900)
        .windowToolbarStyle(.unified)
        .commands { ForestCommands() }

        Window("Welcome to Forest", id: "welcome") {
            WelcomeView()
                .frame(width: 760, height: 500)
                .tint(Theme.leaf)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)

        Window("Software Update", id: "update") {
            UpdateView()
                .tint(Theme.leaf)
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsView()
                .tint(Theme.leaf)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare executable (`swift run`) rather than from the .app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // `Forest /path/to/repo` or `open -a Forest --args /path/to/repo`
        let paths = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        var isDirectory: ObjCBool = false
        let directories = paths.filter { FileManager.default.fileExists(atPath: $0, isDirectory: &isDirectory) && isDirectory.boolValue }
        Task { @MainActor in
            WindowOpener.pending += directories.map { URL(fileURLWithPath: $0) }
            Updater.shared.startAutomaticChecks()
        }
    }

    /// Folders dropped on the Dock icon or opened with "Open With".
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            if WindowOpener.openWindow == nil {
                WindowOpener.pending += urls
            } else {
                urls.forEach(WindowOpener.open)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { Updater.shared.installOnQuit() }
    }
}

/// Lets models and menu commands open repository windows.
@MainActor
enum WindowOpener {
    static var openWindow: OpenWindowAction?
    static var dismissWindow: DismissWindowAction?
    /// Repositories requested before any window could open them.
    static var pending: [URL] = []

    static func install(open: OpenWindowAction, dismiss: DismissWindowAction) {
        openWindow = open
        dismissWindow = dismiss
        let queued = pending
        pending = []
        queued.forEach(Self.open)
    }

    /// Adds the repository to the workspace (or selects it, and the worktree `url` points into).
    static func open(_ url: URL) {
        Task {
            await WorkspaceStore.shared.open(url)
            openWindow?(id: "main")
            dismissWindow?(id: "welcome")
        }
    }

    static func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Open"
        panel.message = "Choose a git repository"
        guard panel.runModal() == .OK else { return }
        panel.urls.forEach(open)
    }
}

struct RepoStoreKey: FocusedValueKey {
    typealias Value = RepoStore
}

extension FocusedValues {
    var repoStore: RepoStore? {
        get { self[RepoStoreKey.self] }
        set { self[RepoStoreKey.self] = newValue }
    }
}

struct ForestCommands: Commands {
    @FocusedValue(\.repoStore) private var store
    @FocusedValue(\.workspace) private var workspace
    @Environment(\.openWindow) private var openWindow

    private var project: ProjectStore? { workspace?.selectedProject }
    private var path: String? { workspace?.selection?.worktree }

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Forest") { AboutPanel.show() }
        }

        CommandGroup(replacing: .help) {
            Button("Forest Help") { Launcher.openURL(HelpLinks.help) }
                .keyboardShortcut("?", modifiers: .command)
            Button("Keyboard Shortcuts") { Launcher.openURL(HelpLinks.shortcuts) }
            Button("Troubleshooting") { Launcher.openURL(HelpLinks.troubleshooting) }
            Divider()
            Button("What's New in Forest \(Updater.currentVersion)") { Launcher.openURL(HelpLinks.releaseNotes) }
            Button("Report an Issue…") { Launcher.openURL(HelpLinks.newIssue) }
        }

        CommandGroup(after: .appInfo) {
            if let ready = Updater.shared.readyRelease {
                Button("Restart to Update to \(ready.version)") { Updater.shared.restartToUpdate() }
            }
            Button("Check for Updates…") {
                openWindow(id: "update")
                Task { await Updater.shared.check(userInitiated: true) }
            }
        }

        CommandGroup(replacing: .newItem) {
            Button("New Agent…") { (store ?? project?.main)?.sheet = .newAgent(base: nil) }
                .keyboardShortcut("n")
                .disabled(project == nil)
            Divider()
            Button("Add Project…") { WindowOpener.showOpenPanel() }
                .keyboardShortcut("o")
            Button("Clone Repository…") { NotificationCenter.default.post(name: .showClone, object: nil); openWindow(id: "welcome") }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Button("Welcome Window") { openWindow(id: "welcome") }
                .keyboardShortcut("1", modifiers: [.command, .shift])
        }

        CommandGroup(after: .sidebar) {
            Button(workspace?.showInspector == true ? "Hide Live Changes" : "Show Live Changes") { workspace?.showInspector.toggle() }
                .keyboardShortcut("0", modifiers: [.command, .option])
            Divider()
            Button("Terminal") { store?.sidebar = .terminal }.keyboardShortcut("1", modifiers: [.command, .option])
            Button("Changes") { store?.sidebar = .changes }.keyboardShortcut("2", modifiers: [.command, .option])
            Button("History") { store?.sidebar = .history }.keyboardShortcut("3", modifiers: [.command, .option])
        }

        CommandMenu("Agent") {
            ForEach(1...9, id: \.self) { index in
                Button("Worktree \(index)") { workspace?.selectWorktree(at: index - 1) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index)")), modifiers: .command)
            }
            Button("Next Worktree") { workspace?.selectAdjacent(1) }.keyboardShortcut(.tab, modifiers: .control)
            Button("Previous Worktree") { workspace?.selectAdjacent(-1) }.keyboardShortcut(.tab, modifiers: [.control, .shift])
            Divider()
            Button("Continue Last Session") {
                if let project, let path { project.continueLatest(in: path); store?.sidebar = .terminal }
            }
            .keyboardShortcut(.return, modifiers: [.command, .shift])
            .disabled(path == nil)
            Button("New Claude Session") {
                if let project, let path { project.launch(.newSession(prompt: nil), in: path); store?.sidebar = .terminal }
            }
            .disabled(path == nil)
            Button("Toggle Shell") {
                if let project, let path { store?.sidebar = .terminal; project.toggleShell(for: path) }
            }
            .keyboardShortcut("d")
            .disabled(path == nil || project?.terminal(for: path ?? "") == nil)
            Button("Close Terminal") { if let project, let path { project.closeTerminal(for: path) } }
                .disabled(path == nil || project?.terminal(for: path ?? "") == nil)
            Divider()
            Button("Compare…") { store?.sheet = .compare(left: nil, right: nil, file: nil) }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(store == nil)
            Button("Review Agent…") {
                if let project, let path, let worktree = project.worktree(at: path), !worktree.isMain { project.main.sheet = .review(worktree) }
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(path == nil || project?.worktree(at: path ?? "")?.isMain != false)
        }

        CommandMenu("Repository") {
            Button("Command Palette…") { store?.showPalette.toggle() }
                .keyboardShortcut("k")
                .disabled(store == nil)
            Divider()
            Button(store?.undo.map { "Undo \($0.title)" } ?? "Undo") { store?.performUndo() }
                .keyboardShortcut("z", modifiers: [.command, .option])
                .disabled(store?.undo == nil)
            Divider()
            Button("Refresh") { Task { await store?.refresh(full: true) } }.keyboardShortcut("r")
            Button("Fetch") { store?.fetch() }.keyboardShortcut("f", modifiers: [.command, .shift])
            Button("Pull") { store?.pull() }.keyboardShortcut("p", modifiers: [.command, .shift])
            Button("Push") { store?.push() }.keyboardShortcut("u", modifiers: [.command, .shift])
            Divider()
            Button("Commit") { store?.commit() }
                .keyboardShortcut(.return)
                .disabled(store?.canCommit != true)
            Button("Write Commit Message with Claude") { store?.generateCommitMessage() }
                .keyboardShortcut("m", modifiers: [.command, .option])
                .disabled(store == nil || store?.status.staged.isEmpty == true)
            Button("Stage All") { store?.stageAll() }.keyboardShortcut("a", modifiers: [.command, .shift])
            Button("Stash Changes…") { store?.sheet = .stash }.keyboardShortcut("s", modifiers: [.command, .option])
            Divider()
            Button("New Branch…") { store?.sheet = .newBranch(start: nil) }.keyboardShortcut("b", modifiers: [.command, .shift])
            Divider()
            Button("Open in \(Preferences.terminal.rawValue)") { if let s = store { Launcher.openTerminal(at: s.repository.root) } }
                .keyboardShortcut("t", modifiers: [.command, .option])
            Button("Open in \(Preferences.editor.rawValue)") { if let s = store { Launcher.openInEditor(s.repository.root) } }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            Button("Reveal in Finder") { if let s = store { Launcher.revealInFinder(s.repository.root) } }
        }
    }
}

extension Notification.Name {
    static let showClone = Notification.Name("ForestShowClone")
}

/// The standard About panel, with what Forest is, its links and credits.
@MainActor
enum AboutPanel {
    static func show() {
        let body = NSMutableAttributedString()
        let center = NSMutableParagraphStyle()
        center.alignment = .center
        center.paragraphSpacing = 6
        func add(_ text: String, _ font: NSFont, _ color: NSColor = .labelColor, link: URL? = nil) {
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: center]
            if let link { attributes[.link] = link }
            body.append(NSAttributedString(string: text, attributes: attributes))
        }
        let small = NSFont.systemFont(ofSize: 11)
        add("Your coding agents, their terminals and their changes, with a native Git client.\n",
            .systemFont(ofSize: 11.5, weight: .medium))
        add("Claude Code · Codex · Gemini CLI\n", small, .secondaryLabelColor)
        add("GitHub", small, link: URL(string: "https://github.com/pballada/forest"))
        add("  ·  ", small, .tertiaryLabelColor)
        add("Help", small, link: HelpLinks.help)
        add("  ·  ", small, .tertiaryLabelColor)
        add("What's new", small, link: URL(string: "https://github.com/pballada/forest/releases/tag/v\(Updater.currentVersion)"))
        add("\nTerminal by Ghostty (MIT)", .systemFont(ofSize: 10), .tertiaryLabelColor)

        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: body,
            .applicationVersion: Updater.currentVersion,
            .version: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
            NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): "© 2026 Pau Ballada",
        ])
    }
}

/// Help lives in the README on GitHub, so it's always current.
@MainActor
enum HelpLinks {
    static let repository = URL(string: "https://github.com/pballada/forest")!
    static let help = URL(string: "https://github.com/pballada/forest#help")!
    static let shortcuts = URL(string: "https://github.com/pballada/forest#keyboard-shortcuts")!
    static let troubleshooting = URL(string: "https://github.com/pballada/forest#troubleshooting")!
    static var releaseNotes: URL { URL(string: "https://github.com/pballada/forest/releases/tag/v\(Updater.currentVersion)")! }
    static var newIssue: URL {
        var components = URLComponents(string: "https://github.com/pballada/forest/issues/new")!
        let system = ProcessInfo.processInfo.operatingSystemVersionString
        components.queryItems = [URLQueryItem(name: "body", value: "**What happened**\n\n\n**What I expected**\n\n\n---\nForest \(Updater.currentVersion), macOS \(system)")]
        return components.url!
    }
}
