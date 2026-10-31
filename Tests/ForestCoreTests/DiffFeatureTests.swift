import Foundation
import Testing
@testable import ForestCore

@Suite struct DiffFeatureTests {
    static let sample = """
    diff --git a/f.swift b/f.swift
    index 1..2 100644
    --- a/f.swift
    +++ b/f.swift
    @@ -1,4 +1,5 @@
     let a = 1
    -let total = price * count
    -print(total)
    +let total = price * quantity
    +print(total)
    +log(total)
     done()
    """

    @Test func splitLayoutPairsDeletionsWithAdditions() throws {
        let diff = try #require(DiffParser.parse(Self.sample).first)
        let layout = DiffLayout.build(diff, presentation: .split)
        #expect(layout.rows.first?.isHeader == true)
        let body = layout.rows.dropFirst()
        #expect(body.count == 5)  // context, 2 pairs (+1 filler on the left), context
        let pairs = Array(body)
        #expect(pairs[0].left?.id == pairs[0].right?.id)
        #expect(pairs[1].left?.text == "let total = price * count")
        #expect(pairs[1].right?.text == "let total = price * quantity")
        #expect(pairs[3].left == nil && pairs[3].right?.text == "log(total)")
        #expect(layout.changeStarts == [2])
    }

    @Test func unifiedLayoutKeepsEveryLine() throws {
        let diff = try #require(DiffParser.parse(Self.sample).first)
        let layout = DiffLayout.build(diff, presentation: .unified)
        #expect(layout.rows.count == 1 + diff.hunks[0].lines.count)
        #expect(layout.maxColumns == "let total = price * quantity".count)
    }

    @Test func wordLevelHighlightsOnlyTheChangedWord() throws {
        let (old, new) = try #require(IntralineDiff.changes(old: "let total = price * count", new: "let total = price * quantity"))
        #expect(old == [20..<25])
        #expect(new == [20..<28])
        // Unrelated lines are not highlighted at all.
        #expect(IntralineDiff.changes(old: "import Foundation", new: "return value + 42 * x") == nil)
        #expect(IntralineDiff.changes(old: "same", new: "same") == nil)
    }

    @Test func wordHighlightsHandleMultipleEdits() throws {
        let (old, new) = try #require(IntralineDiff.changes(old: "foo(a, b, c)", new: "foo(x, b, z)"))
        #expect(old.count == 2)
        #expect(new.count == 2)
    }

    @Test func fingerprintsTrackContent() throws {
        let a = try #require(DiffParser.parse(Self.sample).first)
        let b = try #require(DiffParser.parse(Self.sample).first)
        let c = try #require(DiffParser.parse(Self.sample.replacingOccurrences(of: "log(total)", with: "log(sum)")).first)
        #expect(a == b && a.fingerprint == b.fingerprint)
        #expect(a != c)
        #expect(a.additions == 3 && a.deletions == 2)
    }

    @Test func xcodeProjectSummary() throws {
        let text = """
        diff --git a/App.xcodeproj/project.pbxproj b/App.xcodeproj/project.pbxproj
        --- a/App.xcodeproj/project.pbxproj
        +++ b/App.xcodeproj/project.pbxproj
        @@ -10,6 +10,8 @@
         /* Begin PBXBuildFile section */
        +\t\tAA01 /* Login.swift in Sources */ = {isa = PBXBuildFile; fileRef = AA02 /* Login.swift */; };
        -\t\tBB01 /* Old.swift in Sources */ = {isa = PBXBuildFile; fileRef = BB02 /* Old.swift */; };
         /* End PBXBuildFile section */
        +\t\tAA02 /* Login.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = Login.swift; sourceTree = "<group>"; };
        -\t\tBB02 /* Old.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = Old.swift; sourceTree = "<group>"; };
        +\t\tCC01 /* XCRemoteSwiftPackageReference "swift-collections" */ = {
        @@ -200,7 +202,7 @@
         \t\t\tbuildSettings = {
        -\t\t\t\tMARKETING_VERSION = 1.2;
        +\t\t\t\tMARKETING_VERSION = 1.3;
        -\t\t\t\tSWIFT_VERSION = 5.0;
        +\t\t\t\tSWIFT_VERSION = 6.0;
         \t\t\t};
        @@ -300,7 +302,7 @@
         \t\t\tbuildSettings = {
        -\t\t\t\tMARKETING_VERSION = 1.2;
        +\t\t\t\tMARKETING_VERSION = 1.3;
        +\t\t\t\t"CODE_SIGN_IDENTITY[sdk=iphoneos*]" = "iPhone Developer";
         \t\t\t};
        """
        let diff = try #require(DiffParser.parse(text).first)
        let insights = DiffInsights.analyze(diff)
        #expect(!insights.isGenerated)
        let summary = try #require(insights.project)
        #expect(summary.addedFiles == ["Login.swift"])
        #expect(summary.removedFiles == ["Old.swift"])
        #expect(summary.addedToTargets == ["Login.swift in Sources"])
        #expect(summary.removedFromTargets == ["Old.swift in Sources"])
        #expect(summary.addedPackages == ["swift-collections"])
        let version = try #require(summary.settings.first { $0.key == "MARKETING_VERSION" })
        #expect(version.old == "1.2" && version.new == "1.3" && version.count == 2)
        #expect(summary.settings.contains { $0.key == "SWIFT_VERSION" && $0.new == "6.0" })
        #expect(summary.settings.contains { $0.key == "\"CODE_SIGN_IDENTITY[sdk=iphoneos*]\"" && $0.old == nil && $0.new == "iPhone Developer" })
    }

