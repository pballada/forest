import ForestCore
import SwiftUI

struct RepoWindow: View {
    let path: String
    @State private var store: RepoStore?
    @State private var failure: String?
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Group {
            if let store {
                RepoContent(store: store)
            } else if let failure {
                EmptyState(title: "Not a git repository", systemImage: "exclamationmark.triangle", message: failure)
                    .frame(minWidth: 600, minHeight: 400)
            } else {
                ProgressView().frame(minWidth: 600, minHeight: 400)
            }
        }
        .task(id: path) {
            WindowOpener.install(open: openWindow, dismiss: dismissWindow)
            do {
                let repository = try await Repository.open(URL(fileURLWithPath: path))
                let store = RepoStore(repository: repository)
                store.start()
                self.store = store
                await Snapshotter.run(store: store)
            } catch {
                failure = "\(Format.abbreviatePath(path))\n\(error.localizedDescription)"
            }
        }
        .onDisappear { store?.stop() }
    }
}

private struct RepoContent: View {
    @Bindable var store: RepoStore
    @State private var columns = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            SidebarView(store: store)
                .navigationSplitViewColumnWidth(min: 210, ideal: 250, max: 360)
        } detail: {
            VStack(spacing: 0) {
                if store.operation != .none {
                    OperationBanner(store: store)
                }
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(store.name)
        .navigationSubtitle(subtitle)
        .toolbar { RepoToolbar(store: store) }
        .focusedSceneValue(\.repoStore, store)
        .overlay(alignment: .bottom) { ToastView(store: store) }
        .overlay {
            if store.showPalette {
                CommandPalette(store: store)
            }
        }
        .sheet(item: $store.sheet) { sheet in
            SheetHost(store: store, sheet: sheet)
        }
        .alert(item: $store.alert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("OK")))
        }
        .alert(store.confirmation?.title ?? "", isPresented: Binding(
            get: { store.confirmation != nil }, set: { if !$0 { store.confirmation = nil } }
        ), presenting: store.confirmation) { confirmation in
            Button(confirmation.actionTitle, role: confirmation.destructive ? .destructive : nil) { confirmation.action() }
            Button("Cancel", role: .cancel) {}
        } message: { confirmation in
            Text(confirmation.message)
        }
        .frame(minWidth: 960, minHeight: 600)
        .tint(Theme.leaf)
    }

    private var subtitle: String {
        var parts: [String] = []
        if let branch = store.status.branch {
            parts.append(branch)
        } else if let sha = store.status.headSHA {
            parts.append("detached at \(sha.prefix(7))")
        }
        if let worktree = store.currentWorktree, !worktree.isMain {
            parts.append(worktree.isClaude ? "Claude worktree" : "linked worktree")
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var detail: some View {
        switch store.sidebar {
        case .changes:
            ChangesView(store: store)
        case .history, .branch, .tag:
            HistoryView(store: store)
        case .worktrees, .worktree:
            WorktreesView(store: store)
        case .stash(let sha):
            StashDetailView(store: store, sha: sha)
        }
    }
}

private struct OperationBanner: View {
    let store: RepoStore

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(store.operation.title).font(.system(size: 12.5, weight: .semibold))
                Text(store.status.conflicted.isEmpty ? "All conflicts resolved — continue when ready."
                     : "\(store.status.conflicted.count) conflicted file\(store.status.conflicted.count == 1 ? "" : "s") to resolve.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !store.status.conflicted.isEmpty {
                Button("Show Conflicts") { store.sidebar = .changes }
                Button { store.resolveConflictsWithClaude() } label: { Label("Resolve with Claude", systemImage: "sparkles") }
                    .tint(Theme.claude)
                    .help("Opens Claude Code in your terminal to resolve the conflict markers; you review before continuing")
            }
            Button("Abort", role: .destructive) { store.abortOperation() }
            Button("Continue") { store.continueOperation() }
                .buttonStyle(.borderedProminent)
                .disabled(!store.status.conflicted.isEmpty)
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Color.orange.opacity(0.12))
        .overlay(alignment: .bottom) { Divider() }
    }
}

private struct ToastView: View {
    let store: RepoStore

    var body: some View {
        if let message = store.toast {
            HStack(spacing: 10) {
                Image(systemName: "leaf.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Theme.leafGradient))
                Text(message)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                if let undo = store.undo {
                    Divider().frame(height: 14)
                    Button("Undo") { store.performUndo() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Theme.leaf)
                        .help("Undo \(undo.title.lowercased()) (⌥⌘Z)")
                }
            }
            .padding(.leading, 6)
            .padding(.trailing, 14)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.leaf.opacity(0.25)))
            .shadow(color: Theme.leaf.opacity(0.18), radius: 14, y: 5)
            .padding(.bottom, 22)
            .frame(maxWidth: 560)
            .transition(.move(edge: .bottom).combined(with: .scale(scale: 0.9)).combined(with: .opacity))
        }
    }
}

