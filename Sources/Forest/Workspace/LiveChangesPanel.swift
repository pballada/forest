import ForestCore
import SwiftUI

/// Files changing in the selected worktree, as they change: uncommitted work first (freshest on top,
/// briefly lit when just written), then what the branch has already committed on top of main.
struct LiveChangesPanel: View {
    let project: ProjectStore
    @Bindable var store: RepoStore
    let path: String
    @Environment(\.theme) private var theme
    @AppStorage("live.grouping") private var grouping = Grouping.recent
    @State private var committed: [FileChange] = []
    @State private var commitsAhead = 0

    enum Grouping: String { case recent, folder }

    private var worktree: Worktree? { project.worktree(at: path) }
    private var base: String? {
        guard let worktree, !worktree.isMain else { return nil }
        return project.main.status.branch
    }

    /// Working-copy changes, one row per path (a file can be both staged and modified).
    private var uncommitted: [FileChange] {
        var seen = Set<String>()
        return store.allChanges.filter { seen.insert($0.path).inserted }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(theme.borderColor).frame(height: 0.5)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                List {
                    section(title: "Uncommitted", files: sorted(uncommitted, now: context.date), committed: false, now: context.date)
                    if base != nil {
                        section(title: "Committed on this branch", files: sorted(committed, now: context.date), committed: true, now: context.date)
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .overlay {
                    if uncommitted.isEmpty && committed.isEmpty && store.loaded {
                        VStack(spacing: 6) {
                            Image(systemName: "leaf").font(.system(size: 22)).foregroundStyle(theme.tertiaryColor)
                            Text("Nothing changed yet").font(.system(size: 12, weight: .medium)).foregroundStyle(theme.secondaryColor)
                            Text("Files appear here the moment they're written.").font(.system(size: 11)).foregroundStyle(theme.tertiaryColor)
                        }
                        .multilineTextAlignment(.center)
                        .padding()
                    }
                }
            }
            footer
        }
        .background(theme.sidebarColor)
        .task(id: "\(store.status.headSHA ?? "")-\(base ?? "")") { await loadCommitted() }
    }

    // MARK: Header & footer

