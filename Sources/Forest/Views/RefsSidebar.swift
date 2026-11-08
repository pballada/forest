import ForestCore
import SwiftUI
import UniformTypeIdentifiers

/// Branches, remotes, tags and stashes of a worktree, beside its history.
struct RefsSidebar: View {
    @Bindable var store: RepoStore
    @State private var filter = ""
    @AppStorage("sidebar.remotesExpanded") private var remotesExpanded = true
    @AppStorage("sidebar.tagsExpanded") private var tagsExpanded = false
    @Environment(\.theme) private var theme

    var body: some View {
        List(selection: Binding<SidebarItem?>(get: { store.sidebar }, set: { if let item = $0 { select(item) } })) {
            Section("Branches") {
                ForEach(filtered(store.localBranches)) { branch in
                    BranchRow(branch: branch, pullRequest: store.pullRequest(for: branch.name))
                        .tag(SidebarItem.branch(branch.fullName))
                        .contextMenu { BranchMenuItems(store: store, branch: branch) }
                        .draggable(BranchDrag(name: branch.name))
                        .dropDestination(for: BranchDrag.self) { items, _ in
                            guard let dragged = items.first?.name, dragged != branch.name else { return false }
                            dropped(dragged, on: branch)
                            return true
                        }
                }
            }

            if !store.remoteBranches.isEmpty {
                Section("Remotes") {
                    ForEach(store.remotes) { remote in
                        DisclosureGroup {
                            ForEach(filtered(store.remoteBranches.filter { $0.remoteName == remote.name })) { branch in
                                Label {
                                    Text(branch.nameWithoutRemote).lineLimit(1)
                                } icon: {
                                    Image(systemName: "arrow.triangle.branch").foregroundStyle(.secondary)
                                }
                                .tag(SidebarItem.branch(branch.fullName))
                                .contextMenu { BranchMenuItems(store: store, branch: branch) }
                            }
                        } label: {
                            Label(remote.name, systemImage: "cloud")
                                .contextMenu {
                                    Button("Fetch \(remote.name)") { store.run("Fetching \(remote.name)") { try await store.repository.fetch(remote: remote.name) } }
                                    if let web = remote.webURL { Button("Open on Web") { Launcher.openURL(web) } }
                                    Button("Copy URL") { copy(remote.fetchURL) }
                                    Divider()
                                    Button("Remove Remote…", role: .destructive) {
                                        store.confirm("Remove remote “\(remote.name)”?", "Remote-tracking branches are deleted locally.", action: "Remove") {
                                            store.run("Removing remote") { try await store.repository.removeRemote(remote.name) }
                                        }
                                    }
                                }
                        }
                    }
                }
            }

            if !store.tags.isEmpty {
                Section(isExpanded: $tagsExpanded) {
                    ForEach(store.tags.filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) }) { tag in
                        Label(tag.name, systemImage: "tag")
                            .lineLimit(1)
                            .tag(SidebarItem.tag(tag.name))
                            .contextMenu {
                                Button("Copy Name") { copy(tag.name) }
                                if let remote = store.remotes.first {
                                    Button("Push to \(remote.name)") { store.run("Pushing tag", success: "Pushed \(tag.name)") { try await store.repository.pushTag(tag.name, remote: remote.name) } }
                                }
                                Button("New Claude Agent from Here…") { store.sheet = .newAgent(base: tag.name) }
                                Divider()
                                Button("Delete Tag…", role: .destructive) { store.deleteTag(tag) }
                            }
                    }
                } header: {
                    Text("Tags")
                }
            }

            if !store.stashes.isEmpty {
                Section("Stashes") {
                    ForEach(store.stashes) { stash in
                        Label {
                            VStack(alignment: .leading, spacing: 0) {
                                Text(stash.message).lineLimit(1)
                                Text(Format.ago(stash.date)).font(.caption2).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "tray.full")
                        }
                        .tag(SidebarItem.stash(stash.sha))
                        .contextMenu {
                            Button("Apply") { store.apply(stash, pop: false) }
                            Button("Pop") { store.apply(stash, pop: true) }
                            Divider()
                            Button("Drop…", role: .destructive) { store.drop(stash) }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(theme.sidebarColor)
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease").foregroundStyle(.secondary)
                TextField("Filter branches", text: $filter)
                    .textFieldStyle(.plain)
                if !filter.isEmpty {
                    Button { filter = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                        .buttonStyle(.plain)
                }
            }
            .font(.callout)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.05)))
            .padding(10)
        }
    }

    /// Drag a branch onto the current one to merge it in; drag the current branch onto another to rebase.
    private func dropped(_ dragged: String, on target: Branch) {
        if target.isHead {
            store.merge(dragged)
        } else if dragged == store.status.branch {
            store.rebase(onto: target.name)
        } else {
            store.alert = AlertMessage(title: "Drop onto the current branch",
                                       message: "Drag a branch onto “\(store.status.branch ?? "HEAD")” to merge it, or drag “\(store.status.branch ?? "HEAD")” onto another branch to rebase onto it.")
        }
    }

    private func filtered(_ branches: [Branch]) -> [Branch] {
        guard !filter.isEmpty else { return branches }
        return branches.filter { $0.name.localizedCaseInsensitiveContains(filter) }
    }

    private func select(_ item: SidebarItem) {
        store.sidebar = item
        switch item {
        case .branch(let fullName):
            if let branch = (store.localBranches + store.remoteBranches).first(where: { $0.fullName == fullName }) {
                store.historyFilter = ""
                store.scrollTarget = branch.sha
                Task { await store.selectCommit(branch.sha) }
            }
        case .tag(let name):
            if let tag = store.tags.first(where: { $0.name == name }) {
                store.historyFilter = ""
                store.scrollTarget = tag.sha
                Task { await store.selectCommit(tag.sha) }
            }
        default:
            break
        }
    }
}

