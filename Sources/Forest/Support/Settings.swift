import Foundation
import ForestCore

enum TerminalApp: String, CaseIterable, Identifiable {
    case terminal = "Terminal", iTerm = "iTerm", ghostty = "Ghostty", warp = "Warp"
    var id: String { rawValue }
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
    static let worktreeLocation = "worktreeLocation"
    static let recentRepositories = "recentRepositories"
    static let claudeModel = "claudeModel"
    static let aiFeatures = "aiFeatures"
    static let diffFullFile = "diff.fullFile"
    static let diffIgnoreWhitespace = "diff.ignoreWhitespace"
    static let celebrate = "celebrate"
    static let pullRequests = "pullRequests"
    static let codeTheme = "codeTheme"
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
    /// "sibling" puts native worktrees next to the repo (`../repo-branch`), "nested" inside `.worktrees/`.
    static var worktreeLocation: String { defaults.string(forKey: SettingsKey.worktreeLocation) ?? "sibling" }
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
