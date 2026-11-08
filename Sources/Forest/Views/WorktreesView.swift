import ForestCore
import SwiftUI

struct WorktreesView: View {
    @Bindable var store: RepoStore

    var body: some View {
        let main = store.worktrees.filter(\.isMain)
        let agents = store.worktrees.filter { $0.isClaude && !$0.isMain }
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    header
                    WorktreeSection(title: "Main", systemImage: "house", store: store, worktrees: main, tint: Theme.leaf)
                    WorktreeSection(title: "Claude Agents", systemImage: "sparkles", store: store, worktrees: agents, tint: Theme.claude) {
                        AgentEmptyCard(store: store)
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onAppear { scroll(proxy) }
            .onChange(of: store.sidebar) { _, _ in scroll(proxy) }
        }
        .background(
            LinearGradient(colors: [Theme.leaf.opacity(0.07), Theme.claude.opacity(0.03), Color.clear], startPoint: .top, endPoint: .center)
        )
        .task {
            await store.refreshWorktreeStatuses()
            store.refreshClaudeSessions()
        }
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        if case .worktree(let path) = store.sidebar {
            withAnimation { proxy.scrollTo(path, anchor: .center) }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Worktrees")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                HStack(spacing: 10) {
                    Text("\(store.worktrees.count) checked out")
                    if !store.claudeWorktrees.isEmpty {
                        Text("·")
                        Label("\(store.claudeWorktrees.count) Claude agent\(store.claudeWorktrees.count == 1 ? "" : "s")", systemImage: "sparkles")
                            .foregroundStyle(Theme.claude)
                    }
                    if store.activeAgents > 0 {
                        Text("·")
                        HStack(spacing: 5) {
                            PulsingDot(color: .green)
                            Text("\(store.activeAgents) working now")
                        }
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button { store.pruneWorktrees() } label: { Label("Prune", systemImage: "scissors") }
                .help("Remove records of worktrees whose folders were deleted")
            Button { store.sheet = .newAgent(base: nil) } label: {
                Label("New Claude Agent", systemImage: "sparkles")
                    .padding(.horizontal, 4)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.claude)
        }
        .controlSize(.large)
    }
}

private struct WorktreeSection<Empty: View>: View {
    let title: String
    let systemImage: String
    let store: RepoStore
    let worktrees: [Worktree]
    var tint: Color = .secondary
    @ViewBuilder var empty: Empty

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 330, maximum: 520), spacing: 16)], alignment: .leading, spacing: 16) {
                if worktrees.isEmpty {
                    empty
                }
                ForEach(worktrees) { worktree in
                    WorktreeCard(store: store, worktree: worktree)
                        .id(worktree.path)
                }
            }
        }
    }
}

extension WorktreeSection where Empty == EmptyView {
    init(title: String, systemImage: String, store: RepoStore, worktrees: [Worktree], tint: Color = .secondary) {
        self.init(title: title, systemImage: systemImage, store: store, worktrees: worktrees, tint: tint) { EmptyView() }
    }
}

private struct AgentEmptyCard: View {
    let store: RepoStore
    @State private var hovering = false

