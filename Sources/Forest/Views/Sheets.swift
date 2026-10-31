import ForestCore
import SwiftUI

/// Standard chrome for every sheet: icon + title, content, and Cancel/primary buttons.
struct SheetScaffold<Content: View>: View {
    let title: String
    let systemImage: String
    var tint: Color = Theme.leaf
    let actionTitle: String
    let canSubmit: Bool
    let submit: () -> Void
    @ViewBuilder var content: Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint.gradient))
                Text(title).font(.title3.weight(.semibold))
            }
            content
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(actionTitle) {
                    submit()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(tint)
                .disabled(!canSubmit)
            }
        }
        .padding(22)
        .frame(width: 500)
    }
}

func isValidRefName(_ name: String) -> Bool {
    let trimmed = name.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty, !trimmed.contains(" "), !trimmed.contains(".."), !trimmed.hasPrefix("-"),
          !trimmed.hasSuffix("/"), !trimmed.hasSuffix(".lock") else { return false }
    let invalid = CharacterSet(charactersIn: "~^:?*[\\")
    return trimmed.rangeOfCharacter(from: invalid) == nil
}

struct NewBranchSheet: View {
    let store: RepoStore
    let start: String?
    @State private var name = ""
    @State private var checkout = true

    var body: some View {
        SheetScaffold(title: "New Branch", systemImage: "arrow.triangle.branch", actionTitle: checkout ? "Create & Check Out" : "Create",
                      canSubmit: isValidRefName(name)) {
            store.createBranch(name.trimmingCharacters(in: .whitespaces), at: start, checkout: checkout)
        } content: {
            Form {
                TextField("Name", text: $name, prompt: Text("feature/amazing-thing"))
                LabeledContent("Starting at") {
                    Text(startLabel).font(Theme.mono).foregroundStyle(.secondary)
                }
                Toggle("Check out after creating", isOn: $checkout)
            }
            .formStyle(.columns)
        }
    }

    private var startLabel: String {
        guard let start else { return store.status.branch ?? "HEAD" }
        return start.count == 40 ? String(start.prefix(7)) : start
    }
}

struct RenameBranchSheet: View {
    let store: RepoStore
    let branch: Branch
    @State private var name: String

    init(store: RepoStore, branch: Branch) {
        self.store = store
        self.branch = branch
        _name = State(initialValue: branch.name)
    }

    var body: some View {
        SheetScaffold(title: "Rename “\(branch.name)”", systemImage: "pencil", actionTitle: "Rename",
                      canSubmit: isValidRefName(name) && name != branch.name) {
            store.rename(branch, to: name)
        } content: {
            TextField("New name", text: $name).textFieldStyle(.roundedBorder)
        }
    }
}

struct NewTagSheet: View {
    let store: RepoStore
    let sha: String
    @State private var name = ""
    @State private var message = ""
    @State private var push = false

    var body: some View {
        SheetScaffold(title: "New Tag", systemImage: "tag.fill", tint: .purple, actionTitle: "Create Tag", canSubmit: isValidRefName(name)) {
            store.createTag(name, at: sha, message: message.isEmpty ? nil : message, push: push)
        } content: {
            Form {
                TextField("Name", text: $name, prompt: Text("v1.0.0"))
                TextField("Message", text: $message, prompt: Text("Optional — creates an annotated tag"))
                LabeledContent("Commit") { Text(sha.prefix(7)).font(Theme.mono).foregroundStyle(.secondary) }
                Toggle("Push to \(store.remotes.first?.name ?? "remote")", isOn: $push).disabled(store.remotes.isEmpty)
            }
            .formStyle(.columns)
        }
    }
}

struct StashSheet: View {
    let store: RepoStore
    @State private var message = ""
    @State private var includeUntracked = true

    var body: some View {
        SheetScaffold(title: "Stash Changes", systemImage: "tray.and.arrow.down.fill", tint: .indigo, actionTitle: "Stash", canSubmit: true) {
            store.stash(message: message, includeUntracked: includeUntracked)
        } content: {
            Form {
                TextField("Message", text: $message, prompt: Text("What were you working on?"))
                Toggle("Include untracked files", isOn: $includeUntracked)
                LabeledContent("Changes") { Text("\(store.status.changeCount) files").foregroundStyle(.secondary) }
            }
            .formStyle(.columns)
        }
    }
}

struct AddRemoteSheet: View {
    let store: RepoStore
    @State private var name = "origin"
    @State private var url = ""

    var body: some View {
        SheetScaffold(title: "Add Remote", systemImage: "cloud.fill", actionTitle: "Add", canSubmit: isValidRefName(name) && !url.isEmpty) {
            store.run("Adding remote") { try await store.repository.addRemote(name: name, url: url) }
        } content: {
            Form {
                TextField("Name", text: $name)
                TextField("URL", text: $url, prompt: Text("git@github.com:owner/repo.git"))
            }
            .formStyle(.columns)
        }
    }
}

struct NewWorktreeSheet: View {
    let store: RepoStore
    @State private var claude: Bool
    @State private var base: String
    @Environment(\.dismiss) private var dismiss

    // Native
    @State private var branchMode = BranchMode.new
    @State private var branchName = ""
    @State private var existingBranch = ""
    @State private var path: URL?
    @State private var openAfter = true

    // Claude
    @State private var task = ""
    @State private var agentName = ""
    @State private var nameEdited = false
    @State private var launch = true

    enum BranchMode: String, CaseIterable, Identifiable {
        case new = "New branch", existing = "Existing branch", detached = "Detached"
        var id: String { rawValue }
    }

