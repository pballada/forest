import Foundation

/// A published Forest release, read from the GitHub Releases API.
public struct AppRelease: Sendable, Equatable {
    public let version: String
    public let notes: String
    public let page: URL
    /// The notarized `Forest-<version>.zip`.
    public let archive: URL
    public let archiveSize: Int
}

public enum UpdateFeed {
    public static let latestRelease = URL(string: "https://api.github.com/repos/pballada/forest/releases/latest")!

    /// Parses the `releases/latest` response; nil for drafts, prereleases or releases without a zip.
    public static func parse(_ data: Data) -> AppRelease? {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
            let size: Int
        }
        struct Release: Decodable {
            let tag_name: String
            let body: String?
            let html_url: URL
            let draft: Bool?
            let prerelease: Bool?
            let assets: [Asset]
        }
        guard let release = try? JSONDecoder().decode(Release.self, from: data),
              release.draft != true, release.prerelease != true,
              let zip = release.assets.first(where: { $0.name.hasPrefix("Forest") && $0.name.hasSuffix(".zip") }),
              zip.browser_download_url.scheme == "https"
        else { return nil }
        let version = release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name
        return AppRelease(version: version, notes: release.body ?? "", page: release.html_url,
                          archive: zip.browser_download_url, archiveSize: zip.size)
    }

    /// Numeric, dot-separated comparison: "0.10.0" is newer than "0.9.3", "1.0" equals "1.0.0".
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ version: String) -> [Int] {
            version.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
