import Foundation
import Testing
@testable import ForestCore

/// A throwaway repository on disk with a deterministic identity.
struct Sandbox {
    let url: URL
    let repo: Repository

    init() async throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("forest-tests-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        repo = try await Repository.initialize(url)
        try await repo.git.run(["config", "user.name", "Forest Tests"])
        try await repo.git.run(["config", "user.email", "tests@forest.app"])
        try await repo.git.run(["config", "commit.gpgsign", "false"])
        try await repo.git.run(["symbolic-ref", "HEAD", "refs/heads/main"])
    }

    func write(_ path: String, _ contents: String) throws {
        let file = url.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: file, atomically: true, encoding: .utf8)
    }

    func read(_ path: String) throws -> String {
        try String(contentsOf: url.appendingPathComponent(path), encoding: .utf8)
    }

    func commit(_ path: String, _ contents: String, message: String) async throws {
        try write(path, contents)
        try await repo.stage([path])
        try await repo.commit(message: message)
    }
}

@Suite struct RepositoryTests {
    @Test func emptyRepositoryHasNoHistory() async throws {
        let box = try await Sandbox()
        #expect(try await box.repo.log().isEmpty)
        let status = try await box.repo.status()
        #expect(status.branch == "main")
        #expect(status.headSHA == nil)
    }

    @Test func statusSeparatesStagedUnstagedAndUntracked() async throws {
        let box = try await Sandbox()
        try await box.commit("a.txt", "one\n", message: "initial")
        try box.write("a.txt", "one\ntwo\n")
        try box.write("new file.txt", "hello\n")
        try box.write("b.txt", "b\n")
        try await box.repo.stage(["b.txt"])

        let status = try await box.repo.status()
        #expect(status.staged.map(\.path) == ["b.txt"])
        #expect(status.staged.first?.status == .added)
        #expect(Set(status.unstaged.map(\.path)) == ["a.txt", "new file.txt"])
        #expect(status.unstaged.first { $0.path == "new file.txt" }?.status == .untracked)
        #expect(status.changeCount == 3)
    }

    @Test func commitAndLogRoundTrip() async throws {
        let box = try await Sandbox()
        try await box.commit("a.txt", "1\n", message: "first")
        try await box.commit("a.txt", "2\n", message: "second\n\nwith a body")
        let log = try await box.repo.log()
        #expect(log.map(\.subject) == ["second", "first"])
        #expect(log[0].parents == [log[1].sha])
        #expect(try await box.repo.commitMessage(log[0].sha) == "second\n\nwith a body")

        let files = try await box.repo.changedFiles(in: log[0].sha, parent: log[0].parents.first)
        #expect(files.map(\.path) == ["a.txt"])
        #expect(files.first?.additions == 1)
        #expect(files.first?.deletions == 1)

        let rootFiles = try await box.repo.changedFiles(in: log[1].sha, parent: nil)
        #expect(rootFiles.first?.status == .added)
    }

    @Test func branchesTagsAndDecorations() async throws {
        let box = try await Sandbox()
        try await box.commit("a.txt", "1\n", message: "first")
        try await box.repo.createBranch("feature/x", checkout: true)
        try await box.commit("a.txt", "2\n", message: "feature work")
        try await box.repo.createTag("v1.0", at: "HEAD", message: "Release")

        let refs = try await box.repo.refs()
        #expect(Set(refs.localBranches.map(\.name)) == ["main", "feature/x"])
        #expect(refs.localBranches.first { $0.isHead }?.name == "feature/x")
        #expect(refs.tags.map(\.name) == ["v1.0"])
        let head = try await box.repo.log(limit: 1, revisions: ["HEAD"]).first!
        // The annotated tag must be peeled to the commit it points at.
        #expect(refs.labels[head.sha]?.contains { $0.kind == .tag && $0.name == "v1.0" } == true)

        try await box.repo.checkout(refs.localBranches.first { $0.name == "main" }!)
        try await box.repo.merge("feature/x", noFastForward: true)
        let merged = try await box.repo.log(limit: 1, revisions: ["HEAD"]).first!
        #expect(merged.isMerge)
    }

    @Test func partialStagingOfSelectedLines() async throws {
        let box = try await Sandbox()
        try await box.commit("f.txt", "a\nb\nc\nd\n", message: "base")
        try box.write("f.txt", "a\nB1\nc\nD1\nextra\n")

        let change = try await box.repo.status().unstaged.first!
        let diff = try #require(try await box.repo.diff(of: change))
        let hunk = try #require(diff.hunks.first)
        // Select only the change pair for line "b" → "B1".
        let selected = Set(hunk.lines.filter { $0.text == "b" || $0.text == "B1" }.map(\.id))
        let patch = try #require(PatchBuilder.patch(file: diff, hunk: hunk, selected: selected))
        try await box.repo.apply(patch: patch, toIndex: true, reverse: false)

        let index = try await box.repo.git.run(["show", ":f.txt"]).output
        #expect(index == "a\nB1\nc\nd\n")
        #expect(try box.read("f.txt") == "a\nB1\nc\nD1\nextra\n")

        // Unstage it again via a reverse patch built from the staged diff.
        let staged = try await box.repo.status().staged.first!
        let stagedDiff = try #require(try await box.repo.diff(of: staged))
        let unstage = try #require(PatchBuilder.patch(file: stagedDiff, hunk: stagedDiff.hunks[0], reverse: true))
        try await box.repo.apply(patch: unstage, toIndex: true, reverse: true)
        #expect(try await box.repo.status().staged.isEmpty)
    }

