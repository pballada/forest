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

/// Starts a Claude Code agent in its own worktree under `.claude/worktrees/<name>`.
struct NewAgentSheet: View {
    let store: RepoStore
    @State private var base: String
    @Environment(\.dismiss) private var dismiss

    @State private var task = ""
    @State private var agentName = ""
    @State private var nameEdited = false
    @State private var launch = true
    @State private var tool = Preferences.agentTool

    init(store: RepoStore, base: String?) {
        self.store = store
        _base = State(initialValue: base ?? store.mainWorktree?.branch ?? store.status.branch ?? "HEAD")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                ClaudeMark(size: 30)
                Text("New Agent").font(.title3.weight(.semibold))
                Spacer()
                Picker("", selection: $tool) {
                    ForEach(AgentTool.allCases) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            Form {
                VStack(alignment: .leading, spacing: 4) {
                    Text("What should \(tool == .claude ? "Claude" : tool.name) do?").font(.callout.weight(.medium))
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
                Toggle("Start \(tool.name) now with this task", isOn: $launch)
            }
            .formStyle(.columns)

            HStack {
                Text("Same layout Claude Code uses for claude --worktree; any agent CLI can work in it.")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(launch ? "Create & Start" : "Create Worktree") {
                    store.createClaudeWorktree(name: agentName, base: base, task: task, launch: launch, tool: tool)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(Theme.claude)
                .disabled(!canSubmit)
            }
        }
        .padding(22)
        .frame(width: 560)
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

    private var canSubmit: Bool {
        !agentName.isEmpty && isValidRefName(Preferences.claudeBranchPrefix + agentName)
            && !store.worktrees.contains { $0.path.hasSuffix("/.claude/worktrees/\(agentName)") }
    }
}
