import Foundation

/// An open pull request, read through the GitHub CLI (`gh`) when it is installed and signed in.
public struct PullRequest: Identifiable, Hashable, Sendable {
    public enum Checks: String, Sendable { case passing, failing, pending, none }

    public let number: Int
    public let title: String
    public let branch: String
    public let url: URL
    public let isDraft: Bool
    public let author: String
    public let reviewDecision: String?
    public let checks: Checks

    public var id: Int { number }
    public var isApproved: Bool { reviewDecision == "APPROVED" }
    public var changesRequested: Bool { reviewDecision == "CHANGES_REQUESTED" }
}

public enum GitHubCLI {
    public static func locate() -> String? {
        ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Open pull requests for the repository at `directory`; empty when `gh` is missing or not signed in.
    public static func pullRequests(in directory: URL) async -> [PullRequest] {
        guard let gh = locate() else { return [] }
        let fields = "number,title,headRefName,url,isDraft,author,reviewDecision,statusCheckRollup"
        guard let result = try? await ProcessRunner.run(executable: gh, arguments: ["pr", "list", "--state", "open", "--limit", "60", "--json", fields],
                                                        directory: directory, timeout: 20),
              result.exitCode == 0 else { return [] }
        return parse(Data(result.output.utf8))
    }

    static func parse(_ data: Data) -> [PullRequest] {
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return array.compactMap { object in
            guard let number = object["number"] as? Int, let branch = object["headRefName"] as? String,
                  let url = (object["url"] as? String).flatMap(URL.init(string:)) else { return nil }
            let author = (object["author"] as? [String: Any])?["login"] as? String ?? ""
            let decision = (object["reviewDecision"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return PullRequest(number: number, title: object["title"] as? String ?? "", branch: branch, url: url,
                               isDraft: object["isDraft"] as? Bool ?? false, author: author, reviewDecision: decision,
                               checks: checks(object["statusCheckRollup"] as? [[String: Any]] ?? []))
        }
    }

    static func checks(_ rollup: [[String: Any]]) -> PullRequest.Checks {
        guard !rollup.isEmpty else { return .none }
        var pending = false
        for check in rollup {
            // Check runs report status + conclusion; commit statuses report a single state.
            let conclusion = (check["conclusion"] as? String ?? check["state"] as? String ?? "").uppercased()
            let status = (check["status"] as? String ?? "").uppercased()
            if ["FAILURE", "ERROR", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE"].contains(conclusion) { return .failing }
            if conclusion.isEmpty || conclusion == "PENDING" || conclusion == "EXPECTED" || (status != "" && status != "COMPLETED") { pending = true }
        }
        return pending ? .pending : .passing
    }
}
