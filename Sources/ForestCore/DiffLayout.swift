import Foundation

public enum DiffPresentation: String, CaseIterable, Sendable, Identifiable {
    case unified, split
    public var id: String { rawValue }
}

/// One visual row of a diff. In unified mode `left` holds the line; in split mode `left` is the old
/// side and `right` the new side (a context line appears on both).
public struct DiffRow: Sendable, Hashable {
    public let hunk: Int
    public let isHeader: Bool
    public let left: DiffLine?
    public let right: DiffLine?

    public var isChange: Bool { (left?.isChange ?? false) || (right?.isChange ?? false) }
    public var lines: [DiffLine] {
        if let left, let right, left.id == right.id { return [left] }
        return [left, right].compactMap { $0 }
    }
}

/// A diff flattened into rows, with word-level highlights. Built off the main thread so huge files
/// (lockfiles, `project.pbxproj`) stay cheap to show: the view only ever draws the visible rows.
public struct DiffLayout: Sendable {
    public let presentation: DiffPresentation
    public let rows: [DiffRow]
    /// Changed character ranges (UTF-16 offsets into the tab-expanded text) keyed by line id.
    public let highlights: [Int: [Range<Int>]]
    /// Row indices where a run of changes begins, for next/previous change navigation.
    public let changeStarts: [Int]
    /// Widest line in characters after tab expansion.
    public let maxColumns: Int

    public static let tabWidth = 4

    public static func displayText(_ text: String) -> String {
        text.contains("\t") ? text.replacingOccurrences(of: "\t", with: String(repeating: " ", count: tabWidth)) : text
    }

    public static func build(_ diff: FileDiff, presentation: DiffPresentation) -> DiffLayout {
        var rows: [DiffRow] = []
        var highlights: [Int: [Range<Int>]] = [:]
        var budget = IntralineDiff.Budget()
        var maxColumns = 0

        for hunk in diff.hunks {
            rows.append(DiffRow(hunk: hunk.id, isHeader: true, left: nil, right: nil))
            let lines = hunk.lines
            for line in lines {
                let tabs = line.text.utf8.reduce(0) { $1 == 9 ? $0 + 1 : $0 }
                maxColumns = max(maxColumns, line.text.utf16.count + tabs * (tabWidth - 1))
            }
            var i = 0
            while i < lines.count {
                let line = lines[i]
                guard line.kind == .deletion || line.kind == .addition else {
                    if presentation == .split {
                        rows.append(DiffRow(hunk: hunk.id, isHeader: false, left: line, right: line.kind == .context ? line : nil))
                    } else {
                        rows.append(DiffRow(hunk: hunk.id, isHeader: false, left: line, right: nil))
                    }
                    i += 1
                    continue
                }
                var deletions: [DiffLine] = []
                while i < lines.count, lines[i].kind == .deletion { deletions.append(lines[i]); i += 1 }
                var additions: [DiffLine] = []
                while i < lines.count, lines[i].kind == .addition { additions.append(lines[i]); i += 1 }

                for (old, new) in zip(deletions, additions) {
                    if let (a, b) = IntralineDiff.changes(old: displayText(old.text), new: displayText(new.text), budget: &budget) {
                        if !a.isEmpty { highlights[old.id] = a }
                        if !b.isEmpty { highlights[new.id] = b }
                    }
                }
                switch presentation {
                case .unified:
                    for line in deletions + additions { rows.append(DiffRow(hunk: hunk.id, isHeader: false, left: line, right: nil)) }
                case .split:
                    for index in 0..<max(deletions.count, additions.count) {
                        rows.append(DiffRow(hunk: hunk.id, isHeader: false,
                                            left: index < deletions.count ? deletions[index] : nil,
                                            right: index < additions.count ? additions[index] : nil))
                    }
                }
            }
        }

        var starts: [Int] = []
        var previousWasChange = false
        for (index, row) in rows.enumerated() {
            let change = row.isChange
            if change && !previousWasChange { starts.append(index) }
            previousWasChange = change
        }
        return DiffLayout(presentation: presentation, rows: rows, highlights: highlights, changeStarts: starts, maxColumns: maxColumns)
    }
}

/// Word-level emphasis for modified lines, like a document comparison: lines are split into
/// words, whitespace and punctuation, and the tokens outside their longest common subsequence
/// are highlighted.
public enum IntralineDiff {
    /// Caps total LCS work per diff so a pathological file can't stall the layout.
    public struct Budget: Sendable {
        public var remaining = 4_000_000
        public init() {}
    }

