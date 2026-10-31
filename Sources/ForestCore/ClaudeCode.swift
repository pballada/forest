import Foundation

/// What Forest can learn about Claude Code activity in a worktree from `~/.claude/projects`.
public struct ClaudeSessionInfo: Hashable, Sendable {
    public let sessionCount: Int
    public let lastActivity: Date?
    /// The first prompt of the most recent session — a good proxy for "what is this agent doing".
    public let task: String?
    /// The title Claude Code generated for the most recent session, when available.
    public let title: String?
    /// Pull request opened from the session, if Claude Code recorded one.
    public let pullRequestURL: URL?

    /// Transcripts are appended to while a session runs, so a fresh write means it is live.
    public var isActive: Bool {
        guard let lastActivity else { return false }
        return Date().timeIntervalSince(lastActivity) < 90
    }
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

    public static func sessionInfo(for path: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> ClaudeSessionInfo? {
        let directory = projectDirectory(for: path, home: home)
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey],
                                                       options: [.skipsHiddenFiles]) else { return nil }
        let transcripts = files.filter { $0.pathExtension == "jsonl" }
            .map { url -> (URL, Date) in
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return (url, date)
            }
            .sorted { $0.1 > $1.1 }
        guard let latest = transcripts.first else { return nil }
        let transcript = readTranscript(latest.0)
        return ClaudeSessionInfo(sessionCount: transcripts.count, lastActivity: latest.1, task: transcript.task,
                                 title: transcript.title, pullRequestURL: transcript.pullRequest)
    }

    /// Scans a transcript for the first user prompt, the latest AI title and any PR link.
    /// Only lines that can matter are JSON-decoded, so multi-megabyte transcripts stay cheap.
    static func readTranscript(_ url: URL) -> (task: String?, title: String?, pullRequest: URL?) {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return (nil, nil, nil) }
        var task: String?
        var title: String?
        var pullRequest: URL?
        for line in data.split(separator: UInt8(ascii: "\n")) {
            let head = String(decoding: line.prefix(200), as: UTF8.self)
            let interesting = head.contains("\"ai-title\"") || head.contains("\"pr-link\"")
                || (task == nil && head.contains("\"type\":\"user\""))
            guard interesting, let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            switch object["type"] as? String {
            case "ai-title":
                title = object["aiTitle"] as? String ?? title
            case "pr-link":
                if let string = object["prUrl"] as? String { pullRequest = URL(string: string) }
            case "user" where task == nil && object["isMeta"] as? Bool != true && object["isSidechain"] as? Bool != true:
                if let message = object["message"] as? [String: Any] { task = promptText(message["content"]) }
            default:
                break
            }
        }
        return (task, title, pullRequest)
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
