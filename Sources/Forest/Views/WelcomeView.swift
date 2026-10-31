import ForestCore
import SwiftUI

struct WelcomeView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var recents = RecentRepositories.shared
    @State private var showClone = false
    @State private var dropTargeted = false

    var body: some View {
        HStack(spacing: 0) {
            hero
                .frame(width: 330)
            Divider()
            recentList
        }
        .background(.background)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Theme.leaf, style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
                    .padding(8)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            urls.forEach(WindowOpener.open)
            return !urls.isEmpty
        } isTargeted: { dropTargeted = $0 }
        .sheet(isPresented: $showClone) { CloneSheet() }
        .onReceive(NotificationCenter.default.publisher(for: .showClone)) { _ in showClone = true }
        .task {
            // Give the delegate a beat to queue command-line paths before installing.
            try? await Task.sleep(for: .milliseconds(50))
            WindowOpener.install(open: openWindow, dismiss: dismissWindow)
        }
    }

    private var hero: some View {
        VStack(spacing: 18) {
            Spacer()
            AppGlyph(size: 108)
            VStack(spacing: 6) {
                Text("Forest")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                Text(greeting)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.leaf)
                Text("Git that grows with you. Worktrees and Claude agents, side by side.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 8) {
                WelcomeAction(title: "Open Repository…", systemImage: "folder.fill", shortcut: "⌘O") { WindowOpener.showOpenPanel() }
                WelcomeAction(title: "Clone Repository…", systemImage: "arrow.down.circle.fill", shortcut: "⇧⌘O") { showClone = true }
                WelcomeAction(title: "New Repository…", systemImage: "leaf.fill", shortcut: "") { createRepository() }
            }
            .padding(.top, 8)
            Spacer()
            TipView()
                .padding(.bottom, 64)
        }
        .padding(.horizontal, 28)
        .frame(maxHeight: .infinity)
        .background(
            ZStack(alignment: .bottom) {
                LinearGradient(colors: [Theme.leaf.opacity(0.16), Theme.sky.opacity(0.06), Theme.sun.opacity(0.05)],
                               startPoint: .top, endPoint: .bottom)
                RadialGradient(colors: [Theme.leaf.opacity(0.22), .clear], center: .top, startRadius: 10, endRadius: 320)
                TreeLine()
            }
        )
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: .now) {
        case 5..<12: "Good morning"
        case 12..<18: "Good afternoon"
        case 18..<23: "Good evening"
        default: "Working late? Happy hacking"
        }
    }

    private var recentList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Recent")
                .font(.headline)
                .padding(.horizontal, 20)
                .padding(.top, 34)
                .padding(.bottom, 8)
            if recents.paths.isEmpty {
                EmptyState(title: "No recent repositories", systemImage: "clock",
                           message: "Repositories you open will show up here.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(recents.paths, id: \.self) { path in
                            RecentRow(path: path) {
                                WindowOpener.open(URL(fileURLWithPath: path))
                            } remove: {
                                recents.remove(path)
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 12)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func createRepository() {
        let panel = NSSavePanel()
        panel.prompt = "Create"
        panel.nameFieldLabel = "Repository:"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            if let repo = try? await Repository.initialize(url) { WindowOpener.open(repo.root) }
        }
    }
}

