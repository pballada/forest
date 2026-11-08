import Foundation

/// What Forest can learn about Claude Code activity in a worktree from `~/.claude/projects`.
public struct ClaudeSessionInfo: Hashable, Sendable {
    /// Every session recorded in the worktree, most recent first. Never empty.
    public let sessions: [ClaudeSession]

    public init?(sessions: [ClaudeSession]) {
        guard !sessions.isEmpty else { return nil }
        self.sessions = sessions
    }

    public var latest: ClaudeSession { sessions[0] }
    public var sessionCount: Int { sessions.count }
    public var lastActivity: Date? { latest.lastActivity }
    /// The first prompt of the most recent session.
    public var task: String? { latest.firstPrompt }
    public var title: String? { latest.title }
    public var pullRequestURL: URL? { sessions.lazy.compactMap(\.pullRequestURL).first }
    /// Claude is in the middle of a turn in one of the sessions.
    public var isActive: Bool { sessions.contains { $0.isWorking() } }
}

public enum ClaudeCode {
    public static let worktreesDirectory = ".claude/worktrees"
    public static let defaultBranchPrefix = "worktree-"

    public static func isClaudeWorktree(path: String) -> Bool {
        path.contains("/" + worktreesDirectory + "/")
    }

    public static func worktreePath(repoRoot: URL, name: String) -> URL {
        repoRoot.appendingPathComponent(worktreesDirectory).appendingPathComponent(name)
    }

    /// Claude Code stores transcripts under `~/.claude/projects/<path with / and . replaced by ->`.
    public static func projectDirectory(for path: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        let encoded = String(path.unicodeScalars.map { scalar -> Character in
            scalar.isASCII && CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "-"
        })
        return home.appendingPathComponent(".claude/projects").appendingPathComponent(encoded)
    }

    public static func sessionInfo(for path: String, index: ClaudeSessionIndex = .shared) -> ClaudeSessionInfo? {
        ClaudeSessionInfo(sessions: index.sessions(for: path))
    }

    static func promptText(_ content: Any?) -> String? {
        var text: String?
        if let string = content as? String {
            text = string
        } else if let parts = content as? [[String: Any]] {
            text = parts.first { $0["type"] as? String == "text" }?["text"] as? String
        }
        guard let raw = text?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        // Skip slash-command wrappers and tool results that Claude Code records as user turns.
        if raw.hasPrefix("<") || raw.hasPrefix("Caveat:") { return nil }
        return raw.count > 280 ? String(raw.prefix(280)) + "…" : raw
    }

    /// Locates the `claude` CLI, which is usually not on a GUI app's PATH.
    public static func locateCLI(override: String? = nil) -> String? {
        let fm = FileManager.default
        if let override, !override.isEmpty {
            return fm.isExecutableFile(atPath: override) ? override : nil
        }
        let home = fm.homeDirectoryForCurrentUser.path
        let candidates = ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude",
                          "/usr/local/bin/claude", "\(home)/.npm-global/bin/claude", "\(home)/.bun/bin/claude"]
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }

    /// Turns free text into a valid worktree/branch name: `Fix login bug!` → `fix-login-bug`.
    public static func slug(_ text: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let lowered = text.lowercased().unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        var slug = String(lowered)
        while slug.contains("--") { slug = slug.replacingOccurrences(of: "--", with: "-") }
        return slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}
