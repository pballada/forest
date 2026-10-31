import Foundation

public struct DiffLine: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable { case context, addition, deletion, noNewline }

    public let id: Int
    public let kind: Kind
    public let text: String
    public let oldLine: Int?
    public let newLine: Int?

    public var isChange: Bool { kind == .addition || kind == .deletion }
}

public struct DiffHunk: Identifiable, Hashable, Sendable {
    public let id: Int
    public let header: String
    public let oldStart: Int
    public let oldCount: Int
    public let newStart: Int
    public let newCount: Int
    public let lines: [DiffLine]

    /// Text after the second `@@`, usually the enclosing function.
    public var context: String {
        let parts = header.components(separatedBy: "@@")
        return parts.count >= 3 ? parts[2...].joined(separator: "@@").trimmingCharacters(in: .whitespaces) : ""
    }
}

public struct FileDiff: Hashable, Sendable {
    public let oldPath: String?
    public let newPath: String?
    /// Header lines from `diff --git` up to (excluding) the first hunk; needed to build patches.
    public let headerLines: [String]
    public let hunks: [DiffHunk]
    public let isBinary: Bool
    public let isTruncated: Bool

    public var path: String { newPath ?? oldPath ?? "" }
    public var additions: Int { hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .addition }.count } }
    public var deletions: Int { hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .deletion }.count } }
    public var isNewFile: Bool { oldPath == nil }
    public var isDeletedFile: Bool { newPath == nil }
}

public enum DiffParser {
    public static let maxLines = 25_000

    public static func parse(_ text: String) -> [FileDiff] {
        var files: [FileDiff] = []
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }

        var i = 0
        while i < lines.count {
            guard lines[i].hasPrefix("diff --git ") || lines[i].hasPrefix("diff --cc ") else {
                i += 1
                continue
            }
            var header: [String] = [lines[i]]
            var oldPath: String?
            var newPath: String?
            var isBinary = false
            let (gitOld, gitNew) = pathsFromDiffGitLine(lines[i])
            i += 1

            while i < lines.count, !lines[i].hasPrefix("@@"), !lines[i].hasPrefix("diff --git ") {
                let line = lines[i]
                header.append(line)
                if line.hasPrefix("--- ") {
                    oldPath = stripPrefix(String(line.dropFirst(4)))
                } else if line.hasPrefix("+++ ") {
                    newPath = stripPrefix(String(line.dropFirst(4)))
                } else if line.hasPrefix("Binary files ") || line.hasPrefix("GIT binary patch") {
                    isBinary = true
                }
                i += 1
            }

            let sawMarkers = header.contains { $0.hasPrefix("--- ") }
            if !sawMarkers {
                // Pure renames, mode changes and binaries carry no ---/+++ lines.
                let isNew = header.contains { $0.hasPrefix("new file mode") }
                let isDeleted = header.contains { $0.hasPrefix("deleted file mode") }
                oldPath = isNew ? nil : gitOld
                newPath = isDeleted ? nil : gitNew
                if let from = header.first(where: { $0.hasPrefix("rename from ") }) { oldPath = String(from.dropFirst(12)) }
                if let to = header.first(where: { $0.hasPrefix("rename to ") }) { newPath = String(to.dropFirst(10)) }
            }

            var hunks: [DiffHunk] = []
            var lineID = 0
            var truncated = false
            while i < lines.count, lines[i].hasPrefix("@@") {
                let headerLine = lines[i]
                let ranges = parseHunkHeader(headerLine)
                i += 1
                var hunkLines: [DiffLine] = []
                var oldLine = ranges.oldStart
                var newLine = ranges.newStart
                while i < lines.count {
                    let line = lines[i]
                    if line.hasPrefix("@@") || line.hasPrefix("diff --git ") { break }
                    if lineID >= maxLines {
                        truncated = true
                        i += 1
                        continue
                    }
                    let body = String(line.dropFirst())
                    switch line.first {
                    case "+":
                        hunkLines.append(DiffLine(id: lineID, kind: .addition, text: body, oldLine: nil, newLine: newLine))
                        newLine += 1
                    case "-":
                        hunkLines.append(DiffLine(id: lineID, kind: .deletion, text: body, oldLine: oldLine, newLine: nil))
                        oldLine += 1
                    case "\\":
                        hunkLines.append(DiffLine(id: lineID, kind: .noNewline, text: line, oldLine: nil, newLine: nil))
                    default:
                        hunkLines.append(DiffLine(id: lineID, kind: .context, text: body, oldLine: oldLine, newLine: newLine))
                        oldLine += 1
                        newLine += 1
                    }
                    lineID += 1
                    i += 1
                }
                hunks.append(DiffHunk(id: hunks.count, header: headerLine, oldStart: ranges.oldStart, oldCount: ranges.oldCount,
                                      newStart: ranges.newStart, newCount: ranges.newCount, lines: hunkLines))
            }
            files.append(FileDiff(oldPath: oldPath, newPath: newPath, headerLines: header, hunks: hunks,
                                  isBinary: isBinary, isTruncated: truncated))
        }
        return files
    }

    static func stripPrefix(_ path: String) -> String? {
        var p = path
        if let tab = p.firstIndex(of: "\t") { p = String(p[..<tab]) }
        if p == "/dev/null" { return nil }
        if p.hasPrefix("a/") || p.hasPrefix("b/") { return String(p.dropFirst(2)) }
        return p
    }

    static func pathsFromDiffGitLine(_ line: String) -> (String?, String?) {
        // "diff --git a/foo b/foo" — ambiguous with spaces, but good enough as a fallback.
        let rest = line.dropFirst("diff --git ".count)
        guard let range = rest.range(of: " b/") else { return (nil, nil) }
        let old = rest[..<range.lowerBound]
        let new = rest[range.upperBound...]
        return (old.hasPrefix("a/") ? String(old.dropFirst(2)) : String(old), String(new))
    }

    static func parseHunkHeader(_ header: String) -> (oldStart: Int, oldCount: Int, newStart: Int, newCount: Int) {
        // @@ -l,s +l,s @@
        let parts = header.split(separator: " ")
        func range(_ s: Substring?) -> (Int, Int) {
            guard let s else { return (0, 0) }
            let nums = s.dropFirst().split(separator: ",")
            let start = Int(nums.first ?? "0") ?? 0
            let count = nums.count > 1 ? (Int(nums[1]) ?? 1) : 1
            return (start, count)
        }
        let old = range(parts.count > 1 ? parts[1] : nil)
        let new = range(parts.count > 2 ? parts[2] : nil)
        return (old.0, old.1, new.0, new.1)
    }
}

