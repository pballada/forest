import ForestCore
import SwiftUI

enum DiffMode: Equatable {
    case readOnly
    case unstaged
    case staged
}

/// Loads the before/after bytes of a binary file so images can be compared visually.
typealias ImagePairLoader = @Sendable () async -> (before: Data?, after: Data?)

struct DiffView: View {
    let diff: FileDiff?
    let mode: DiffMode
    let store: RepoStore
    var images: ImagePairLoader?
    var emptyTitle = "No file selected"

    @AppStorage("diff.wrap") private var wrap = false
    @AppStorage("diff.presentation") private var presentation = DiffPresentation.unified
    @State private var built: BuiltDiff?
    @State private var controller = DiffCanvasController()
    @State private var localSelection: Set<Int> = []
    @State private var revealedGenerated: String?

    struct BuiltDiff {
        let diff: FileDiff
        let layout: DiffLayout
        let insights: DiffInsights
    }

    private struct BuildKey: Hashable {
        let fingerprint: Int
        let path: String
        let presentation: DiffPresentation
    }

    var body: some View {
        Group {
            if let diff {
                VStack(spacing: 0) {
                    DiffHeader(diff: diff, mode: mode, store: store, wrap: $wrap, presentation: $presentation,
                               controller: controller, canNavigate: !diff.hunks.isEmpty)
                    Divider()
                    content(for: diff)
                }
            } else {
                EmptyState(title: emptyTitle, systemImage: "doc.text.magnifyingglass")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .task(id: diff.map { BuildKey(fingerprint: $0.fingerprint, path: $0.path, presentation: presentation) }) {
            guard let diff else { built = nil; return }
            let presentation = presentation
            let result = await Task.detached(priority: .userInitiated) {
                BuiltDiff(diff: diff, layout: DiffLayout.build(diff, presentation: presentation), insights: DiffInsights.analyze(diff))
            }.value
            if diff.path != built?.diff.path { localSelection = [] }
            built = result
        }
    }

    @ViewBuilder private func content(for diff: FileDiff) -> some View {
        if diff.isBinary {
            if let images, ImageDiffView.isImage(diff.path) {
                ImageDiffView(path: diff.path, load: images)
                    .id(diff.path + String(diff.fingerprint))
            } else {
                EmptyState(title: "Binary file", systemImage: "doc.zipper", message: "There's no text to compare.")
            }
        } else if diff.hunks.isEmpty {
            EmptyState(title: "No content changes", systemImage: "equal.circle",
                       message: diff.headerLines.contains { $0.hasPrefix("old mode") } ? "Only the file mode changed."
                           : store.diffOptions.ignoreWhitespace ? "Only whitespace changed." : "The file was renamed or is empty.")
        } else if let built, built.diff.path == diff.path {
            VStack(spacing: 0) {
                if let project = built.insights.project, !project.isEmpty {
                    XcodeProjectCard(summary: project)
                    Divider()
                }
                if store.diffOptions.ignoreWhitespace, mode != .readOnly {
                    Label("Whitespace changes are hidden, so hunks can't be staged. Show them again to stage.", systemImage: "eye.slash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.orange.opacity(0.08))
                    Divider()
                }
                if let kind = built.insights.generatedKind, revealedGenerated != diff.path {
                    GeneratedFileCard(kind: kind, diff: diff) { revealedGenerated = diff.path }
                } else {
                    DiffCanvas(diff: built.diff, layout: built.layout, wrap: wrap, actions: actions,
                               selection: mode == .readOnly ? localSelection : store.selectedLines,
                               controller: controller,
                               onSelect: { ids in
                                   if mode == .readOnly { localSelection = ids } else { store.selectedLines = ids }
                               },
                               onHunkAction: { hunk, action in store.applyHunk(hunk, action: action) },
                               onOpenInEditor: mode == .readOnly ? nil : { line in
                                   Launcher.openInEditor(store.repository.root.appendingPathComponent(diff.path), line: line)
                               })
                }
                if diff.isTruncated {
                    Text("This diff is very large and was truncated. Open the file to see everything.")
                        .font(.caption).foregroundStyle(.secondary).padding(8)
                }
            }
        } else {
            VStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Laying out \(diff.lineCount.formatted()) lines…").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var actions: HunkActions {
        if store.diffOptions.ignoreWhitespace { return .none }
        switch mode {
        case .readOnly: return .none
        case .unstaged: return .unstaged
        case .staged: return .staged
        }
    }
}

private struct DiffHeader: View {
    let diff: FileDiff
    let mode: DiffMode
    let store: RepoStore
    @Binding var wrap: Bool
    @Binding var presentation: DiffPresentation
    let controller: DiffCanvasController
    let canNavigate: Bool

    var body: some View {
        HStack(spacing: 8) {
            FileTypeIcon(path: diff.path)
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
            Spacer(minLength: 8)
            if mode != .readOnly, !store.selectedLines.isEmpty {
                Button { store.selectedLines = [] } label: {
                    Label("\(store.selectedLines.count) selected", systemImage: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .help("Clear selection (Esc)")
            }
            if !diff.isBinary {
                HStack(spacing: 6) {
                    Text("+\(diff.additions)").foregroundStyle(Theme.added)
                    Text("−\(diff.deletions)").foregroundStyle(Theme.removed)
                }
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
            }

            if canNavigate {
                ControlGroup {
                    Button { controller.previousChange() } label: { Image(systemName: "chevron.up") }
                        .help("Previous change (⌥⌘↑)")
                        .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                    Button { controller.nextChange() } label: { Image(systemName: "chevron.down") }
                        .help("Next change (⌥⌘↓)")
                        .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                }
                .controlSize(.small)
                .fixedSize()
            }

            if !diff.isBinary {
            Picker("Layout", selection: $presentation) {
                Image(systemName: "text.justify.left").tag(DiffPresentation.unified).help("Unified")
                Image(systemName: "rectangle.split.2x1").tag(DiffPresentation.split).help("Side by side")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            .help("Unified or side-by-side")
            }

            Menu {
                Toggle("Wrap Long Lines", isOn: $wrap)
                Toggle("Show Whole File", isOn: Binding(get: { store.diffOptions.context >= DiffOptions.fullFileContext },
                                                       set: { store.setFullFile($0) }))
                Toggle("Hide Whitespace Changes", isOn: Binding(get: { store.diffOptions.ignoreWhitespace },
                                                               set: { store.setIgnoreWhitespace($0) }))
                Divider()
                Button("Open in \(Preferences.editor.rawValue)") {
                    Launcher.openInEditor(store.repository.root.appendingPathComponent(diff.path))
                }
                Button("Copy Path") { copy(diff.path) }
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Diff options")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

/// A coloured document glyph keyed to the file type.
struct FileTypeIcon: View {
    let path: String

    var body: some View {
        let (symbol, color) = Self.style(for: path)
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: 18)
    }

    static func style(for path: String) -> (String, Color) {
        let name = (path as NSString).lastPathComponent
        switch (path as NSString).pathExtension.lowercased() {
        case "swift": return ("swift", .orange)
        case "pbxproj", "xcconfig", "xcscheme", "entitlements": return ("hammer.fill", Theme.sky)
        case "png", "jpg", "jpeg", "gif", "heic", "tiff", "webp", "icns", "bmp", "svg": return ("photo.fill", Theme.moss)
        case "json", "resolved", "yml", "yaml", "toml", "plist", "xcstrings": return ("curlybraces", .purple)
        case "md", "txt", "rtf": return ("doc.richtext.fill", .secondary)
        case "js", "ts", "jsx", "tsx": return ("chevron.left.forwardslash.chevron.right", Theme.sun)
        case "py", "rb", "go", "rs", "kt", "java", "c", "h", "m", "mm", "cpp": return ("chevron.left.forwardslash.chevron.right", Theme.leaf)
        case "sh", "zsh", "bash": return ("terminal.fill", .secondary)
        default:
            if name.hasSuffix(".lock") || DiffInsights.generatedKind(for: name) != nil {
                return ("lock.doc.fill", .secondary)
            }
            return ("doc.text.fill", .secondary)
        }
    }
}

/// Lockfiles are machine-written; show what kind of file it is and let the user opt in.
private struct GeneratedFileCard: View {
    let kind: String
    let diff: FileDiff
    let reveal: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.doc.fill")
                .font(.system(size: 36))
                .foregroundStyle(Theme.leafGradient)
            Text(kind).font(.headline)
            Text("Generated by a tool, so the diff is collapsed. \(diff.additions + diff.deletions) lines changed.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Show Diff", action: reveal)
                .buttonStyle(.bordered)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Reads a `project.pbxproj` change the way you'd describe it out loud.
private struct XcodeProjectCard: View {
    let summary: XcodeProjectSummary
    @AppStorage("diff.projectSummaryExpanded") private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { withAnimation(.snappy) { expanded.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: "hammer.fill").foregroundStyle(Theme.sky)
                    Text("Xcode project changes").font(.system(size: 12, weight: .semibold))
                    Text(headline).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        group("Files added", summary.addedFiles, symbol: "plus", color: Theme.added)
                        group("Files removed", summary.removedFiles, symbol: "minus", color: Theme.removed)
                        group("Added to targets", summary.addedToTargets, symbol: "target", color: Theme.added)
                        group("Removed from targets", summary.removedFromTargets, symbol: "target", color: Theme.removed)
                        group("New targets", summary.addedTargets, symbol: "app.badge", color: Theme.added)
                        group("Removed targets", summary.removedTargets, symbol: "app.badge", color: Theme.removed)
                        group("Packages added", summary.addedPackages, symbol: "shippingbox.fill", color: Theme.added)
                        group("Packages removed", summary.removedPackages, symbol: "shippingbox", color: Theme.removed)
                        if !summary.settings.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Build settings").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                                ForEach(summary.settings.prefix(40)) { setting in
                                    SettingRow(setting: setting)
                                }
                                if summary.settings.count > 40 {
                                    Text("and \(summary.settings.count - 40) more…").font(.caption).foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 190)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.sky.opacity(0.06))
    }

    private var headline: String {
        var parts: [String] = []
        let files = summary.addedFiles.count + summary.removedFiles.count
        if files > 0 { parts.append("\(files) file\(files == 1 ? "" : "s")") }
        let membership = summary.addedToTargets.count + summary.removedFromTargets.count
        if membership > 0 { parts.append("\(membership) target membership\(membership == 1 ? "" : "s")") }
        let packages = summary.addedPackages.count + summary.removedPackages.count
        if packages > 0 { parts.append("\(packages) package\(packages == 1 ? "" : "s")") }
        if !summary.settings.isEmpty { parts.append("\(summary.settings.count) build setting\(summary.settings.count == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private func group(_ title: String, _ items: [String], symbol: String, color: Color) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                FlowLayout(spacing: 5) {
                    ForEach(items.prefix(60), id: \.self) { item in
                        Chip(text: item, systemImage: symbol, color: color)
                    }
                    if items.count > 60 { Chip(text: "+\(items.count - 60) more") }
                }
            }
        }
    }
}

private struct SettingRow: View {
    let setting: XcodeProjectSummary.SettingChange

    var body: some View {
        HStack(spacing: 6) {
            Text(setting.key).font(Theme.monoSmall.weight(.medium))
            if let old = setting.old {
                Text(old.isEmpty ? "\"\"" : old).font(Theme.monoSmall).foregroundStyle(Theme.removed).strikethrough(setting.new != nil)
            }
            if setting.old != nil, setting.new != nil {
                Image(systemName: "arrow.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary)
            }
            if let new = setting.new {
                Text(new.isEmpty ? "\"\"" : new).font(Theme.monoSmall).foregroundStyle(Theme.added)
            }
            if setting.old == nil { Text("added").font(.caption2).foregroundStyle(.tertiary) }
            if setting.new == nil { Text("removed").font(.caption2).foregroundStyle(.tertiary) }
            if setting.count > 1 {
                Text("×\(setting.count)").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    .help("Changed in \(setting.count) build configurations")
            }
        }
        .lineLimit(1)
        .textSelection(.enabled)
    }
}

/// Wraps its children onto as many lines as needed.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: min(maxX, width), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// Before/after comparison for images: side by side, or a swipe you drag across.
struct ImageDiffView: View {
    let path: String
    let load: ImagePairLoader

    enum Style: String, CaseIterable { case twoUp = "2-Up", swipe = "Swipe" }

    @State private var before: NSImage?
    @State private var after: NSImage?
    @State private var beforeBytes = 0
    @State private var afterBytes = 0
    @State private var loaded = false
    @State private var style = Style.twoUp
    @State private var swipe: CGFloat = 0.5

    static func isImage(_ path: String) -> Bool {
        ["png", "jpg", "jpeg", "gif", "heic", "tiff", "tif", "webp", "bmp", "icns", "ico", "pdf"].contains((path as NSString).pathExtension.lowercased())
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Style", selection: $style) {
                    ForEach(Style.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .disabled(before == nil || after == nil)
                Spacer()
            }
            .padding(10)
            if !loaded {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if style == .swipe, let before, let after {
                swipeView(before: before, after: after)
            } else {
                HStack(spacing: 16) {
                    pane("Before", image: before, bytes: beforeBytes, tint: Theme.removed)
                    pane("After", image: after, bytes: afterBytes, tint: Theme.added)
                }
                .padding(16)
            }
        }
        .task {
            let pair = await load()
            before = pair.before.flatMap(NSImage.init(data:))
            after = pair.after.flatMap(NSImage.init(data:))
            beforeBytes = pair.before?.count ?? 0
            afterBytes = pair.after?.count ?? 0
            loaded = true
        }
    }

    private func pane(_ title: String, image: NSImage?, bytes: Int, tint: Color) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(tint).frame(width: 7, height: 7)
                Text(title).font(.system(size: 12, weight: .semibold))
                Spacer()
                if let image {
                    Text(verbatim: "\(Int(image.size.width))×\(Int(image.size.height)) · \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            ZStack {
                Checkerboard()
                if let image {
                    Image(nsImage: image).resizable().interpolation(.high).scaledToFit().padding(8)
                } else {
                    Text(title == "Before" ? "Didn't exist" : "Deleted").foregroundStyle(.secondary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(tint.opacity(0.35), lineWidth: 1.5))
        }
    }

    private func swipeView(before: NSImage, after: NSImage) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Checkerboard()
                Image(nsImage: before).resizable().interpolation(.high).scaledToFit().padding(8)
                Image(nsImage: after).resizable().interpolation(.high).scaledToFit().padding(8)
                    .mask(alignment: .leading) { Rectangle().frame(width: geometry.size.width * swipe) }
                Rectangle()
                    .fill(Theme.leaf)
                    .frame(width: 2)
                    .overlay(Circle().fill(Theme.leaf).frame(width: 18, height: 18).overlay(
                        Image(systemName: "arrow.left.and.right").font(.system(size: 8, weight: .bold)).foregroundStyle(.white)))
                    .offset(x: geometry.size.width * swipe - 1)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                swipe = max(0, min(1, value.location.x / max(geometry.size.width, 1)))
            })
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .padding(16)
        .overlay(alignment: .bottom) {
            HStack {
                Text("After").foregroundStyle(Theme.added)
                Spacer()
                Text("Before").foregroundStyle(Theme.removed)
            }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 28)
            .padding(.bottom, 22)
        }
    }
}

private struct Checkerboard: View {
    var body: some View {
        Canvas { context, size in
            let tile: CGFloat = 10
            for row in 0..<Int(size.height / tile + 1) {
                for column in 0..<Int(size.width / tile + 1) where (row + column).isMultiple(of: 2) {
                    context.fill(Path(CGRect(x: CGFloat(column) * tile, y: CGFloat(row) * tile, width: tile, height: tile)),
                                 with: .color(.primary.opacity(0.05)))
                }
            }
        }
    }
}
