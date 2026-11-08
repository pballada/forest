import ForestCore
import ForestTerminal
import SwiftUI

/// The selected worktree: a header saying what it is, then Terminal, Changes or History.
struct WorktreeWorkspace: View {
    let project: ProjectStore
    @Bindable var store: RepoStore
    let worktree: Worktree
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            WorktreeHeader(project: project, store: store, worktree: worktree)
            if store.operation != .none {
                OperationBanner(store: store)
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(theme.canvasColor)
        .navigationTitle(worktree.isMain ? project.name : worktree.name)
        .navigationSubtitle(store.status.branch ?? "")
        .toolbar { RepoToolbar(store: store) }
        .storePresentation(store)
        // Sheets and confirmations raised from the project's main store (sidebar menus) show here too.
        .background {
            if store !== project.main {
                Color.clear.storePresentation(project.main, overlays: false)
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch store.sidebar {
        case .changes:
            ChangesView(store: store)
        case .history, .branch, .tag, .stash:
            HSplitView {
                RefsSidebar(store: store)
                    .frame(minWidth: 190, idealWidth: 230, maxWidth: 340)
                Group {
                    if case .stash(let sha) = store.sidebar {
                        StashDetailView(store: store, sha: sha)
                    } else {
                        HistoryView(store: store)
                    }
                }
                .frame(minWidth: 500)
            }
        case .terminal, .worktrees, .worktree:
            TerminalPane(project: project, worktree: worktree)
        }
    }
}

// MARK: - Header

private struct WorktreeHeader: View {
    let project: ProjectStore
    @Bindable var store: RepoStore
    let worktree: Worktree
    @Environment(\.theme) private var theme

    var body: some View {
        let session = project.currentSession(for: worktree.path)
        let state = project.state(for: worktree.path)
        HStack(alignment: .center, spacing: 14) {
            AgentStateGlyph(state: state, isMain: worktree.isMain)
            VStack(alignment: .leading, spacing: 2) {
                Text(session?.displayTitle ?? (worktree.isMain ? project.name : worktree.name))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.textColor)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.branch").font(.system(size: 9.5, weight: .semibold))
                    Text(store.status.branch ?? "detached")
                        .font(.system(size: 11.5, design: .monospaced))
                    if !worktree.isMain, let base = project.main.status.branch {
                        Image(systemName: "arrow.right").font(.system(size: 8.5, weight: .semibold))
                        Text(base).font(.system(size: 11.5, design: .monospaced))
                    }
                    AheadBehind(ahead: store.status.ahead, behind: store.status.behind)
                    if let pr = store.pullRequest(for: store.status.branch) {
                        PullRequestChip(pullRequest: pr).scaleEffect(0.92)
                    }
                }
                .foregroundStyle(theme.secondaryColor)
                .lineLimit(1)
            }
            Spacer(minLength: 12)
            TabSwitcher(store: store)
            actions
        }
        .padding(.horizontal, 16)
        .frame(height: 54)
        .background(theme.canvasColor)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.borderColor).frame(height: 0.5) }
    }

    private var actions: some View {
        HStack(spacing: 2) {
            if !worktree.isMain {
                HeaderButton(systemImage: "eye", help: "Review everything this agent changed (⇧⌘R)") { project.main.sheet = .review(worktree) }
            }
            HeaderButton(systemImage: "sidebar.right", help: "Show or hide live changes (⌥⌘0)") {
                WorkspaceStore.shared.showInspector.toggle()
            }
            Menu {
                WorktreeRowMenu(project: project, worktree: worktree)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
        }
    }
}

private struct HeaderButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13))
                .frame(width: 28, height: 26)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(theme.textColor.opacity(hovering ? 0.08 : 0)))
                .foregroundStyle(theme.secondaryColor)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// Terminal · Changes · History, as a compact segmented control in the header.
private struct TabSwitcher: View {
    @Bindable var store: RepoStore
    @Environment(\.theme) private var theme
    @Namespace private var namespace

    private enum Tab: CaseIterable {
        case terminal, changes, history
        var title: String { switch self { case .terminal: "Terminal"; case .changes: "Changes"; case .history: "History" } }
        var symbol: String { switch self { case .terminal: "terminal"; case .changes: "plusminus"; case .history: "clock.arrow.circlepath" } }
        var item: SidebarItem { switch self { case .terminal: .terminal; case .changes: .changes; case .history: .history } }
    }

    private var current: Tab {
        switch store.sidebar {
        case .changes: .changes
        case .history, .branch, .tag, .stash: .history
        default: .terminal
        }
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Tab.allCases, id: \.self) { tab in
                Button {
                    store.sidebar = tab.item
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: tab.symbol).font(.system(size: 10.5, weight: .semibold))
                        Text(tab.title).font(.system(size: 12, weight: .medium))
                        if tab == .changes, store.status.changeCount > 0 {
                            Text("\(store.status.changeCount)")
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(current == tab ? theme.textColor : theme.secondaryColor)
                        }
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .foregroundStyle(current == tab ? theme.textColor : theme.secondaryColor)
                    .background {
                        if current == tab {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(theme.elevatedColor)
                                .shadow(color: .black.opacity(0.12), radius: 1.5, y: 0.5)
                                .matchedGeometryEffect(id: "tab", in: namespace)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(theme.textColor.opacity(0.06)))
        .animation(.snappy(duration: 0.18), value: current)
    }
}

// MARK: - Terminal

/// The worktree's terminal (Claude, usually), with an optional shell underneath; or a card to start one.
struct TerminalPane: View {
    let project: ProjectStore
    let worktree: Worktree
    @Environment(\.theme) private var theme

