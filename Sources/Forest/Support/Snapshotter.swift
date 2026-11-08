import AppKit
import ForestCore
import ForestTerminal
import SwiftUI

/// Development aid: with `FOREST_SNAPSHOT_DIR` set, walks through the main screens of the first
/// repository window and writes PNGs of the window (toolbar included), then quits.
/// Paths in `FOREST_SNAPSHOT_FILES` (comma-separated) are selected in turn on the Changes screen.
@MainActor
enum Snapshotter {
    static var directory: URL? {
        ProcessInfo.processInfo.environment["FOREST_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }
    }

    static func run(workspace: WorkspaceStore) async {
        guard let directory else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Wait for the project from the command line to load.
        for _ in 0..<40 where workspace.selectedProject?.main.loaded != true {
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard let project = workspace.selectedProject else { return }
        let mainPath = project.root.path
        try? await Task.sleep(for: .seconds(1.5))
        let store = project.store(for: mainPath)
        let themes = (ProcessInfo.processInfo.environment["FOREST_SNAPSHOT_THEMES"] ?? "")
            .split(separator: ",").map(String.init)

        let files = (ProcessInfo.processInfo.environment["FOREST_SNAPSHOT_FILES"] ?? "")
            .split(separator: ",").map(String.init)
        var steps: [(String, () -> Void)] = []
        steps.append(("1-terminal", {
            workspace.select(project: project, worktree: mainPath)
            store.sidebar = .terminal
            let session = project.launch(.shell, in: mainPath)
            Task {
                try? await Task.sleep(for: .seconds(1))
                session.send("echo forest $TERM && git log --oneline -3", submit: true)
            }
        }))
        for (index, file) in files.enumerated() {
            let split = file.hasPrefix("split:")
            let path = split ? String(file.dropFirst(6)) : file
            steps.append(("2-changes-\(index)", {
                UserDefaults.standard.set(split ? DiffPresentation.split.rawValue : DiffPresentation.unified.rawValue, forKey: "diff.presentation")
                store.sidebar = .changes
                let id = store.allChanges.first { $0.path == path }?.id
                store.selectedChangeIDs = id.map { [$0] } ?? []
            }))
        }
        steps += [
            ("3-history", {
                UserDefaults.standard.set(DiffPresentation.unified.rawValue, forKey: "diff.presentation")
                store.sidebar = .history
                if let merge = store.commits.first(where: \.isMerge) { Task { await store.selectCommit(merge.id) } }
            }),
            ("4-overview", { workspace.select(project: project, worktree: nil) }),
        ]
        if let agent = project.agents.first {
            steps.append(("5-agent", {
                workspace.select(project: project, worktree: agent.path)
                project.store(for: agent.path).sidebar = .terminal
            }))
            steps.append(("6-review", { project.main.sheet = .review(agent) }))
        }
        steps += [
            ("7-palette", {
                project.main.sheet = nil
                workspace.select(project: project, worktree: mainPath)
                store.sidebar = .terminal
                store.showPalette = true
            }),
            ("8-new-agent", {
                store.showPalette = false
                store.sheet = .newAgent(base: nil)
            }),
            ("9-toast", {
                store.sheet = nil
                store.offerUndo("Commit") {}
                store.flash("Committed “Add onboarding analytics”")
            }),
        ]
        for theme in themes {
            steps.append(("theme-\(theme)", {
                UserDefaults.standard.set(theme, forKey: SettingsKey.codeTheme)
                workspace.select(project: project, worktree: project.agents.first?.path ?? mainPath)
            }))
        }
        for (name, step) in steps {
            let start = Date()
            step()
            try? await Task.sleep(for: .seconds(2.2))
            capture(name: name, in: directory)
            if name == "1-terminal", let session = project.terminal(for: mainPath) {
                try? session.visibleText().write(to: directory.appendingPathComponent("1-terminal.txt"), atomically: true, encoding: .utf8)
            }
            print("snapshot \(name) after \(String(format: "%.1f", Date().timeIntervalSince(start)))s")
        }
        let settings = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 420), styleMask: [.titled], backing: .buffered, defer: false)
        settings.contentView = NSHostingView(rootView: AppearanceSettings().padding(20).frame(width: 620).background(Color(nsColor: .windowBackgroundColor)))
        settings.orderFront(nil)
        try? await Task.sleep(for: .seconds(1))
        if let view = settings.contentView { write(view: view, to: directory.appendingPathComponent("10-themes.png")) }
        settings.close()
        NSApp.terminate(nil)
    }

    private static func capture(name: String, in directory: URL) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.identifier?.rawValue.contains("main") == true })
                ?? NSApp.windows.first(where: { $0.isVisible && $0.title != "Welcome to Forest" && $0.contentView != nil && $0.frame.width > 800 }),
              let frameView = window.contentView?.superview else { return }
        write(view: frameView, to: directory.appendingPathComponent("\(name).png"))
        if let sheet = window.attachedSheet, let sheetView = sheet.contentView?.superview {
            write(view: sheetView, to: directory.appendingPathComponent("\(name)-sheet.png"))
        }
    }

    private static func write(view: NSView, to url: URL) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
