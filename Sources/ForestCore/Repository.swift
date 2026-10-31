import Foundation

/// A working tree of a git repository. Linked worktrees are repositories in their own right,
/// so the same type is used for every worktree Forest opens.
public struct Repository: Sendable, Hashable, Identifiable {
    public let root: URL
    public let git: GitRunner

    public var id: String { root.path }
    public var name: String { root.lastPathComponent }

    public init(root: URL) {
        self.root = root.standardizedFileURL
        self.git = GitRunner(directory: self.root)
    }

    // MARK: - Opening

    /// Resolves any directory inside a working tree to its top level.
    public static func open(_ url: URL) async throws -> Repository {
        let result = try await GitRunner(directory: url).run(["rev-parse", "--show-toplevel"])
        return Repository(root: URL(fileURLWithPath: result.trimmed))
    }

    public static func clone(_ remote: String, into directory: URL) async throws -> Repository {
        let parent = directory.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try await GitRunner(directory: parent).run(["clone", "--", remote, directory.path])
        return Repository(root: directory)
    }

    public static func initialize(_ directory: URL) async throws -> Repository {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try await GitRunner(directory: directory).run(["init"])
        return Repository(root: directory)
    }

    public func gitDirectory() async throws -> URL {
        URL(fileURLWithPath: try await git.run(["rev-parse", "--absolute-git-dir"]).trimmed)
    }

    /// Shared `.git` directory; differs from `gitDirectory()` inside linked worktrees.
    public func commonDirectory() async throws -> URL {
        let path = try await git.run(["rev-parse", "--git-common-dir"]).trimmed
        return URL(fileURLWithPath: path, relativeTo: root).standardizedFileURL
    }

    /// Root of the main worktree, even when called from a linked worktree.
    public func mainWorktreeRoot() async throws -> URL {
        let common = try await commonDirectory()
        return common.lastPathComponent == ".git" ? common.deletingLastPathComponent() : common
    }

    public func hasCommits() async -> Bool {
        (try? await git.run(["rev-parse", "--verify", "--quiet", "HEAD"])) != nil
    }

    // MARK: - Reading

    public func status() async throws -> RepoStatus {
        let result = try await git.run(["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all"],
                                       environment: ["GIT_OPTIONAL_LOCKS": "0"])
        return StatusParser.parse(result.stdout)
    }

    public func log(limit: Int = 2000, skip: Int = 0, revisions: [String]? = nil, path: String? = nil) async throws -> [Commit] {
        var args = ["log", "--date-order", "--format=\(LogParser.format)", "-n", "\(limit)", "--skip", "\(skip)"]
        if let revisions {
            args += revisions
        } else {
            guard await hasCommits() else { return [] }
            args += ["--branches", "--remotes", "--tags", "HEAD"]
        }
        if let path { args += ["--follow", "--", path] }
        return LogParser.parse(try await git.run(args).output)
    }

    public func refs() async throws -> RefSnapshot {
        RefParser.parse(try await git.run(["for-each-ref", "--format=\(RefParser.format)",
                                           "refs/heads", "refs/remotes", "refs/tags"]).output)
    }

