import ForestCore
import SwiftUI

struct HistoryView: View {
    @Bindable var store: RepoStore

    var body: some View {
        VSplitView {
            CommitList(store: store)
                .frame(minHeight: 180, idealHeight: 420)
            CommitDetailView(store: store)
                .frame(minHeight: 220, idealHeight: 380)
        }
    }
}

private enum Layout {
    static let rowHeight: CGFloat = 26
    static let laneWidth: CGFloat = 14
}

struct CommitList: View {
    @Bindable var store: RepoStore
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if store.commits.isEmpty && store.loaded {
                EmptyState(title: "No commits yet", systemImage: "clock",
                           message: "Stage some changes and make your first commit.")
            } else {
                list
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search commits, authors, SHAs, refs", text: $store.historyFilter)
                .textFieldStyle(.plain)
            if !store.historyFilter.isEmpty {
                Text("\(store.filteredCommits.count) matches").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(store.commits.count)\(store.canLoadMore ? "+" : "") commits")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var list: some View {
        let rows = store.filteredCommits
        let filtering = !store.historyFilter.isEmpty
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows, id: \.0.id) { commit, row in
                        CommitRow(store: store, commit: commit, row: row, showGraph: !filtering,
                                  selected: store.selectedCommitID == commit.id)
                            .id(commit.id)
                            .onTapGesture { Task { await store.selectCommit(commit.id) } }
                            .contextMenu { CommitMenuItems(store: store, commit: commit) }
                    }
                    if store.canLoadMore && !filtering {
                        Button("Load more history") { Task { await store.loadMoreHistory() } }
                            .buttonStyle(.link)
                            .padding(12)
                    }
                }
            }
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(.downArrow) { move(1, rows: rows, proxy: proxy) }
            .onKeyPress(.upArrow) { move(-1, rows: rows, proxy: proxy) }
            .onChange(of: store.scrollTarget) { _, target in
                guard let target else { return }
                withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(target, anchor: .center) }
                store.scrollTarget = nil
            }
            .onAppear {
                if let target = store.scrollTarget ?? store.selectedCommitID {
                    proxy.scrollTo(target, anchor: .center)
                    store.scrollTarget = nil
                }
            }
        }
    }

    private func move(_ delta: Int, rows: [(Commit, GraphRow)], proxy: ScrollViewProxy) -> KeyPress.Result {
        guard let index = rows.firstIndex(where: { $0.0.id == store.selectedCommitID }) else { return .ignored }
        let next = min(max(index + delta, 0), rows.count - 1)
        let id = rows[next].0.id
        Task { await store.selectCommit(id) }
        proxy.scrollTo(id)
        return .handled
    }
}

private struct CommitRow: View {
    let store: RepoStore
    let commit: Commit
    let row: GraphRow
    let showGraph: Bool
    let selected: Bool
    @State private var hovering = false

    var body: some View {
        let labels = store.labels[commit.sha] ?? []
        let isHead = commit.sha == store.status.headSHA
        HStack(spacing: 8) {
            if showGraph {
                GraphCell(row: row, isHead: isHead, lanes: store.graphWidth)
                    .frame(width: CGFloat(store.graphWidth) * Layout.laneWidth + 6, height: Layout.rowHeight)
            }
            HStack(spacing: 4) {
                ForEach(sortedLabels(labels)) { label in
                    RefBadge(label: label, color: Theme.lane(row.color))
                }
            }
            Text(commit.subject)
                .font(.system(size: 12.5, weight: isHead ? .semibold : .regular))
                .foregroundStyle(selected ? Color.white : .primary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 12)
            HStack(spacing: 6) {
                Avatar(name: commit.authorName, email: commit.authorEmail, size: 17)
                Text(commit.authorName)
                    .lineLimit(1)
            }
            .frame(width: 150, alignment: .leading)
            Text(Format.compact(commit.authorDate))
                .frame(width: 92, alignment: .trailing)
                .help(Format.absolute.string(from: commit.authorDate))
            Text(commit.shortSHA)
                .font(Theme.monoSmall)
                .frame(width: 58, alignment: .trailing)
        }
        .font(.system(size: 12))
        .foregroundStyle(selected ? Color.white.opacity(0.85) : .secondary)
        .padding(.leading, showGraph ? 4 : 12)
        .padding(.trailing, 12)
        .frame(height: Layout.rowHeight)
        .background(background)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    @ViewBuilder private var background: some View {
        if selected {
            Color.accentColor
        } else if hovering {
            Color.primary.opacity(0.045)
        } else {
            Color.clear
        }
    }

    private func sortedLabels(_ labels: [RefLabel]) -> [RefLabel] {
        // HEAD first, then local branches, tags, and remotes that duplicate a local name last.
        let localNames = Set(labels.filter { $0.kind == .localBranch }.map(\.name))
        return labels
            .filter { label in
                guard label.kind == .remoteBranch, let slash = label.name.firstIndex(of: "/") else { return true }
                return !localNames.contains(String(label.name[label.name.index(after: slash)...])) || labels.count <= 3
            }
            .sorted { lhs, rhs in
                if lhs.isHead != rhs.isHead { return lhs.isHead }
                return order(lhs.kind) < order(rhs.kind)
            }
            .prefix(4)
            .map { $0 }
    }

    private func order(_ kind: RefKind) -> Int {
        switch kind {
        case .localBranch: 0
        case .tag: 1
        case .remoteBranch: 2
        case .stash: 3
        }
    }
}

/// Draws one row of the commit graph. Rows tile vertically into continuous lanes.
struct GraphCell: View {
    let row: GraphRow
    let isHead: Bool
    let lanes: Int

