import Foundation
import Testing
@testable import ForestCore

@Suite struct ParserTests {
    func commit(_ id: String, _ parents: [String]) -> Commit {
        Commit(id: id, parents: parents, authorName: "a", authorEmail: "a@b", authorDate: .now,
               committerName: "a", commitDate: .now, subject: id)
    }

    @Test func linearHistoryStaysInOneLane() {
        let rows = GraphLayout.layout([commit("c", ["b"]), commit("b", ["a"]), commit("a", [])])
        #expect(rows.map(\.column) == [0, 0, 0])
        #expect(rows.allSatisfy { $0.laneCount == 1 })
        #expect(rows[0].incoming.isEmpty)
        #expect(rows[1].incoming.count == 1)
        #expect(rows[2].outgoing.isEmpty)
    }

    @Test func mergeOpensAndClosesALane() {
        // m merges f into b; f and b both descend from a.
        let rows = GraphLayout.layout([
            commit("m", ["b", "f"]),
            commit("f", ["a"]),
            commit("b", ["a"]),
            commit("a", []),
        ])
        #expect(rows[0].column == 0)
        #expect(rows[0].outgoing.map(\.to) == [0, 1])
        #expect(rows[1].column == 1)
        #expect(rows[2].column == 0)
        #expect(rows[2].passThrough.map(\.from) == [1])
        // Both lanes converge on the root commit.
        #expect(rows[3].incoming.map(\.from).sorted() == [0, 1])
        #expect(rows[3].column == 0)
    }

    @Test func branchTipsGetDistinctColors() {
        let rows = GraphLayout.layout([commit("x", ["a"]), commit("y", ["a"]), commit("a", [])])
        #expect(rows[0].column == 0)
        #expect(rows[1].column == 1)
        #expect(rows[0].color != rows[1].color)
    }

    @Test func headKeepsTheFirstLane() {
        // A newer commit on another branch comes first, but HEAD's line stays in lane 0.
        let rows = GraphLayout.layout([commit("other", ["a"]), commit("head", ["a"]), commit("a", [])], head: "head")
        #expect(rows[0].column == 1)
        #expect(rows[0].passThrough.isEmpty)
        #expect(rows[1].column == 0)
        #expect(rows[1].incoming.isEmpty)
        #expect(rows[2].column == 0)
    }

    @Test func childrenOfHeadStillConnect() {
        let rows = GraphLayout.layout([commit("child", ["head"]), commit("head", ["a"]), commit("a", [])], head: "head")
        #expect(rows[0].column == 1)
        #expect(rows[1].incoming.map(\.from) == [1])
    }

    @Test func trackInfo() {
        #expect(RefParser.parseTrack("[ahead 3, behind 12]") == (3, 12, false))
        #expect(RefParser.parseTrack("[behind 1]") == (0, 1, false))
        #expect(RefParser.parseTrack("[gone]") == (0, 0, true))
        #expect(RefParser.parseTrack("") == (0, 0, false))
    }

    @Test func porcelainV2WithRenameAndConflict() {
        let raw = [
            "# branch.oid abc", "# branch.head feature/a b", "# branch.upstream origin/feature", "# branch.ab +2 -1",
            "1 .M N... 100644 100644 100644 aaa bbb dir/file with space.txt",
            "2 R. N... 100644 100644 100644 aaa bbb R100 new.txt", "old.txt",
            "u UU N... 100644 100644 100644 100644 a b c conflict.txt",
            "? untracked.txt", "",
        ].joined(separator: "\0")
        let status = StatusParser.parse(Data(raw.utf8))
        #expect(status.branch == "feature/a b")
        #expect(status.ahead == 2 && status.behind == 1)
        #expect(status.unstaged.map(\.path) == ["dir/file with space.txt", "untracked.txt"])
        #expect(status.staged.first?.originalPath == "old.txt")
        #expect(status.staged.first?.status == .renamed)
        #expect(status.conflicted.map(\.path) == ["conflict.txt"])
    }

    @Test func diffParsing() {
        let text = """
        diff --git a/f.txt b/f.txt
        index 1..2 100644
        --- a/f.txt
        +++ b/f.txt
        @@ -1,3 +1,3 @@ func main()
         a
        -b
        +B
         c
        \\ No newline at end of file
        diff --git a/img.png b/img.png
        Binary files a/img.png and b/img.png differ
        """
        let files = DiffParser.parse(text)
        #expect(files.count == 2)
        #expect(files[0].path == "f.txt")
        #expect(files[0].hunks.first?.context == "func main()")
        #expect(files[0].additions == 1 && files[0].deletions == 1)
        let lines = files[0].hunks[0].lines
        #expect(lines.map(\.oldLine) == [1, 2, nil, 3, nil])
        #expect(lines.map(\.newLine) == [1, nil, 2, 3, nil])
        #expect(files[1].isBinary)
    }

