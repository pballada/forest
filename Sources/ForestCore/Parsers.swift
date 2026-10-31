import Foundation

enum Separators {
    static let field = "\u{1f}"
    static let record = "\u{1e}"
}

public enum LogParser {
    /// `git log --format=` string matching `parse(_:)`.
    public static let format = ["%H", "%P", "%an", "%ae", "%at", "%cn", "%ct", "%s"]
        .joined(separator: "%x1f") + "%x1e"

    public static func parse(_ output: String) -> [Commit] {
        output.components(separatedBy: Separators.record).compactMap { record in
            let trimmed = record.trimmingCharacters(in: .newlines)
            guard !trimmed.isEmpty else { return nil }
            let fields = trimmed.components(separatedBy: Separators.field)
            guard fields.count >= 8 else { return nil }
            return Commit(
                id: fields[0],
                parents: fields[1].split(separator: " ").map(String.init),
                authorName: fields[2],
                authorEmail: fields[3],
                authorDate: Date(timeIntervalSince1970: TimeInterval(fields[4]) ?? 0),
                committerName: fields[5],
                commitDate: Date(timeIntervalSince1970: TimeInterval(fields[6]) ?? 0),
                subject: fields[7...].joined(separator: Separators.field)
            )
        }
    }
}

public struct RefSnapshot: Sendable {
    public var localBranches: [Branch] = []
    public var remoteBranches: [Branch] = []
    public var tags: [Tag] = []
    /// Decorations keyed by commit sha.
    public var labels: [String: [RefLabel]] = [:]
}

public enum RefParser {
    public static let format = [
        "%(refname)", "%(objectname)", "%(*objectname)", "%(upstream:short)", "%(upstream:track)",
        "%(HEAD)", "%(creatordate:unix)", "%(contents:subject)", "%(worktreepath)",
    ].joined(separator: "%1f")

    public static func parse(_ output: String) -> RefSnapshot {
        var snapshot = RefSnapshot()
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let f = line.components(separatedBy: Separators.field)
            guard f.count >= 9 else { continue }
            let refname = f[0]
            let sha = f[2].isEmpty ? f[1] : f[2]
            let date = Date(timeIntervalSince1970: TimeInterval(f[6]) ?? 0)
            let track = parseTrack(f[4])
            let isHead = f[5] == "*"

            if refname.hasPrefix("refs/heads/") {
                let name = String(refname.dropFirst("refs/heads/".count))
                snapshot.localBranches.append(Branch(
                    name: name, fullName: refname, sha: sha, isRemote: false,
                    upstream: f[3].isEmpty ? nil : f[3], ahead: track.ahead, behind: track.behind,
                    upstreamGone: track.gone, isHead: isHead, date: date, subject: f[7],
                    worktreePath: f[8].isEmpty ? nil : f[8]))
                snapshot.labels[sha, default: []].append(RefLabel(name: name, kind: .localBranch, isHead: isHead))
            } else if refname.hasPrefix("refs/remotes/") {
                let name = String(refname.dropFirst("refs/remotes/".count))
                if name.hasSuffix("/HEAD") { continue }
                snapshot.remoteBranches.append(Branch(
                    name: name, fullName: refname, sha: sha, isRemote: true, upstream: nil, ahead: 0, behind: 0,
                    upstreamGone: false, isHead: false, date: date, subject: f[7], worktreePath: nil))
                snapshot.labels[sha, default: []].append(RefLabel(name: name, kind: .remoteBranch, isHead: false))
            } else if refname.hasPrefix("refs/tags/") {
                let name = String(refname.dropFirst("refs/tags/".count))
                snapshot.tags.append(Tag(name: name, sha: sha, date: date, subject: f[7]))
                snapshot.labels[sha, default: []].append(RefLabel(name: name, kind: .tag, isHead: false))
            }
        }
        snapshot.tags.sort { $0.date > $1.date }
        return snapshot
    }

    /// Parses `[ahead 1, behind 2]` / `[gone]`.
    static func parseTrack(_ track: String) -> (ahead: Int, behind: Int, gone: Bool) {
        if track.contains("gone") { return (0, 0, true) }
        func value(_ key: String) -> Int {
            guard let range = track.range(of: key + " ") else { return 0 }
            let digits = track[range.upperBound...].prefix { $0.isNumber }
            return Int(digits) ?? 0
        }
        return (value("ahead"), value("behind"), false)
    }
}

