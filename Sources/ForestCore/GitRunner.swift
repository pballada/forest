import Foundation

/// A failed git invocation, carrying git's own stderr so the UI can show something meaningful.
public struct GitError: LocalizedError, Sendable {
    public let arguments: [String]
    public let exitCode: Int32
    public let stderr: String

    public var errorDescription: String? {
        let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if message.isEmpty {
            return "git \(arguments.first ?? "") failed with exit code \(exitCode)"
        }
        return message
    }
}

public struct GitResult: Sendable {
    public let stdout: Data
    public let stderr: String
    public let exitCode: Int32

    public var output: String { String(decoding: stdout, as: UTF8.self) }
    public var trimmed: String { output.trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// Runs the system `git` binary. Every operation in Forest goes through here, so the app
/// behaves exactly like the user's command line (hooks, config, credential helpers, LFS).
public struct GitRunner: Sendable, Hashable {
    public let directory: URL
    public let executable: URL

    public init(directory: URL, executable: URL = GitRunner.defaultExecutable) {
        self.directory = directory
        self.executable = executable
    }

    public static let defaultExecutable: URL = {
        let candidates = ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/usr/bin/git"]
        let path = candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/bin/git"
        return URL(fileURLWithPath: path)
    }()

    /// GUI apps get a minimal PATH from launchd; hooks (husky, lint-staged, git-lfs) need the usual tools.
    static let baseEnvironment: [String: String] = {
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let extra = ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "\(home)/.local/bin",
                     "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var path = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        for dir in extra where !path.contains(dir) { path.append(dir) }
        env["PATH"] = path.joined(separator: ":")
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_EDITOR"] = "true"
        env["LANG"] = "en_US.UTF-8"
        env["LC_ALL"] = "en_US.UTF-8"
        return env
    }()

    @discardableResult
    public func run(
        _ arguments: [String],
        input: Data? = nil,
        allowedExitCodes: Set<Int32> = [0],
        environment: [String: String] = [:]
    ) async throws -> GitResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try runSync(arguments, input: input, allowedExitCodes: allowedExitCodes, environment: environment)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    @discardableResult
    public func runSync(
        _ arguments: [String],
        input: Data? = nil,
        allowedExitCodes: Set<Int32> = [0],
        environment: [String: String] = [:]
    ) throws -> GitResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["-c", "color.ui=false", "-c", "core.quotepath=false", "-c", "advice.detachedHead=false"] + arguments
        process.currentDirectoryURL = directory
        process.environment = Self.baseEnvironment.merging(environment) { $1 }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let stdinPipe = input.map { _ in Pipe() }
        process.standardInput = stdinPipe ?? FileHandle.nullDevice

        try process.run()

        if let stdinPipe, let input {
            DispatchQueue.global().async {
                stdinPipe.fileHandleForWriting.write(input)
                try? stdinPipe.fileHandleForWriting.close()
            }
        }

        // Drain stderr concurrently so a chatty command can never deadlock on a full pipe.
        let stderrBox = DataBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            stderrBox.data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let stdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()

        let stderr = String(decoding: stderrBox.data, as: UTF8.self)
        let status = process.terminationStatus
        guard allowedExitCodes.contains(status) else {
            throw GitError(arguments: arguments, exitCode: status, stderr: stderr)
        }
        return GitResult(stdout: stdout, stderr: stderr, exitCode: status)
    }
}

private final class DataBox: @unchecked Sendable {
    var data = Data()
}