    @Test func claudeHelpers() throws {
        #expect(ClaudeCode.isClaudeWorktree(path: "/x/repo/.claude/worktrees/fix"))
        #expect(!ClaudeCode.isClaudeWorktree(path: "/x/repo-fix"))
        #expect(ClaudeCode.slug("  Fix the Login bug!! ") == "fix-the-login-bug")
        let home = URL(fileURLWithPath: "/home")
        #expect(ClaudeCode.projectDirectory(for: "/Users/me/my.repo/.claude/worktrees/a_b", home: home).lastPathComponent
                == "-Users-me-my-repo--claude-worktrees-a-b")
    }

    @Test func claudeTranscript() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("forest-home-\(UUID().uuidString)")
        let dir = ClaudeCode.projectDirectory(for: "/tmp/proj", home: home)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let lines = [
            #"{"type":"mode","mode":"x"}"#,
            #"{"parentUuid":null,"type":"user","message":{"role":"user","content":"Add dark mode to settings"}}"#,
            #"{"type":"assistant","message":{"content":[]}}"#,
            #"{"type":"ai-title","aiTitle":"Dark mode settings"}"#,
            #"{"type":"pr-link","prUrl":"https://github.com/a/b/pull/7"}"#,
        ]
        // Claude Code ends every record with a newline; a trailing partial line is still being written.
        try (lines.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent("s.jsonl"), atomically: true, encoding: .utf8)
        let info = try #require(ClaudeCode.sessionInfo(for: "/tmp/proj", index: ClaudeSessionIndex(home: home)))
        #expect(info.task == "Add dark mode to settings")
        #expect(info.title == "Dark mode settings")
        #expect(info.pullRequestURL?.absoluteString == "https://github.com/a/b/pull/7")
        #expect(info.isActive)
    }

    @Test func claudeSessionsAreIncremental() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("forest-home-\(UUID().uuidString)")
        let dir = ClaudeCode.projectDirectory(for: "/tmp/wt", home: home)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("1111.jsonl")
        let first = [
            #"{"parentUuid":null,"isSidechain":false,"type":"user","message":{"role":"user","content":"Fix the login timeout"},"gitBranch":"worktree-login"}"#,
            #"{"message":{"content":[{"type":"text","text":"working"}]},"type":"assistant"}"#,
        ]
        try (first.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        try #"{"parentUuid":null,"type":"user","message":{"content":"<command-name>/clear</command-name>"}}"#
            .write(to: dir.appendingPathComponent("2222.jsonl"), atomically: true, encoding: .utf8)
        let index = ClaudeSessionIndex(home: home)

        var sessions = index.sessions(for: "/tmp/wt")
        #expect(sessions.map(\.id) == ["1111"])
        #expect(sessions[0].firstPrompt == "Fix the login timeout")
        #expect(sessions[0].gitBranch == "worktree-login")
        #expect(sessions[0].isWorking())

        let more = [
            #"{"isSidechain":false,"type":"system","subtype":"turn_duration","durationMs":10,"messageCount":4}"#,
            #"{"type":"last-prompt","lastPrompt":"Fix the login timeout"}"#,
            #"{"type":"ai-title","aiTitle":"Login timeout fix"}"#,
        ]
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((more.joined(separator: "\n") + "\n").utf8))
        try handle.close()

        sessions = index.sessions(for: "/tmp/wt")
        #expect(sessions[0].title == "Login timeout fix")
        #expect(sessions[0].displayTitle == "Login timeout fix")
        #expect(sessions[0].messageCount == 4)
        #expect(sessions[0].turnEnded)
        #expect(!sessions[0].isWorking())
        #expect(sessions[0].firstPrompt == "Fix the login timeout")
    }

    @Test func remoteWebURL() {
        #expect(Remote(name: "o", fetchURL: "git@github.com:pballada/forest.git", pushURL: "").webURL?.absoluteString
                == "https://github.com/pballada/forest")
        #expect(Remote(name: "o", fetchURL: "https://github.com/a/b.git", pushURL: "").webURL?.absoluteString
                == "https://github.com/a/b")
    }
}
