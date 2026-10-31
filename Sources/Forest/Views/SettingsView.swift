import ForestCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            IntegrationSettings()
                .tabItem { Label("Integrations", systemImage: "puzzlepiece.extension") }
            ClaudeSettings()
                .tabItem { Label("Claude Code", systemImage: "sparkles") }
        }
        .frame(width: 520)
        .padding(20)
    }
}

private struct GeneralSettings: View {
    @AppStorage(SettingsKey.pullStrategy) private var pull = PullStrategy.fastForwardOnly.rawValue
    @AppStorage(SettingsKey.historyLimit) private var historyLimit = 3000
    @AppStorage(SettingsKey.worktreeLocation) private var worktreeLocation = "sibling"
    @AppStorage(SettingsKey.celebrate) private var celebrate = true

    var body: some View {
        Form {
            Toggle("Celebrate commits with a little leaf burst", isOn: $celebrate)
            Picker("Pull strategy", selection: $pull) {
                ForEach(PullStrategy.allCases) { Text($0.title).tag($0.rawValue) }
            }
            Picker("Commits loaded at once", selection: $historyLimit) {
                ForEach([1000, 3000, 10000, 30000], id: \.self) { Text("\($0)").tag($0) }
            }
            Picker("New worktree location", selection: $worktreeLocation) {
                Text("Next to the repository (../repo-branch)").tag("sibling")
                Text("Inside the repository (.worktrees/branch)").tag("nested")
            }
            LabeledContent("Git") {
                Text(GitRunner.defaultExecutable.path).font(Theme.mono).foregroundStyle(.secondary)
            }
        }
    }
}

private struct IntegrationSettings: View {
    @AppStorage(SettingsKey.terminal) private var terminal = TerminalApp.terminal.rawValue
    @AppStorage(SettingsKey.editor) private var editor = EditorApp.vscode.rawValue
    @AppStorage(SettingsKey.pullRequests) private var pullRequests = true

    var body: some View {
        Form {
            Picker("Terminal", selection: $terminal) {
                ForEach(TerminalApp.allCases) { Text($0.rawValue).tag($0.rawValue) }
            }
            Picker("Editor", selection: $editor) {
                ForEach(EditorApp.allCases) { Text($0.rawValue).tag($0.rawValue) }
            }
            Toggle("Show pull requests and CI status (needs the GitHub CLI, gh)", isOn: $pullRequests)
            Text("Terminal and iTerm run commands via AppleScript; macOS asks for permission the first time.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct ClaudeSettings: View {
    @AppStorage(SettingsKey.claudePath) private var claudePath = ""
    @AppStorage(SettingsKey.claudeArguments) private var arguments = ""
    @AppStorage(SettingsKey.claudeBranchPrefix) private var prefix = ClaudeCode.defaultBranchPrefix
    @AppStorage(SettingsKey.aiFeatures) private var aiFeatures = true
    @AppStorage(SettingsKey.claudeModel) private var model = ""

    var body: some View {
        Form {
            Toggle("Claude helpers: commit messages, commit explanations, agent reviews", isOn: $aiFeatures)
            Picker("Model for helpers", selection: $model) {
                Text("Claude Code default").tag("")
                Text("Haiku (fastest)").tag("haiku")
                Text("Sonnet").tag("sonnet")
                Text("Opus").tag("opus")
            }
            .disabled(!aiFeatures)
            Text("Helpers run `claude -p` with tools disabled and no saved session, using your Claude Code login. Diffs are sent to Claude; lockfiles and very large files are left out.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            TextField("claude executable", text: $claudePath, prompt: Text(ClaudeCode.locateCLI() ?? "claude"))
            LabeledContent("Detected") {
                if let path = ClaudeCode.locateCLI(override: claudePath.isEmpty ? nil : claudePath) {
                    Label(path, systemImage: "checkmark.circle.fill").foregroundStyle(Theme.leaf)
                } else {
                    Label("Not found — install Claude Code or set the path", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
            TextField("Extra arguments", text: $arguments, prompt: Text("e.g. --model opus --permission-mode acceptEdits"))
            TextField("Agent branch prefix", text: $prefix)
            Text("Agent worktrees live in .claude/worktrees/<name> on branch \(prefix)<name>, the same layout `claude --worktree` uses. Forest reads session transcripts from ~/.claude/projects to show what each agent is doing.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
