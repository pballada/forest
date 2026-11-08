import ForestCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            AppearanceSettings()
                .tabItem { Label("Themes", systemImage: "paintpalette") }
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
            UpdateSettings()
            LabeledContent("Git") {
                Text(GitRunner.defaultExecutable.path).font(Theme.mono).foregroundStyle(.secondary)
            }
        }
    }
}

struct AppearanceSettings: View {
    @AppStorage(SettingsKey.codeTheme) private var themeID = CodeTheme.defaultID

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Colours for diffs and code. Fixed themes keep their own light or dark look; Forest follows the system.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                ForEach(CodeTheme.all) { theme in
                    ThemeCard(theme: theme, selected: theme.id == themeID)
                        .onTapGesture { themeID = theme.id }
                }
            }
        }
    }
}

/// A miniature diff drawn in a theme's colours.
private struct ThemeCard: View {
    let theme: CodeTheme
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 0) {
                line(" ", [("func ", theme.keyword), ("grow", theme.text), ("() {", theme.text)], background: nil)
                line("−", [("  let ", theme.keyword), ("h = ", theme.text), ("1", theme.number)], background: theme.removedBackground, marker: theme.removedText)
                line("+", [("  let ", theme.keyword), ("h = ", theme.text), ("\"tall\"", theme.string)], background: theme.addedBackground, marker: theme.addedText)
                line(" ", [("  // ", theme.comment), ("leaves", theme.comment)], background: nil)
            }
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: theme.background))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(selected ? Theme.leaf : Color.primary.opacity(0.12), lineWidth: selected ? 2.5 : 1)
            )
            .themedColorScheme(theme)
            HStack(spacing: 4) {
                if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.leaf) }
                Text(theme.name).font(.caption.weight(selected ? .semibold : .regular)).lineLimit(1)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private func line(_ sign: String, _ parts: [(String, NSColor)], background: NSColor?, marker: NSColor? = nil) -> some View {
        HStack(spacing: 0) {
            Text(sign).foregroundStyle(Color(nsColor: marker ?? theme.gutterText)).frame(width: 14)
            parts.reduce(Text("")) { $0 + Text($1.0).foregroundColor(Color(nsColor: $1.1)) }
            Spacer(minLength: 0)
        }
        .font(.system(size: 10, design: .monospaced))
        .lineLimit(1)
        .padding(.vertical, 1.5)
        .background(background.map { Color(nsColor: $0) } ?? .clear)
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

private struct UpdateSettings: View {
    @Environment(\.openWindow) private var openWindow
    @State private var updater = Updater.shared

    var body: some View {
        Toggle("Check for updates automatically", isOn: $updater.automaticChecks)
        LabeledContent("Version \(Updater.currentVersion)") {
            HStack {
                if let checked = updater.lastChecked {
                    Text("Checked \(Format.ago(checked))").foregroundStyle(.secondary)
                }
                Button("Check Now") {
                    openWindow(id: "update")
                    Task { await updater.check(userInitiated: true) }
                }
            }
        }
    }
}
