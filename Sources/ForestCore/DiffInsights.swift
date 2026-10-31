import Foundation

/// Human-level reading of a diff for files that are painful to review line by line.
public struct DiffInsights: Sendable, Hashable {
    /// Lockfiles and other machine-written files: collapsed by default.
    public var generatedKind: String?
    public var project: XcodeProjectSummary?

    public var isGenerated: Bool { generatedKind != nil }

    public static func analyze(_ diff: FileDiff) -> DiffInsights {
        var insights = DiffInsights()
        let name = (diff.path as NSString).lastPathComponent
        insights.generatedKind = generatedKind(for: name)
        if name == "project.pbxproj" { insights.project = XcodeProjectSummary.parse(diff) }
        return insights
    }

    public static func generatedKind(for name: String) -> String? {
        switch name {
        case "Package.resolved": "Swift Package Manager lockfile"
        case "package-lock.json", "npm-shrinkwrap.json": "npm lockfile"
        case "yarn.lock": "Yarn lockfile"
        case "pnpm-lock.yaml": "pnpm lockfile"
        case "bun.lock": "Bun lockfile"
        case "Podfile.lock": "CocoaPods lockfile"
        case "Cartfile.resolved": "Carthage lockfile"
        case "Cargo.lock": "Cargo lockfile"
        case "Gemfile.lock": "Bundler lockfile"
        case "poetry.lock", "uv.lock", "Pipfile.lock": "Python lockfile"
        case "composer.lock": "Composer lockfile"
        case "go.sum": "Go checksums"
        case "flake.lock": "Nix lockfile"
        case "mix.lock": "Mix lockfile"
        case "pubspec.lock": "Dart lockfile"
        default: name.hasSuffix(".min.js") || name.hasSuffix(".min.css") || name.hasSuffix(".map") ? "Minified or generated file" : nil
        }
    }
}

/// What a `project.pbxproj` change means: files, target membership, packages and build settings.
public struct XcodeProjectSummary: Sendable, Hashable {
    public struct SettingChange: Sendable, Hashable, Identifiable {
        public let key: String
        public let old: String?
        public let new: String?
        /// How many build configurations made the same change (Debug + Release → 2).
        public var count: Int
        public var id: String { "\(key)|\(old ?? "")|\(new ?? "")" }
    }

    public var addedFiles: [String] = []
    public var removedFiles: [String] = []
    public var addedToTargets: [String] = []
    public var removedFromTargets: [String] = []
    public var addedPackages: [String] = []
    public var removedPackages: [String] = []
    public var addedTargets: [String] = []
    public var removedTargets: [String] = []
    public var settings: [SettingChange] = []

    public var isEmpty: Bool {
        addedFiles.isEmpty && removedFiles.isEmpty && addedToTargets.isEmpty && removedFromTargets.isEmpty
            && addedPackages.isEmpty && removedPackages.isEmpty && addedTargets.isEmpty && removedTargets.isEmpty && settings.isEmpty
    }

