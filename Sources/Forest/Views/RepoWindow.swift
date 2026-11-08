import ForestCore
import SwiftUI

struct OperationBanner: View {
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

struct ToastView: View {
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

            Button { store.sheet = .newAgent(base: nil) } label: { Label("New Agent", systemImage: "sparkles") }
                .help("Start Claude on a task in its own worktree (⌘N)")

            Menu {
                Button("Open in \(Preferences.terminal.rawValue)") { Launcher.openTerminal(at: store.repository.root) }
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
        case .newAgent(let base):
            NewAgentSheet(store: store, base: base)
        case .stash:
            StashSheet(store: store)
        case .addRemote:
            AddRemoteSheet(store: store)
        case .review(let worktree):
            AgentReviewView(worktree: worktree, store: store)
        }
    }
}
