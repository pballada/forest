import ForestCore
import SwiftUI
import UniformTypeIdentifiers

/// Compares two branches (or agents' worktrees), or any two files on disk.
struct CompareView: View {
    let store: RepoStore
    @State private var mode: Mode
    @State private var left: String
    @State private var right: String
    @State private var sinceDiverged = true
    @State private var files: [FileChange] = []
    @State private var selected: FileChange?
    @State private var diff: FileDiff?
    @State private var leftFile: URL?
    @State private var rightFile: URL?
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    enum Mode: String, CaseIterable { case branches = "Branches", files = "Files" }

    init(store: RepoStore, left: String?, right: String?, file: URL? = nil) {
        self.store = store
        let main = store.mainWorktree?.branch ?? store.status.branch ?? "HEAD"
        _mode = State(initialValue: file == nil ? .branches : .files)
        _left = State(initialValue: left ?? main)
        _right = State(initialValue: right ?? store.status.branch ?? main)
        _leftFile = State(initialValue: file)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Rectangle().fill(theme.borderColor).frame(height: 0.5)
            switch mode {
            case .branches: branchComparison
            case .files: fileComparison
            }
        }
        .frame(minWidth: 980, idealWidth: 1200, minHeight: 620, idealHeight: 780)
        .background(theme.canvasColor)
        .task(id: "\(mode)-\(left)-\(right)-\(sinceDiverged)") { if mode == .branches { await loadBranches() } }
        .task(id: "\(leftFile?.path ?? "")|\(rightFile?.path ?? "")") { if mode == .files { await loadFiles() } }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Image(systemName: "rectangle.split.2x1")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(theme.accentColor)
            Text("Compare").font(.system(size: 15, weight: .semibold))
            Picker("", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer()
            if mode == .branches {
                refPicker($left)
                Button {
                    swap(&left, &right)
                } label: { Image(systemName: "arrow.left.arrow.right") }
                    .buttonStyle(.borderless)
                    .help("Swap sides")
                refPicker($right)
                Toggle("Only since they diverged", isOn: $sinceDiverged)
                    .toggleStyle(.checkbox)
                    .help("Show what the right side changed since it branched from the left (left...right)")
            }
            Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .frame(height: 50)
    }

    private func refPicker(_ binding: Binding<String>) -> some View {
        Picker("", selection: binding) {
            Section("Worktrees") {
                ForEach(store.worktrees.compactMap(\.branch), id: \.self) { Text($0).tag($0) }
            }
            Section("Branches") {
                ForEach(store.localBranches.filter { $0.worktreePath == nil }) { Text($0.name).tag($0.name) }
            }
            if !store.remoteBranches.isEmpty {
                Section("Remote") {
                    ForEach(store.remoteBranches) { Text($0.name).tag($0.name) }
                }
            }
        }
        .labelsHidden()
        .frame(maxWidth: 220)
    }

    // MARK: Branches