    @Test func discardSelectedLinesInWorkingCopy() async throws {
        let box = try await Sandbox()
        try await box.commit("f.txt", "a\nb\nc\n", message: "base")
        try box.write("f.txt", "a\nb2\nc\nnew\n")
        let change = try await box.repo.status().unstaged.first!
        let diff = try #require(try await box.repo.diff(of: change))
        let hunk = diff.hunks[0]
        let selected = Set(hunk.lines.filter { $0.text == "new" }.map(\.id))
        let patch = try #require(PatchBuilder.patch(file: diff, hunk: hunk, selected: selected, reverse: true))
        try await box.repo.apply(patch: patch, toIndex: false, reverse: true)
        #expect(try box.read("f.txt") == "a\nb2\nc\n")
    }

    @Test func stashRoundTrip() async throws {
        let box = try await Sandbox()
        try await box.commit("a.txt", "1\n", message: "first")
        try box.write("a.txt", "dirty\n")
        try await box.repo.stash(message: "wip thing", includeUntracked: true)
        #expect(try await box.repo.status().isClean)
        let stashes = try await box.repo.stashes()
        #expect(stashes.count == 1)
        #expect(stashes[0].message.contains("wip thing"))
        try await box.repo.applyStash(stashes[0], pop: true)
        #expect(try box.read("a.txt") == "dirty\n")
        #expect(try await box.repo.stashes().isEmpty)
    }

    @Test func worktreesIncludingClaudeLayout() async throws {
        let box = try await Sandbox()
        try await box.commit("a.txt", "1\n", message: "first")

        let native = box.url.deletingLastPathComponent().appendingPathComponent(box.url.lastPathComponent + "-feature")
        try await box.repo.addWorktree(at: native, newBranch: "feature", base: "main")
        let claude = ClaudeCode.worktreePath(repoRoot: box.url, name: "fix-login")
        try await box.repo.addWorktree(at: claude, newBranch: "worktree-fix-login", base: "main")

        let worktrees = try await box.repo.worktrees()
        #expect(worktrees.count == 3)
        #expect(worktrees[0].isMain)
        #expect(worktrees[0].branch == "main")
        #expect(worktrees.filter(\.isClaude).map(\.branch) == ["worktree-fix-login"])

        let claudeTree = worktrees.first { $0.isClaude }!
        try "x".write(to: claude.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        let status = await Repository.worktreeStatus(claudeTree)
        #expect(status.untracked == 1)
        #expect(status.lastCommit?.subject == "first")

        let refs = try await box.repo.refs()
        let branchPath = try #require(refs.localBranches.first { $0.name == "worktree-fix-login" }?.worktreePath)
        #expect(URL(fileURLWithPath: branchPath).resolvingSymlinksInPath().path == claude.resolvingSymlinksInPath().path)

        // A linked worktree resolves back to the main worktree.
        let linked = Repository(root: claude)
        #expect(try await linked.mainWorktreeRoot().resolvingSymlinksInPath().path == box.url.resolvingSymlinksInPath().path)

        try await box.repo.lockWorktree(claudeTree, reason: "agent running")
        #expect(try await box.repo.worktrees().first { $0.isClaude }?.isLocked == true)
        try await box.repo.unlockWorktree(claudeTree)
        try await box.repo.removeWorktree(claudeTree, force: true)
        #expect(try await box.repo.worktrees().count == 2)
    }

    @Test func conflictedMergeIsDetected() async throws {
        let box = try await Sandbox()
        try await box.commit("a.txt", "base\n", message: "base")
        try await box.repo.createBranch("other", checkout: true)
        try await box.commit("a.txt", "theirs\n", message: "theirs")
        try await box.repo.git.run(["switch", "main"])
        try await box.commit("a.txt", "ours\n", message: "ours")

        await #expect(throws: GitError.self) { try await box.repo.merge("other") }
        #expect(await box.repo.operation() == .merging)
        let status = try await box.repo.status()
        #expect(status.conflicted.map(\.path) == ["a.txt"])

        try await box.repo.resolve("a.txt", using: .theirs)
        #expect(try box.read("a.txt") == "theirs\n")
        try await box.repo.continueOperation(.merging)
        #expect(await box.repo.operation() == .none)
    }
}
