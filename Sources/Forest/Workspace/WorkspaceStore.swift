import AppKit
import ForestCore
import SwiftUI

/// Every project open in Forest's window, what's selected, and what to bring back next launch.
@Observable @MainActor
final class WorkspaceStore {
    static let shared = WorkspaceStore()

    struct Selection: Hashable, Codable {
        var project: String
        /// nil shows the project overview.
        var worktree: String?
    }

    private(set) var projects: [ProjectStore] = []
    var selection: Selection? { didSet { if selection != oldValue { saveSelection() } } }
    var showInspector: Bool {
        didSet { UserDefaults.standard.set(showInspector, forKey: Keys.inspector) }
    }
    private(set) var restored = false

    private enum Keys {
        static let projects = "workspace.projects"
        static let selection = "workspace.selection"
        static let terminals = "workspace.terminals"
        static let inspector = "workspace.inspector"
        static let tools = "workspace.tools"
    }

    private init() {
        showInspector = UserDefaults.standard.object(forKey: Keys.inspector) as? Bool ?? true
    }

    var selectedProject: ProjectStore? {
        guard let selection else { return nil }
        return projects.first { $0.id == selection.project }
    }

    /// The store of the selected worktree (nil on a project overview).
    var selectedStore: RepoStore? {
        guard let project = selectedProject, let path = selection?.worktree else { return nil }
        return project.store(for: path)
    }

    var selectedWorktree: Worktree? {
        guard let project = selectedProject, let path = selection?.worktree else { return nil }
        return project.worktree(at: path)
    }

    // MARK: Projects

    /// Reopens the projects from last time.
    func restore() {
        guard !restored else { return }
        restored = true
        let saved = UserDefaults.standard.stringArray(forKey: Keys.projects) ?? []
        let selection = (UserDefaults.standard.data(forKey: Keys.selection)).flatMap { try? JSONDecoder().decode(Selection.self, from: $0) }
        Task {
            for path in saved where FileManager.default.fileExists(atPath: path) {
                await add(URL(fileURLWithPath: path), select: false)
            }
            if let selection, projects.contains(where: { $0.id == selection.project }) {
                self.selection = selection
            } else if let first = projects.first {
                self.selection = Selection(project: first.id, worktree: first.root.path)
            }
        }
    }

    /// Adds a repository (or one of its worktrees) and selects it.
    func open(_ url: URL) async {
        await add(url, select: true)
    }

    private func add(_ url: URL, select: Bool) async {
        guard let repository = try? await Repository.open(url) else { return }
        let mainRoot = (try? await repository.mainWorktreeRoot()) ?? repository.root
        let rootPath = mainRoot.resolvingSymlinksInPath().path
        let worktreePath = repository.root.resolvingSymlinksInPath().path

        let project: ProjectStore
        if let existing = projects.first(where: { $0.root.resolvingSymlinksInPath().path == rootPath }) {
            project = existing
        } else {
            let mainRepository = mainRoot.path == repository.root.path ? repository : Repository(root: mainRoot)
            project = ProjectStore(main: RepoStore(repository: mainRepository))
            project.start()
            projects.append(project)
            RecentRepositories.shared.add(project.root.path)
            saveProjects()
        }
        if select {
            self.select(project: project, worktree: project.canonicalPath(worktreePath))
        }
    }

    func close(_ project: ProjectStore) {
        project.stop()
        projects.removeAll { $0 === project }
        if selection?.project == project.id {
            selection = projects.first.map { Selection(project: $0.id, worktree: $0.root.path) }
        }
        saveProjects()
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        projects.move(fromOffsets: source, toOffset: destination)
        saveProjects()
    }

    func select(project: ProjectStore, worktree path: String?) {
        selection = Selection(project: project.id, worktree: path)
    }

    /// All worktrees across projects in sidebar order, for ⌘1…⌘9 and ⌃Tab.
    var orderedWorktrees: [(ProjectStore, Worktree)] {
        projects.flatMap { project in project.worktrees.map { (project, $0) } }
    }

    func selectWorktree(at index: Int) {
        let all = orderedWorktrees
        guard all.indices.contains(index) else { return }
        select(project: all[index].0, worktree: all[index].1.path)
    }

    func selectAdjacent(_ offset: Int) {
        let all = orderedWorktrees
        guard !all.isEmpty else { return }
        let current = all.firstIndex { $0.0.id == selection?.project && $0.1.path == selection?.worktree } ?? -1
        let next = ((current + offset) % all.count + all.count) % all.count
        select(project: all[next].0, worktree: all[next].1.path)
    }

    // MARK: Persistence

    private func saveProjects() {
        UserDefaults.standard.set(projects.map(\.root.path), forKey: Keys.projects)
    }

    private func saveSelection() {
        if let selection, let data = try? JSONEncoder().encode(selection) {
            UserDefaults.standard.set(data, forKey: Keys.selection)
        }
    }

    /// Session ids that had a terminal open, by worktree path: offered as "Continue" after a relaunch.
    func rememberTerminal(path: String, sessionID: String?) {
        var saved = UserDefaults.standard.dictionary(forKey: Keys.terminals) as? [String: String] ?? [:]
        saved[path] = sessionID
        UserDefaults.standard.set(saved, forKey: Keys.terminals)
    }

    func rememberTool(_ tool: AgentTool, for path: String) {
        var saved = UserDefaults.standard.dictionary(forKey: Keys.tools) as? [String: String] ?? [:]
        saved[path] = tool.rawValue
        UserDefaults.standard.set(saved, forKey: Keys.tools)
    }

    func rememberedTool(for path: String) -> AgentTool? {
        ((UserDefaults.standard.dictionary(forKey: Keys.tools) as? [String: String])?[path]).flatMap(AgentTool.init(rawValue:))
    }

    func rememberedSessionID(for path: String) -> String? {
        (UserDefaults.standard.dictionary(forKey: Keys.terminals) as? [String: String])?[path]
    }

    func updateDockBadge() {
        let count = projects.map(\.needsInputCount).reduce(0, +)
        NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
    }
}