    private var branchComparison: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("\(files.count) file\(files.count == 1 ? "" : "s")")
                    Spacer()
                    Text("+\(files.compactMap(\.additions).reduce(0, +))").foregroundStyle(theme.addedColor)
                    Text("−\(files.compactMap(\.deletions).reduce(0, +))").foregroundStyle(theme.removedColor)
                }
                .font(.system(size: 11.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(theme.secondaryColor)
                .padding(.horizontal, 14)
                .frame(height: 34)
                List(selection: Binding(get: { selected?.id }, set: { id in
                    selected = files.first { $0.id == id }
                    Task { await loadDiff() }
                })) {
                    ForEach(files) { file in
                        HStack(spacing: 8) {
                            FileTypeIcon(path: file.path)
                            VStack(alignment: .leading, spacing: 0) {
                                Text((file.path as NSString).lastPathComponent).font(.system(size: 12)).lineLimit(1)
                                Text((file.path as NSString).deletingLastPathComponent)
                                    .font(.system(size: 10.5)).foregroundStyle(theme.tertiaryColor).lineLimit(1).truncationMode(.head)
                            }
                            Spacer()
                            Text(file.status.letter)
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(Theme.color(for: file.status))
                        }
                        .tag(file.id)
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .overlay {
                    if let error {
                        Text(error).font(.callout).foregroundStyle(theme.secondaryColor).padding()
                    } else if files.isEmpty {
                        Text(left == right ? "Pick two different branches." : "No differences.")
                            .font(.callout).foregroundStyle(theme.secondaryColor)
                    }
                }
            }
            .frame(minWidth: 260, idealWidth: 320, maxWidth: 460)
            .background(theme.sidebarColor)

            DiffView(diff: diff, mode: .readOnly, store: store, emptyTitle: "Choose a file")
                .frame(minWidth: 500)
        }
    }

    private func loadBranches() async {
        error = nil
        guard left != right else { files = []; diff = nil; return }
        do {
            let repository = store.repository
            let from = sinceDiverged ? try await repository.mergeBase(left, right) : left
            files = try await repository.changedFiles(from: from, to: right)
            selected = files.first
            await loadDiff()
        } catch {
            files = []
            diff = nil
            self.error = error.localizedDescription
        }
    }

    private func loadDiff() async {
        guard let selected else { diff = nil; return }
        let repository = store.repository
        let from = sinceDiverged ? ((try? await repository.mergeBase(left, right)) ?? left) : left
        diff = try? await repository.diff(of: selected, from: from, to: right, options: store.diffOptions)
    }

    // MARK: Files

    private var fileComparison: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                FileSlot(title: "Original", url: $leftFile)
                Image(systemName: "arrow.right").foregroundStyle(theme.tertiaryColor)
                FileSlot(title: "Modified", url: $rightFile)
            }
            .padding(14)
            Rectangle().fill(theme.borderColor).frame(height: 0.5)
            if leftFile != nil && rightFile != nil {
                DiffView(diff: diff, mode: .readOnly, store: store, images: imageLoader,
                         emptyTitle: error ?? "The files are identical")
            } else {
                EmptyState(title: "Drop two files to compare", systemImage: "doc.on.doc",
                           message: "Any files: inside a repository or not, text or images.")
            }
        }
    }

    private var imageLoader: ImagePairLoader? {
        guard let leftFile, let rightFile, ImageDiffView.isImage(rightFile.path) else { return nil }
        let loader: ImagePairLoader = { @Sendable in (try? Data(contentsOf: leftFile), try? Data(contentsOf: rightFile)) }
        return loader
    }

    private func loadFiles() async {
        error = nil
        guard let leftFile, let rightFile else { diff = nil; return }
        do {
            diff = try await Repository.diffFiles(leftFile, rightFile, options: store.diffOptions)
        } catch {
            diff = nil
            self.error = error.localizedDescription
        }
    }
}

/// A drop target for one side of a file comparison.
private struct FileSlot: View {
    let title: String
    @Binding var url: URL?
    @Environment(\.theme) private var theme
    @State private var targeted = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: url == nil ? "doc.badge.plus" : "doc.text")
                .font(.system(size: 16))
                .foregroundStyle(url == nil ? theme.tertiaryColor : theme.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(title.uppercased()).font(.system(size: 9.5, weight: .bold)).foregroundStyle(theme.tertiaryColor)
                Text(url.map { Format.abbreviatePath($0.path) } ?? "Drop a file or choose…")
                    .font(.system(size: 12, design: url == nil ? .default : .monospaced))
                    .foregroundStyle(url == nil ? theme.secondaryColor : theme.textColor)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer()
            Button("Choose…", action: choose).controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(theme.textColor.opacity(targeted ? 0.08 : 0.035)))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(targeted ? theme.accentColor : theme.borderColor, style: StrokeStyle(lineWidth: 1, dash: url == nil ? [5, 4] : []))
        )
        .dropDestination(for: URL.self) { urls, _ in
            guard let first = urls.first(where: \.isFileURL) else { return false }
            url = first
            return true
        } isTargeted: { targeted = $0 }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK { url = panel.url }
    }
}
