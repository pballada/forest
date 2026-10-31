import AppKit
import ForestCore

/// Hands work off to other apps: terminals, editors, Finder and Claude Code.
enum Launcher {
    static func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    static func openInEditor(_ url: URL, editor: EditorApp = Preferences.editor) {
        let configuration = NSWorkspace.OpenConfiguration()
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID(editor)) {
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: configuration)
        } else {
            run("/usr/bin/open", ["-a", editor.rawValue, url.path])
        }
    }

    static func openURL(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    /// Opens a terminal at `directory`, optionally running `command` there.
    static func openTerminal(at directory: URL, command: String? = nil, app: TerminalApp = Preferences.terminal) {
        let cd = "cd \(shellQuote(directory.path))"
        let line = command.map { "\(cd) && \($0)" } ?? cd
        switch app {
        case .terminal:
            appleScript("""
            tell application "Terminal"
                activate
                do script "\(appleScriptEscape(line))"
            end tell
            """)
        case .iTerm:
            appleScript("""
            tell application "iTerm"
                activate
                set newWindow to (create window with default profile)
                tell current session of newWindow to write text "\(appleScriptEscape(line))"
            end tell
            """)
        case .ghostty:
            var args = ["-na", "Ghostty", "--args", "--working-directory=\(directory.path)"]
            if let command { args += ["-e", "/bin/zsh", "-lc", command] }
            run("/usr/bin/open", args)
        case .warp:
            run("/usr/bin/open", ["-a", "Warp", directory.path])
        }
    }

    /// Starts an interactive Claude Code session in `directory`, optionally seeded with a prompt.
    static func launchClaude(in directory: URL, prompt: String? = nil) {
        let executable = ClaudeCode.locateCLI(override: Preferences.claudePath) ?? "claude"
        var command = shellQuote(executable)
        let extra = Preferences.claudeArguments.trimmingCharacters(in: .whitespaces)
        if !extra.isEmpty { command += " " + extra }
        if let prompt, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            command += " " + shellQuote(prompt)
        }
        openTerminal(at: directory, command: command)
    }

    static func shellQuote(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func appleScriptEscape(_ string: String) -> String {
        string.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func bundleID(_ editor: EditorApp) -> String {
        switch editor {
        case .vscode: "com.microsoft.VSCode"
        case .cursor: "com.todesktop.230313mzl4w4u92"
        case .zed: "dev.zed.Zed"
        case .xcode: "com.apple.dt.Xcode"
        case .sublime: "com.sublimetext.4"
        case .nova: "com.panic.Nova"
        }
    }

    private static func appleScript(_ source: String) {
        run("/usr/bin/osascript", ["-e", source])
    }

    private static func run(_ path: String, _ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        try? process.run()
    }
}
