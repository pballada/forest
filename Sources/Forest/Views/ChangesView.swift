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
                     store: store)
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

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 44))
                .foregroundStyle(Theme.forestGradient)
            Text("Working tree clean").font(.title3.weight(.semibold))
            Text(store.status.ahead > 0 ? "\(store.status.ahead) commit\(store.status.ahead == 1 ? "" : "s") ready to push."
                 : "Nothing to commit.")
                .foregroundStyle(.secondary)
            if store.status.ahead > 0 {
                Button { store.push() } label: { Label("Push \(store.status.branch ?? "")", systemImage: "arrow.up") }
                    .buttonStyle(.borderedProminent)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ChangeLists: View {
    @Bindable var store: RepoStore

    var body: some View {
        let status = store.status
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
                .buttonStyle(.link)
                .font(.system(size: 11.5))
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
            }
        }
        .padding(12)
        .background(.bar)
    }

    private var commitTitle: String {
        if store.amend { return "Amend Commit" }
        let count = store.status.staged.count
        return count == 0 ? "Commit" : "Commit \(count) File\(count == 1 ? "" : "s")"
    }
}
