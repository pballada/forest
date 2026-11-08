import AppKit
import Observation
import SwiftUI

/// One embedded terminal: a shell started in `directory`, optionally typing `initialInput` (e.g. a `claude …` command).
/// The surface lives as long as the session, independently of which view is showing it.
@Observable @MainActor
public final class TerminalSession: Identifiable {
    public let id = UUID()
    public let directory: URL
    /// Title set by the running program (Claude Code puts its session title here).
    public var title = ""
    /// Directory reported by the shell (OSC 7).
    public var currentDirectory: String?
    /// A program is reporting progress (OSC 9;4). Claude Code does this while it works.
    public private(set) var progressActive = false
    public private(set) var progressPercent: Int?
    /// The program rang the bell or posted a notification and the user hasn't looked yet.
    public private(set) var needsAttention = false
    public private(set) var lastNotification: String?
    public private(set) var lastActivity = Date()
    public private(set) var hasExited = false
    public private(set) var isClosed = false

    /// Called when the program asks for attention (bell, OSC 9/777 notification).
    @ObservationIgnored public var onAttention: ((TerminalSession) -> Void)?
    /// Called when the shell exits and the surface is gone.
    @ObservationIgnored public var onClose: ((TerminalSession) -> Void)?

    @ObservationIgnored let view: TerminalSurfaceView
    @ObservationIgnored private var progressTimeout: Task<Void, Never>?

    /// - Parameters:
    ///   - initialInput: typed into the shell once it starts, so the user lands back in a shell when the command ends.
    public init(directory: URL, initialInput: String? = nil, environment: [String: String] = [:]) {
        self.directory = directory
        view = TerminalSurfaceView(workingDirectory: directory.path, command: nil, initialInput: initialInput, environment: environment)
        view.session = self
    }

    /// libghostty is available (it could fail to initialise, e.g. without a Metal device).
    public static var isSupported: Bool { GhosttyRuntime.shared.isAvailable }
    public static var failureReason: String? { GhosttyRuntime.shared.failure }

    public var isFocused: Bool { view.window?.firstResponder === view }

    /// Puts text at the prompt (as a paste). With `submit`, presses Return afterwards.
    public func send(_ text: String, submit: Bool = false) {
        view.sendText(text)
        if submit { view.sendReturn() }
    }

    /// What's on screen right now, as text.
    public func visibleText() -> String { view.visibleText() }

    /// The terminal's last rendered frame.
    public func snapshotImage() -> NSImage? { view.snapshotImage() }

    public func focus() {
        view.window?.makeFirstResponder(view)
    }

    /// Ends the shell and frees the terminal.
    public func close() {
        guard !isClosed else { return }
        isClosed = true
        view.destroy()
        view.removeFromSuperview()
        progressTimeout?.cancel()
        onClose?(self)
    }

    // MARK: Events from libghostty

    func surfaceDidClose(processAlive: Bool) {
        close()
    }

    func receivedBell() {
        raiseAttention(nil)
    }

    func receivedNotification(title: String, body: String) {
        raiseAttention([title, body].filter { !$0.isEmpty }.joined(separator: " — "))
    }

    private func raiseAttention(_ message: String?) {
        lastActivity = Date()
        if let message { lastNotification = message }
        progressActive = false
        guard !(isFocused && NSApp.isActive) else { return }
        needsAttention = true
        onAttention?(self)
    }

    func progressChanged(active: Bool, percent: Int?) {
        lastActivity = Date()
        progressActive = active
        progressPercent = percent
        // Programs that crash never clear their progress; Ghostty itself times it out after 15 s.
        progressTimeout?.cancel()
        if active {
            progressTimeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled else { return }
                self?.progressActive = false
            }
        }
    }

    func childExited() {
        hasExited = true
        progressActive = false
    }

    func commandFinished() {
        lastActivity = Date()
    }

    func didFocus() {
        needsAttention = false
    }

    func userTyped() {
        needsAttention = false
        lastActivity = Date()
    }

    // MARK: Appearance

    /// Colours and font for every terminal. Changing it re-themes running terminals in place.
    public static func apply(_ appearance: TerminalAppearance, useOwnGhosttyColors: Bool) {
        let runtime = GhosttyRuntime.shared
        runtime.usesOwnGhosttyColors = useOwnGhosttyColors
        runtime.appearance = appearance
    }
}

/// Shows a session's terminal. The terminal view is moved between hosts, never recreated,
/// so switching worktrees keeps scrollback and the running program.
public struct TerminalHost: NSViewRepresentable {
    let session: TerminalSession
    var focusOnAppear: Bool

    public init(session: TerminalSession, focusOnAppear: Bool = true) {
        self.session = session
        self.focusOnAppear = focusOnAppear
    }

    public func makeNSView(context: Context) -> TerminalContainerView {
        let container = TerminalContainerView()
        container.attach(session, focus: focusOnAppear)
        return container
    }

    public func updateNSView(_ container: TerminalContainerView, context: Context) {
        container.attach(session, focus: focusOnAppear)
    }

    public static func dismantleNSView(_ container: TerminalContainerView, coordinator: ()) {
        container.detach()
    }
}

public final class TerminalContainerView: NSView {
    private weak var current: TerminalSession?

    func attach(_ session: TerminalSession, focus: Bool) {
        guard current !== session || session.view.superview !== self else { return }
        current = session
        subviews.forEach { $0.removeFromSuperview() }
        guard !session.isClosed else { return }
        let view = session.view
        view.removeFromSuperview()
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        addSubview(view)
        if focus {
            DispatchQueue.main.async { [weak view] in
                guard let view, let window = view.window else { return }
                window.makeFirstResponder(view)
            }
        }
    }

    func detach() {
        if let view = current?.view, view.superview === self { view.removeFromSuperview() }
        current = nil
    }

    public override func layout() {
        super.layout()
        subviews.forEach { $0.frame = bounds }
    }
}
