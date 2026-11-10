import AppKit
import ForestCore
import ForestTerminal
import SwiftUI

/// One repository in the workspace: its main checkout, its Claude worktrees, a store per worktree
/// (created when first shown) and the terminals running in them.
@Observable @MainActor
final class ProjectStore: Identifiable {
    /// Store for the main checkout. It loads the worktree list, Claude sessions and pull requests for the project.
    let main: RepoStore
    private(set) var stores: [String: RepoStore] = [:]
    /// The terminal running Claude (or a shell) in each worktree.
    private(set) var terminals: [String: TerminalSession] = [:]
    /// Optional second terminal under the main one (⌘D).
    private(set) var shells: [String: TerminalSession] = [:]
    /// Session id each live terminal was started with, so its row can show that session's title.
    private(set) var terminalSessionIDs: [String: String] = [:]

    let id: String
    var root: URL { main.repository.root }
    var name: String { main.name }

    init(main: RepoStore) {
        self.main = main
        id = main.repository.root.path
        stores[main.repository.root.path] = main
        main.project = self
    }

    /// The main checkout first, then Claude's worktrees by name. The main checkout uses the project's root path.
    var worktrees: [Worktree] {
        let list = main.worktrees.filter { $0.isMain || $0.isClaude }.map { worktree in
            worktree.isMain ? Worktree(path: root.path, head: worktree.head, branch: worktree.branch, isBare: worktree.isBare,
                                       isDetached: worktree.isDetached, isLocked: worktree.isLocked, lockReason: worktree.lockReason,
                                       isPrunable: worktree.isPrunable, isMain: true) : worktree
        }
        return list.filter(\.isMain) + list.filter { !$0.isMain }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var agents: [Worktree] { worktrees.filter { !$0.isMain } }

    func worktree(at path: String) -> Worktree? {
        let key = Self.normalize(path)
        return worktrees.first { Self.normalize($0.path) == key }
    }

    /// Paths from git, the file system and saved state can differ by symlinks (/tmp vs /private/tmp).
    static func normalize(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// The path the worktree list uses for `path`, so stores and terminals are keyed consistently.
    func canonicalPath(_ path: String) -> String {
        if Self.normalize(path) == Self.normalize(root.path) { return root.path }
        return worktree(at: path)?.path ?? path
    }

    func start() { main.start() }

    func stop() {
        terminals.values.forEach { $0.close() }
        shells.values.forEach { $0.close() }
        stores.values.forEach { $0.stop() }
    }

    /// The store for a worktree, started on first use.
    func store(for path: String) -> RepoStore {
        let path = canonicalPath(path)
        if let store = stores[path] { return store }
        let store = RepoStore(repository: Repository(root: URL(fileURLWithPath: path)), primary: main)
        store.project = self
        stores[path] = store
        store.start()
        return store
    }

    // MARK: Agent state

    func sessions(for path: String) -> [ClaudeSession] {
        main.claudeSessions[gitPath(path)]?.sessions ?? []
    }

    /// The path as `git worktree list` spells it (the key for statuses and sessions).
    func gitPath(_ path: String) -> String {
        let key = Self.normalize(path)
        return main.worktrees.first { Self.normalize($0.path) == key }?.path ?? path
    }

    func status(for path: String) -> WorktreeStatus? { main.worktreeStatus[gitPath(path)] }

    /// The session shown for a worktree: the one its terminal runs, else the most recent.
    func currentSession(for path: String) -> ClaudeSession? {
        let all = sessions(for: path)
        if let id = terminalSessionIDs[path], let match = all.first(where: { $0.id == id }) { return match }
        return all.first
    }

    func state(for path: String) -> AgentState {
        if let terminal = terminals[path], !terminal.isClosed {
            if terminal.needsAttention { return .needsInput }
            if terminal.progressActive { return .working }
            if currentSession(for: path)?.isWorking() == true { return .working }
            return .idle
        }
        return sessions(for: path).contains { $0.isWorking() } ? .working : .dormant
    }

    var needsInputCount: Int { worktrees.filter { state(for: $0.path) == .needsInput }.count }
    var workingCount: Int { worktrees.filter { state(for: $0.path) == .working }.count }

    // MARK: Terminals

    func terminal(for path: String) -> TerminalSession? {
        terminals[path].flatMap { $0.isClosed ? nil : $0 }
    }

    func shell(for path: String) -> TerminalSession? {
        shells[path].flatMap { $0.isClosed ? nil : $0 }
    }

    /// Starts Claude in the worktree: a new conversation, a resumed one, or a plain shell.
    enum Launch {
        /// A new Claude Code conversation (Forest assigns its session id).
        case newSession(prompt: String?)
        case resume(sessionID: String, prompt: String? = nil)
        /// A new session of another agent CLI (Codex, Gemini, a custom command).
        case agent(AgentTool, prompt: String?)
        /// That agent's most recent session in this worktree.
        case continueAgent(AgentTool)
        case shell
    }

    /// The agent each worktree's terminal last ran.
    private(set) var tools: [String: AgentTool] = [:]

    func tool(for path: String) -> AgentTool {
        tools[path] ?? WorkspaceStore.shared.rememberedTool(for: path) ?? (sessions(for: path).isEmpty ? Preferences.agentTool : .claude)
    }

    @discardableResult
    func launch(_ launch: Launch, in path: String) -> TerminalSession {
        terminals[path]?.close()
        var input: String?
        switch launch {
        case .newSession(let prompt):
            let id = UUID().uuidString.lowercased()
            terminalSessionIDs[path] = id
            input = claudeCommand(["--session-id", id], prompt: prompt)
        case .resume(let id, let prompt):
            terminalSessionIDs[path] = id
            input = claudeCommand(["--resume", id], prompt: prompt)
        case .agent(let tool, let prompt):
            if tool == .claude { return self.launch(.newSession(prompt: prompt), in: path) }
            terminalSessionIDs[path] = nil
            input = tool.newSessionCommand(prompt: prompt)
        case .continueAgent(let tool):
            if tool == .claude {
                if let latest = sessions(for: path).first { return self.launch(.resume(sessionID: latest.id), in: path) }
                return self.launch(.newSession(prompt: nil), in: path)
            }
            terminalSessionIDs[path] = nil
            input = tool.continueCommand ?? tool.newSessionCommand(prompt: nil)
        case .shell:
            terminalSessionIDs[path] = nil
        }
        switch launch {
        case .newSession, .resume: tools[path] = .claude
        case .agent(let tool, _), .continueAgent(let tool): tools[path] = tool
        case .shell: break
        }
        if let tool = tools[path] { WorkspaceStore.shared.rememberTool(tool, for: path) }
        let session = makeTerminal(in: path, input: input)
        terminals[path] = session
        WorkspaceStore.shared.rememberTerminal(path: path, sessionID: terminalSessionIDs[path])
        return session
    }

    /// Opens (or focuses) the secondary shell under the worktree's main terminal.
    func toggleShell(for path: String) {
        if let shell = shell(for: path) {
            shell.close()
            shells[path] = nil
        } else {
            shells[path] = makeTerminal(in: path, input: nil)
        }
    }

    func closeTerminal(for path: String) {
        terminals[path]?.close()
        terminals[path] = nil
        terminalSessionIDs[path] = nil
        WorkspaceStore.shared.rememberTerminal(path: path, sessionID: nil)
    }

    private func makeTerminal(in path: String, input: String?) -> TerminalSession {
        let session = TerminalSession(directory: URL(fileURLWithPath: path), initialInput: input.map { $0 + "\n" },
                                      environment: ["FOREST_WORKTREE": path])
        session.onClose = { [weak self] closed in
            guard let self else { return }
            if self.terminals[path] === closed { self.terminals[path] = nil }
            if self.shells[path] === closed { self.shells[path] = nil }
        }
        session.onAttention = { _ in WorkspaceStore.shared.updateDockBadge() }
        return session
    }

    private func claudeCommand(_ arguments: [String], prompt: String?) -> String {
        let executable = ClaudeCode.locateCLI(override: Preferences.claudePath) ?? "claude"
        var parts = [Launcher.shellQuote(executable)] + arguments.map(Launcher.shellQuote)
        let extra = Preferences.claudeArguments.trimmingCharacters(in: .whitespaces)
        if !extra.isEmpty { parts.append(extra) }
        if let prompt = prompt?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty {
            parts.append(Launcher.shellQuote(prompt))
        }
        return parts.joined(separator: " ")
    }


    // MARK: Agent actions

    /// Continues the worktree's latest conversation with the agent it last ran (or starts one when there is none).
    func continueLatest(in path: String) {
        launch(.continueAgent(tool(for: path)), in: path)
    }

    /// Called after Forest created an agent worktree: start the agent there with its task.
    func agentCreated(at path: String, task: String?, tool: AgentTool = Preferences.agentTool) {
        if let task { launch(.agent(tool, prompt: task), in: path) }
        WorkspaceStore.shared.select(project: self, worktree: path)
    }

    /// Sends a follow-up to the agent: typed into its running session, or by resuming the last one.
    func send(_ text: String, to worktree: Worktree) {
        let path = worktree.path
        if let terminal = terminal(for: path), terminalSessionIDs[path] != nil {
            terminal.send(text, submit: true)
        } else if tool(for: path) != .claude {
            launch(.agent(tool(for: path), prompt: text), in: path)
        } else if let session = sessions(for: path).first {
            launch(.resume(sessionID: session.id, prompt: text), in: path)
        } else {
            launch(.newSession(prompt: text), in: path)
        }
        WorkspaceStore.shared.select(project: self, worktree: path)
        store(for: path).sidebar = .terminal
    }

    func worktreeWillBeRemoved(_ path: String) {
        terminals[path]?.close()
        shells[path]?.close()
        terminals[path] = nil
        shells[path] = nil
        stores[path]?.stop()
        stores[path] = nil
        WorkspaceStore.shared.rememberTerminal(path: path, sessionID: nil)
        if WorkspaceStore.shared.selection?.worktree == path {
            WorkspaceStore.shared.select(project: self, worktree: root.path)
        }
    }
}
