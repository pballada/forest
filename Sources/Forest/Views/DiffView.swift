import ForestCore
import SwiftUI

enum DiffMode: Equatable {
    case readOnly
    case unstaged
    case staged
}

struct DiffView: View {
    let diff: FileDiff?
    let mode: DiffMode
    let store: RepoStore
    @AppStorage("diff.wrap") private var wrap = false

    var body: some View {
        if let diff {
            VStack(spacing: 0) {
                DiffHeader(diff: diff, mode: mode, store: store, wrap: $wrap)
                Divider()
                if diff.isBinary {
                    EmptyState(title: "Binary file", systemImage: "doc.zipper", message: "Forest doesn't show binary changes.")
                } else if diff.hunks.isEmpty {
                    EmptyState(title: "No content changes", systemImage: "equal.circle",
                               message: diff.headerLines.contains { $0.hasPrefix("old mode") } ? "Only the file mode changed." : "The file was renamed or is empty.")
                } else {
                    GeometryReader { geometry in
                    ScrollView(wrap ? .vertical : [.vertical, .horizontal]) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(diff.hunks) { hunk in
                                HunkView(hunk: hunk, mode: mode, store: store, wrap: wrap)
                            }
                            if diff.isTruncated {
                                Text("Diff truncated — open the file to see everything.")
                                    .font(.caption).foregroundStyle(.secondary).padding(12)
                            }
                        }
                        .padding(.bottom, 20)
                        // Rows stretch to at least the viewport so line backgrounds span the full width.
                        .frame(minWidth: geometry.size.width, maxWidth: wrap ? geometry.size.width : nil, alignment: .leading)
                    }
                    }
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
        } else {
            EmptyState(title: "No file selected", systemImage: "doc.text.magnifyingglass")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor))
        }
    }
}

private struct DiffHeader: View {
    let diff: FileDiff
    let mode: DiffMode
    let store: RepoStore
    @Binding var wrap: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text").foregroundStyle(.secondary)
            if let old = diff.oldPath, let new = diff.newPath, old != new {
                Text(old).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                Image(systemName: "arrow.right").font(.caption).foregroundStyle(.tertiary)
            }
            Text(diff.path)
                .font(.system(size: 12.5, weight: .medium))
                .lineLimit(1)
                .truncationMode(.head)
                .textSelection(.enabled)
            if diff.isNewFile { Chip(text: "new", color: Theme.added) }
            if diff.isDeletedFile { Chip(text: "deleted", color: Theme.removed) }
            Spacer()
            HStack(spacing: 6) {
                Text("+\(diff.additions)").foregroundStyle(Theme.added)
                Text("−\(diff.deletions)").foregroundStyle(Theme.removed)
            }
            .font(.system(size: 11.5, weight: .semibold, design: .rounded))
            .monospacedDigit()
            if mode != .readOnly, !store.selectedLines.isEmpty {
                Text("\(store.selectedLines.count) lines selected").font(.caption).foregroundStyle(.secondary)
                Button("Clear") { store.selectedLines = [] }.controlSize(.small)
            }
            Toggle(isOn: $wrap) { Image(systemName: "text.word.spacing") }
                .toggleStyle(.button)
                .controlSize(.small)
                .help("Wrap long lines")
            HoverButton(systemImage: "arrow.up.forward.square", help: "Open in \(Preferences.editor.rawValue)") {
                Launcher.openInEditor(store.repository.root.appendingPathComponent(diff.path))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }
}

private struct HunkView: View {
    let hunk: DiffHunk
    let mode: DiffMode
    let store: RepoStore
    let wrap: Bool

    var body: some View {
        let highlights = IntralineDiff.highlights(for: hunk)
        let hunkSelection = store.selectedLines.intersection(hunk.lines.map(\.id))
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("@@ −\(hunk.oldStart),\(hunk.oldCount) +\(hunk.newStart),\(hunk.newCount)")
                    .font(Theme.monoSmall)
                    .foregroundStyle(Color.accentColor.opacity(0.9))
                if !hunk.context.isEmpty {
                    Text(hunk.context).font(Theme.monoSmall).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 20)
                hunkActions(selectedCount: hunkSelection.count)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.accentColor.opacity(0.07))
            .overlay(alignment: .top) { Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 1) }

            ForEach(hunk.lines) { line in
                DiffLineRow(line: line, highlight: highlights[line.id], selectable: mode != .readOnly,
                            selected: store.selectedLines.contains(line.id), wrap: wrap) {
                    toggle(line)
                }
            }
        }
    }

    @ViewBuilder private func hunkActions(selectedCount: Int) -> some View {
        let scope = selectedCount > 0 ? "Lines" : "Hunk"
        switch mode {
        case .readOnly:
            EmptyView()
        case .unstaged:
            HStack(spacing: 6) {
                Button("Discard \(scope)") { store.applyHunk(hunk, action: .discard) }
                Button("Stage \(scope)") { store.applyHunk(hunk, action: .stage) }
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.small)
        case .staged:
            Button("Unstage \(scope)") { store.applyHunk(hunk, action: .unstage) }
                .controlSize(.small)
        }
    }

    private func toggle(_ line: DiffLine) {
        guard line.isChange else { return }
        if NSEvent.modifierFlags.contains(.shift), let anchor = store.selectedLines.max() ?? store.selectedLines.min() {
            let range = min(anchor, line.id)...max(anchor, line.id)
            let ids = hunk.lines.filter { range.contains($0.id) && $0.isChange }.map(\.id)
            store.selectedLines.formUnion(ids)
        } else if store.selectedLines.contains(line.id) {
            store.selectedLines.remove(line.id)
        } else {
            store.selectedLines.insert(line.id)
        }
    }
}

