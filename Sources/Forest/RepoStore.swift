import AppKit
import ForestCore
import SwiftUI

enum SidebarItem: Hashable {
    case changes, history, worktrees
    case branch(String)
    case tag(String)
    case stash(String)
    case worktree(String)
}

enum SheetKind: Identifiable {
    case newBranch(start: String?)
    case renameBranch(Branch)
    case newTag(sha: String)
    case newWorktree(base: String?, claude: Bool)
    case stash
    case addRemote
    case review(Worktree)

    var id: String {
        switch self {
        case .newBranch(let s): "branch-\(s ?? "")"
        case .renameBranch(let b): "rename-\(b.id)"
        case .newTag(let s): "tag-\(s)"
        case .newWorktree(let b, let c): "wt-\(b ?? "")-\(c)"
        case .stash: "stash"
        case .addRemote: "remote"
        case .review(let w): "review-\(w.path)"
        }
    }
}

struct Confirmation: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let actionTitle: String
    var destructive = true
    let action: () -> Void
}

/// The last thing Forest did that it knows how to take back.
struct UndoEntry: Identifiable {
    let id = UUID()
    let title: String
    let perform: () async throws -> Void
}

/// Text Claude wrote for the user (a commit explanation, a review), shown in a popover or panel.
struct ClaudeNote: Equatable {
    var title: String
    var text: String?
    var error: String?
    var loading: Bool { text == nil && error == nil }
}

struct AlertMessage: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

/// Everything one repository window shows, plus every action it can take.
@Observable @MainActor
final class RepoStore {
    let repository: Repository

    // Repository state
    var status = RepoStatus()
    var commits: [Commit] = []
    var graph: [GraphRow] = []
    var graphWidth = 1
    var labels: [String: [RefLabel]] = [:]
    var localBranches: [Branch] = []
    var remoteBranches: [Branch] = []
    var tags: [Tag] = []
    var remotes: [Remote] = []
    var stashes: [Stash] = []
    var worktrees: [Worktree] = []
    var worktreeStatus: [String: WorktreeStatus] = [:]
    var claudeSessions: [String: ClaudeSessionInfo] = [:]
    var operation: RepoOperation = .none
    var lineCounts: [String: (Int, Int)] = [:]
    var pullRequests: [PullRequest] = []
    var mainRoot: URL?
    var loaded = false
    var canLoadMore = false

    // Navigation & selection
    var sidebar: SidebarItem = .changes
    var selectedCommitID: String?
    var commitFiles: [FileChange] = []
    var selectedCommitFile: FileChange?
    var commitDiff: FileDiff?
    var commitBody = ""
    var selectedChangeIDs: Set<String> = []
    var changeDiff: FileDiff?
    var selectedLines: Set<Int> = []
    var historyFilter = ""
    /// When set, history shows only this ref's ancestry ("solo" a branch).
    var historyScope: String?
    var scrollTarget: String?
    var diffOptions = Preferences.diffOptions

    // Composer
    var commitSummary = ""
    var commitDescription = ""
    var amend = false
    var generatingMessage = false

    // Presentation
    var busy: String?
    var toast: String?
    var alert: AlertMessage?
    var confirmation: Confirmation?
    var sheet: SheetKind?
    var showPalette = false
    var undo: UndoEntry?
    /// Bumped after a commit so the composer can play its little celebration.
    var celebration = 0
    var commitExplanation: ClaudeNote?

    @ObservationIgnored private var watcher: FileWatcher?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var sessionTimer: Timer?
    @ObservationIgnored private var historyFingerprint = ""
    @ObservationIgnored private var toastTask: Task<Void, Never>?

    init(repository: Repository) {
        self.repository = repository
    }

    var name: String { repository.name }
    var currentBranch: Branch? { localBranches.first(where: \.isHead) }
    var mainWorktree: Worktree? { worktrees.first(where: \.isMain) }
    var currentWorktree: Worktree? {
        worktrees.first { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath() == repository.root.resolvingSymlinksInPath() }
    }
    var claudeWorktrees: [Worktree] { worktrees.filter(\.isClaude) }
    var activeAgents: Int { claudeWorktrees.filter { claudeSessions[$0.path]?.isActive == true }.count }
    var allChanges: [FileChange] { status.conflicted + status.unstaged + status.staged }
    var selectedChanges: [FileChange] { allChanges.filter { selectedChangeIDs.contains($0.id) } }
    var focusedChange: FileChange? { selectedChangeIDs.count == 1 ? selectedChanges.first : nil }
    var selectedCommit: Commit? { commits.first { $0.id == selectedCommitID } }