    var body: some View {
        Button { store.sheet = .newAgent(base: nil) } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    ClaudeMark(size: 30)
                    Text("Run Claude in its own worktree").font(.headline)
                }
                Text("Describe a task and Forest creates an isolated worktree in .claude/worktrees, branches it, and starts Claude Code there — your checkout stays untouched.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Text("New Claude Agent  ⌥⌘N").font(.caption.weight(.semibold)).foregroundStyle(Theme.claude)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Theme.claude.opacity(hovering ? 0.7 : 0.35), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct WorktreeCard: View {
    let store: RepoStore
    let worktree: Worktree
    @State private var hovering = false
    @State private var ahead: [Commit] = []

    private var status: WorktreeStatus? { store.worktreeStatus[worktree.path] }
    private var session: ClaudeSessionInfo? { store.claudeSessions[worktree.path] }
    private var isCurrent: Bool { store.currentWorktree?.path == worktree.path }
    private var highlighted: Bool { store.sidebar == .worktree(worktree.path) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            titleRow
            if worktree.isClaude {
                agentInfo
            }
            statusRow
            if let commit = status?.lastCommit {
                HStack(spacing: 6) {
                    Avatar(name: commit.authorName, email: commit.authorEmail, size: 16)
                    Text(commit.subject).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(Format.ago(commit.commitDate)).foregroundStyle(.tertiary)
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            }
            if !ahead.isEmpty, let base = store.mainWorktree?.branch {
                Text("\(ahead.count)\(ahead.count == 20 ? "+" : "") commit\(ahead.count == 1 ? "" : "s") not on \(base)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Divider().opacity(0.6)
            actions
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.background)
                .shadow(color: .black.opacity(hovering ? 0.14 : 0.07), radius: hovering ? 14 : 6, y: hovering ? 6 : 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(borderColor, lineWidth: highlighted || isCurrent ? 1.5 : 0.75)
        )
        .overlay(alignment: .topLeading) {
            if worktree.isClaude {
                UnevenRoundedRectangle(topLeadingRadius: 14, topTrailingRadius: 14, style: .continuous)
                    .fill(Theme.claudeGradient)
                    .frame(height: 3)
            }
        }
        .scaleEffect(hovering ? 1.006 : 1)
        .animation(.spring(duration: 0.25), value: hovering)
        .onHover { hovering = $0 }
        .contextMenu { WorktreeMenuItems(store: store, worktree: worktree) }
        .onTapGesture(count: 2) { open() }
        .task(id: "\(worktree.path)-\(status?.lastCommit?.sha ?? "")") { ahead = await store.commitsAhead(of: worktree) }
    }

    private var borderColor: Color {
        if highlighted { return Theme.leaf }
        if isCurrent { return worktree.isClaude ? Theme.claude.opacity(0.7) : Theme.leaf.opacity(0.6) }
        return Color.primary.opacity(0.09)
    }

    private var titleRow: some View {
        HStack(spacing: 10) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                Text(worktree.isMain ? store.mainRoot?.lastPathComponent ?? worktree.name : worktree.name)
                    .font(.system(size: 14.5, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Image(systemName: worktree.branch == nil ? "point.topleft.down.to.point.bottomright.curvepath" : "arrow.triangle.branch")
                        .font(.system(size: 9.5, weight: .bold))
                    Text(worktree.branch ?? "detached at \(worktree.head?.prefix(7) ?? "?")")
                        .font(Theme.monoSmall)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            if let pr = store.pullRequest(for: worktree.branch) { PullRequestChip(pullRequest: pr) }
            if isCurrent { Chip(text: "This window", color: Theme.leaf) }
            if worktree.isLocked { Chip(text: "Locked", systemImage: "lock.fill") .help(worktree.lockReason ?? "") }
            if status?.missing == true || worktree.isPrunable { Chip(text: "Missing", systemImage: "exclamationmark.triangle.fill", color: .orange) }
        }
    }

    @ViewBuilder private var icon: some View {
        if worktree.isClaude {
            ClaudeMark(size: 32)
        } else {
            Image(systemName: worktree.isMain ? "house.fill" : "square.stack.3d.up.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(Circle().fill(worktree.isMain ? AnyShapeStyle(Theme.leafGradient) : AnyShapeStyle(Theme.forestGradient)))
        }
    }

    @ViewBuilder private var agentInfo: some View {
        if let session {
            VStack(alignment: .leading, spacing: 6) {
                if let title = session.title {
                    Text(title).font(.system(size: 13, weight: .medium))
                }
                if let task = session.task {
                    Text("“\(task)”")
                        .font(.system(size: 12))
                        .italic()
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                HStack(spacing: 8) {
                    if session.isActive {
                        HStack(spacing: 5) {
                            PulsingDot(color: .green)
                            Text("Working now").foregroundStyle(.green)
                        }
                    } else if let last = session.lastActivity {
                        Label("Last active \(Format.ago(last))", systemImage: "clock")
                            .foregroundStyle(.secondary)
                    }
                    Text("· \(session.sessionCount) session\(session.sessionCount == 1 ? "" : "s")").foregroundStyle(.tertiary)
                    Spacer()
                    if let pr = session.pullRequestURL {
                        Button { Launcher.openURL(pr) } label: {
                            Label("PR #\(pr.lastPathComponent)", systemImage: "arrow.triangle.pull")
                        }
                        .buttonStyle(.plain).foregroundStyle(Theme.leaf)
                    }
                }
                .font(.system(size: 11.5, weight: .medium))
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.claude.opacity(0.08)))
        } else {
            Text("No Claude session yet — launch Claude to start working here.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var statusRow: some View {
        HStack(spacing: 6) {
            if let status {
                if status.missing {
                    Chip(text: "Folder missing", color: .orange)
                } else if !status.isDirty {
                    Chip(text: "Clean", systemImage: "checkmark", color: Theme.added)
                }
                if status.conflicted > 0 { Chip(text: "\(status.conflicted) conflicts", systemImage: "exclamationmark.triangle.fill", color: .red) }
                if status.changed > 0 { Chip(text: "\(status.changed) modified", systemImage: "pencil", color: .orange) }
                if status.staged > 0 { Chip(text: "\(status.staged) staged", systemImage: "tray.full", color: Theme.added) }
                if status.untracked > 0 { Chip(text: "\(status.untracked) new", systemImage: "plus", color: .teal) }
                Spacer(minLength: 4)
                if status.upstream != nil {
                    AheadBehind(ahead: status.ahead, behind: status.behind)
                    if status.ahead == 0 && status.behind == 0 {
                        Image(systemName: "checkmark.icloud").font(.caption).foregroundStyle(.tertiary).help("Up to date with \(status.upstream ?? "")")
                    }
                } else if !worktree.isMain, worktree.branch != nil {
                    Image(systemName: "icloud.slash").font(.caption).foregroundStyle(.tertiary).help("Not pushed yet")
                }
            } else {
                ProgressView().controlSize(.mini)
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 2) {
            if !isCurrent {
                Button(action: open) { Label("Open", systemImage: "macwindow") }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            if !worktree.isMain, worktree.branch != nil, worktree.branch != store.mainWorktree?.branch {
                Button { store.sheet = .review(worktree) } label: { Label("Review", systemImage: "eye") }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("See everything this worktree changed, ask Claude for a review, and send feedback")
            }
            HoverButton(systemImage: "terminal", help: "Open in \(Preferences.terminal.rawValue)") { Launcher.openTerminal(at: worktree.url) }
            HoverButton(systemImage: "chevron.left.forwardslash.chevron.right", help: "Open in \(Preferences.editor.rawValue)") { Launcher.openInEditor(worktree.url) }
            HoverButton(systemImage: "folder", help: "Reveal in Finder") { Launcher.revealInFinder(worktree.url) }
            Spacer()
            Text(Format.abbreviatePath(worktree.path))
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: 160, alignment: .trailing)
                .help(worktree.path)
            Button { Launcher.launchClaude(in: worktree.url, continuing: session != nil) } label: {
                Label(session == nil ? "Launch Claude" : "Continue", systemImage: "sparkles")
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.claude)
            .controlSize(.small)
            .help(session == nil ? "Start Claude Code in this worktree" : "Continue the most recent Claude Code conversation here")
            Menu {
                WorktreeMenuItems(store: store, worktree: worktree)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    private func open() {
        WindowOpener.open(worktree.url)
    }
}

struct WorktreeMenuItems: View {
    let store: RepoStore
    let worktree: Worktree

    var body: some View {
        Button("Open in New Window") { WindowOpener.open(worktree.url) }
        Button("Open in \(Preferences.terminal.rawValue)") { Launcher.openTerminal(at: worktree.url) }
        Button("Open in \(Preferences.editor.rawValue)") { Launcher.openInEditor(worktree.url) }
        Button("Reveal in Finder") { Launcher.revealInFinder(worktree.url) }
        Button("Launch Claude Code") { Launcher.launchClaude(in: worktree.url) }
        if store.claudeSessions[worktree.path] != nil {
            Button("Continue Claude Session") { Launcher.launchClaude(in: worktree.url, continuing: true) }
        }
        Button("Copy Path") { copy(worktree.path) }
        if !worktree.isMain, let branch = worktree.branch {
            Divider()
            if let target = store.mainWorktree?.branch, target != branch {
                Button("Merge “\(branch)” into “\(target)”…") { store.mergeIntoMain(worktree) }
            }
            if branch != store.mainWorktree?.branch {
                Button("Review Changes…") { store.sheet = .review(worktree) }
            }
            Button("Push & Open Pull Request") { store.pushAndOpenPullRequest(worktree) }
            Button("Show Branch in History") {
                if let ref = store.localBranches.first(where: { $0.name == branch }) { store.jump(to: ref.sha) }
            }
        }
        if !worktree.isMain {
            Divider()
            Button(worktree.isLocked ? "Unlock" : "Lock") { store.toggleLock(worktree) }
            Button("Remove Worktree…", role: .destructive) { store.remove(worktree) }
            if worktree.isClaude, worktree.branch != nil {
                Button("Remove Worktree & Delete Branch…", role: .destructive) { store.discardAgent(worktree) }
            }
        }
    }
}
