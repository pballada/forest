import Foundation
import ForestCore

enum TerminalApp: String, CaseIterable, Identifiable {
    case terminal = "Terminal", iTerm = "iTerm", ghostty = "Ghostty", warp = "Warp"
    var id: String { rawValue }
}

/// The coding agent Forest starts in a worktree's terminal.
enum AgentTool: String, CaseIterable, Identifiable {
    case claude, codex, gemini, custom
    var id: String { rawValue }

    var name: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .gemini: "Gemini CLI"
        case .custom: "Custom"
        }
    }

    /// The command that starts a new session, with an optional first prompt.
    func newSessionCommand(prompt: String?) -> String {
        let prompt = prompt?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty.map(Launcher.shellQuote)
        switch self {
        case .claude: return ["claude", prompt].compactMap { $0 }.joined(separator: " ")
        case .codex: return ["codex", prompt].compactMap { $0 }.joined(separator: " ")
        case .gemini: return ["gemini", prompt.map { "-i " + $0 }].compactMap { $0 }.joined(separator: " ")
        case .custom: return [Preferences.customAgentCommand.nilIfEmpty ?? "$SHELL", prompt].compactMap { $0 }.joined(separator: " ")
        }
    }

    /// Continues the most recent session started in the current directory, when the tool supports it.
    var continueCommand: String? {
        switch self {
        case .claude: "claude --continue"
        case .codex: "codex resume --last"
        case .gemini: "gemini --resume latest"
        case .custom: nil
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

enum EditorApp: String, CaseIterable, Identifiable {
    case vscode = "Visual Studio Code", cursor = "Cursor", zed = "Zed", xcode = "Xcode", sublime = "Sublime Text", nova = "Nova"
    var id: String { rawValue }
}

/// UserDefaults keys shared between `@AppStorage` in views and plain reads in models.
enum SettingsKey {
    static let pullStrategy = "pullStrategy"
    static let historyLimit = "historyLimit"
    static let terminal = "terminalApp"
    static let editor = "editorApp"
    static let claudePath = "claudePath"
    static let claudeArguments = "claudeArguments"
    static let claudeBranchPrefix = "claudeBranchPrefix"
    static let agentTool = "agentTool"
    static let soundNeedsInput = "alert.soundNeedsInput"
    static let soundFinished = "alert.soundFinished"
    static let soundOnlyInBackground = "alert.onlyInBackground"
    static let agentNotifications = "alert.notifications"
    static let customAgentCommand = "customAgentCommand"
    static let recentRepositories = "recentRepositories"
    static let claudeModel = "claudeModel"
    static let aiFeatures = "aiFeatures"
    static let diffFullFile = "diff.fullFile"
    static let diffIgnoreWhitespace = "diff.ignoreWhitespace"
    static let celebrate = "celebrate"
    static let pullRequests = "pullRequests"
    static let codeTheme = "codeTheme"
    static let terminalFont = "terminal.font"
    static let terminalFontSize = "terminal.fontSize"
    static let terminalOwnColors = "terminal.ownGhosttyColors"
    static let updateAutomatically = "update.automatically"
    static let updateLastCheck = "update.lastCheck"
    static let updateSkippedVersion = "update.skippedVersion"
}

enum Preferences {
    static var defaults: UserDefaults { .standard }

    static var pullStrategy: PullStrategy {
        PullStrategy(rawValue: defaults.string(forKey: SettingsKey.pullStrategy) ?? "") ?? .fastForwardOnly
    }
    static var historyLimit: Int {
        let value = defaults.integer(forKey: SettingsKey.historyLimit)
        return value > 0 ? value : 3000
    }
    static var terminal: TerminalApp { TerminalApp(rawValue: defaults.string(forKey: SettingsKey.terminal) ?? "") ?? .terminal }
    static var editor: EditorApp { EditorApp(rawValue: defaults.string(forKey: SettingsKey.editor) ?? "") ?? .vscode }
    static var claudePath: String? { defaults.string(forKey: SettingsKey.claudePath) }
    static var claudeArguments: String { defaults.string(forKey: SettingsKey.claudeArguments) ?? "" }
    /// The agent new sessions use by default.
    static var agentTool: AgentTool { AgentTool(rawValue: defaults.string(forKey: SettingsKey.agentTool) ?? "") ?? .claude }
    static var customAgentCommand: String { defaults.string(forKey: SettingsKey.customAgentCommand) ?? "" }
    static var claudeBranchPrefix: String {
        defaults.string(forKey: SettingsKey.claudeBranchPrefix) ?? ClaudeCode.defaultBranchPrefix
    }
    /// Model alias for quick headless tasks (commit messages, explanations); empty uses Claude Code's default.
    static var claudeModel: String { defaults.string(forKey: SettingsKey.claudeModel) ?? "" }
    static var aiFeatures: Bool { defaults.object(forKey: SettingsKey.aiFeatures) as? Bool ?? true }
    static var celebrate: Bool { defaults.object(forKey: SettingsKey.celebrate) as? Bool ?? true }
    static var pullRequests: Bool { defaults.object(forKey: SettingsKey.pullRequests) as? Bool ?? true }
    static var diffOptions: DiffOptions {
        DiffOptions(context: defaults.bool(forKey: SettingsKey.diffFullFile) ? DiffOptions.fullFileContext : 3,
                    ignoreWhitespace: defaults.bool(forKey: SettingsKey.diffIgnoreWhitespace))
    }
}

/// Recently opened repositories, most recent first.
@Observable
final class RecentRepositories {
    static let shared = RecentRepositories()

    private(set) var paths: [String]

    private init() {
        paths = UserDefaults.standard.stringArray(forKey: SettingsKey.recentRepositories) ?? []
    }

    func add(_ path: String) {
        paths.removeAll { $0 == path }
        paths.insert(path, at: 0)
        paths = Array(paths.prefix(20))
        save()
    }

    func remove(_ path: String) {
        paths.removeAll { $0 == path }
        save()
    }

    private func save() {
        UserDefaults.standard.set(paths, forKey: SettingsKey.recentRepositories)
    }
}