    public func remotes() async throws -> [Remote] {
        let output = try await git.run(["remote", "-v"]).output
        var fetch: [String: String] = [:]
        var push: [String: String] = [:]
        var order: [String] = []
        for line in output.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == "\t" || $0 == " " }).map(String.init)
            guard parts.count >= 3 else { continue }
            if !order.contains(parts[0]) { order.append(parts[0]) }
            if parts[2] == "(push)" { push[parts[0]] = parts[1] } else { fetch[parts[0]] = parts[1] }
        }
        return order.map { Remote(name: $0, fetchURL: fetch[$0] ?? "", pushURL: push[$0] ?? fetch[$0] ?? "") }
    }

    public func stashes() async throws -> [Stash] {
        StashParser.parse(try await git.run(["stash", "list", "--format=\(StashParser.format)"]).output)
    }

    public func worktrees() async throws -> [Worktree] {
        WorktreeParser.parse(try await git.run(["worktree", "list", "--porcelain", "-z"]).stdout)
    }

    public func operation() async -> RepoOperation {
        guard let dir = try? await gitDirectory() else { return .none }
        let fm = FileManager.default
        func exists(_ name: String) -> Bool { fm.fileExists(atPath: dir.appendingPathComponent(name).path) }
        if exists("rebase-merge") || exists("rebase-apply") { return .rebasing }
        if exists("MERGE_HEAD") { return .merging }
        if exists("CHERRY_PICK_HEAD") { return .cherryPicking }
        if exists("REVERT_HEAD") { return .reverting }
        if exists("BISECT_LOG") { return .bisecting }
        return .none
    }

    public func commitMessage(_ sha: String) async throws -> String {
        try await git.run(["show", "-s", "--format=%B", sha]).output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func emptyTree() async throws -> String {
        try await git.run(["hash-object", "-t", "tree", "--stdin"], input: Data()).trimmed
    }

    /// Files changed by `sha` relative to its first parent (or the empty tree for root commits).
    public func changedFiles(in sha: String, parent: String?) async throws -> [FileChange] {
        let base = try await parentOrEmptyTree(parent)
        async let names = git.run(["diff", "--name-status", "-z", "-M", base, sha])
        async let numstat = git.run(["diff", "--numstat", "-z", "-M", base, sha])
        return NameStatusParser.parse(nameStatus: try await names.stdout, numstat: try? await numstat.stdout)
    }

    public func diff(of change: FileChange, in sha: String, parent: String?, context: Int = 3) async throws -> FileDiff? {
        let base = try await parentOrEmptyTree(parent)
        var paths = [change.path]
        if let original = change.originalPath { paths.insert(original, at: 0) }
        let output = try await git.run(["diff", "--no-ext-diff", "-M", "-U\(context)", base, sha, "--"] + paths).output
        return DiffParser.parse(output).first
    }

    /// Diff of a working-copy change: staged (HEAD→index), unstaged (index→worktree) or untracked.
    public func diff(of change: FileChange, context: Int = 3) async throws -> FileDiff? {
        let output: String
        if change.status == .untracked {
            output = try await git.run(["diff", "--no-ext-diff", "--no-index", "-U\(context)", "--", "/dev/null", change.path],
                                       allowedExitCodes: [0, 1]).output
        } else if change.staged {
            var paths = [change.path]
            if let original = change.originalPath { paths.insert(original, at: 0) }
            output = try await git.run(["diff", "--no-ext-diff", "--cached", "-M", "-U\(context)", "--"] + paths).output
        } else {
            output = try await git.run(["diff", "--no-ext-diff", "-U\(context)", "--", change.path]).output
        }
        return DiffParser.parse(output).first
    }

    public func lastCommitMessage() async throws -> String {
        try await git.run(["log", "-1", "--format=%B"]).output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func configValue(_ key: String) async -> String? {
        let value = try? await git.run(["config", "--get", key]).trimmed
        return value?.isEmpty == false ? value : nil
    }

    /// Adds a pattern to `.git/info/exclude` — ignored locally without touching tracked files.
    public func excludeLocally(_ pattern: String) async throws {
        let info = try await commonDirectory().appendingPathComponent("info")
        try FileManager.default.createDirectory(at: info, withIntermediateDirectories: true)
        let file = info.appendingPathComponent("exclude")
        var contents = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        guard !contents.split(separator: "\n").contains(where: { $0.trimmingCharacters(in: .whitespaces) == pattern }) else { return }
        if !contents.isEmpty, !contents.hasSuffix("\n") { contents += "\n" }
        contents += pattern + "\n"
        try contents.write(to: file, atomically: true, encoding: .utf8)
    }

    public func isIgnored(_ path: String) async -> Bool {
        (try? await git.run(["check-ignore", "-q", path])) != nil
    }

    private func parentOrEmptyTree(_ parent: String?) async throws -> String {
        if let parent { return parent }
        return try await emptyTree()
    }

    // MARK: - Index & working copy

    public func stage(_ paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        try await git.run(["add", "-A", "--"] + paths)
    }

    public func stageAll() async throws {
        try await git.run(["add", "-A"])
    }

    public func unstage(_ paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        if await hasCommits() {
            try await git.run(["restore", "--staged", "--"] + paths)
        } else {
            try await git.run(["rm", "--cached", "-r", "-q", "--"] + paths)
        }
    }

    public func unstageAll() async throws {
        if await hasCommits() {
            try await git.run(["reset", "-q"])
        } else {
            try await git.run(["rm", "--cached", "-r", "-q", "."])
        }
    }

    /// Discards working-copy changes. Untracked files are moved to the Trash, never deleted.
    public func discard(_ changes: [FileChange]) async throws {
        let untracked = changes.filter { $0.status == .untracked }
        let tracked = changes.filter { $0.status != .untracked }.map(\.path)
        for change in untracked {
            try FileManager.default.trashItem(at: root.appendingPathComponent(change.path), resultingItemURL: nil)
        }
        if !tracked.isEmpty {
            try await git.run(["restore", "--worktree", "--"] + tracked)
        }
    }

    /// Applies a patch built by `PatchBuilder` to the index (staging) or the working copy (discarding).
    public func apply(patch: String, toIndex: Bool, reverse: Bool) async throws {
        var args = ["apply", "--recount", "--whitespace=nowarn"]
        if toIndex { args.append("--cached") }
        if reverse { args.append("--reverse") }
        args.append("-")
        try await git.run(args, input: Data(patch.utf8))
    }

    public func commit(message: String, amend: Bool = false, allowEmpty: Bool = false) async throws {
        var args = ["commit", "-F", "-"]
        if amend { args.append("--amend") }
        if allowEmpty { args.append("--allow-empty") }
        try await git.run(args, input: Data(message.utf8))
    }

    public func resolve(_ path: String, using side: ConflictSide) async throws {
        try await git.run(["checkout", side == .ours ? "--ours" : "--theirs", "--", path])
        try await git.run(["add", "--", path])
    }

    public func markResolved(_ paths: [String]) async throws {
        try await git.run(["add", "--"] + paths)
    }

    // MARK: - Branches

    public func checkout(_ branch: Branch) async throws {
        if branch.isRemote {
            let local = branch.nameWithoutRemote
            let exists = (try? await git.run(["rev-parse", "--verify", "--quiet", "refs/heads/\(local)"])) != nil
            if exists {
                try await git.run(["switch", local])
            } else {
                try await git.run(["switch", "-c", local, "--track", branch.name])
            }
        } else {
            try await git.run(["switch", branch.name])
        }
    }

    public func checkout(commit sha: String) async throws {
        try await git.run(["switch", "--detach", sha])
    }

    public func createBranch(_ name: String, at start: String? = nil, checkout: Bool) async throws {
        if checkout {
            try await git.run(["switch", "-c", name] + (start.map { [$0] } ?? []))
        } else {
            try await git.run(["branch", name] + (start.map { [$0] } ?? []))
        }
    }

    public func renameBranch(_ old: String, to new: String) async throws {
        try await git.run(["branch", "-m", old, new])
    }

    public func deleteBranch(_ branch: Branch, force: Bool = false) async throws {
        if branch.isRemote, let remote = branch.remoteName {
            try await git.run(["push", remote, "--delete", branch.nameWithoutRemote])
        } else {
            try await git.run(["branch", force ? "-D" : "-d", branch.name])
        }
    }

    public func setUpstream(_ branch: String, upstream: String) async throws {
        try await git.run(["branch", "--set-upstream-to=\(upstream)", branch])
    }

    public func merge(_ revision: String, noFastForward: Bool = false, squash: Bool = false) async throws {
        var args = ["merge", "--no-edit"]
        if noFastForward { args.append("--no-ff") }
        if squash { args.append("--squash") }
        try await git.run(args + [revision])
    }

    public func rebase(onto revision: String) async throws {
        try await git.run(["rebase", revision])
    }

    public func cherryPick(_ commit: Commit) async throws {
        try await git.run(["cherry-pick"] + (commit.isMerge ? ["-m", "1"] : []) + [commit.sha])
    }

    public func revert(_ commit: Commit) async throws {
        try await git.run(["revert", "--no-edit"] + (commit.isMerge ? ["-m", "1"] : []) + [commit.sha])
    }

    public func reset(to revision: String, mode: ResetMode) async throws {
        try await git.run(["reset", "--\(mode.rawValue)", revision])
    }

    public func continueOperation(_ operation: RepoOperation) async throws {
        guard let command = operation.command else { return }
        try await git.run([command, "--continue"])
    }

    public func abortOperation(_ operation: RepoOperation) async throws {
        if operation == .bisecting {
            try await git.run(["bisect", "reset"])
            return
        }
        guard let command = operation.command else { return }
        try await git.run([command, "--abort"])
    }

    /// Rewrites only the message of HEAD, leaving its tree untouched.
    public func reword(head message: String) async throws {
        try await git.run(["commit", "--amend", "--only", "-F", "-"], input: Data(message.utf8))
    }

    // MARK: - Tags

    public func createTag(_ name: String, at revision: String, message: String? = nil) async throws {
        if let message, !message.isEmpty {
            try await git.run(["tag", "-a", name, revision, "-F", "-"], input: Data(message.utf8))
        } else {
            try await git.run(["tag", name, revision])
        }
    }

    public func deleteTag(_ name: String) async throws {
        try await git.run(["tag", "-d", name])
    }

    public func pushTag(_ name: String, remote: String) async throws {
        try await git.run(["push", remote, "refs/tags/\(name)"])
    }

    // MARK: - Remotes

    public func fetch(remote: String? = nil, prune: Bool = true) async throws {
        var args = ["fetch"]
        args.append(remote ?? "--all")
        if prune { args.append("--prune") }
        try await git.run(args)
    }

    public func pull(strategy: PullStrategy) async throws {
        let flag: String = switch strategy {
        case .fastForwardOnly: "--ff-only"
        case .merge: "--no-rebase"
        case .rebase: "--rebase"
        }
        try await git.run(["pull", flag])
    }

    /// Pushes the current branch, creating the upstream on first push.
    public func push(force: Bool = false, remote preferredRemote: String? = nil) async throws {
        let status = try await status()
        guard let branch = status.branch else {
            throw GitError(arguments: ["push"], exitCode: 1, stderr: "Cannot push a detached HEAD. Create a branch first.")
        }
        var args = ["push"]
        if force { args.append("--force-with-lease") }
        if status.upstream == nil {
            let remotes = try await remotes()
            guard let remote = preferredRemote ?? remotes.first(where: { $0.name == "origin" })?.name ?? remotes.first?.name else {
                throw GitError(arguments: ["push"], exitCode: 1, stderr: "This repository has no remotes.")
            }
            args += ["-u", remote, branch]
        }
        try await git.run(args)
    }

    public func addRemote(name: String, url: String) async throws {
        try await git.run(["remote", "add", name, url])
    }

    public func removeRemote(_ name: String) async throws {
        try await git.run(["remote", "remove", name])
    }

    // MARK: - Stashes

    public func stash(message: String?, includeUntracked: Bool, keepIndex: Bool = false) async throws {
        var args = ["stash", "push"]
        if includeUntracked { args.append("--include-untracked") }
        if keepIndex { args.append("--keep-index") }
        if let message, !message.isEmpty { args += ["-m", message] }
        try await git.run(args)
    }

    public func applyStash(_ stash: Stash, pop: Bool) async throws {
        try await git.run(["stash", pop ? "pop" : "apply", "--index", stash.ref])
    }

    public func dropStash(_ stash: Stash) async throws {
        try await git.run(["stash", "drop", stash.ref])
    }

    // MARK: - Worktrees

    /// Creates a worktree. With `newBranch`, a branch is created from `base`; otherwise
    /// `base` (a branch or commit) is checked out, detached when `detach` is set.
    public func addWorktree(at path: URL, newBranch: String? = nil, base: String? = nil, detach: Bool = false) async throws {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        var args = ["worktree", "add"]
        if let newBranch { args += ["-b", newBranch] }
        if detach { args.append("--detach") }
        args.append(path.path)
        if let base { args.append(base) }
        try await git.run(args)
    }

    public func removeWorktree(_ worktree: Worktree, force: Bool = false) async throws {
        try await git.run(["worktree", "remove"] + (force ? ["--force"] : []) + [worktree.path])
    }

    public func lockWorktree(_ worktree: Worktree, reason: String?) async throws {
        var args = ["worktree", "lock"]
        if let reason, !reason.isEmpty { args += ["--reason", reason] }
        try await git.run(args + [worktree.path])
    }

    public func unlockWorktree(_ worktree: Worktree) async throws {
        try await git.run(["worktree", "unlock", worktree.path])
    }

    public func moveWorktree(_ worktree: Worktree, to path: URL) async throws {
        try await git.run(["worktree", "move", worktree.path, path.path])
    }

    public func pruneWorktrees() async throws {
        try await git.run(["worktree", "prune"])
    }

    /// Lightweight status for a worktree card: counts, ahead/behind and its HEAD commit.
    public static func worktreeStatus(_ worktree: Worktree) async -> WorktreeStatus {
        var result = WorktreeStatus()
        guard FileManager.default.fileExists(atPath: worktree.path) else {
            result.missing = true
            return result
        }
        let repo = Repository(root: worktree.url)
        if let status = try? await repo.status() {
            result.staged = status.staged.count
            result.changed = status.unstaged.filter { $0.status != .untracked }.count
            result.untracked = status.unstaged.filter { $0.status == .untracked }.count
            result.conflicted = status.conflicted.count
            result.ahead = status.ahead
            result.behind = status.behind
            result.upstream = status.upstream
        }
        result.lastCommit = try? await repo.log(limit: 1, revisions: ["HEAD"]).first
        return result
    }

    /// Commits on `branch` that are not on `base` — what a worktree would contribute if merged.
    public func commits(in branch: String, notIn base: String, limit: Int = 50) async throws -> [Commit] {
        try await log(limit: limit, revisions: ["\(base)..\(branch)"])
    }
}

public enum ConflictSide: Sendable { case ours, theirs }