    var filteredCommits: [(Commit, GraphRow)] {
        let pairs = Array(zip(commits, graph))
        let query = historyFilter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return pairs }
        return pairs.filter { commit, _ in
            commit.subject.lowercased().contains(query) || commit.authorName.lowercased().contains(query)
                || commit.sha.hasPrefix(query) || (labels[commit.sha]?.contains { $0.name.lowercased().contains(query) } ?? false)
        }
    }

    // MARK: - Lifecycle

    func start() {
        Task { await refresh(full: true) }
        Task { [weak self] in
            guard let repository = self?.repository else { return }
            let common = try? await repository.commonDirectory()
            self?.mainRoot = try? await repository.mainWorktreeRoot()
            var paths = [repository.root.path]
            if let common, !common.path.hasPrefix(repository.root.path) { paths.append(common.path) }
            let watcher = FileWatcher(paths: paths) { [weak self] in self?.scheduleRefresh() }
            watcher.start()
            self?.watcher = watcher
        }
        // Claude transcripts live outside the repo, so poll them instead of watching.
        sessionTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshClaudeSessions() }
        }
    }

    func stop() {
        watcher?.stop()
        sessionTimer?.invalidate()
    }

    func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await refresh(full: false)
        }
    }

    /// Reloads repository state. History is only re-read when refs moved (or when `full`).
    func refresh(full: Bool) async {
        let repo = repository
        async let statusResult = repo.status()
        async let refsResult = repo.refs()
        async let remotesResult = repo.remotes()
        async let stashResult = repo.stashes()
        async let worktreeResult = repo.worktrees()
        async let operationResult = repo.operation()

        do {
            let refs = try await refsResult
            status = try await statusResult
            localBranches = refs.localBranches.sorted { lhs, rhs in
                lhs.isHead != rhs.isHead ? lhs.isHead : lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            remoteBranches = refs.remoteBranches
            tags = refs.tags
            labels = refs.labels
            remotes = (try? await remotesResult) ?? []
            stashes = (try? await stashResult) ?? []
            worktrees = (try? await worktreeResult) ?? []
            operation = await operationResult

            let fingerprint = ([status.headSHA ?? ""] + refs.labels.keys.sorted()).joined(separator: ",")
                + stashes.map(\.sha).joined()
            if full || fingerprint != historyFingerprint {
                historyFingerprint = fingerprint
                await reloadHistory()
            }
            pruneSelection()
            if let change = focusedChange { await loadDiff(for: change) } else { changeDiff = nil }
            lineCounts = await repo.workingCopyLineCounts()
            loaded = true
        } catch {
            show(error)
        }
        await refreshWorktreeStatuses()
        refreshClaudeSessions()
        if full { refreshPullRequests() }
    }

    func refreshPullRequests() {
        guard Preferences.pullRequests, remotes.contains(where: { $0.fetchURL.contains("github.com") }) else { return }
        let root = repository.root
        Task {
            let prs = await GitHubCLI.pullRequests(in: root)
            pullRequests = prs
        }
    }

    func pullRequest(for branch: String?) -> PullRequest? {
        guard let branch else { return nil }
        return pullRequests.first { $0.branch == branch }
    }

    func reloadHistory() async {
        let limit = Preferences.historyLimit
        let log = (try? await repository.log(limit: limit, revisions: historyScope.map { [$0] })) ?? []
        commits = log
        canLoadMore = log.count >= limit
        graph = GraphLayout.layout(log, head: status.headSHA)
        graphWidth = min(graph.map(\.laneCount).max() ?? 1, 14)
        if selectedCommitID == nil || !commits.contains(where: { $0.id == selectedCommitID }) {
            if let first = commits.first { await selectCommit(first.id) }
        }
    }

    func loadMoreHistory() async {
        let more = (try? await repository.log(limit: Preferences.historyLimit, skip: commits.count, revisions: historyScope.map { [$0] })) ?? []
        commits += more
        canLoadMore = more.count >= Preferences.historyLimit
        graph = GraphLayout.layout(commits, head: status.headSHA)
        graphWidth = min(graph.map(\.laneCount).max() ?? 1, 14)
    }

    func refreshWorktreeStatuses() async {
        let list = worktrees
        let results = await withTaskGroup(of: (String, WorktreeStatus).self) { group in
            for worktree in list {
                group.addTask { (worktree.path, await Repository.worktreeStatus(worktree)) }
            }
            var collected: [String: WorktreeStatus] = [:]
            for await (path, status) in group { collected[path] = status }
            return collected
        }
        worktreeStatus = results
    }

    func refreshClaudeSessions() {
        let paths = worktrees.map(\.path)
        Task.detached(priority: .utility) {
            let sessions = paths.reduce(into: [String: ClaudeSessionInfo]()) { result, path in
                if let info = ClaudeCode.sessionInfo(for: path) { result[path] = info }
            }
            await MainActor.run { self.claudeSessions = sessions }
        }
    }

    private func pruneSelection() {
        let ids = Set(allChanges.map(\.id))
        selectedChangeIDs = selectedChangeIDs.intersection(ids)
        if selectedChangeIDs.isEmpty, let first = allChanges.first {
            selectedChangeIDs = [first.id]
        }
    }

    // MARK: - Selection

    func selectCommit(_ id: String?) async {
        guard selectedCommitID != id || commitFiles.isEmpty else { return }
        selectedCommitID = id
        commitDiff = nil
        selectedCommitFile = nil
        commitExplanation = nil
        var found = commits.first { $0.id == id }
        if found == nil, let id { found = try? await repository.log(limit: 1, revisions: [id]).first }
        guard let id, let commit = found else {
            commitFiles = []
            commitBody = ""
            return
        }
        async let body = repository.commitMessage(id)
        async let files = repository.changedFiles(in: id, parent: commit.parents.first)
        commitBody = (try? await body) ?? commit.subject
        commitFiles = (try? await files) ?? []
        guard selectedCommitID == id else { return }
        if let first = commitFiles.first { await selectCommitFile(first) }
    }

    func selectCommitFile(_ file: FileChange?) async {
        selectedCommitFile = file
        guard let file, let id = selectedCommitID else {
            commitDiff = nil
            return
        }
        var parent = commits.first { $0.id == id }?.parents.first
        if parent == nil, !commits.contains(where: { $0.id == id }) {
            parent = try? await repository.log(limit: 1, revisions: [id]).first?.parents.first
        }
        commitDiff = try? await repository.diff(of: file, in: id, parent: parent, options: diffOptions)
    }

    func loadDiff(for change: FileChange) async {
        let diff = try? await repository.diff(of: change, options: diffOptions)
        if diff?.fingerprint != changeDiff?.fingerprint || diff?.path != changeDiff?.path {
            changeDiff = diff
            selectedLines = []
        }
    }

    func setFullFile(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: SettingsKey.diffFullFile)
        diffOptions = Preferences.diffOptions
        reloadDiffs()
    }

    func setIgnoreWhitespace(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: SettingsKey.diffIgnoreWhitespace)
        diffOptions = Preferences.diffOptions
        reloadDiffs()
    }

    private func reloadDiffs() {
        Task {
            if let change = focusedChange { await loadDiff(for: change) }
            if let file = selectedCommitFile { await selectCommitFile(file) }
        }
    }

    /// Before/after bytes for a working-copy change, for the image comparison.
    func imagePair(for change: FileChange) -> ImagePairLoader {
        let repo = repository
        return {
            let working = { try? Data(contentsOf: repo.root.appendingPathComponent(change.path)) }
            if change.status == .untracked { return (nil, working()) }
            if change.staged {
                return (await repo.blob("HEAD:\(change.originalPath ?? change.path)"), await repo.blob(":\(change.path)"))
            }
            return (await repo.blob(":\(change.path)"), working())
        }
    }

    func imagePair(commit sha: String, parent: String?, file: FileChange) -> ImagePairLoader {
        let repo = repository
        return {
            let before = parent == nil ? nil : await repo.blob("\(parent!):\(file.originalPath ?? file.path)")
            return (before, await repo.blob("\(sha):\(file.path)"))
        }
    }

    /// Show only `ref`'s history (nil shows everything again).
    func solo(_ ref: String?) {
        historyScope = ref
        sidebar = .history
        Task {
            selectedCommitID = nil
            await reloadHistory()
        }
    }

    func jump(to sha: String) {
        sidebar = .history
        historyFilter = ""
        scrollTarget = sha
        Task { await selectCommit(sha) }
    }

    // MARK: - Running operations

    func run(_ label: String, success: String? = nil, _ work: @escaping () async throws -> Void) {
        Task {
            busy = label
            undo = nil
            defer { busy = nil }
            do {
                try await work()
                if let success { flash(success) }
            } catch {
                show(error)
            }
            await refresh(full: false)
        }
    }

    /// Runs an operation that moves HEAD and offers to put it back afterwards.
    /// Undo uses `reset --keep`, which refuses rather than overwriting uncommitted work.
    func runUndoable(_ label: String, success: String, undoTitle: String, _ work: @escaping () async throws -> Void) {
        Task {
            let before = await repository.headSHA()
            let branch = status.branch
            run(label, success: success) {
                try await work()
                guard let before, await self.repository.headSHA() != before else { return }
                if await self.repository.operation() != .none { return }
                self.offerUndo(undoTitle) {
                    if let branch, self.status.branch != branch { try await self.repository.git.run(["switch", branch]) }
                    try await self.repository.rewind(to: before)
                }
            }
        }
    }

    func offerUndo(_ title: String, _ perform: @escaping () async throws -> Void) {
        undo = UndoEntry(title: title, perform: perform)
    }

    func performUndo() {
        guard let entry = undo else { return }
        undo = nil
        run("Undoing", success: "Undid \(entry.title.lowercased())") { try await entry.perform() }
    }

    func show(_ error: Error) {
        alert = AlertMessage(title: "Something went wrong", message: error.localizedDescription)
    }

    func flash(_ message: String) {
        toastTask?.cancel()
        withAnimation(.spring(duration: 0.35, bounce: 0.3)) { toast = message }
        toastTask = Task {
            // Linger longer when the toast offers Undo.
            try? await Task.sleep(for: .seconds(undo == nil ? 2.4 : 6))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { toast = nil }
            try? await Task.sleep(for: .seconds(0.3))
            undo = nil
        }
    }

    func confirm(_ title: String, _ message: String, action actionTitle: String, destructive: Bool = true, _ action: @escaping () -> Void) {
        confirmation = Confirmation(title: title, message: message, actionTitle: actionTitle, destructive: destructive, action: action)
    }

    // MARK: - Working copy

    func stage(_ changes: [FileChange]) {
        let paths = changes.map(\.path)
        run("Staging") { try await self.repository.stage(paths) }
    }

    func unstage(_ changes: [FileChange]) {
        let paths = changes.flatMap { [$0.path] + ($0.originalPath.map { [$0] } ?? []) }
        run("Unstaging") { try await self.repository.unstage(paths) }
    }

    func stageAll() { run("Staging all") { try await self.repository.stageAll() } }
    func unstageAll() { run("Unstaging all") { try await self.repository.unstageAll() } }

    func discard(_ changes: [FileChange]) {
        let unstaged = changes.filter { !$0.staged }
        guard !unstaged.isEmpty else { return }
        let names = unstaged.count == 1 ? "“\(unstaged[0].fileName)”" : "\(unstaged.count) files"
        confirm("Discard changes to \(names)?", "Modified files are restored from the index. Untracked files are moved to the Trash. You can undo this right after.",
                action: "Discard") {
            self.run("Discarding", success: "Discarded \(names)") {
                let backup = try await self.repository.discard(unstaged)
                self.offerUndo("Discard") { try self.repository.restore(backup) }
            }
        }
    }

    /// Stages, unstages or discards a hunk (or the selected lines within it).
    func applyHunk(_ hunk: DiffHunk, action: HunkAction) {
        guard let diff = changeDiff, let change = focusedChange else { return }
        let lines = selectedLines.intersection(Set(hunk.lines.map(\.id)))
        let selection: Set<Int>? = lines.isEmpty ? nil : lines
        if change.status == .untracked, action == .stage, selection == nil {
            stage([change])
            return
        }
        let reverse = action != .stage
        guard let patch = PatchBuilder.patch(file: diff, hunk: hunk, selected: selection, reverse: reverse) else { return }
        let path = change.path
        let apply = {
            self.run(action.progress, success: action == .discard ? "Discarded \(selection == nil ? "hunk" : "lines")" : nil) {
                let backup = action == .discard ? WorkingCopyBackup(capturing: [path], in: self.repository.root) : nil
                try await self.repository.apply(patch: patch, toIndex: action != .discard, reverse: reverse)
                if let backup { self.offerUndo("Discard") { try self.repository.restore(backup) } }
            }
            self.selectedLines = []
        }
        if action == .discard {
            confirm("Discard \(selection == nil ? "this hunk" : "the selected lines")?", "This change will be removed from your working copy.",
                    action: "Discard", apply)
        } else {
            apply()
        }
    }

    func resolve(_ change: FileChange, _ side: ConflictSide) {
        run("Resolving") { try await self.repository.resolve(change.path, using: side) }
    }

    func markResolved(_ changes: [FileChange]) {
        run("Marking resolved") { try await self.repository.markResolved(changes.map(\.path)) }
    }

    func setAmend(_ value: Bool) {
        amend = value
        guard value, commitSummary.isEmpty else { return }
        Task {
            let message = (try? await repository.lastCommitMessage()) ?? ""
            let parts = message.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            commitSummary = parts.first.map(String.init) ?? ""
            commitDescription = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        }
    }

    var canCommit: Bool {
        !commitSummary.trimmingCharacters(in: .whitespaces).isEmpty && (amend || !status.staged.isEmpty) && status.conflicted.isEmpty
    }

    func commit(andPush: Bool = false) {
        guard canCommit else { return }
        var message = commitSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = commitDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty { message += "\n\n" + body }
        let amending = amend
        let summary = commitSummary
        run(andPush ? "Committing & pushing" : "Committing", success: amending ? "Commit amended" : "Committed “\(summary)”") {
            let before = await self.repository.headSHA()
            try await self.repository.commit(message: message, amend: amending)
            self.commitSummary = ""
            self.commitDescription = ""
            self.amend = false
            self.celebration += 1
            if andPush {
                try await self.repository.push(force: amending)
            } else if let before {
                // Soft reset: the commit disappears and its changes return to the staging area.
                self.offerUndo(amending ? "Amend" : "Commit") {
                    try await self.repository.reset(to: before, mode: .soft)
                    self.commitSummary = summary
                }
            }
        }
    }

    // MARK: - Remote

    func fetch() { run("Fetching", success: "Fetched all remotes") { try await self.repository.fetch() } }

    func pull(_ strategy: PullStrategy = Preferences.pullStrategy) {
        runUndoable("Pulling", success: "Pulled", undoTitle: "Pull") { try await self.repository.pull(strategy: strategy) }
    }

    func push(force: Bool = false) {
        let branch = status.branch ?? "HEAD"
        let action = {
            self.run("Pushing", success: "Pushed \(branch)") { try await self.repository.push(force: force) }
        }
        if force {
            confirm("Force push “\(branch)”?", "Uses --force-with-lease: the push fails if someone else pushed in the meantime.",
                    action: "Force Push", action)
        } else {
            action()
        }
    }

    // MARK: - Branches

    func checkout(_ branch: Branch) {
        if let path = branch.worktreePath, !branch.isHead {
            confirm("“\(branch.name)” is checked out in another worktree",
                    "Git can't check out a branch in two worktrees. Open that worktree instead?",
                    action: "Open Worktree", destructive: false) {
                WindowOpener.open(URL(fileURLWithPath: path))
            }
            return
        }
        let previous = status.branch
        run("Checking out \(branch.name)", success: "Switched to \(branch.nameWithoutRemote)") {
            try await self.repository.checkout(branch)
            if let previous { self.offerUndo("Checkout") { try await self.repository.git.run(["switch", previous]) } }
        }
    }

    func checkout(commit: Commit) {
        confirm("Check out \(commit.shortSHA)?", "You'll be in detached HEAD state. Create a branch to keep any commits you make.",
                action: "Check Out", destructive: false) {
            self.run("Checking out") { try await self.repository.checkout(commit: commit.sha) }
        }
    }

    func createBranch(_ name: String, at start: String?, checkout: Bool) {
        run("Creating branch", success: "Created \(name)") { try await self.repository.createBranch(name, at: start, checkout: checkout) }
    }

    func rename(_ branch: Branch, to name: String) {
        run("Renaming", success: "Renamed to \(name)") { try await self.repository.renameBranch(branch.name, to: name) }
    }

    func delete(_ branch: Branch) {
        let message = branch.isRemote ? "This deletes the branch on \(branch.remoteName ?? "the remote") for everyone."
            : "Unmerged commits on this branch will become unreachable."
        confirm("Delete \(branch.isRemote ? "remote " : "")branch “\(branch.name)”?", message, action: "Delete") {
            self.run("Deleting \(branch.name)", success: "Deleted \(branch.name)") {
                do {
                    try await self.repository.deleteBranch(branch)
                } catch let error as GitError where error.stderr.contains("not fully merged") {
                    try await self.repository.deleteBranch(branch, force: true)
                }
                if !branch.isRemote {
                    self.offerUndo("Delete") { try await self.repository.createBranch(branch.name, at: branch.sha, checkout: false) }
                }
            }
        }
    }

    func merge(_ revision: String) {
        let into = status.branch ?? "HEAD"
        confirm("Merge “\(revision)” into “\(into)”?", "Creates a merge commit unless the merge can fast-forward.",
                action: "Merge", destructive: false) {
            self.runUndoable("Merging", success: "Merged \(revision)", undoTitle: "Merge") { try await self.repository.merge(revision) }
        }
    }

    func rebase(onto revision: String) {
        let branch = status.branch ?? "HEAD"
        confirm("Rebase “\(branch)” onto “\(revision)”?", "Rewrites the commits on \(branch). Don't rebase commits others have pulled.",
                action: "Rebase", destructive: false) {
            self.runUndoable("Rebasing", success: "Rebased onto \(revision)", undoTitle: "Rebase") { try await self.repository.rebase(onto: revision) }
        }
    }

    func cherryPick(_ commit: Commit) {
        runUndoable("Cherry-picking", success: "Cherry-picked \(commit.shortSHA)", undoTitle: "Cherry-pick") { try await self.repository.cherryPick(commit) }
    }

    func revert(_ commit: Commit) {
        runUndoable("Reverting", success: "Reverted \(commit.shortSHA)", undoTitle: "Revert") { try await self.repository.revert(commit) }
    }

    func reset(to commit: Commit, mode: ResetMode) {
        let branch = status.branch ?? "HEAD"
        let detail: String = switch mode {
        case .soft: "Keeps all changes staged."
        case .mixed: "Keeps changes in your working copy, unstaged."
        case .hard: "Discards all uncommitted changes. This cannot be undone."
        }
        confirm("Reset “\(branch)” to \(commit.shortSHA) (\(mode.rawValue))?", detail, action: "Reset", destructive: mode == .hard) {
            if mode == .hard {
                self.run("Resetting", success: "Reset to \(commit.shortSHA)") { try await self.repository.reset(to: commit.sha, mode: mode) }
            } else {
                self.runUndoable("Resetting", success: "Reset to \(commit.shortSHA)", undoTitle: "Reset") {
                    try await self.repository.reset(to: commit.sha, mode: mode)
                }
            }
        }
    }

    func continueOperation() {
        run("Continuing", success: "Done") { try await self.repository.continueOperation(self.operation) }
    }

    func abortOperation() {
        let op = operation
        confirm("Abort the \(op.title.lowercased())?", "Your branch returns to where it was before.", action: "Abort") {
            self.run("Aborting") { try await self.repository.abortOperation(op) }
        }
    }

    // MARK: - Tags & stashes

    func createTag(_ name: String, at sha: String, message: String?, push: Bool) {
        run("Creating tag", success: "Tagged \(name)") {
            try await self.repository.createTag(name, at: sha, message: message)
            if push, let remote = self.remotes.first?.name { try await self.repository.pushTag(name, remote: remote) }
        }
    }

    func deleteTag(_ tag: Tag) {
        confirm("Delete tag “\(tag.name)”?", "Only the local tag is deleted.", action: "Delete") {
            self.run("Deleting tag") { try await self.repository.deleteTag(tag.name) }
        }
    }

    func stash(message: String, includeUntracked: Bool) {
        run("Stashing", success: "Changes stashed") {
            try await self.repository.stash(message: message, includeUntracked: includeUntracked)
            self.offerUndo("Stash") {
                if let top = try await self.repository.stashes().first { try await self.repository.applyStash(top, pop: true) }
            }
        }
    }

    func apply(_ stash: Stash, pop: Bool) {
        run(pop ? "Popping stash" : "Applying stash", success: pop ? "Stash popped" : "Stash applied") {
            try await self.repository.applyStash(stash, pop: pop)
        }
    }

    func drop(_ stash: Stash) {
        confirm("Drop “\(stash.message)”?", "The stashed changes will be lost.", action: "Drop") {
            self.run("Dropping stash") { try await self.repository.dropStash(stash) }
        }
    }

    // MARK: - Worktrees

    /// Default location for a native worktree of `branch`.
    func suggestedWorktreePath(for branch: String) -> URL {
        let base = mainRoot ?? repository.root
        let slug = ClaudeCode.slug(branch.replacingOccurrences(of: "/", with: "-"))
        if Preferences.worktreeLocation == "nested" {
            return base.appendingPathComponent(".worktrees").appendingPathComponent(slug)
        }
        return base.deletingLastPathComponent().appendingPathComponent("\(base.lastPathComponent)-\(slug)")
    }

    func createWorktree(at path: URL, newBranch: String?, base: String?, detach: Bool, openAfter: Bool) {
        run("Creating worktree", success: "Worktree ready") {
            if path.path.contains("/.worktrees/") { try await self.repository.excludeLocally("/.worktrees/") }
            try await self.repository.addWorktree(at: path, newBranch: newBranch, base: base, detach: detach)
            if openAfter { WindowOpener.open(path) }
        }
    }

    /// Creates a worktree with Claude Code's own layout and starts an agent in it.
    func createClaudeWorktree(name: String, base: String?, task: String, launch: Bool) {
        let root = mainRoot ?? repository.root
        let path = ClaudeCode.worktreePath(repoRoot: root, name: name)
        let branch = Preferences.claudeBranchPrefix + name
        run("Creating Claude worktree", success: launch ? "Claude is starting in \(name)" : "Claude worktree ready") {
            try await self.repository.excludeLocally("/.claude/worktrees/")
            try await self.repository.addWorktree(at: path, newBranch: branch, base: base)
            if launch { Launcher.launchClaude(in: path, prompt: task) }
            self.sidebar = .worktrees
        }
    }

    func remove(_ worktree: Worktree) {
        let status = worktreeStatus[worktree.path]
        let dirty = status?.isDirty == true
        let branch = worktree.branch
        var message = claudeSessions[worktree.path]?.isActive == true ? "Claude is still working here. " : ""
        message += dirty ? "This worktree has uncommitted changes that will be lost. " : ""
        message += branch.map { "The branch “\($0)” is kept." } ?? ""
        confirm("Remove worktree “\(worktree.name)”?", message, action: "Remove") {
            self.run("Removing worktree", success: "Removed \(worktree.name)") {
                try await self.repository.removeWorktree(worktree, force: dirty || worktree.isLocked)
            }
        }
    }

    /// Removes a finished agent's worktree and deletes its branch.
    func discardAgent(_ worktree: Worktree) {
        guard let branch = worktree.branch else { return remove(worktree) }
        let active = claudeSessions[worktree.path]?.isActive == true ? "Claude is still working here. " : ""
        confirm("Remove “\(worktree.name)” and delete “\(branch)”?",
                active + "The worktree folder and its branch are deleted, including unmerged commits.", action: "Remove & Delete") {
            self.run("Cleaning up", success: "Removed \(worktree.name)") {
                try await self.repository.removeWorktree(worktree, force: true)
                try await self.repository.git.run(["branch", "-D", branch])
            }
        }
    }

    func toggleLock(_ worktree: Worktree) {
        run(worktree.isLocked ? "Unlocking" : "Locking") {
            if worktree.isLocked {
                try await self.repository.unlockWorktree(worktree)
            } else {
                try await self.repository.lockWorktree(worktree, reason: worktree.isClaude ? "Claude Code agent" : nil)
            }
        }
    }

    func pruneWorktrees() {
        run("Pruning worktrees", success: "Pruned stale worktrees") { try await self.repository.pruneWorktrees() }
    }

    /// Merges a worktree's branch into the branch checked out in the main worktree.
    func mergeIntoMain(_ worktree: Worktree) {
        guard let branch = worktree.branch, let main = mainWorktree, let target = main.branch else { return }
        confirm("Merge “\(branch)” into “\(target)”?", "Runs in the main worktree at \(Format.abbreviatePath(main.path)).",
                action: "Merge", destructive: false) {
            self.run("Merging \(branch)", success: "Merged \(branch) into \(target)") {
                try await Repository(root: main.url).merge(branch)
            }
        }
    }

    /// Pushes a worktree's branch and opens the host's "compare / new pull request" page.
    func pushAndOpenPullRequest(_ worktree: Worktree) {
        guard let branch = worktree.branch else { return }
        run("Pushing \(branch)", success: "Pushed \(branch)") {
            let repo = Repository(root: worktree.url)
            try await repo.push()
            if let web = self.remotes.first(where: { $0.name == "origin" })?.webURL ?? self.remotes.first?.webURL {
                let encoded = branch.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? branch
                Launcher.openURL(web.appendingPathComponent("compare").appendingPathComponent(encoded).appending(queryItems: [URLQueryItem(name: "expand", value: "1")]))
            }
        }
    }

    // MARK: - Claude

    var claudeExecutable: String? { ClaudeCode.locateCLI(override: Preferences.claudePath) }

    /// Asks Claude Code (headless, no tools) for a commit message describing the staged changes.
    func generateCommitMessage() {
        guard !generatingMessage else { return }
        guard !status.staged.isEmpty else {
            alert = AlertMessage(title: "Nothing staged", message: "Stage the changes you want to commit, then ask Claude to describe them.")
            return
        }
        generatingMessage = true
        Task {
            defer { generatingMessage = false }
            do {
                let patch = try await repository.stagedPatchForReview()
                let text = try await ClaudeHeadless.run(prompt: ClaudeHeadless.commitMessagePrompt, input: patch, directory: repository.root,
                                                        executable: claudeExecutable, model: Preferences.claudeModel)
                let message = ClaudeHeadless.splitCommitMessage(text)
                withAnimation(.snappy) {
                    commitSummary = message.summary
                    commitDescription = message.body
                }
            } catch {
                alert = AlertMessage(title: "Claude couldn't write a message", message: error.localizedDescription)
            }
        }
    }

    func explain(_ commit: Commit) {
        let sha = commit.sha
        commitExplanation = ClaudeNote(title: commit.subject)
        Task {
            do {
                let patch = try await repository.commitPatchForReview(sha, parent: commit.parents.first)
                let text = try await ClaudeHeadless.run(prompt: ClaudeHeadless.explainCommitPrompt, input: patch, directory: repository.root,
                                                        executable: claudeExecutable, model: Preferences.claudeModel)
                if selectedCommitID == sha { commitExplanation?.text = text }
            } catch {
                if selectedCommitID == sha { commitExplanation?.error = error.localizedDescription }
            }
        }
    }

    /// Opens Claude Code in the terminal with instructions to resolve the current conflicts.
    func resolveConflictsWithClaude() {
        let files = status.conflicted.map(\.path)
        let operation = self.operation == .none ? "merge" : self.operation.title.lowercased()
        let prompt = """
        There are merge conflicts in this repository (\(operation)). Resolve the conflict markers in: \(files.joined(separator: ", ")).
        Keep the intent of both sides; if they truly contradict, prefer the incoming change and tell me. \
        Build or run the tests if that's quick, then `git add` each resolved file. \
        Don't commit and don't continue the operation: I'll review the result in Forest.
        """
        Launcher.launchClaude(in: repository.root, prompt: prompt)
        flash("Claude is resolving \(files.count) conflict\(files.count == 1 ? "" : "s") in your terminal")
    }

    /// Sends a follow-up instruction to the agent working in `worktree`, continuing its last conversation.
    func sendFeedback(_ text: String, to worktree: Worktree) {
        Launcher.launchClaude(in: worktree.url, prompt: text, continuing: claudeSessions[worktree.path] != nil)
        flash("Sent to \(worktree.name)")
    }

    func commitsAhead(of worktree: Worktree) async -> [Commit] {
        guard let branch = worktree.branch, let base = mainWorktree?.branch, branch != base else { return [] }
        return (try? await repository.commits(in: branch, notIn: base, limit: 20)) ?? []
    }
}

enum HunkAction {
    case stage, unstage, discard

    var progress: String {
        switch self {
        case .stage: "Staging"
        case .unstage: "Unstaging"
        case .discard: "Discarding"
        }
    }
}
