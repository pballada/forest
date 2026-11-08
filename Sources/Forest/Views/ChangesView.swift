import ForestCore
import SwiftUI

struct ChangesView: View {
    @Bindable var store: RepoStore

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                if store.status.isClean && store.loaded {
                    CleanState(store: store)
                } else {
                    ChangeLists(store: store)
                }
                Divider()
                CommitComposer(store: store)
            }
            .frame(minWidth: 300, idealWidth: 400, maxWidth: 620)

            DiffView(diff: store.focusedChange == nil ? nil : store.changeDiff,
                     mode: store.focusedChange.map { $0.staged ? .staged : ($0.status == .conflicted ? .readOnly : .unstaged) } ?? .readOnly,
                     store: store,
                     images: store.focusedChange.map { store.imagePair(for: $0) },
                     emptyTitle: store.selectedChangeIDs.count > 1 ? "\(store.selectedChangeIDs.count) files selected" : "No file selected")
                .frame(minWidth: 400)
        }
        .onChange(of: store.selectedChangeIDs) { _, _ in
            if let change = store.focusedChange {
                Task { await store.loadDiff(for: change) }
            } else {
                store.changeDiff = nil
            }
        }
    }
}

private struct CleanState: View {
    let store: RepoStore
    @State private var sway = false

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            ZStack(alignment: .bottom) {
                Ellipse().fill(Theme.leaf.opacity(0.12)).frame(width: 150, height: 22).offset(y: 8)
                HStack(alignment: .bottom, spacing: -6) {
                    tree(size: 34, color: Theme.moss, delay: 0.3)
                    tree(size: 54, color: Theme.leaf, delay: 0)
                    tree(size: 40, color: Color(red: 0.10, green: 0.55, blue: 0.45), delay: 0.6)
                }
            }
            .onAppear { sway = true }
            Text("All clean").font(.system(size: 19, weight: .semibold, design: .rounded))
            Text(store.status.ahead > 0 ? "\(store.status.ahead) commit\(store.status.ahead == 1 ? "" : "s") ready to push."
                 : "Nothing to commit. Enjoy the quiet.")
                .foregroundStyle(.secondary)
            if store.status.ahead > 0 {
                Button { store.push() } label: { Label("Push \(store.status.branch ?? "")", systemImage: "arrow.up") }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func tree(size: CGFloat, color: Color, delay: Double) -> some View {
        Image(systemName: "tree.fill")
            .font(.system(size: size))
            .foregroundStyle(color.gradient)
            .rotationEffect(.degrees(sway ? 2.5 : -2.5), anchor: .bottom)
            .animation(.easeInOut(duration: 2.6).repeatForever().delay(delay), value: sway)
    }
}

private struct ChangeLists: View {
    @Bindable var store: RepoStore
    @State private var filter = ""

    private func matches(_ change: FileChange) -> Bool {
        filter.isEmpty || change.path.localizedCaseInsensitiveContains(filter)
    }

    var body: some View {
        let status = filteredStatus
        List(selection: $store.selectedChangeIDs) {
            if !status.conflicted.isEmpty {
                Section {
                    ForEach(status.conflicted) { change in
                        ChangeRow(store: store, change: change)
                    }
                } header: {
                    ListHeader(title: "Conflicts", count: status.conflicted.count, tint: .red) {
                        Button("Mark All Resolved") { store.markResolved(status.conflicted) }
                    }
                }
            }
            Section {
                ForEach(status.unstaged) { change in
                    ChangeRow(store: store, change: change)
                }
            } header: {
                ListHeader(title: "Unstaged", count: status.unstaged.count) {
                    if !status.unstaged.isEmpty {
                        Button("Stage All") { store.stageAll() }
                    }
                }
            }
            Section {
                ForEach(status.staged) { change in
                    ChangeRow(store: store, change: change)
                }
            } header: {
                ListHeader(title: "Staged", count: status.staged.count, tint: Theme.added) {
                    if !status.staged.isEmpty {
                        Button("Unstage All") { store.unstageAll() }
                    }
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: String.self) { ids in
            let changes = store.allChanges.filter { ids.contains($0.id) }
            ChangeMenuItems(store: store, changes: changes)
        } primaryAction: { ids in
            // Double-click (or Return) moves files between staged and unstaged.
            let changes = store.allChanges.filter { ids.contains($0.id) }
            let unstaged = changes.filter { !$0.staged && $0.status != .conflicted }
            let staged = changes.filter(\.staged)
            if !unstaged.isEmpty { store.stage(unstaged) }
            if !staged.isEmpty { store.unstage(staged) }
        }
        .onKeyPress(.space) {
            let changes = store.selectedChanges
            guard !changes.isEmpty else { return .ignored }
            if changes.allSatisfy(\.staged) { store.unstage(changes) } else { store.stage(changes.filter { !$0.staged }) }
            return .handled
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if store.allChanges.count > 8 {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Filter files", text: $filter).textFieldStyle(.plain)
                    if !filter.isEmpty {
                        Button { filter = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                            .buttonStyle(.plain)
                    }
                }
                .font(.callout)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.05)))
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 2)
            }
        }
    }

    private var filteredStatus: RepoStatus {
        guard !filter.isEmpty else { return store.status }
        var status = store.status
        status.staged = status.staged.filter(matches)
        status.unstaged = status.unstaged.filter(matches)
        status.conflicted = status.conflicted.filter(matches)
        return status
    }
}

