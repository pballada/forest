import Foundation

public struct Commit: Identifiable, Hashable, Sendable {
    public let id: String
    public let parents: [String]
    public let authorName: String
    public let authorEmail: String
    public let authorDate: Date
    public let committerName: String
    public let commitDate: Date
    public let subject: String

    public init(id: String, parents: [String], authorName: String, authorEmail: String, authorDate: Date,
                committerName: String, commitDate: Date, subject: String) {
        self.id = id
        self.parents = parents
        self.authorName = authorName
        self.authorEmail = authorEmail
        self.authorDate = authorDate
        self.committerName = committerName
        self.commitDate = commitDate
        self.subject = subject
    }

    public var sha: String { id }
    public var shortSHA: String { String(id.prefix(7)) }
    public var isMerge: Bool { parents.count > 1 }
}

public enum RefKind: String, Hashable, Sendable {
    case localBranch, remoteBranch, tag, stash
}

/// A ref decoration shown next to a commit in the graph.
public struct RefLabel: Hashable, Sendable, Identifiable {
    public let name: String
    public let kind: RefKind
    public let isHead: Bool
    public var id: String { "\(kind.rawValue):\(name)" }
}

public struct Branch: Identifiable, Hashable, Sendable {
    public let name: String
    public let fullName: String
    public let sha: String
    public let isRemote: Bool
    public let upstream: String?
    public let ahead: Int
    public let behind: Int
    public let upstreamGone: Bool
    public let isHead: Bool
    public let date: Date
    public let subject: String
    /// Path of the worktree this branch is checked out in, if any.
    public let worktreePath: String?

    public var id: String { fullName }

    public var remoteName: String? {
        guard isRemote else { return nil }
        return name.split(separator: "/", maxSplits: 1).first.map(String.init)
    }

    /// For `origin/feature/x` returns `feature/x`.
    public var nameWithoutRemote: String {
        guard isRemote, let slash = name.firstIndex(of: "/") else { return name }
        return String(name[name.index(after: slash)...])
    }
}

public struct Tag: Identifiable, Hashable, Sendable {
    public let name: String
    public let sha: String
    public let date: Date
    public let subject: String
    public var id: String { name }
}

public struct Remote: Identifiable, Hashable, Sendable {
    public let name: String
    public let fetchURL: String
    public let pushURL: String
    public var id: String { name }

    /// A browsable https URL for common hosts, e.g. `git@github.com:a/b.git` → `https://github.com/a/b`.
    public var webURL: URL? {
        var url = fetchURL
        if url.hasPrefix("git@") {
            url = url.replacingOccurrences(of: "git@", with: "https://")
            if let colon = url.range(of: ":", range: url.index(url.startIndex, offsetBy: 8)..<url.endIndex) {
                url.replaceSubrange(colon, with: "/")
            }
        } else if url.hasPrefix("ssh://git@") {
            url = url.replacingOccurrences(of: "ssh://git@", with: "https://")
        }
        if url.hasSuffix(".git") { url.removeLast(4) }
        return url.hasPrefix("http") ? URL(string: url) : nil
    }
}

public struct Stash: Identifiable, Hashable, Sendable {
    public let index: Int
    public let sha: String
    public let date: Date
    public let message: String
    public var ref: String { "stash@{\(index)}" }
    public var id: String { sha }
}

public enum ChangeStatus: String, Hashable, Sendable {
    case modified, added, deleted, renamed, copied, typeChanged, untracked, conflicted

    init(code: Character) {
        switch code {
        case "A": self = .added
        case "D": self = .deleted
        case "R": self = .renamed
        case "C": self = .copied
        case "T": self = .typeChanged
        case "U": self = .conflicted
        case "?": self = .untracked
        default: self = .modified
        }
    }

    public var letter: String {
        switch self {
        case .modified: "M"
        case .added: "A"
        case .deleted: "D"
        case .renamed: "R"
        case .copied: "C"
        case .typeChanged: "T"
        case .untracked: "?"
        case .conflicted: "!"
        }
    }
}

/// One file in the working copy, the index, or a commit.
public struct FileChange: Identifiable, Hashable, Sendable {
    public let path: String
    public let originalPath: String?
    public let status: ChangeStatus
    public let staged: Bool
    public var additions: Int?
    public var deletions: Int?

    public init(path: String, originalPath: String? = nil, status: ChangeStatus, staged: Bool,
                additions: Int? = nil, deletions: Int? = nil) {
        self.path = path
        self.originalPath = originalPath
        self.status = status
        self.staged = staged
        self.additions = additions
        self.deletions = deletions
    }

    public var id: String { "\(staged ? "S" : "W"):\(path)" }
    public var fileName: String { (path as NSString).lastPathComponent }
    public var directory: String {
        let dir = (path as NSString).deletingLastPathComponent
        return dir.isEmpty ? "" : dir
    }
}

public struct RepoStatus: Hashable, Sendable {
    public var branch: String?
    public var headSHA: String?
    public var upstream: String?
    public var ahead = 0
    public var behind = 0
    public var staged: [FileChange] = []
    public var unstaged: [FileChange] = []
    public var conflicted: [FileChange] = []

    public init() {}

    public var isDetached: Bool { branch == nil }
    public var isClean: Bool { staged.isEmpty && unstaged.isEmpty && conflicted.isEmpty }
    public var changeCount: Int {
        Set(staged.map(\.path) + unstaged.map(\.path) + conflicted.map(\.path)).count
    }
}

/// A multi-step operation that is paused waiting for the user (usually because of conflicts).
public enum RepoOperation: String, Hashable, Sendable {
    case none, merging, rebasing, cherryPicking, reverting, bisecting

    public var title: String {
        switch self {
        case .none: ""
        case .merging: "Merge in progress"
        case .rebasing: "Rebase in progress"
        case .cherryPicking: "Cherry-pick in progress"
        case .reverting: "Revert in progress"
        case .bisecting: "Bisect in progress"
        }
    }

    var command: String? {
        switch self {
        case .merging: "merge"
        case .rebasing: "rebase"
        case .cherryPicking: "cherry-pick"
        case .reverting: "revert"
        case .bisecting, .none: nil
        }
    }
}

public enum ResetMode: String, CaseIterable, Sendable {
    case soft, mixed, hard
}

public enum PullStrategy: String, CaseIterable, Sendable, Identifiable {
    case fastForwardOnly, merge, rebase
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .fastForwardOnly: "Fast-forward only"
        case .merge: "Merge"
        case .rebase: "Rebase"
        }
    }
}

public struct Worktree: Identifiable, Hashable, Sendable {
    public let path: String
    public let head: String?
    /// Short branch name, nil when detached.
    public let branch: String?
    public let isBare: Bool
    public let isDetached: Bool
    public let isLocked: Bool
    public let lockReason: String?
    public let isPrunable: Bool
    public let isMain: Bool

    public var id: String { path }
    public var name: String { (path as NSString).lastPathComponent }
    public var url: URL { URL(fileURLWithPath: path) }
    /// Claude Code creates its worktrees under `<repo>/.claude/worktrees/<name>`.
    public var isClaude: Bool { ClaudeCode.isClaudeWorktree(path: path) }
}

public struct WorktreeStatus: Hashable, Sendable {
    public var changed = 0
    public var staged = 0
    public var untracked = 0
    public var conflicted = 0
    public var ahead = 0
    public var behind = 0
    public var upstream: String?
    public var lastCommit: Commit?
    public var missing = false

    public init() {}

    public var isDirty: Bool { changed + staged + untracked + conflicted > 0 }
}
