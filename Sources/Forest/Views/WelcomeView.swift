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
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
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
            VStack(spacing: 4) {
                Text("Forest")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                Text("Git, beautifully. Worktrees & agents, natively.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            VStack(spacing: 8) {
                WelcomeAction(title: "Open Repository…", systemImage: "folder", shortcut: "⌘O") { WindowOpener.showOpenPanel() }
                WelcomeAction(title: "Clone Repository…", systemImage: "arrow.down.circle", shortcut: "⇧⌘O") { showClone = true }
                WelcomeAction(title: "New Repository…", systemImage: "plus.square.dashed", shortcut: "") { createRepository() }
            }
            .padding(.top, 8)
            Spacer()
            Text("Drop a folder anywhere to open it")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 18)
        }
        .padding(.horizontal, 28)
        .frame(maxHeight: .infinity)
        .background(
            ZStack {
                Theme.forestGradient.opacity(0.10)
                RadialGradient(colors: [Color.green.opacity(0.18), .clear], center: .top, startRadius: 10, endRadius: 320)
            }
        )
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
                    .foregroundStyle(Color.accentColor)
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
                    .foregroundStyle(ClaudeCode.isClaudeWorktree(path: path) ? Theme.claude : Color.accentColor)
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

/// The Forest mark: three stacked trees on a green squircle.
struct AppGlyph: View {
    var size: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.23, style: .continuous)
            .fill(Theme.forestGradient)
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
            .shadow(color: Color.green.opacity(0.35), radius: size * 0.15, y: size * 0.06)
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
