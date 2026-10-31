import AppKit
import SwiftUI

/// Development aid: with `FOREST_SNAPSHOT_DIR` set, walks through the main screens of the first
/// repository window and writes PNGs of the window (toolbar included), then quits.
@MainActor
enum Snapshotter {
    static var directory: URL? {
        ProcessInfo.processInfo.environment["FOREST_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }
    }

    static func run(store: RepoStore) async {
        guard let directory else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? await Task.sleep(for: .seconds(2.5))

        let steps: [(String, () -> Void)] = [
            ("1-changes", { store.sidebar = .changes }),
            ("2-history", {
                store.sidebar = .history
                if let merge = store.commits.first(where: \.isMerge) { Task { await store.selectCommit(merge.id) } }
            }),
            ("3-worktrees", { store.sidebar = .worktrees }),
            ("4-palette", { store.showPalette = true }),
            ("5-new-agent", {
                store.showPalette = false
                store.sheet = .newWorktree(base: nil, claude: true)
            }),
        ]
        for (name, step) in steps {
            step()
            try? await Task.sleep(for: .seconds(1.6))
            capture(name: name, in: directory)
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