private struct WelcomeAction: View {
    let title: String
    let systemImage: String
    let shortcut: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: systemImage)
                    .frame(width: 20)
                    .foregroundStyle(Theme.leaf)
                Text(title)
                Spacer()
                Text(shortcut).foregroundStyle(.tertiary).font(.caption)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(hovering ? 0.08 : 0.04)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct RecentRow: View {
    let path: String
    let open: () -> Void
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        let exists = FileManager.default.fileExists(atPath: path)
        Button(action: open) {
            HStack(spacing: 10) {
                Image(systemName: ClaudeCode.isClaudeWorktree(path: path) ? "sparkles" : "folder.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(ClaudeCode.isClaudeWorktree(path: path) ? Theme.claude : Theme.leaf)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text((path as NSString).lastPathComponent)
                        .font(.system(size: 13, weight: .medium))
                    Text(Format.abbreviatePath(path))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                if hovering {
                    HoverButton(systemImage: "xmark", help: "Remove from Recents", action: remove)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? Color.primary.opacity(0.06) : .clear))
            .contentShape(Rectangle())
            .opacity(exists ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .disabled(!exists)
        .contextMenu {
            Button("Reveal in Finder") { Launcher.revealInFinder(URL(fileURLWithPath: path)) }
            Button("Remove from Recents", action: remove)
        }
    }
}

/// A soft horizon of trees along the bottom of the welcome hero.
private struct TreeLine: View {
    private let trees: [(CGFloat, CGFloat, Double)] = [
        (0.04, 34, 0.10), (0.13, 52, 0.14), (0.22, 30, 0.09), (0.31, 44, 0.12), (0.42, 60, 0.15), (0.53, 36, 0.10),
        (0.63, 48, 0.13), (0.73, 28, 0.08), (0.82, 56, 0.14), (0.92, 38, 0.10),
    ]

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottomLeading) {
                ForEach(Array(trees.enumerated()), id: \.offset) { _, tree in
                    Image(systemName: "tree.fill")
                        .font(.system(size: tree.1))
                        .foregroundStyle(Theme.leaf.opacity(tree.2))
                        .position(x: geometry.size.width * tree.0, y: geometry.size.height - tree.1 / 2 + 2)
                }
            }
        }
        .frame(height: 70)
        .allowsHitTesting(false)
    }
}

/// One rotating hint about something worth knowing.
private struct TipView: View {
    private static let tips = [
        "Press ⌥⌘N to start a Claude agent in its own worktree.",
        "Click ✨ in the commit box and Claude writes the message.",
        "Drag a branch onto the current one to merge it.",
        "Made a mistake? ⌥⌘Z undoes commits, discards, merges and more.",
        "Review an agent's work against main before you merge it.",
        "⌘K opens the command palette from anywhere.",
        "Select lines in a diff to stage just those lines.",
    ]
    @State private var index = Int.random(in: 0..<tips.count)

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "lightbulb.fill").foregroundStyle(Theme.sun)
            Text(Self.tips[index])
                .contentTransition(.opacity)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .onTapGesture { withAnimation { index = (index + 1) % Self.tips.count } }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(7))
                withAnimation(.easeInOut(duration: 0.4)) { index = (index + 1) % Self.tips.count }
            }
        }
        .help("Click for another tip")
    }
}

/// The Forest mark: three stacked trees on a green squircle.
struct AppGlyph: View {
    var size: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.23, style: .continuous)
            .fill(Theme.leafGradient)
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.23, style: .continuous)
                    .fill(LinearGradient(colors: [.white.opacity(0.28), .clear], startPoint: .top, endPoint: .center))
            )
            .overlay(
                Image(systemName: "tree.fill")
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.2), radius: size * 0.03, y: size * 0.02)
            )
            .frame(width: size, height: size)
            .shadow(color: Theme.leaf.opacity(0.4), radius: size * 0.15, y: size * 0.06)
    }
}

struct CloneSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var remote = ""
    @State private var parent = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Developer")
    @State private var name = ""
    @State private var cloning = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Clone Repository", systemImage: "arrow.down.circle.fill")
                .font(.title3.bold())
            Form {
                TextField("URL", text: $remote, prompt: Text("https://github.com/owner/repo.git"))
                    .onChange(of: remote) { _, value in name = Self.repoName(from: value) }
                TextField("Name", text: $name)
                LabeledContent("Location") {
                    HStack {
                        Text(Format.abbreviatePath(parent.path)).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Choose…", action: choose)
                    }
                }
            }
            .formStyle(.columns)
            if let error {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                if cloning { ProgressView().controlSize(.small); Text("Cloning…").foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Clone", action: clone)
                    .keyboardShortcut(.defaultAction)
                    .disabled(remote.isEmpty || name.isEmpty || cloning)
            }
        }
        .padding(22)
        .frame(width: 500)
    }

    static func repoName(from url: String) -> String {
        var last = url.split(whereSeparator: { $0 == "/" || $0 == ":" }).last.map(String.init) ?? ""
        if last.hasSuffix(".git") { last.removeLast(4) }
        return last
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { parent = url }
    }

    private func clone() {
        cloning = true
        error = nil
        Task {
            do {
                let repo = try await Repository.clone(remote, into: parent.appendingPathComponent(name))
                WindowOpener.open(repo.root)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            cloning = false
        }
    }
}
