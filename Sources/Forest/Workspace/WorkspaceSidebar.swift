import ForestCore
import SwiftUI

/// An accordion of projects → worktrees → sessions, each with what its agent is doing.
struct WorkspaceSidebar: View {
    @Bindable var workspace: WorkspaceStore
    @Environment(\.theme) private var theme

    var body: some View {
        List(selection: $workspace.selection) {
            ForEach(workspace.projects, id: \.id) { project in
                Section(isExpanded: Binding(get: { workspace.isExpanded(project: project) },
                                            set: { workspace.setExpanded($0, project: project) })) {
                    ForEach(project.worktrees) { worktree in
                        worktreeItem(project: project, worktree: worktree)
                    }
                } header: {
                    ProjectHeader(project: project, workspace: workspace)
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(theme.sidebarColor)
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
    }

    /// A worktree row; when it has conversations, it unfolds to list them.
    @ViewBuilder
    private func worktreeItem(project: ProjectStore, worktree: Worktree) -> some View {
        let row = WorktreeRow(project: project, worktree: worktree, shortcut: shortcutIndex(project: project, worktree: worktree))
            .tag(WorkspaceStore.Selection(project: project.id, worktree: worktree.path))
            .contextMenu { WorktreeRowMenu(project: project, worktree: worktree) }
        let sessions = project.sessions(for: worktree.path)
        if sessions.isEmpty {
            row
        } else {
            DisclosureGroup(isExpanded: Binding(get: { workspace.isExpanded(worktree: worktree.path) },
                                                set: { workspace.setExpanded($0, worktree: worktree.path) })) {
                ForEach(sessions.prefix(8)) { session in
                    SessionRow(project: project, worktree: worktree, session: session)
                }
            } label: {
                row
            }
        }
    }

    private func shortcutIndex(project: ProjectStore, worktree: Worktree) -> Int? {
        let index = workspace.orderedWorktrees.firstIndex { $0.0 === project && $0.1.path == worktree.path }
        return index.flatMap { $0 < 9 ? $0 + 1 : nil }
    }

    private var footer: some View {
        VStack(spacing: 8) {
            if let ready = Updater.shared.readyRelease {
                UpdateReadyPill(version: ready.version)
            }
            footerButtons
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .background(theme.sidebarColor)
    }

    private var footerButtons: some View {
        HStack(spacing: 8) {
            Button {
                (workspace.selectedStore ?? workspace.selectedProject?.main)?.sheet = .newAgent(base: nil)
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .bold))
                    Text("New Agent")
                        .font(.system(size: 12.5, weight: .semibold))
                    Spacer()
                    Text("⌘N")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.tertiaryColor)
                }
                .padding(.horizontal, 11)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(theme.agentColor.opacity(0.14)))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(theme.agentColor.opacity(0.28), lineWidth: 0.5))
                .foregroundStyle(theme.agentColor)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(workspace.selectedProject == nil)
            .help("Start Claude on a task in its own worktree")

            Button { WindowOpener.showOpenPanel() } label: {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 13))
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(theme.textColor.opacity(0.06)))
                    .foregroundStyle(theme.secondaryColor)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Add a project (⌘O)")
        }
    }
}

private struct ProjectHeader: View {
    let project: ProjectStore
    let workspace: WorkspaceStore
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Button {
                workspace.select(project: project, worktree: nil)
            } label: {
                HStack(spacing: 6) {
                    Text(project.name)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(workspace.selection == .init(project: project.id, worktree: nil) ? theme.accentColor : theme.secondaryColor)
                        .textCase(nil)
                    if project.workingCount > 0 {
                        HStack(spacing: 3) {
                            Circle().fill(theme.agentColor).frame(width: 6, height: 6)
                            Text("\(project.workingCount)")
                        }
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(theme.agentColor)
                        .help("\(project.workingCount) agent\(project.workingCount == 1 ? "" : "s") working")
                    }
                    if project.needsInputCount > 0 {
                        Text("! \(project.needsInputCount)")
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .frame(height: 15)
                            .background(Capsule().fill(theme.warningColor))
                            .help("Agents waiting for you")
                    }
                }
            }
            .buttonStyle(.plain)
            .help("Show every agent in \(project.name)")
            Spacer()
            Menu {
                Button("New Agent…") { project.main.sheet = .newAgent(base: nil) }
                Button("Overview") { workspace.select(project: project, worktree: nil) }
                Divider()
                Button("Open in \(Preferences.editor.rawValue)") { Launcher.openInEditor(project.root) }
                Button("Reveal in Finder") { Launcher.revealInFinder(project.root) }
                Button("Prune Missing Worktrees") { project.main.pruneWorktrees() }
                Divider()
                Button("Close Project") { workspace.close(project) }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 18, height: 16)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .opacity(hovering ? 1 : 0)
        }
        .onHover { hovering = $0 }
    }
}