private struct ListHeader<Actions: View>: View {
    let title: String
    let count: Int
    var tint: Color = .secondary
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(tint).frame(width: 6, height: 6)
            Text(title).font(.system(size: 11.5, weight: .semibold))
            Text("\(count)").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).monospacedDigit()
            Spacer()
            actions
                .buttonStyle(.plain)
                .foregroundStyle(Theme.leaf)
                .font(.system(size: 11.5, weight: .medium))
        }
        .padding(.vertical, 2)
    }
}

private struct ChangeRow: View {
    let store: RepoStore
    let change: FileChange
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 7) {
            StatusIcon(status: change.status)
            FilePathLabel(change: change)
            if let original = change.originalPath {
                Text("← \((original as NSString).lastPathComponent)").font(.caption).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if !hovering, let counts = store.lineCounts[change.id], counts.0 + counts.1 > 0 {
                LineCountLabel(additions: counts.0, deletions: counts.1)
            }
            if hovering {
                if change.status == .conflicted {
                    HoverButton(systemImage: "checkmark", help: "Mark resolved") { store.markResolved([change]) }
                } else if change.staged {
                    HoverButton(systemImage: "minus", help: "Unstage") { store.unstage([change]) }
                } else {
                    HoverButton(systemImage: "arrow.uturn.backward", help: "Discard changes") { store.discard([change]) }
                    HoverButton(systemImage: "plus", help: "Stage", tint: Theme.added) { store.stage([change]) }
                }
            }
        }
        .frame(height: 20)
        .tag(change.id)
        .onHover { hovering = $0 }
    }
}

private struct LineCountLabel: View {
    let additions: Int
    let deletions: Int

    var body: some View {
        HStack(spacing: 4) {
            if additions > 0 { Text("+\(additions.formatted(.number.notation(.compactName)))").foregroundStyle(Theme.added) }
            if deletions > 0 { Text("−\(deletions.formatted(.number.notation(.compactName)))").foregroundStyle(Theme.removed) }
        }
        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
        .monospacedDigit()
        .opacity(0.85)
    }
}

private struct ChangeMenuItems: View {
    let store: RepoStore
    let changes: [FileChange]

    var body: some View {
        let unstaged = changes.filter { !$0.staged && $0.status != .conflicted }
        let staged = changes.filter(\.staged)
        let conflicted = changes.filter { $0.status == .conflicted }
        if !unstaged.isEmpty { Button("Stage") { store.stage(unstaged) } }
        if !staged.isEmpty { Button("Unstage") { store.unstage(staged) } }
        if conflicted.count == 1, let change = conflicted.first {
            Button("Resolve Using Ours") { store.resolve(change, .ours) }
            Button("Resolve Using Theirs") { store.resolve(change, .theirs) }
        }
        if !conflicted.isEmpty { Button("Mark Resolved") { store.markResolved(conflicted) } }
        if changes.count == 1, let change = changes.first {
            Divider()
            Button("Open in \(Preferences.editor.rawValue)") { Launcher.openInEditor(store.repository.root.appendingPathComponent(change.path)) }
            Button("Reveal in Finder") { Launcher.revealInFinder(store.repository.root.appendingPathComponent(change.path)) }
            Button("Copy Path") { copy(change.path) }
            if change.status == .untracked {
                Button("Ignore “\(change.fileName)”") {
                    store.run("Ignoring") { try await appendToGitignore(change.path, root: store.repository.root) }
                }
            }
        }
        if !unstaged.isEmpty {
            Divider()
            Button("Discard Changes…", role: .destructive) { store.discard(unstaged) }
        }
    }
}

