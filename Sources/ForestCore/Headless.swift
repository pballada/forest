import Foundation

/// Runs Claude Code non-interactively (`claude -p`) for small, tool-free tasks such as writing a
/// commit message or reviewing a diff. Uses the user's own Claude Code login; no API key needed.
public enum ClaudeHeadless {
    public struct Failure: LocalizedError, Sendable {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// - Parameters:
    ///   - prompt: the instruction, passed as the `-p` argument.
    ///   - input: material piped on stdin (a diff, for example).
    ///   - directory: where to run, so the project's CLAUDE.md conventions apply.
    ///   - model: an alias such as `sonnet`, or nil for the CLI default.
    public static func run(prompt: String, input: String, directory: URL, executable: String?, model: String?,
                           timeout: TimeInterval = 120) async throws -> String {
        guard let executable else {
            throw Failure(message: "Claude Code isn't installed. Install it from claude.com/claude-code, or set its path in Settings → Claude Code.")
        }
        var arguments = ["-p", prompt, "--output-format", "text", "--tools", "", "--no-session-persistence"]
        if let model, !model.isEmpty { arguments += ["--model", model] }
        let result = try await ProcessRunner.run(executable: executable, arguments: arguments, input: Data(input.utf8),
                                                 directory: directory, timeout: timeout)
        let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.exitCode == 0, !output.isEmpty else {
            let detail = result.error.trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure(message: detail.isEmpty ? (output.isEmpty ? "Claude returned nothing." : output) : detail)
        }
        return output
    }

    public static let commitMessagePrompt = """
    Write a git commit message for the staged changes provided on stdin.
    Follow the conventions visible in the repository (CLAUDE.md, recent history) if any.
    Format: a summary line in the imperative mood under 72 characters, then a blank line, then a short body \
    explaining what changed and why, wrapped at 72 columns. Omit the body for trivial changes.
    Reply with the commit message only: no preamble, no code fences, no quotes.
    """

    public static let explainCommitPrompt = """
    Explain the commit provided on stdin to a teammate who is about to review it.
    Start with one sentence on what it does, then a few short bullet points on the notable changes \
    and anything risky or worth testing. Be concise. Plain text with "-" bullets, no headings.
    """

    public static let reviewPrompt = """
    You are reviewing work an AI coding agent did on a branch; the diff against its base is on stdin.
    Give a short code review: first a one-line verdict (ready to merge, needs changes, or risky), \
    then bullet points for concrete problems (bugs, missing tests, leftover debug code, unrelated changes), \
    citing file names. Skip praise. Plain text with "-" bullets, no headings.
    """

    /// Splits a model-written commit message into summary and description.
    public static func splitCommitMessage(_ text: String) -> (summary: String, body: String) {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("```") {
            cleaned = cleaned.split(separator: "\n", omittingEmptySubsequences: false).dropFirst()
                .filter { !$0.hasPrefix("```") }.joined(separator: "\n")
        }
        let lines = cleaned.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let summary = (lines.first.map(String.init) ?? "").trimmingCharacters(in: CharacterSet(charactersIn: " \"'`"))
        let body = lines.count > 1 ? lines[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        return (summary, body)
    }
}

/// Minimal async process runner for non-git tools (`claude`, `gh`).
public enum ProcessRunner {
    public struct Result: Sendable {
        public let output: String
        public let error: String
        public let exitCode: Int32
    }

    public static func run(executable: String, arguments: [String], input: Data? = nil, directory: URL,
                           timeout: TimeInterval = 60) async throws -> Result {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.currentDirectoryURL = directory
                process.environment = GitRunner.baseEnvironment
                let out = Pipe(), err = Pipe(), inPipe = Pipe()
                process.standardOutput = out
                process.standardError = err
                process.standardInput = input == nil ? FileHandle.nullDevice : inPipe
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                if let input {
                    DispatchQueue.global().async {
                        inPipe.fileHandleForWriting.write(input)
                        try? inPipe.fileHandleForWriting.close()
                    }
                }
                let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
                let errorBox = Box()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    errorBox.data = err.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                let data = out.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                process.waitUntilExit()
                timer.cancel()
                continuation.resume(returning: Result(output: String(decoding: data, as: UTF8.self),
                                                      error: String(decoding: errorBox.data, as: UTF8.self),
                                                      exitCode: process.terminationStatus))
            }
        }
    }

    private final class Box: @unchecked Sendable { var data = Data() }
}