    private var header: some View {
        let files = uncommitted.count + committed.count
        let working = project.state(for: path) == .working
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text("Live Changes").font(.system(size: 12.5, weight: .semibold))
                    if working { PulsingDot(color: theme.agentColor).help("Claude is working") }
                }
                Text(files == 0 ? "Clean" : "\(files) file\(files == 1 ? "" : "s")\(totals)")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.secondaryColor)
                    .monospacedDigit()
            }
            Spacer()
            Picker("", selection: $grouping) {
                Image(systemName: "clock").help("Most recent first").tag(Grouping.recent)
                Image(systemName: "folder").help("By folder").tag(Grouping.folder)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .frame(height: 54)
    }

    private var totals: String {
        let counts = uncommitted.map(lineCounts)
        let added = counts.map(\.0).reduce(0, +) + committed.compactMap(\.additions).reduce(0, +)
        let removed = counts.map(\.1).reduce(0, +) + committed.compactMap(\.deletions).reduce(0, +)
        return added + removed > 0 ? " · +\(added) −\(removed)" : ""
    }

    @ViewBuilder private var footer: some View {
        if let worktree {
            VStack(spacing: 8) {
                Rectangle().fill(theme.borderColor).frame(height: 0.5)
                if let base {
                    HStack {
                        Text(commitsAhead == 0 ? "No commits on top of \(base)" : "\(commitsAhead) commit\(commitsAhead == 1 ? "" : "s") on top of \(base)")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.secondaryColor)
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    HStack(spacing: 8) {
                        Button { project.main.sheet = .review(worktree) } label: {
                            Label("Review", systemImage: "eye").frame(maxWidth: .infinity)
                        }
                        Button { project.main.mergeIntoMain(worktree) } label: {
                            Label("Merge", systemImage: "arrow.triangle.merge").frame(maxWidth: .infinity)
                        }
                        .disabled(commitsAhead == 0)
                    }
                    .controlSize(.regular)
                    .padding(.horizontal, 12)
                } else {
                    Button { store.sidebar = .changes } label: {
                        Label("Commit…", systemImage: "checkmark.circle").frame(maxWidth: .infinity)
                    }
                    .disabled(store.status.isClean)
                    .padding(.horizontal, 12)
                }
            }
            .padding(.bottom, 12)
        }
    }

    // MARK: Rows

    @ViewBuilder
    private func section(title: String, files: [FileChange], committed: Bool, now: Date) -> some View {
        if !files.isEmpty {
            Section {
                switch grouping {
                case .recent:
                    ForEach(files, id: \.path) { row($0, committed: committed, now: now) }
                case .folder:
                    let groups = Dictionary(grouping: files) { ($0.path as NSString).deletingLastPathComponent }
                    ForEach(groups.keys.sorted(), id: \.self) { folder in
                        Text(folder.isEmpty ? "/" : folder + "/")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(theme.tertiaryColor)
                            .lineLimit(1)
                            .truncationMode(.head)
                            .padding(.top, 4)
                        ForEach(groups[folder] ?? [], id: \.path) { row($0, committed: committed, now: now, showFolder: false) }
                    }
                }
            } header: {
                HStack {
                    Text(title)
                    Spacer()
                    Text("\(files.count)").monospacedDigit()
                }
            }
        }
    }

    private func row(_ file: FileChange, committed: Bool, now: Date, showFolder: Bool = true) -> some View {
        let touched = store.recentlyTouched[file.path]
        let age = touched.map { now.timeIntervalSince($0) } ?? .infinity
        let counts = committed ? (file.additions ?? 0, file.deletions ?? 0) : lineCounts(file)
        return LiveFileRow(file: file, counts: counts, freshness: age, showFolder: showFolder)
            .contentShape(Rectangle())
            .onTapGesture { open(file, committed: committed) }
            .contextMenu {
                Button("Show Diff") { open(file, committed: committed) }
                Button("Open in \(Preferences.editor.rawValue)") { Launcher.openInEditor(store.repository.root.appendingPathComponent(file.path)) }
                Button("Reveal in Finder") { Launcher.revealInFinder(store.repository.root.appendingPathComponent(file.path)) }
                Button("Copy Path") { copy(file.path) }
                Button("Compare with Another File…") {
                    store.sheet = .compare(left: nil, right: nil, file: store.repository.root.appendingPathComponent(file.path))
                }
                if !committed {
                    Divider()
                    Button("Discard Changes…", role: .destructive) { store.discard(store.allChanges.filter { $0.path == file.path }) }
                }
            }
    }

    /// Staged and unstaged line counts of a working-copy path, added together (untracked files count every line).
    private func lineCounts(_ file: FileChange) -> (Int, Int) {
        let entries = store.allChanges.filter { $0.path == file.path }
        var added = 0, removed = 0
        for entry in entries {
            if let counts = store.lineCounts[entry.id] {
                added += counts.0
                removed += counts.1
            } else if entry.status == .untracked,
                      let url = Optional(store.repository.root.appendingPathComponent(entry.path)),
                      ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? .max) < 512_000,
                      let text = try? String(contentsOf: url, encoding: .utf8) {
                added += text.split(separator: "\n", omittingEmptySubsequences: false).count - (text.hasSuffix("\n") ? 1 : 0)
            }
        }
        return (added, removed)
    }

    private func open(_ file: FileChange, committed: Bool) {
        if committed, let worktree {
            project.main.sheet = .review(worktree)
        } else {
            store.sidebar = .changes
            let ids = store.allChanges.filter { $0.path == file.path }.map(\.id)
            store.selectedChangeIDs = Set(ids.prefix(1))
        }
    }

    private func sorted(_ files: [FileChange], now: Date) -> [FileChange] {
        files.sorted { lhs, rhs in
            let l = store.recentlyTouched[lhs.path] ?? .distantPast
            let r = store.recentlyTouched[rhs.path] ?? .distantPast
            return l != r ? l > r : lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
        }
    }

    private func loadCommitted() async {
        guard let base else {
            committed = []
            commitsAhead = 0
            return
        }
        let repository = store.repository
        guard let mergeBase = try? await repository.mergeBase(base, "HEAD") else { return }
        committed = (try? await repository.changedFiles(from: mergeBase, to: "HEAD")) ?? []
        commitsAhead = (try? await repository.log(limit: 500, revisions: ["\(base)..HEAD"]))?.count ?? 0
    }
}

private struct LiveFileRow: View {
    let file: FileChange
    let counts: (Int, Int)
    /// Seconds since the file was last written (infinity when unknown).
    let freshness: TimeInterval
    var showFolder = true
    @Environment(\.theme) private var theme

    private var fresh: Bool { freshness < 4 }

    var body: some View {
        HStack(spacing: 8) {
            FileTypeIcon(path: file.path)
            VStack(alignment: .leading, spacing: 0) {
                Text((file.path as NSString).lastPathComponent)
                    .font(.system(size: 12, weight: fresh ? .semibold : .regular))
                    .foregroundStyle(theme.textColor)
                    .lineLimit(1)
                if showFolder {
                    let folder = (file.path as NSString).deletingLastPathComponent
                    if !folder.isEmpty {
                        Text(folder)
                            .font(.system(size: 10.5))
                            .foregroundStyle(theme.tertiaryColor)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
            }
            Spacer(minLength: 4)
            if freshness < 60 {
                Text(freshness < 5 ? "now" : "\(Int(freshness))s")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(fresh ? theme.agentColor : theme.tertiaryColor)
                    .monospacedDigit()
            }
            HStack(spacing: 3) {
                if counts.0 > 0 { Text("+\(counts.0)").foregroundStyle(theme.addedColor) }
                if counts.1 > 0 { Text("−\(counts.1)").foregroundStyle(theme.removedColor) }
            }
            .font(.system(size: 10.5, weight: .medium, design: .rounded))
            .monospacedDigit()
            Text(file.status.letter)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(Theme.color(for: file.status))
                .frame(width: 12)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(theme.agentColor.opacity(fresh ? 0.16 * (1 - freshness / 4) + 0.04 : 0))
        )
        .animation(.easeOut(duration: 0.6), value: fresh)
    }
}