private struct BranchRow: View {
    let branch: Branch
    var pullRequest: PullRequest?

    var body: some View {
        HStack(spacing: 6) {
            Label {
                Text(branch.name)
                    .fontWeight(branch.isHead ? .semibold : .regular)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } icon: {
                Image(systemName: branch.isHead ? "checkmark.circle.fill" : "arrow.triangle.branch")
                    .foregroundStyle(branch.isHead ? Theme.leaf : .secondary)
            }
            Spacer(minLength: 4)
            if let pullRequest {
                PullRequestChip(pullRequest: pullRequest).scaleEffect(0.9)
            }
            if branch.worktreePath != nil && !branch.isHead {
                Image(systemName: ClaudeCode.isClaudeWorktree(path: branch.worktreePath ?? "") ? "sparkles" : "square.stack.3d.up")
                    .font(.caption2)
                    .foregroundStyle(ClaudeCode.isClaudeWorktree(path: branch.worktreePath ?? "") ? Theme.claude : .secondary)
                    .help("Checked out in \(Format.abbreviatePath(branch.worktreePath ?? ""))")
            }
            if branch.upstreamGone {
                Image(systemName: "icloud.slash").font(.caption2).foregroundStyle(.tertiary).help("Upstream branch was deleted")
            }
            AheadBehind(ahead: branch.ahead, behind: branch.behind)
        }
    }
}

struct AheadBehind: View {
    let ahead: Int
    let behind: Int

    var body: some View {
        HStack(spacing: 4) {
            if ahead > 0 {
                Text("↑\(ahead)").foregroundStyle(Theme.leaf)
            }
            if behind > 0 {
                Text("↓\(behind)").foregroundStyle(.orange)
            }
        }
        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
        .monospacedDigit()
    }
}

/// Context menu shared by sidebar rows and the history view.
struct BranchMenuItems: View {
    let store: RepoStore
    let branch: Branch

    var body: some View {
        let current = store.status.branch ?? "HEAD"
        if !branch.isHead {
            Button("Check Out “\(branch.nameWithoutRemote)”") { store.checkout(branch) }
            Button("Merge into “\(current)”…") { store.merge(branch.name) }
            Button("Rebase “\(current)” onto This…") { store.rebase(onto: branch.name) }
            Divider()
        }
        Button(store.historyScope == branch.name ? "Show All Branches" : "Show Only This Branch") {
            store.solo(store.historyScope == branch.name ? nil : branch.name)
        }
        Divider()
        Button("New Branch from Here…") { store.sheet = .newBranch(start: branch.name) }
        Button("New Claude Agent from Here…") { store.sheet = .newAgent(base: branch.name) }
        if let pr = store.pullRequest(for: branch.nameWithoutRemote) {
            Button("Open Pull Request #\(pr.number)") { Launcher.openURL(pr.url) }
        }
        if let path = branch.worktreePath, !branch.isHead {
            Button("Show Worktree") { WindowOpener.open(URL(fileURLWithPath: path)) }
        }
        Divider()
        if !branch.isRemote {
            Button("Rename…") { store.sheet = .renameBranch(branch) }
            if branch.isHead { Button("Push") { store.push() } }
        }
        Button("Copy Name") { copy(branch.name) }
        if !branch.isHead {
            Divider()
            Button("Delete…", role: .destructive) { store.delete(branch) }
        }
    }
}

/// Drag payload for branch-onto-branch merge and rebase.
struct BranchDrag: Codable, Transferable {
    let name: String
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .forestBranch)
    }
}

extension UTType {
    static let forestBranch = UTType(exportedAs: "com.pballada.forest.branch")
}

func copy(_ string: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(string, forType: .string)
}