/// One worktree: what Claude is doing there, the conversation's title and the amount of work in flight.
struct WorktreeRow: View {
    let project: ProjectStore
    let worktree: Worktree
    var shortcut: Int?
    @Environment(\.theme) private var theme

    var body: some View {
        let state = project.state(for: worktree.path)
        let session = project.currentSession(for: worktree.path)
        let status = project.status(for: worktree.path)
        HStack(alignment: .center, spacing: 9) {
            AgentStateGlyph(state: state, isMain: worktree.isMain)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1.5) {
                HStack(spacing: 5) {
                    Text(worktree.isMain ? (worktree.branch ?? "main") : worktree.name)
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if worktree.isLocked && !worktree.isMain && state == .dormant {
                        Image(systemName: "lock.fill").font(.system(size: 8.5)).foregroundStyle(theme.tertiaryColor)
                    }
                }
                Text(subtitle(state: state, session: session))
                    .font(.system(size: 11))
                    .foregroundStyle(state == .needsInput ? theme.warningColor : theme.secondaryColor)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if let status, status.isDirty {
                Text("\(status.changed + status.staged + status.untracked + status.conflicted)")
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(theme.secondaryColor)
                    .padding(.horizontal, 6)
                    .frame(height: 17)
                    .background(Capsule().fill(theme.textColor.opacity(0.07)))
                    .help("Files with uncommitted changes")
            }
        }
        .padding(.vertical, 3)
        .help(shortcut.map { "⌘\($0)" } ?? "")
    }

    private func subtitle(state: AgentState, session: ClaudeSession?) -> String {
        switch state {
        case .needsInput:
            return project.terminal(for: worktree.path)?.lastNotification ?? "Waiting for you"
        case .working:
            return session?.displayTitle ?? "Working…"
        case .idle, .dormant:
            if let session { return session.displayTitle }
            return worktree.isMain ? "Main checkout" : "No conversation yet"
        }
    }
}

/// The leading mark of a worktree row.
struct AgentStateGlyph: View {
    let state: AgentState
    var isMain = false
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        ZStack {
            switch state {
            case .working:
                Circle()
                    .stroke(theme.agentColor.opacity(0.35), lineWidth: 2)
                    .scaleEffect(pulse ? 1.55 : 0.9)
                    .opacity(pulse ? 0 : 1)
                Circle().fill(theme.agentColor).frame(width: 8, height: 8)
            case .needsInput:
                Circle().fill(theme.warningColor).frame(width: 14, height: 14)
                Text("!").font(.system(size: 9.5, weight: .black)).foregroundStyle(.white)
            case .idle:
                if isMain {
                    Image(systemName: "house.fill").font(.system(size: 11)).foregroundStyle(theme.accentColor)
                } else {
                    Circle().fill(theme.accentColor).frame(width: 8, height: 8)
                }
            case .dormant:
                if isMain {
                    Image(systemName: "house").font(.system(size: 11)).foregroundStyle(theme.secondaryColor)
                } else {
                    Circle().strokeBorder(theme.tertiaryColor, lineWidth: 1.2).frame(width: 8, height: 8)
                }
            }
        }
        .frame(width: 16, height: 16)
        .onAppear { startPulse() }
        .onChange(of: state) { _, _ in startPulse() }
        .accessibilityLabel(label)
        .help(label)
    }

    private var label: String {
        switch state {
        case .working: "Agent working"
        case .needsInput: "Waiting for your input"
        case .idle: "Session open, agent idle"
        case .dormant: "Not running"
        }
    }

    private func startPulse() {
        pulse = false
        guard state == .working, !reduceMotion else { return }
        withAnimation(.easeOut(duration: 1.3).repeatForever(autoreverses: false)) { pulse = true }
    }
}

