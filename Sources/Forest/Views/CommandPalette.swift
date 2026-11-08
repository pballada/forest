import ForestCore
import SwiftUI

private struct PaletteItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let systemImage: String
    var tint: Color = .secondary
    let action: () -> Void
}

struct CommandPalette: View {
    @Bindable var store: RepoStore
    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var focused: Bool

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.18)
                .ignoresSafeArea()
                .onTapGesture { close() }

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "command").foregroundStyle(.secondary)
                    TextField("Type a command, branch or worktree…", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 17))
                        .focused($focused)
                        .onSubmit(runHighlighted)
                }
                .padding(16)
                Divider()
                let items = results
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                PaletteRow(item: item, highlighted: index == highlighted)
                                    .id(index)
                                    .onTapGesture {
                                        highlighted = index
                                        runHighlighted()
                                    }
                            }
                            if items.isEmpty {
                                Text("No matches").foregroundStyle(.secondary).padding(20)
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: 360)
                    .onChange(of: highlighted) { _, value in proxy.scrollTo(value) }
                }
            }
            .frame(width: 580)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
            .shadow(color: .black.opacity(0.3), radius: 30, y: 12)
            .padding(.top, 70)
        }
        .onAppear { focused = true }
        .onChange(of: query) { _, _ in highlighted = 0 }
        .onKeyPress(.escape) { close(); return .handled }
        .onKeyPress(.downArrow) { highlighted = min(highlighted + 1, max(results.count - 1, 0)); return .handled }
        .onKeyPress(.upArrow) { highlighted = max(highlighted - 1, 0); return .handled }
        .transition(.opacity)
    }

    private func close() { store.showPalette = false }

    private func runHighlighted() {
        let items = results
        guard items.indices.contains(highlighted) else { return }
        close()
        items[highlighted].action()
    }

    private var results: [PaletteItem] {
        let all = commands + branchItems + worktreeItems
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return Array(all.prefix(40)) }
        return all
            .compactMap { item -> (PaletteItem, Int)? in
                guard let score = fuzzyScore(q, in: (item.title + " " + item.subtitle).lowercased()) else { return nil }
                return (item, score)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(40)
            .map(\.0)
    }

    private var commands: [PaletteItem] {
        let root = store.repository.root
        return [
            PaletteItem(id: "claude-agent", title: "New Claude Agent…", subtitle: "Isolated worktree + Claude Code", systemImage: "sparkles", tint: Theme.claude) { store.sheet = .newAgent(base: nil) },
            PaletteItem(id: "compare", title: "Compare…", subtitle: "Two branches, two agents or any two files", systemImage: "rectangle.split.2x1") { store.sheet = .compare(left: nil, right: nil, file: nil) },
            PaletteItem(id: "claude-message", title: "Write Commit Message with Claude", subtitle: "\(store.status.staged.count) staged files",
                        systemImage: "text.badge.star", tint: Theme.claude) { store.sidebar = .changes; store.generateCommitMessage() },
            PaletteItem(id: "undo", title: store.undo.map { "Undo \($0.title)" } ?? "Undo", subtitle: store.undo == nil ? "Nothing to undo" : "⌥⌘Z",
                        systemImage: "arrow.uturn.backward") { store.performUndo() },
            PaletteItem(id: "fetch", title: "Fetch", subtitle: "All remotes", systemImage: "arrow.triangle.2.circlepath") { store.fetch() },
            PaletteItem(id: "pull", title: "Pull", subtitle: Preferences.pullStrategy.title, systemImage: "arrow.down") { store.pull() },
            PaletteItem(id: "push", title: "Push", subtitle: store.status.branch ?? "", systemImage: "arrow.up") { store.push() },
            PaletteItem(id: "branch", title: "New Branch…", subtitle: "From \(store.status.branch ?? "HEAD")", systemImage: "arrow.triangle.branch") { store.sheet = .newBranch(start: nil) },
            PaletteItem(id: "stash", title: "Stash Changes…", subtitle: "\(store.status.changeCount) files", systemImage: "tray.and.arrow.down") { store.sheet = .stash },
            PaletteItem(id: "stage-all", title: "Stage All", subtitle: "", systemImage: "plus.circle") { store.stageAll() },
            PaletteItem(id: "changes", title: "Go to Changes", subtitle: "⌘1", systemImage: "pencil.and.list.clipboard") { store.sidebar = .changes },
            PaletteItem(id: "history", title: "Go to History", subtitle: "⌘2", systemImage: "clock.arrow.circlepath") { store.sidebar = .history },
            PaletteItem(id: "worktrees", title: "Go to Worktrees", subtitle: "⌘3", systemImage: "square.stack.3d.up") { store.sidebar = .worktrees },
            PaletteItem(id: "launch-claude", title: "Launch Claude Code Here", subtitle: Format.abbreviatePath(root.path), systemImage: "terminal", tint: Theme.claude) { Launcher.launchClaude(in: root) },
            PaletteItem(id: "terminal", title: "Open in Terminal", subtitle: Preferences.terminal.rawValue, systemImage: "terminal") { Launcher.openTerminal(at: root) },
            PaletteItem(id: "editor", title: "Open in Editor", subtitle: Preferences.editor.rawValue, systemImage: "chevron.left.forwardslash.chevron.right") { Launcher.openInEditor(root) },
            PaletteItem(id: "finder", title: "Reveal in Finder", subtitle: "", systemImage: "folder") { Launcher.revealInFinder(root) },
            PaletteItem(id: "remote", title: "Add Remote…", subtitle: "", systemImage: "cloud") { store.sheet = .addRemote },
            PaletteItem(id: "prune", title: "Prune Worktrees", subtitle: "Forget deleted worktree folders", systemImage: "scissors") { store.pruneWorktrees() },
        ]
    }

    private var branchItems: [PaletteItem] {
        store.localBranches.filter { !$0.isHead }.map { branch in
            PaletteItem(id: "checkout-\(branch.fullName)", title: "Check Out \(branch.name)", subtitle: branch.subject,
                        systemImage: "arrow.triangle.branch", tint: Theme.leaf) { store.checkout(branch) }
        }
    }

    private var worktreeItems: [PaletteItem] {
        let open = store.worktrees.filter { $0.path != store.currentWorktree?.path }.map { worktree in
            PaletteItem(id: "open-\(worktree.path)", title: "Open Worktree \(worktree.name)", subtitle: worktree.branch ?? "",
                        systemImage: worktree.isClaude ? "sparkles" : "square.stack.3d.up",
                        tint: worktree.isClaude ? Theme.claude : .secondary) { WindowOpener.open(worktree.url) }
        }
        let review = store.worktrees.filter { !$0.isMain && $0.branch != nil && $0.branch != store.mainWorktree?.branch }.map { worktree in
            PaletteItem(id: "review-\(worktree.path)", title: "Review \(worktree.name)", subtitle: "Changes vs \(store.mainWorktree?.branch ?? "main")",
                        systemImage: "eye", tint: worktree.isClaude ? Theme.claude : Theme.leaf) { store.sheet = .review(worktree) }
        }
        return open + review
    }

    /// Subsequence match; consecutive and word-start matches score higher.
    private func fuzzyScore(_ query: String, in text: String) -> Int? {
        if text.contains(query) { return 1000 - (text.range(of: query).map { text.distance(from: text.startIndex, to: $0.lowerBound) } ?? 0) }
        var score = 0
        var index = text.startIndex
        var previousMatched = false
        for char in query {
            guard let found = text[index...].firstIndex(of: char) else { return nil }
            if found == index && previousMatched { score += 5 }
            if found == text.startIndex || text[text.index(before: found)] == " " { score += 8 }
            score += 1
            previousMatched = true
            index = text.index(after: found)
        }
        return score
    }
}

private struct PaletteRow: View {
    let item: PaletteItem
    let highlighted: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.systemImage)
                .foregroundStyle(highlighted ? .white : item.tint)
                .frame(width: 22)
            Text(item.title)
                .foregroundStyle(highlighted ? .white : .primary)
            Text(item.subtitle)
                .foregroundStyle(highlighted ? Color.white.opacity(0.75) : .secondary)
                .lineLimit(1)
            Spacer()
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(highlighted ? Theme.leaf : .clear))
        .contentShape(Rectangle())
    }
}