private func appendToGitignore(_ path: String, root: URL) async throws {
    let file = root.appendingPathComponent(".gitignore")
    var contents = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
    if !contents.isEmpty, !contents.hasSuffix("\n") { contents += "\n" }
    contents += "/" + path + "\n"
    try contents.write(to: file, atomically: true, encoding: .utf8)
}

struct CommitComposer: View {
    @Environment(\.theme) private var theme
    @Bindable var store: RepoStore
    @FocusState private var summaryFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                TextField("Summary", text: $store.commitSummary, prompt: Text(store.amend ? "Amend message" : "Commit summary"))
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .focused($summaryFocused)
                    .onSubmit { store.commit() }
                Text("\(store.commitSummary.count)")
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(store.commitSummary.count > 72 ? Color.orange : Color.secondary.opacity(0.6))
                    .help("Keep summaries under 72 characters")
                if Preferences.aiFeatures {
                    ClaudeWriteButton(store: store)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))

            ZStack(alignment: .topLeading) {
                if store.commitDescription.isEmpty {
                    Text("Description (optional)")
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $store.commitDescription)
                    .scrollContentBackground(.hidden)
                    .font(.system(size: 12.5))
            }
            .frame(height: 64)
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))

            HStack {
                Toggle("Amend", isOn: Binding(get: { store.amend }, set: { store.setAmend($0) }))
                    .toggleStyle(.checkbox)
                    .disabled(store.status.headSHA == nil)
                Spacer()
                Menu {
                    Button("Commit & Push") { store.commit(andPush: true) }
                } label: {
                    Text(commitTitle).frame(minWidth: 110)
                } primaryAction: {
                    store.commit()
                }
                .menuStyle(.borderedButton)
                .fixedSize()
                .disabled(!store.canCommit)
                .help("⌘↩")
                .overlay { LeafBurst(trigger: store.celebration) }
            }
        }
        .padding(12)
        .background(theme.sidebarColor)
    }

    private var commitTitle: String {
        if store.amend { return "Amend Commit" }
        let count = store.status.staged.count
        return count == 0 ? "Commit" : "Commit \(count) File\(count == 1 ? "" : "s")"
    }
}

/// Asks Claude to describe the staged changes and fills in the message.
private struct ClaudeWriteButton: View {
    let store: RepoStore
    @State private var hovering = false

    var body: some View {
        Button { store.generateCommitMessage() } label: {
            Image(systemName: "sparkles")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(store.generatingMessage || hovering ? AnyShapeStyle(Theme.claudeGradient) : AnyShapeStyle(Color.secondary))
                .symbolEffect(.pulse, isActive: store.generatingMessage)
                .frame(width: 22, height: 20)
                .background(RoundedRectangle(cornerRadius: 5).fill(hovering ? Theme.claude.opacity(0.12) : .clear))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .disabled(store.generatingMessage)
        .help(store.status.staged.isEmpty ? "Stage changes, then let Claude write the message (⌥⌘M)"
              : store.generatingMessage ? "Claude is writing…" : "Write the message with Claude (⌥⌘M)")
    }
}

/// A small burst of leaves when a commit lands.
struct LeafBurst: View {
    let trigger: Int
    @State private var progress: CGFloat = 1
    private let leaves = 9

    var body: some View {
        ZStack {
            ForEach(0..<leaves, id: \.self) { index in
                let angle = Double(index) / Double(leaves) * 2 * .pi + 0.4
                Image(systemName: index.isMultiple(of: 3) ? "leaf.fill" : "circle.fill")
                    .font(.system(size: index.isMultiple(of: 3) ? 11 : 5))
                    .foregroundStyle([Theme.leaf, Theme.moss, Theme.sun][index % 3])
                    .rotationEffect(.radians(angle + Double(progress) * 2))
                    .offset(x: cos(angle) * 46 * progress, y: sin(angle) * 26 * progress - 10 * progress)
                    .opacity(progress < 1 ? Double(1 - progress) * 1.4 : 0)
                    .scaleEffect(0.6 + progress * 0.6)
            }
        }
        .allowsHitTesting(false)
        .onChange(of: trigger) { _, _ in
            guard Preferences.celebrate else { return }
            progress = 0
            withAnimation(.easeOut(duration: 0.9)) { progress = 1 }
        }
    }
}