struct WorktreeRowMenu: View {
    let project: ProjectStore
    let worktree: Worktree

    var body: some View {
        let sessions = project.sessions(for: worktree.path)
        if let latest = sessions.first {
            Button("Continue “\(latest.displayTitle.prefix(40))”") { open { project.launch(.resume(sessionID: latest.id), in: worktree.path) } }
        }
        let other = project.tool(for: worktree.path)
        if other != .claude, other.continueCommand != nil {
            Button("Continue Last \(other.name) Session") { open { project.launch(.continueAgent(other), in: worktree.path) } }
        }
        Menu("New Session") {
            ForEach(AgentTool.allCases) { tool in
                Button(tool.name) { open { project.launch(.agent(tool, prompt: nil), in: worktree.path) } }
            }
        }
        if sessions.count > 1 {
            Menu("Resume Session") {
                ForEach(sessions.prefix(15)) { session in
                    Button("\(session.displayTitle.prefix(50)) — \(Format.ago(session.lastActivity))") {
                        open { project.launch(.resume(sessionID: session.id), in: worktree.path) }
                    }
                }
            }
        }
        if project.terminal(for: worktree.path) != nil {
            Button("Close Terminal") { project.closeTerminal(for: worktree.path) }
        }
        Divider()
        WorktreeMenuItems(store: project.main, worktree: worktree)
    }

    private func open(_ action: () -> Void) {
        action()
        WorkspaceStore.shared.select(project: project, worktree: worktree.path)
        project.store(for: worktree.path).sidebar = .terminal
    }
}

/// A new version is downloaded and verified: it installs on quit, or now with Restart.
private struct UpdateReadyPill: View {
    let version: String
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(theme.accentColor)
            VStack(alignment: .leading, spacing: 0) {
                Text("Forest \(version) is ready").font(.system(size: 11.5, weight: .semibold))
                Text("Installs when you quit").font(.system(size: 10.5)).foregroundStyle(theme.secondaryColor)
            }
            Spacer(minLength: 4)
            Button("Restart") { Updater.shared.restartToUpdate() }
                .controlSize(.small)
                .help("Install Forest \(version) now and reopen; agents' sessions can be continued afterwards")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(theme.accentColor.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(theme.accentColor.opacity(0.3), lineWidth: 0.5))
    }
}

/// One conversation inside a worktree: whether it's the one running, and when it was last active.
/// Clicking it resumes that conversation in the worktree's terminal.
private struct SessionRow: View {
    let project: ProjectStore
    let worktree: Worktree
    let session: ClaudeSession
    @Environment(\.theme) private var theme

    private var isRunning: Bool {
        project.terminal(for: worktree.path) != nil && project.terminalSessionIDs[worktree.path] == session.id
    }

    private var state: AgentState {
        if isRunning { return project.state(for: worktree.path) }
        return session.isWorking() ? .working : .dormant
    }

    var body: some View {
        Button(action: open) {
            HStack(spacing: 7) {
                AgentStateGlyph(state: state)
                    .scaleEffect(0.8)
                    .frame(width: 14)
                Text(session.displayTitle)
                    .font(.system(size: 11.5, weight: isRunning ? .medium : .regular))
                    .foregroundStyle(isRunning ? theme.textColor : theme.secondaryColor)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(Format.ago(session.lastActivity))
                    .font(.system(size: 10))
                    .foregroundStyle(theme.tertiaryColor)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isRunning ? "Running in this worktree's terminal" : "Resume “\(session.displayTitle)”")
    }

    private func open() {
        let workspace = WorkspaceStore.shared
        workspace.select(project: project, worktree: worktree.path)
        let store = project.store(for: worktree.path)
        store.sidebar = .terminal
        guard !isRunning else { return }
        if project.terminal(for: worktree.path) != nil {
            store.confirm("Switch to “\(session.displayTitle)”?", "The terminal running in \(worktree.name) closes; its conversation can be resumed later.",
                          action: "Switch", destructive: false) {
                project.launch(.resume(sessionID: session.id), in: worktree.path)
            }
        } else {
            project.launch(.resume(sessionID: session.id), in: worktree.path)
        }
    }
}