    var body: some View {
        Canvas { context, size in
            let lane = Layout.laneWidth
            let mid = size.height / 2
            func x(_ column: Int) -> CGFloat { CGFloat(column) * lane + lane / 2 + 3 }
            let style = StrokeStyle(lineWidth: 2, lineCap: .round)

            for edge in row.passThrough where edge.from < lanes {
                var path = Path()
                path.move(to: CGPoint(x: x(edge.from), y: 0))
                path.addLine(to: CGPoint(x: x(edge.to), y: size.height))
                context.stroke(path, with: .color(Theme.lane(edge.color)), style: style)
            }
            for edge in row.incoming {
                var path = Path()
                let start = CGPoint(x: x(min(edge.from, lanes - 1)), y: 0)
                let end = CGPoint(x: x(min(row.column, lanes - 1)), y: mid)
                path.move(to: start)
                if start.x == end.x {
                    path.addLine(to: end)
                } else {
                    path.addCurve(to: end, control1: CGPoint(x: start.x, y: mid * 0.7), control2: CGPoint(x: end.x, y: mid * 0.3))
                }
                context.stroke(path, with: .color(Theme.lane(edge.color)), style: style)
            }
            for edge in row.outgoing {
                var path = Path()
                let start = CGPoint(x: x(min(row.column, lanes - 1)), y: mid)
                let end = CGPoint(x: x(min(edge.to, lanes - 1)), y: size.height)
                path.move(to: start)
                if start.x == end.x {
                    path.addLine(to: end)
                } else {
                    path.addCurve(to: end, control1: CGPoint(x: start.x, y: mid + mid * 0.7), control2: CGPoint(x: end.x, y: mid + mid * 0.3))
                }
                context.stroke(path, with: .color(Theme.lane(edge.color)), style: style)
            }

            let color = Theme.lane(row.color)
            let center = CGPoint(x: x(min(row.column, lanes - 1)), y: mid)
            let radius: CGFloat = isHead ? 5.5 : 4.5
            let node = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            let isMerge = row.outgoing.count > 1
            if isMerge {
                context.fill(node, with: .color(Color(nsColor: .textBackgroundColor)))
                context.stroke(node, with: .color(color), lineWidth: 2)
            } else {
                context.fill(node, with: .color(color))
                context.stroke(node, with: .color(Color(nsColor: .textBackgroundColor)), lineWidth: 1.5)
            }
            if isHead {
                let ring = Path(ellipseIn: CGRect(x: center.x - radius - 3, y: center.y - radius - 3,
                                                  width: (radius + 3) * 2, height: (radius + 3) * 2))
                context.stroke(ring, with: .color(color.opacity(0.45)), lineWidth: 1.5)
            }
        }
    }
}

struct CommitMenuItems: View {
    let store: RepoStore
    let commit: Commit

    var body: some View {
        let branch = store.status.branch ?? "HEAD"
        Button("Copy SHA") { copy(commit.sha) }
        Button("Copy Subject") { copy(commit.subject) }
        Divider()
        Button("Check Out Commit…") { store.checkout(commit: commit) }
        Button("New Branch Here…") { store.sheet = .newBranch(start: commit.sha) }
        Button("New Tag Here…") { store.sheet = .newTag(sha: commit.sha) }
        Button("New Worktree Here…") { store.sheet = .newWorktree(base: commit.sha, claude: false) }
        Button("New Claude Agent Here…") { store.sheet = .newWorktree(base: commit.sha, claude: true) }
        Divider()
        Button("Cherry-pick onto “\(branch)”") { store.cherryPick(commit) }
        Button("Revert Commit") { store.revert(commit) }
        if commit.sha == store.status.headSHA {
            Button("Amend Message…") {
                store.sidebar = .changes
                store.setAmend(true)
            }
        }
        Menu("Reset “\(branch)” to Here") {
            Button("Soft — keep changes staged") { store.reset(to: commit, mode: .soft) }
            Button("Mixed — keep changes unstaged") { store.reset(to: commit, mode: .mixed) }
            Button("Hard — discard all changes") { store.reset(to: commit, mode: .hard) }
        }
        if let web = store.remotes.first?.webURL {
            Divider()
            Button("Open on Web") { Launcher.openURL(web.appendingPathComponent("commit").appendingPathComponent(commit.sha)) }
        }
    }
}