    public static func parse(_ diff: FileDiff) -> XcodeProjectSummary {
        var summary = XcodeProjectSummary()
        var added = Ordered(), removed = Ordered()
        var addedBuild = Ordered(), removedBuild = Ordered()
        var addedPackages = Ordered(), removedPackages = Ordered()
        var addedTargets = Ordered(), removedTargets = Ordered()
        var settings: [SettingChange] = []

        for hunk in diff.hunks {
            var oldSettings: [(String, String)] = []
            var newSettings: [(String, String)] = []
            func flushSettings() {
                // Pair removed and added values of the same key, in order, within a run of changes.
                var unmatched = newSettings
                for (key, value) in oldSettings {
                    if let index = unmatched.firstIndex(where: { $0.0 == key }) {
                        if unmatched[index].1 != value { record(&settings, key, value, unmatched[index].1) }
                        unmatched.remove(at: index)
                    } else {
                        record(&settings, key, value, nil)
                    }
                }
                for (key, value) in unmatched { record(&settings, key, nil, value) }
                oldSettings = []
                newSettings = []
            }

            for (index, line) in hunk.lines.enumerated() {
                guard line.isChange else { flushSettings(); continue }
                let isAddition = line.kind == .addition
                let text = line.text
                if text.contains("isa = PBXFileReference"), let name = comment(in: text) {
                    isAddition ? added.insert(name) : removed.insert(name)
                } else if text.contains("isa = PBXBuildFile"), let name = comment(in: text) {
                    isAddition ? addedBuild.insert(name) : removedBuild.insert(name)
                } else if text.contains("/* XCRemoteSwiftPackageReference \""), text.hasSuffix("= {"), let name = quoted(in: text) {
                    isAddition ? addedPackages.insert(name) : removedPackages.insert(name)
                } else if text.contains("isa = PBXNativeTarget;") {
                    // The target's name is on the object's opening line, just above its `isa`.
                    let header = index > 0 ? hunk.lines[index - 1] : nil
                    if let header, header.kind == line.kind, let name = comment(in: header.text) {
                        isAddition ? addedTargets.insert(name) : removedTargets.insert(name)
                    }
                } else if let (key, value) = buildSetting(text) {
                    if isAddition { newSettings.append((key, value)) } else { oldSettings.append((key, value)) }
                }
            }
            flushSettings()
        }

        // A file moved between groups shows up as both removed and added; that isn't news.
        summary.addedFiles = added.items.filter { !removed.contains($0) }
        summary.removedFiles = removed.items.filter { !added.contains($0) }
        summary.addedToTargets = addedBuild.items.filter { !removedBuild.contains($0) }
        summary.removedFromTargets = removedBuild.items.filter { !addedBuild.contains($0) }
        summary.addedPackages = addedPackages.items.filter { !removedPackages.contains($0) }
        summary.removedPackages = removedPackages.items.filter { !addedPackages.contains($0) }
        summary.addedTargets = addedTargets.items.filter { !removedTargets.contains($0) }
        summary.removedTargets = removedTargets.items.filter { !addedTargets.contains($0) }
        summary.settings = settings
        return summary
    }

    private static func record(_ settings: inout [SettingChange], _ key: String, _ old: String?, _ new: String?) {
        if let index = settings.firstIndex(where: { $0.key == key && $0.old == old && $0.new == new }) {
            settings[index].count += 1
        } else {
            settings.append(SettingChange(key: key, old: old, new: new, count: 1))
        }
    }

    /// `A1B2 /* Foo.swift in Sources */ = {…}` → `Foo.swift in Sources`.
    static func comment(in text: String) -> String? {
        guard let open = text.range(of: "/* "), let close = text.range(of: " */", range: open.upperBound..<text.endIndex) else { return nil }
        return String(text[open.upperBound..<close.lowerBound])
    }

    static func quoted(in text: String) -> String? {
        guard let open = text.firstIndex(of: "\"") else { return nil }
        let rest = text[text.index(after: open)...]
        guard let close = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<close])
    }

    nonisolated(unsafe) private static let settingKey = #/"?[A-Z][A-Z0-9_]*(\[[^\]]*\])?"?/#

    /// `\t\t\t\tSWIFT_VERSION = 5.0;` → ("SWIFT_VERSION", "5.0").
    static func buildSetting(_ text: String) -> (String, String)? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasSuffix(";"), let equals = trimmed.range(of: " = ") else { return nil }
        let key = String(trimmed[..<equals.lowerBound])
        guard key.wholeMatch(of: settingKey) != nil else { return nil }
        var value = String(trimmed[equals.upperBound...].dropLast())
        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 { value = String(value.dropFirst().dropLast()) }
        return (key, value)
    }
}

/// Insertion-ordered set of strings.
private struct Ordered {
    private(set) var items: [String] = []
    private var seen: Set<String> = []
    mutating func insert(_ item: String) { if seen.insert(item).inserted { items.append(item) } }
    func contains(_ item: String) -> Bool { seen.contains(item) }
}
