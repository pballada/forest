import ForestCore
import ForestTerminal
import SwiftUI

/// Forest's single window: projects and their agents on the left, the selected worktree in the middle
/// (terminal, changes, history) and its live changes on the right.
struct WorkspaceWindow: View {
    @State private var workspace = WorkspaceStore.shared
    @AppStorage(SettingsKey.codeTheme) private var themeID = CodeTheme.defaultID
    @AppStorage(SettingsKey.terminalFont) private var terminalFont = ""
    @AppStorage(SettingsKey.terminalFontSize) private var terminalFontSize = 0.0
    @AppStorage(SettingsKey.terminalOwnColors) private var terminalOwnColors = false
    @Environment(\.colorScheme) private var systemScheme
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var columns = NavigationSplitViewVisibility.all

    private var theme: CodeTheme { CodeTheme.named(themeID) }

    var body: some View {
        content
            .environment(\.theme, theme)
            .preferredColorScheme(theme.colorScheme)
            // List selections draw white text on the tint, so it must be dark enough to read.
            .tint(theme.accentFillColor)
            .frame(minWidth: 1000, minHeight: 620)
            .task {
                WindowOpener.install(open: openWindow, dismiss: dismissWindow)
                workspace.restore()
                await Snapshotter.run(workspace: workspace)
            }
            .task(id: terminalKey) { applyTerminalAppearance() }
            .focusedSceneValue(\.repoStore, workspace.selectedStore ?? workspace.selectedProject?.main)
            .focusedSceneValue(\.workspace, workspace)
    }

    @ViewBuilder private var content: some View {
        if workspace.projects.isEmpty {
            WelcomeView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            NavigationSplitView(columnVisibility: $columns) {
                WorkspaceSidebar(workspace: workspace)
                    .navigationSplitViewColumnWidth(min: 220, ideal: 264, max: 380)
            } detail: {
                detail
                    .inspector(isPresented: inspectorBinding) {
                        if let project = workspace.selectedProject, let path = workspace.selection?.worktree {
                            LiveChangesPanel(project: project, store: project.store(for: path), path: path)
                                .inspectorColumnWidth(min: 250, ideal: 300, max: 440)
                        }
                    }
            }
            .navigationSplitViewStyle(.balanced)
            .toolbarBackground(theme.canvasColor, for: .windowToolbar)
            .modifier(HiddenWindowTitle())
        }
    }

    private var inspectorBinding: Binding<Bool> {
        Binding(get: { workspace.showInspector && workspace.selection?.worktree != nil },
                set: { value in
                    // The inspector reports "hidden" while a project overview is shown; that isn't a user choice.
                    if workspace.selection?.worktree != nil { workspace.showInspector = value }
                })
    }

    @ViewBuilder private var detail: some View {
        if let project = workspace.selectedProject {
            if let path = workspace.selection?.worktree, let worktree = project.worktree(at: path) {
                WorktreeWorkspace(project: project, store: project.store(for: path), worktree: worktree)
                    .id(path)
            } else if workspace.selection?.worktree != nil && !project.main.loaded {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProjectOverview(project: project)
            }
        } else {
            EmptyState(title: "Choose a worktree", systemImage: "square.stack.3d.up", message: "Pick a project or agent on the left.")
        }
    }

    private var terminalKey: String { "\(themeID)-\(systemScheme == .dark)-\(terminalFont)-\(terminalFontSize)-\(terminalOwnColors)" }

    private func applyTerminalAppearance() {
        let appearance = theme.terminalAppearance(dark: systemScheme == .dark,
                                                  fontFamily: terminalFont.isEmpty ? nil : terminalFont,
                                                  fontSize: terminalFontSize > 0 ? terminalFontSize : nil)
        TerminalSession.apply(appearance, useOwnGhosttyColors: terminalOwnColors)
    }
}

/// Every agent of a project as cards: the landing page when a project (not a worktree) is selected.
struct ProjectOverview: View {
    let project: ProjectStore

    var body: some View {
        WorktreesView(store: project.main)
            .navigationTitle(project.name)
            .toolbar { RepoToolbar(store: project.main) }
            .storePresentation(project.main)
    }
}

struct WorkspaceKey: FocusedValueKey {
    typealias Value = WorkspaceStore
}

extension FocusedValues {
    var workspace: WorkspaceStore? {
        get { self[WorkspaceKey.self] }
        set { self[WorkspaceKey.self] = newValue }
    }
}

/// The worktree header already names what's shown; the toolbar keeps only its buttons.
private struct HiddenWindowTitle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.toolbar(removing: .title)
        } else {
            content
        }
    }
}