    public static func changes(old: String, new: String) -> ([Range<Int>], [Range<Int>])? {
        var budget = Budget()
        return changes(old: old, new: new, budget: &budget)
    }

    static func changes(old: String, new: String, budget: inout Budget) -> ([Range<Int>], [Range<Int>])? {
        let a = Array(old.utf16), b = Array(new.utf16)
        guard a != b, a.count < 2000, b.count < 2000 else { return nil }
        let ta = tokens(a), tb = tokens(b)

        // Trim the common token prefix and suffix; most edits are small and this skips the DP.
        var prefix = 0
        while prefix < ta.count, prefix < tb.count, a[ta[prefix]] == b[tb[prefix]] { prefix += 1 }
        var suffix = 0
        while suffix < ta.count - prefix, suffix < tb.count - prefix,
              a[ta[ta.count - 1 - suffix]] == b[tb[tb.count - 1 - suffix]] { suffix += 1 }

        let midA = Array(ta[prefix..<(ta.count - suffix)])
        let midB = Array(tb[prefix..<(tb.count - suffix)])
        var keepA = Set<Int>(), keepB = Set<Int>()
        let cells = midA.count * midB.count
        if cells > 0, cells <= 40_000, budget.remaining >= cells {
            budget.remaining -= cells
            (keepA, keepB) = lcs(midA.map { Array(a[$0]) }, midB.map { Array(b[$0]) })
        }

        let changedA = midA.indices.filter { !keepA.contains($0) }.map { midA[$0] }
        let changedB = midB.indices.filter { !keepB.contains($0) }.map { midB[$0] }

        // Only emphasise when the lines are recognisably related.
        let changedChars = changedA.reduce(0) { $0 + $1.count } + changedB.reduce(0) { $0 + $1.count }
        let total = a.count + b.count
        guard total > 0, changedChars * 10 <= total * 7 else { return nil }
        return (merge(changedA, in: a), merge(changedB, in: b))
    }

    /// Splits UTF-16 text into word runs, whitespace runs, and single punctuation characters.
    static func tokens(_ s: [UInt16]) -> [Range<Int>] {
        func isWord(_ c: UInt16) -> Bool {
            (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c > 127
        }
        func isSpace(_ c: UInt16) -> Bool { c == 32 || c == 9 }
        var result: [Range<Int>] = []
        var i = 0
        while i < s.count {
            let start = i
            if isWord(s[i]) {
                while i < s.count, isWord(s[i]) { i += 1 }
            } else if isSpace(s[i]) {
                while i < s.count, isSpace(s[i]) { i += 1 }
            } else {
                i += 1
            }
            result.append(start..<i)
        }
        return result
    }

    static func lcs(_ a: [[UInt16]], _ b: [[UInt16]]) -> (Set<Int>, Set<Int>) {
        let n = a.count, m = b.count
        var table = [Int](repeating: 0, count: (n + 1) * (m + 1))
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                table[i * (m + 1) + j] = a[i] == b[j] ? table[(i + 1) * (m + 1) + j + 1] + 1
                    : max(table[(i + 1) * (m + 1) + j], table[i * (m + 1) + j + 1])
            }
        }
        var keepA = Set<Int>(), keepB = Set<Int>()
        var i = 0, j = 0
        while i < n, j < m {
            if a[i] == b[j] {
                keepA.insert(i); keepB.insert(j); i += 1; j += 1
            } else if table[(i + 1) * (m + 1) + j] >= table[i * (m + 1) + j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return (keepA, keepB)
    }

    /// Joins adjacent changed tokens, bridging single spaces so "foo bar" reads as one change.
    static func merge(_ ranges: [Range<Int>], in text: [UInt16]) -> [Range<Int>] {
        var merged: [Range<Int>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = merged.last {
                let gap = text[last.upperBound..<range.lowerBound]
                if gap.count <= 1, gap.allSatisfy({ $0 == 32 }) {
                    merged[merged.count - 1] = last.lowerBound..<range.upperBound
                    continue
                }
            }
            merged.append(range)
        }
        // Whitespace-only highlights are noise unless that's all that changed.
        let meaningful = merged.filter { r in text[r].contains { $0 != 32 && $0 != 9 } }
        return meaningful.isEmpty ? merged : meaningful
    }
}