    var body: some View {
        if let terminal = project.terminal(for: worktree.path) {
            VSplitView {
                TerminalHost(session: terminal)
                    .frame(minHeight: 160)
                if let shell = project.shell(for: worktree.path) {
                    TerminalHost(session: shell, focusOnAppear: false)
                        .frame(minHeight: 90, idealHeight: 220)
                }
            }
            .background(Color(nsColor: theme.background))
        } else if !TerminalSession.isSupported {
            EmptyState(title: "The terminal couldn't start", systemImage: "exclamationmark.triangle",
                       message: TerminalSession.failureReason ?? "")
        } else {
            SessionLauncher(project: project, worktree: worktree)
        }
    }
}

/// Shown where a terminal would be when none is running: continue a conversation or start one.
struct SessionLauncher: View {
    let project: ProjectStore
    let worktree: Worktree
    @Environment(\.theme) private var theme
    @State private var prompt = ""
    @FocusState private var promptFocused: Bool

    var body: some View {
        let sessions = project.sessions(for: worktree.path)
        let remembered = WorkspaceStore.shared.rememberedSessionID(for: worktree.path)
        let primary = sessions.first { $0.id == remembered } ?? sessions.first
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 12) {
                    ClaudeMark(size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(primary == nil ? "Start Claude here" : "Pick up where you left off")
                            .font(.system(size: 19, weight: .semibold))
                        Text(Format.abbreviatePath(worktree.path))
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(theme.tertiaryColor)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }

                if let primary {
                    Button { resume(primary) } label: {
                        SessionCard(session: primary, highlighted: true)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.defaultAction)

                    let others = sessions.filter { $0.id != primary.id }.prefix(5)
                    if !others.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Earlier conversations")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(theme.tertiaryColor)
                                .textCase(.uppercase)
                            ForEach(Array(others)) { session in
                                Button { resume(session) } label: { SessionCard(session: session, highlighted: false) }
                                    .buttonStyle(.plain)
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(primary == nil ? "What should Claude do?" : "Or start a new conversation")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.secondaryColor)
                    HStack(alignment: .bottom, spacing: 8) {
                        TextField("Describe a task, or leave empty", text: $prompt, axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                            .lineLimit(1...6)
                            .focused($promptFocused)
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(theme.elevatedColor))
                            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(theme.borderColor, lineWidth: 0.5))
                            .onSubmit(startNew)
                        Button(action: startNew) {
                            Label("New Session", systemImage: "sparkles")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(theme.agentColor)
                        .controlSize(.large)
                    }
                    Button("Open a plain shell instead") { project.launch(.shell, in: worktree.path) }
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(theme.accentColor)
                }
            }
            .padding(32)
            .frame(maxWidth: 620, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
        .onAppear { if sessions.isEmpty { promptFocused = true } }
    }

    private func resume(_ session: ClaudeSession) {
        project.launch(.resume(sessionID: session.id), in: worktree.path)
    }

    private func startNew() {
        project.launch(.newSession(prompt: prompt), in: worktree.path)
        prompt = ""
    }
}

private struct SessionCard: View {
    let session: ClaudeSession
    let highlighted: Bool
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(session.displayTitle)
                    .font(.system(size: highlighted ? 14 : 12.5, weight: .semibold))
                    .foregroundStyle(theme.textColor)
                    .lineLimit(1)
                if let prompt = session.lastPrompt ?? session.firstPrompt {
                    Text(prompt)
                        .font(.system(size: 12))
                        .foregroundStyle(theme.secondaryColor)
                        .lineLimit(highlighted ? 3 : 1)
                }
                HStack(spacing: 8) {
                    Label(Format.ago(session.lastActivity), systemImage: "clock")
                    if session.messageCount > 0 { Text("· \(session.messageCount) messages") }
                    if let branch = session.gitBranch { Text("· \(branch)").font(.system(size: 11, design: .monospaced)) }
                }
                .font(.system(size: 11))
                .foregroundStyle(theme.tertiaryColor)
            }
            Spacer(minLength: 8)
            if highlighted {
                HStack(spacing: 5) {
                    Text("Continue")
                    Image(systemName: "return")
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(Capsule().fill(theme.agentColor))
            } else {
                Image(systemName: "arrow.uturn.forward")
                    .foregroundStyle(theme.tertiaryColor)
                    .opacity(hovering ? 1 : 0)
            }
        }
        .padding(highlighted ? 16 : 11)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(highlighted ? theme.agentColor.opacity(0.08) : theme.textColor.opacity(hovering ? 0.05 : 0.025))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(highlighted ? theme.agentColor.opacity(0.35) : theme.borderColor, lineWidth: highlighted ? 1 : 0.5)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

// MARK: - Presentation

private struct StorePresentation: ViewModifier {
    @Bindable var store: RepoStore
    var overlays: Bool

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) { if overlays { ToastView(store: store) } }
            .overlay { if overlays && store.showPalette { CommandPalette(store: store) } }
            .sheet(item: $store.sheet) { SheetHost(store: store, sheet: $0) }
            .background {
                Color.clear
                    .alert(item: $store.alert) { alert in
                        Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("OK")))
                    }
            }
            .alert(store.confirmation?.title ?? "", isPresented: Binding(
                get: { store.confirmation != nil }, set: { if !$0 { store.confirmation = nil } }
            ), presenting: store.confirmation) { confirmation in
                Button(confirmation.actionTitle, role: confirmation.destructive ? .destructive : nil) { confirmation.action() }
                Button("Cancel", role: .cancel) {}
            } message: { confirmation in
                Text(confirmation.message)
            }
    }
}

extension View {
    /// Sheets, alerts, confirmations, toasts and the command palette of a store.
    func storePresentation(_ store: RepoStore, overlays: Bool = true) -> some View {
        modifier(StorePresentation(store: store, overlays: overlays))
    }
}
