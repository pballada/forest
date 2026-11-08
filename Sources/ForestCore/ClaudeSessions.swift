import Foundation

/// One Claude Code conversation, read from its transcript in `~/.claude/projects/<encoded cwd>/<id>.jsonl`.
public struct ClaudeSession: Identifiable, Hashable, Sendable {
    /// The session UUID: the transcript's file name, and what `claude --resume <id>` takes.
    public let id: String
    public var title: String?
    /// The first prompt typed in the session: a good proxy for "what is this agent doing".
    public var firstPrompt: String?
    /// The most recent prompt, as Claude Code records it for `/resume`.
    public var lastPrompt: String?
    public var lastActivity: Date
    /// Messages in the conversation at the end of the last completed turn.
    public var messageCount: Int
    public var pullRequestURL: URL?
    public var gitBranch: String?
    /// True once Claude finished its last turn and is waiting for the next prompt.
    public var turnEnded: Bool

    public init(id: String, title: String? = nil, firstPrompt: String? = nil, lastPrompt: String? = nil,
                lastActivity: Date, messageCount: Int = 0, pullRequestURL: URL? = nil, gitBranch: String? = nil,
                turnEnded: Bool = false) {
        self.id = id
        self.title = title
        self.firstPrompt = firstPrompt
        self.lastPrompt = lastPrompt
        self.lastActivity = lastActivity
        self.messageCount = messageCount
        self.pullRequestURL = pullRequestURL
        self.gitBranch = gitBranch
        self.turnEnded = turnEnded
    }

    public var displayTitle: String { title ?? firstPrompt ?? "Untitled session" }

    /// Claude writes to the transcript continuously while a turn runs.
    public func isWorking(now: Date = Date()) -> Bool {
        !turnEnded && now.timeIntervalSince(lastActivity) < 90
    }
}

/// What an agent is doing right now, from the transcript and (when Forest hosts it) the terminal.
public enum AgentState: String, Sendable, Hashable {
    /// Claude is running a turn.
    case working
    /// Claude asked for something: a permission, an answer, or it rang the bell.
    case needsInput
    /// A session is open in Forest and waiting for the next prompt.
    case idle
    /// No live terminal in Forest; the session can be continued.
    case dormant
}

/// Reads and caches Claude Code transcripts. Transcripts grow to tens of megabytes and are appended to
/// constantly, so each one is parsed once and then only from where the last read stopped.
public final class ClaudeSessionIndex: @unchecked Sendable {
    /// `FOREST_CLAUDE_HOME` points Forest at another home's `.claude` (demos and screenshots).
    public static let shared = ClaudeSessionIndex(home: ProcessInfo.processInfo.environment["FOREST_CLAUDE_HOME"]
        .map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser)

    private struct Entry {
        var offset: UInt64 = 0
        var session: ClaudeSession
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private let home: URL

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }

    /// Every session recorded for `path` (a worktree or the main checkout), most recent first.
    public func sessions(for path: String) -> [ClaudeSession] {
        let directory = ClaudeCode.projectDirectory(for: path, home: home)
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys,
                                                                        options: [.skipsHiddenFiles]) else { return [] }
        return files.filter { $0.pathExtension == "jsonl" }
            .compactMap { url -> ClaudeSession? in
                let values = try? url.resourceValues(forKeys: Set(keys))
                return session(at: url, modified: values?.contentModificationDate ?? .distantPast,
                               size: UInt64(values?.fileSize ?? 0))
            }
            // Transcripts without a single prompt are bookkeeping from sessions that never started.
            .filter { $0.firstPrompt != nil || $0.title != nil }
            .sorted { $0.lastActivity > $1.lastActivity }
    }

    private func session(at url: URL, modified: Date, size: UInt64) -> ClaudeSession? {
        let key = url.path
        lock.lock()
        var entry = entries[key] ?? Entry(session: ClaudeSession(id: url.deletingPathExtension().lastPathComponent, lastActivity: modified))
        lock.unlock()
        if size < entry.offset {
            // Rewritten from scratch (rare); start over.
            entry = Entry(session: ClaudeSession(id: entry.session.id, lastActivity: modified))
        }
        if size > entry.offset, let handle = try? FileHandle(forReadingFrom: url) {
            defer { try? handle.close() }
            try? handle.seek(toOffset: entry.offset)
            if let data = try? handle.readToEnd(), let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) {
                let complete = data[data.startIndex...lastNewline]
                ClaudeCode.apply(transcript: complete, to: &entry.session)
                entry.offset += UInt64(complete.count)
            }
        }
        entry.session.lastActivity = modified
        lock.lock()
        entries[key] = entry
        lock.unlock()
        return entry.session
    }
}

extension ClaudeCode {
    /// Folds transcript lines into `session`. Only lines that can matter are JSON-decoded:
    /// their `type` appears near the start, while assistant lines (huge) are skipped by the prefix check.
    static func apply(transcript data: Data, to session: inout ClaudeSession) {
        for line in data.split(separator: UInt8(ascii: "\n")) {
            let head = String(decoding: line.prefix(240), as: UTF8.self)
            let isUser = head.contains("\"type\":\"user\"")
            let isTurnEnd = head.contains("\"subtype\":\"turn_duration\"")
            let interesting = isUser || isTurnEnd || head.contains("\"ai-title\"") || head.contains("\"pr-link\"")
                || head.contains("\"last-prompt\"")
            guard interesting, let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            switch object["type"] as? String {
            case "ai-title":
                session.title = object["aiTitle"] as? String ?? session.title
            case "pr-link":
                if let string = object["prUrl"] as? String { session.pullRequestURL = URL(string: string) }
            case "last-prompt":
                if let prompt = object["lastPrompt"] as? String { session.lastPrompt = prompt }
            case "system" where isTurnEnd:
                session.turnEnded = true
                if let count = object["messageCount"] as? Int { session.messageCount = count }
            case "user" where object["isMeta"] as? Bool != true && object["isSidechain"] as? Bool != true:
                if let branch = object["gitBranch"] as? String, branch != "HEAD" { session.gitBranch = branch }
                guard let message = object["message"] as? [String: Any], let prompt = promptText(message["content"]) else { continue }
                // A typed prompt starts a turn; tool results recorded as user turns do not.
                session.turnEnded = false
                if session.firstPrompt == nil { session.firstPrompt = prompt }
            default:
                break
            }
        }
    }
}