    @Test func lockfilesAreGenerated() {
        #expect(DiffInsights.generatedKind(for: "Package.resolved") != nil)
        #expect(DiffInsights.generatedKind(for: "yarn.lock") != nil)
        #expect(DiffInsights.generatedKind(for: "bundle.min.js") != nil)
        #expect(DiffInsights.generatedKind(for: "Package.swift") == nil)
    }

    @Test func commitMessageSplitting() {
        let message = ClaudeHeadless.splitCommitMessage("```\nAdd login screen\n\nWires the form to the auth service.\n```")
        #expect(message.summary == "Add login screen")
        #expect(message.body == "Wires the form to the auth service.")
        #expect(ClaudeHeadless.splitCommitMessage("\"Fix typo\"").summary == "Fix typo")
    }

    @Test func pullRequestParsing() {
        let json = """
        [{"number":7,"title":"Agent work","headRefName":"worktree-a","url":"https://github.com/o/r/pull/7","isDraft":false,
          "author":{"login":"me"},"reviewDecision":"APPROVED",
          "statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS"},{"status":"IN_PROGRESS","conclusion":""}]},
         {"number":8,"title":"x","headRefName":"b","url":"https://github.com/o/r/pull/8","isDraft":true,"author":{"login":"me"},
          "reviewDecision":"","statusCheckRollup":[{"state":"FAILURE"}]}]
        """
        let prs = GitHubCLI.parse(Data(json.utf8))
        #expect(prs.count == 2)
        #expect(prs[0].checks == .pending && prs[0].isApproved)
        #expect(prs[1].checks == .failing && prs[1].isDraft && prs[1].reviewDecision == nil)
    }

    @Test func discardCanBeUndone() async throws {
        let box = try await Sandbox()
        try await box.commit("a.txt", "one\n", message: "initial")
        try box.write("a.txt", "one\ntwo\n")
        try box.write("new.txt", "fresh\n")
        let status = try await box.repo.status()
        let backup = try await box.repo.discard(status.unstaged)
        #expect(try await box.repo.status().isClean)
        try box.repo.restore(backup)
        #expect(try box.read("a.txt") == "one\ntwo\n")
        #expect(try box.read("new.txt") == "fresh\n")
    }

    @Test func rewindUndoesACommitKeepingChanges() async throws {
        let box = try await Sandbox()
        try await box.commit("a.txt", "one\n", message: "initial")
        let before = try #require(await box.repo.headSHA())
        try await box.commit("a.txt", "two\n", message: "second")
        try box.write("b.txt", "wip\n")
        try await box.repo.rewind(to: before)
        #expect(await box.repo.headSHA() == before)
        #expect(try box.read("b.txt") == "wip\n")
    }

    @Test func reviewDiffAgainstBaseIncludesWorkingTree() async throws {
        let box = try await Sandbox()
        try await box.commit("a.txt", "one\n", message: "initial")
        try await box.repo.createBranch("agent", checkout: true)
        try await box.commit("b.txt", "agent work\n", message: "agent")
        try box.write("a.txt", "one\nuncommitted\n")
        try box.write("Package.resolved", "{}\n")
        try await box.repo.stage(["Package.resolved"])
        let base = try await box.repo.mergeBase("main", "HEAD")
        let committed = try await box.repo.changedFiles(from: base, to: "HEAD")
        #expect(committed.map(\.path) == ["b.txt"])
        let everything = try await box.repo.changedFiles(from: base, to: nil)
        #expect(Set(everything.map(\.path)) == ["a.txt", "b.txt", "Package.resolved"])
        let patch = try await box.repo.patchForReview(from: base, includeWorkingTree: true)
        #expect(patch.contains("+agent work"))
        #expect(patch.contains("+uncommitted"))
        #expect(patch.contains("not shown (generated, binary or very large): Package.resolved"))
        let diff = try #require(try await box.repo.diff(of: everything.first { $0.path == "a.txt" }!, from: base, to: nil,
                                                       options: DiffOptions(context: DiffOptions.fullFileContext)))
        #expect(diff.additions == 1)
        #expect(await box.repo.blob("\(base):a.txt") == Data("one\n".utf8))
    }
}