struct RepoToolbar: ToolbarContent {
    let store: RepoStore

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            BranchMenu(store: store)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if let busy = store.busy {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(busy).font(.caption).foregroundStyle(.secondary)
                }
                .padding(.trailing, 4)
            }

            ControlGroup {
                Button { store.fetch() } label: { Label("Fetch", systemImage: "arrow.triangle.2.circlepath") }
                    .help("Fetch all remotes (⇧⌘F)")
                Menu {
                    ForEach(PullStrategy.allCases) { strategy in
                        Button("Pull (\(strategy.title))") { store.pull(strategy) }
                    }
                } label: {
                    Label("Pull", systemImage: "arrow.down")
                        .badge(store.status.behind)
                } primaryAction: {
                    store.pull()
                }
                .help(store.status.behind > 0 ? "Pull \(store.status.behind) commit(s) (⇧⌘P)" : "Pull (⇧⌘P)")
                Menu {
                    Button("Push") { store.push() }
                    Button("Force Push (with lease)") { store.push(force: true) }
                } label: {
                    Label("Push", systemImage: "arrow.up")
                        .badge(store.status.ahead)
                } primaryAction: {
                    store.push()
                }
                .help(store.status.ahead > 0 ? "Push \(store.status.ahead) commit(s) (⇧⌘U)" : "Push (⇧⌘U)")
            }

            Button { store.sheet = .newBranch(start: nil) } label: { Label("Branch", systemImage: "arrow.triangle.branch") }
                .help("New branch (⇧⌘B)")
            Button { store.sheet = .stash } label: { Label("Stash", systemImage: "tray.and.arrow.down") }
                .help("Stash changes (⌥⌘S)")
                .disabled(store.status.isClean)

            Menu {
                Button { store.sheet = .newWorktree(base: nil, claude: true) } label: { Label("New Claude Agent…", systemImage: "sparkles") }
                Button { store.sheet = .newWorktree(base: nil, claude: false) } label: { Label("New Worktree…", systemImage: "square.stack.3d.up") }
                Divider()
                Button { Launcher.launchClaude(in: store.repository.root) } label: { Label("Launch Claude Code Here", systemImage: "terminal") }
            } label: {
                Label("Worktree", systemImage: "square.stack.3d.up.fill")
            } primaryAction: {
                store.sheet = .newWorktree(base: nil, claude: true)
            }
            .help("New Claude agent worktree (⌥⌘N)")

            Menu {
                Button("Open in Terminal") { Launcher.openTerminal(at: store.repository.root) }
                Button("Open in \(Preferences.editor.rawValue)") { Launcher.openInEditor(store.repository.root) }
                Button("Reveal in Finder") { Launcher.revealInFinder(store.repository.root) }
                if let web = store.remotes.first?.webURL {
                    Button("Open on Web") { Launcher.openURL(web) }
                }
            } label: {
                Label("Open", systemImage: "arrow.up.forward.app")
            }

            Button { store.showPalette.toggle() } label: { Label("Commands", systemImage: "command") }
                .help("Command palette (⌘K)")
        }
    }
}

private struct BranchMenu: View {
    let store: RepoStore

    var body: some View {
        Menu {
            Section("Switch Branch") {
                ForEach(store.localBranches.prefix(30)) { branch in
                    Button {
                        store.checkout(branch)
                    } label: {
                        if branch.isHead {
                            Label(branch.name, systemImage: "checkmark")
                        } else if branch.worktreePath != nil {
                            Label(branch.name, systemImage: "square.stack.3d.up")
                        } else {
                            Text(branch.name)
                        }
                    }
                    .disabled(branch.isHead)
                }
            }
            Divider()
            Button("New Branch…") { store.sheet = .newBranch(start: nil) }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: store.currentWorktree?.isClaude == true ? "sparkles" : "arrow.triangle.branch")
                    .foregroundStyle(store.currentWorktree?.isClaude == true ? Theme.claude : Theme.leaf)
                Text(store.status.branch ?? "Detached")
                    .fontWeight(.semibold)
                    .lineLimit(1)
                if store.status.changeCount > 0 {
                    Circle().fill(Color.orange).frame(width: 6, height: 6)
                }
            }
        }
        .menuIndicator(.visible)
        .fixedSize()
        .help("Current branch")
    }
}

struct SheetHost: View {
    let store: RepoStore
    let sheet: SheetKind

    var body: some View {
        switch sheet {
        case .newBranch(let start):
            NewBranchSheet(store: store, start: start)
        case .renameBranch(let branch):
            RenameBranchSheet(store: store, branch: branch)
        case .newTag(let sha):
            NewTagSheet(store: store, sha: sha)
        case .newWorktree(let base, let claude):
            NewWorktreeSheet(store: store, base: base, claude: claude)
        case .stash:
            StashSheet(store: store)
        case .addRemote:
            AddRemoteSheet(store: store)
        case .review(let worktree):
            AgentReviewView(worktree: worktree, store: store)
        }
    }
}