    init(store: RepoStore, base: String?, claude: Bool) {
        self.store = store
        _claude = State(initialValue: claude)
        _base = State(initialValue: base ?? store.status.branch ?? "HEAD")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                if claude {
                    ClaudeMark(size: 30)
                } else {
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.leaf.gradient))
                }
                Text(claude ? "New Claude Agent" : "New Worktree").font(.title3.weight(.semibold))
                Spacer()
                Picker("", selection: $claude.animation(.snappy)) {
                    Label("Native", systemImage: "square.stack.3d.up").tag(false)
                    Label("Claude", systemImage: "sparkles").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }

            if claude { claudeForm } else { nativeForm }

            HStack {
                Text(footnote).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(claude ? (launch ? "Create & Launch Claude" : "Create Worktree") : "Create Worktree") {
                    submit()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(claude ? Theme.claude : Theme.leaf)
                .disabled(!canSubmit)
            }
        }
        .padding(22)
        .frame(width: 560)
        .onAppear {
            existingBranch = store.localBranches.first { $0.worktreePath == nil }?.name ?? ""
        }
    }

    // MARK: Claude

    private var claudeForm: some View {
        Form {
            VStack(alignment: .leading, spacing: 4) {
                Text("What should Claude do?").font(.callout.weight(.medium))
                TextEditor(text: $task)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(height: 90)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
                    .onChange(of: task) { _, value in
                        if !nameEdited { agentName = String(ClaudeCode.slug(value).prefix(40)).trimmingCharacters(in: CharacterSet(charactersIn: "-")) }
                    }
            }
            TextField("Name", text: Binding(get: { agentName }, set: { agentName = $0; nameEdited = true }), prompt: Text("fix-login-bug"))
            basePicker
            LabeledContent("Branch") {
                Text(Preferences.claudeBranchPrefix + (agentName.isEmpty ? "<name>" : agentName)).font(Theme.mono).foregroundStyle(.secondary)
            }
            LabeledContent("Location") {
                Text(".claude/worktrees/\(agentName.isEmpty ? "<name>" : agentName)").font(Theme.mono).foregroundStyle(.secondary)
            }
            Toggle("Launch Claude Code in \(Preferences.terminal.rawValue) with this task", isOn: $launch)
        }
        .formStyle(.columns)
    }

    // MARK: Native

    private var nativeForm: some View {
        Form {
            Picker("Branch", selection: $branchMode) {
                ForEach(BranchMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            switch branchMode {
            case .new:
                TextField("New branch", text: $branchName, prompt: Text("feature/name"))
                basePicker
            case .existing:
                Picker("Check out", selection: $existingBranch) {
                    ForEach(store.localBranches.filter { $0.worktreePath == nil }) { Text($0.name).tag($0.name) }
                }
            case .detached:
                basePicker
            }
            LabeledContent("Location") {
                HStack {
                    Text(Format.abbreviatePath(resolvedPath.path))
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Spacer()
                    Button("Choose…", action: choosePath)
                }
            }
            Toggle("Open in a new window", isOn: $openAfter)
        }
        .formStyle(.columns)
    }

    private var basePicker: some View {
        Picker("Based on", selection: $base) {
            ForEach(store.localBranches) { Text($0.name).tag($0.name) }
            if !store.remoteBranches.isEmpty {
                Divider()
                ForEach(store.remoteBranches) { Text($0.name).tag($0.name) }
            }
            if !(store.localBranches + store.remoteBranches).contains(where: { $0.name == base }) {
                Divider()
                Text(base.count == 40 ? String(base.prefix(7)) : base).tag(base)
            }
        }
    }

    private var resolvedPath: URL {
        if let path { return path }
        let name = switch branchMode {
        case .new: branchName.isEmpty ? "new-branch" : branchName
        case .existing: existingBranch
        case .detached: String(base.prefix(12))
        }
        return store.suggestedWorktreePath(for: name)
    }

    private var footnote: String {
        claude ? "Same layout Claude Code uses for claude --worktree, so both tools see the same agents."
            : "Each worktree is a separate checkout sharing this repository's history."
    }

    private var canSubmit: Bool {
        if claude {
            return !agentName.isEmpty && isValidRefName(Preferences.claudeBranchPrefix + agentName)
                && !store.worktrees.contains { $0.path.hasSuffix("/.claude/worktrees/\(agentName)") }
        }
        switch branchMode {
        case .new: return isValidRefName(branchName)
        case .existing: return !existingBranch.isEmpty
        case .detached: return !base.isEmpty
        }
    }

    private func choosePath() {
        let panel = NSSavePanel()
        panel.prompt = "Choose"
        panel.nameFieldStringValue = resolvedPath.lastPathComponent
        panel.directoryURL = resolvedPath.deletingLastPathComponent()
        panel.canCreateDirectories = true
        if panel.runModal() == .OK { path = panel.url }
    }

    private func submit() {
        if claude {
            store.createClaudeWorktree(name: agentName, base: base, task: task, launch: launch)
            return
        }
        switch branchMode {
        case .new:
            store.createWorktree(at: resolvedPath, newBranch: branchName, base: base, detach: false, openAfter: openAfter)
        case .existing:
            store.createWorktree(at: resolvedPath, newBranch: nil, base: existingBranch, detach: false, openAfter: openAfter)
        case .detached:
            store.createWorktree(at: resolvedPath, newBranch: nil, base: base, detach: true, openAfter: openAfter)
        }
    }
}