public enum StatusParser {
    /// Parses `git status --porcelain=v2 --branch -z`.
    public static func parse(_ data: Data) -> RepoStatus {
        var status = RepoStatus()
        let tokens = String(decoding: data, as: UTF8.self).components(separatedBy: "\0")
        var i = 0
        while i < tokens.count {
            let token = tokens[i]
            i += 1
            guard let kind = token.first else { continue }
            switch kind {
            case "#":
                parseHeader(token, into: &status)
            case "1":
                let parts = token.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false)
                guard parts.count == 9 else { continue }
                addEntry(xy: parts[1], path: String(parts[8]), original: nil, to: &status)
            case "2":
                let parts = token.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: false)
                guard parts.count == 10 else { continue }
                let original = i < tokens.count ? tokens[i] : nil
                i += 1
                addEntry(xy: parts[1], path: String(parts[9]), original: original, to: &status)
            case "u":
                let parts = token.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
                guard parts.count == 11 else { continue }
                status.conflicted.append(FileChange(path: String(parts[10]), status: .conflicted, staged: false))
            case "?":
                let path = String(token.dropFirst(2))
                status.unstaged.append(FileChange(path: path, status: .untracked, staged: false))
            default:
                continue
            }
        }
        return status
    }

    private static func parseHeader(_ line: String, into status: inout RepoStatus) {
        let parts = line.split(separator: " ")
        guard parts.count >= 3 else { return }
        switch parts[1] {
        case "branch.oid":
            status.headSHA = parts[2] == "(initial)" ? nil : String(parts[2])
        case "branch.head":
            status.branch = parts[2] == "(detached)" ? nil : parts[2...].joined(separator: " ")
        case "branch.upstream":
            status.upstream = String(parts[2])
        case "branch.ab":
            guard parts.count >= 4 else { return }
            status.ahead = Int(parts[2].dropFirst()) ?? 0
            status.behind = Int(parts[3].dropFirst()) ?? 0
        default:
            break
        }
    }

    private static func addEntry(xy: Substring, path: String, original: String?, to status: inout RepoStatus) {
        let codes = Array(xy)
        guard codes.count == 2 else { return }
        if codes[0] != "." {
            status.staged.append(FileChange(path: path, originalPath: original, status: ChangeStatus(code: codes[0]), staged: true))
        }
        if codes[1] != "." {
            // Renames are only tracked in the index; the worktree side is a plain modification.
            status.unstaged.append(FileChange(path: path, status: ChangeStatus(code: codes[1]), staged: false))
        }
    }
}

public enum WorktreeParser {
    /// Parses `git worktree list --porcelain -z`.
    public static func parse(_ data: Data) -> [Worktree] {
        let text = String(decoding: data, as: UTF8.self)
        var result: [Worktree] = []
        var fields: [String: String] = [:]
        var flags = Set<String>()

        func flush() {
            guard let path = fields["worktree"] else { return }
            var branch = fields["branch"]
            if let b = branch, b.hasPrefix("refs/heads/") { branch = String(b.dropFirst("refs/heads/".count)) }
            result.append(Worktree(
                path: path, head: fields["HEAD"], branch: branch,
                isBare: flags.contains("bare"), isDetached: flags.contains("detached"),
                isLocked: flags.contains("locked"), lockReason: fields["locked"],
                isPrunable: flags.contains("prunable"), isMain: result.isEmpty))
            fields = [:]
            flags = []
        }

        for token in text.components(separatedBy: "\0") {
            if token.isEmpty {
                flush()
                continue
            }
            if let space = token.firstIndex(of: " ") {
                let key = String(token[..<space])
                fields[key] = String(token[token.index(after: space)...])
                flags.insert(key)
            } else {
                flags.insert(token)
            }
        }
        flush()
        return result
    }
}

public enum StashParser {
    public static let format = "%gd%x1f%H%x1f%ct%x1f%gs%x1e"

    public static func parse(_ output: String) -> [Stash] {
        output.components(separatedBy: Separators.record).compactMap { record in
            let fields = record.trimmingCharacters(in: .newlines).components(separatedBy: Separators.field)
            guard fields.count >= 4 else { return nil }
            let ref = fields[0]
            guard let open = ref.firstIndex(of: "{"), let close = ref.firstIndex(of: "}"),
                  let index = Int(ref[ref.index(after: open)..<close]) else { return nil }
            return Stash(index: index, sha: fields[1],
                         date: Date(timeIntervalSince1970: TimeInterval(fields[2]) ?? 0),
                         message: fields[3])
        }
    }
}

public enum NameStatusParser {
    /// Parses `git diff --name-status -z` together with `git diff --numstat -z`.
    public static func parse(nameStatus: Data, numstat: Data?) -> [FileChange] {
        let tokens = String(decoding: nameStatus, as: UTF8.self).components(separatedBy: "\0")
        var changes: [FileChange] = []
        var i = 0
        while i < tokens.count {
            let code = tokens[i]
            i += 1
            guard let letter = code.first, i < tokens.count else { continue }
            if letter == "R" || letter == "C" {
                guard i + 1 < tokens.count else { break }
                changes.append(FileChange(path: tokens[i + 1], originalPath: tokens[i], status: ChangeStatus(code: letter), staged: false))
                i += 2
            } else {
                changes.append(FileChange(path: tokens[i], status: ChangeStatus(code: letter), staged: false))
                i += 1
            }
        }
        guard let numstat else { return changes }
        let counts = parseNumstat(numstat)
        return changes.map { change in
            var c = change
            if let n = counts[change.path] {
                c.additions = n.0
                c.deletions = n.1
            }
            return c
        }
    }

    static func parseNumstat(_ data: Data) -> [String: (Int, Int)] {
        // With -z, renames are emitted as `add\tdel\t\0old\0new\0`.
        let tokens = String(decoding: data, as: UTF8.self).components(separatedBy: "\0")
        var result: [String: (Int, Int)] = [:]
        var i = 0
        while i < tokens.count {
            let parts = tokens[i].split(separator: "\t", omittingEmptySubsequences: false)
            i += 1
            guard parts.count >= 3 else { continue }
            let adds = Int(parts[0]) ?? 0
            let dels = Int(parts[1]) ?? 0
            if parts[2].isEmpty {
                guard i + 1 < tokens.count else { break }
                result[tokens[i + 1]] = (adds, dels)
                i += 2
            } else {
                result[String(parts[2])] = (adds, dels)
            }
        }
        return result
    }
}