private struct DiffLineRow: View {
    let line: DiffLine
    let highlight: Range<Int>?
    let selectable: Bool
    let selected: Bool
    let wrap: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            gutter(line.oldLine)
            gutter(line.newLine)
            Text(marker)
                .frame(width: 16)
                .foregroundStyle(markerColor)
            Text(attributed)
                .lineLimit(wrap ? nil : 1)
                .fixedSize(horizontal: !wrap, vertical: true)
                .frame(maxWidth: wrap ? .infinity : nil, alignment: .leading)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .font(Theme.mono)
        .padding(.vertical, 0.5)
        .frame(minHeight: 18)
        .background(background)
        .overlay(alignment: .leading) {
            if selected { Rectangle().fill(Color.accentColor).frame(width: 3) }
        }
    }

    private func gutter(_ number: Int?) -> some View {
        Text(number.map(String.init) ?? "")
            .foregroundStyle(.tertiary)
            .frame(width: 44, alignment: .trailing)
            .padding(.trailing, 6)
            .background(selected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.025))
            .contentShape(Rectangle())
            .onTapGesture { if selectable { toggle() } }
            .help(selectable && line.isChange ? "Click to select this line, ⇧-click to select a range" : "")
    }

    private var marker: String {
        switch line.kind {
        case .addition: "+"
        case .deletion: "−"
        default: ""
        }
    }

    private var markerColor: Color {
        line.kind == .addition ? Theme.added : line.kind == .deletion ? Theme.removed : .secondary
    }

    private var background: Color {
        switch line.kind {
        case .addition: Theme.added.opacity(selected ? 0.24 : 0.11)
        case .deletion: Theme.removed.opacity(selected ? 0.24 : 0.10)
        default: .clear
        }
    }

    private var attributed: AttributedString {
        if line.kind == .noNewline {
            var text = AttributedString(line.text)
            text.foregroundColor = .secondary
            return text
        }
        let content = line.text.replacingOccurrences(of: "\t", with: "    ")
        var text = AttributedString(content)
        if let highlight, line.text.count == content.count {
            let chars = Array(content)
            if highlight.upperBound <= chars.count, !highlight.isEmpty {
                let start = text.index(text.startIndex, offsetByCharacters: highlight.lowerBound)
                let end = text.index(text.startIndex, offsetByCharacters: highlight.upperBound)
                text[start..<end].backgroundColor = (line.kind == .addition ? Theme.added : Theme.removed).opacity(0.32)
            }
        }
        return text
    }
}

/// Word-level emphasis for modified lines: pairs runs of deletions with following additions
/// and highlights everything between their common prefix and suffix.
enum IntralineDiff {
    static func highlights(for hunk: DiffHunk) -> [Int: Range<Int>] {
        var result: [Int: Range<Int>] = [:]
        let lines = hunk.lines
        var i = 0
        while i < lines.count {
            guard lines[i].kind == .deletion else { i += 1; continue }
            var deletions: [DiffLine] = []
            while i < lines.count, lines[i].kind == .deletion { deletions.append(lines[i]); i += 1 }
            var additions: [DiffLine] = []
            while i < lines.count, lines[i].kind == .addition { additions.append(lines[i]); i += 1 }
            guard deletions.count == additions.count else { continue }
            for (old, new) in zip(deletions, additions) {
                let a = Array(old.text), b = Array(new.text)
                guard a.count < 800, b.count < 800 else { continue }
                var prefix = 0
                while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
                var suffix = 0
                while suffix < a.count - prefix, suffix < b.count - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
                // Only emphasise when the lines are recognisably similar.
                let shared = prefix + suffix
                guard shared * 3 >= max(a.count, b.count) else { continue }
                if prefix < a.count - suffix { result[old.id] = prefix..<(a.count - suffix) }
                if prefix < b.count - suffix { result[new.id] = prefix..<(b.count - suffix) }
            }
        }
        return result
    }
}