/// Builds patches for partial staging, unstaging and discarding.
public enum PatchBuilder {
    /// Builds a single-hunk patch containing only `selected` line ids (all change lines when nil).
    ///
    /// - Parameter reverse: true when the patch will be applied with `--reverse` (unstaging or
    ///   discarding). Unselected lines must then be expressed relative to the *new* side.
    public static func patch(file: FileDiff, hunk: DiffHunk, selected: Set<Int>? = nil, reverse: Bool = false) -> String? {
        var body: [String] = []
        var oldCount = 0
        var newCount = 0
        var includesChange = false
        var lastWasDropped = false

        for line in hunk.lines {
            let isSelected = selected?.contains(line.id) ?? true
            switch line.kind {
            case .context:
                body.append(" " + line.text)
                oldCount += 1
                newCount += 1
                lastWasDropped = false
            case .addition:
                if isSelected {
                    body.append("+" + line.text)
                    newCount += 1
                    includesChange = true
                    lastWasDropped = false
                } else if reverse {
                    body.append(" " + line.text)
                    oldCount += 1
                    newCount += 1
                    lastWasDropped = false
                } else {
                    lastWasDropped = true
                }
            case .deletion:
                if isSelected {
                    body.append("-" + line.text)
                    oldCount += 1
                    includesChange = true
                    lastWasDropped = false
                } else if reverse {
                    lastWasDropped = true
                } else {
                    body.append(" " + line.text)
                    oldCount += 1
                    newCount += 1
                    lastWasDropped = false
                }
            case .noNewline:
                if !lastWasDropped { body.append(line.text) }
            }
        }
        guard includesChange else { return nil }

        let header = file.headerLines.filter { !$0.hasPrefix("index ") }
        let hunkHeader = "@@ -\(hunk.oldStart),\(oldCount) +\(hunk.newStart),\(newCount) @@"
        return (header + [hunkHeader] + body).joined(separator: "\n") + "\n"
    }
}
