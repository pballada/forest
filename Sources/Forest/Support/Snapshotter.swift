import AppKit
import ForestCore
import SwiftUI

/// Development aid: with `FOREST_SNAPSHOT_DIR` set, walks through the main screens of the first
/// repository window and writes PNGs of the window (toolbar included), then quits.
/// Paths in `FOREST_SNAPSHOT_FILES` (comma-separated) are selected in turn on the Changes screen.
@MainActor
enum Snapshotter {
    static var directory: URL? {
        ProcessInfo.processInfo.environment["FOREST_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }
    }

    static func run(store: RepoStore) async {
        guard let directory else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? await Task.sleep(for: .seconds(2.5))

        let files = (ProcessInfo.processInfo.environment["FOREST_SNAPSHOT_FILES"] ?? "")
            .split(separator: ",").map(String.init)
        var steps: [(String, () -> Void)] = []
        for (index, file) in files.enumerated() {
            let split = file.hasPrefix("split:")
            let path = split ? String(file.dropFirst(6)) : file
            steps.append(("1-changes-\(index)", {
                UserDefaults.standard.set(split ? DiffPresentation.split.rawValue : DiffPresentation.unified.rawValue, forKey: "diff.presentation")
                store.sidebar = .changes
                let id = store.allChanges.first { $0.path == path }?.id
                store.selectedChangeIDs = id.map { [$0] } ?? []
            }))
        }
        UserDefaults.standard.set(DiffPresentation.unified.rawValue, forKey: "diff.presentation")
        steps += [
            ("2-history", {
                UserDefaults.standard.set(DiffPresentation.unified.rawValue, forKey: "diff.presentation")
                store.sidebar = .history
                if let merge = store.commits.first(where: \.isMerge) { Task { await store.selectCommit(merge.id) } }
            }),
            ("3-worktrees", { store.sidebar = .worktrees }),
            ("4-review", {
                if let agent = store.worktrees.first(where: { $0.isClaude && $0.branch != store.mainWorktree?.branch && $0.name.contains("refactor") })
                    ?? store.claudeWorktrees.first {
                    store.sheet = .review(agent)
                }
            }),
            ("5-palette", {
                store.sheet = nil
                store.showPalette = true
            }),
            ("6-new-agent", {
                store.showPalette = false
                store.sheet = .newWorktree(base: nil, claude: true)
            }),
            ("7-toast", {
                store.sheet = nil
                store.offerUndo("Commit") {}
                store.flash("Committed “Add onboarding analytics”")
            }),
        ]
        for (name, step) in steps {
            let start = Date()
            step()
            try? await Task.sleep(for: .seconds(2.2))
            capture(name: name, in: directory)
            print("snapshot \(name) after \(String(format: "%.1f", Date().timeIntervalSince(start)))s")
        }
        WindowOpener.openWindow?(id: "welcome")
        try? await Task.sleep(for: .seconds(1.5))
        if let welcome = NSApp.windows.first(where: { $0.title == "Welcome to Forest" && $0.isVisible }), let view = welcome.contentView?.superview {
            write(view: view, to: directory.appendingPathComponent("0-welcome.png"))
        }
        NSApp.terminate(nil)
    }

    private static func capture(name: String, in directory: URL) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.title != "Welcome to Forest" && $0.contentView != nil && $0.frame.width > 800 }),
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
