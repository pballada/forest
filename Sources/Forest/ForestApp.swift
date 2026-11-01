import AppKit
import ForestCore
import SwiftUI

@main
struct ForestApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Welcome to Forest", id: "welcome") {
            WelcomeView()
                .frame(width: 760, height: 500)
                .tint(Theme.leaf)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .commands { ForestCommands() }

        WindowGroup("Repository", id: "repo", for: String.self) { $path in
            if let path {
                RepoWindow(path: path)
            } else {
                WelcomeView().frame(width: 760, height: 500)
            }
        }
        .defaultSize(width: 1320, height: 840)
        .windowToolbarStyle(.unified)

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

    static func open(_ url: URL) {
        Task {
            let root = (try? await Repository.open(url))?.root ?? url
            RecentRepositories.shared.add(root.path)
            openWindow?(id: "repo", value: root.path)
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
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") {
                openWindow(id: "update")
                Task { await Updater.shared.check(userInitiated: true) }
            }
        }

        CommandGroup(replacing: .newItem) {
            Button("Open Repository…") { WindowOpener.showOpenPanel() }
                .keyboardShortcut("o")
            Button("Clone Repository…") { NotificationCenter.default.post(name: .showClone, object: nil); openWindow(id: "welcome") }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Button("Welcome Window") { openWindow(id: "welcome") }
                .keyboardShortcut("1", modifiers: [.command, .shift])
        }

        CommandMenu("Repository") {
            Button("Command Palette…") { store?.showPalette.toggle() }
                .keyboardShortcut("k")
                .disabled(store == nil)
            Divider()
            Button("Changes") { store?.sidebar = .changes }.keyboardShortcut("1")
            Button("History") { store?.sidebar = .history }.keyboardShortcut("2")
            Button("Worktrees") { store?.sidebar = .worktrees }.keyboardShortcut("3")
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
            Button("New Worktree…") { store?.sheet = .newWorktree(base: nil, claude: false) }
                .keyboardShortcut("t", modifiers: [.command, .shift])
            Button("New Claude Agent…") { store?.sheet = .newWorktree(base: nil, claude: true) }
                .keyboardShortcut("n", modifiers: [.command, .option])
            Divider()
            Button("Open in Terminal") { if let s = store { Launcher.openTerminal(at: s.repository.root) } }
                .keyboardShortcut("t", modifiers: [.command, .option])
            Button("Open in \(Preferences.editor.rawValue)") { if let s = store { Launcher.openInEditor(s.repository.root) } }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            Button("Launch Claude Code Here") { if let s = store { Launcher.launchClaude(in: s.repository.root) } }
                .keyboardShortcut("l", modifiers: [.command, .option])
            Button("Reveal in Finder") { if let s = store { Launcher.revealInFinder(s.repository.root) } }
                .keyboardShortcut("r", modifiers: [.command, .shift])
        }
    }
}

extension Notification.Name {
    static let showClone = Notification.Name("ForestShowClone")
}
