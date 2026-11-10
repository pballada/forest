import AppKit
import ForestCore
import Observation

/// Keeps Forest up to date from GitHub Releases, automatically: it checks at launch and every few hours,
/// downloads a newer notarized zip in the background, checks it is signed by the same Developer ID team,
/// and swaps it in when Forest quits. "Restart to Update" applies it right away.
@MainActor
@Observable
final class Updater {
    static let shared = Updater()

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(AppRelease)
        case downloading(AppRelease, progress: Double)
        case installing(AppRelease)
        /// Downloaded and verified; installed when Forest quits (or now, with Restart).
        case ready(AppRelease, app: URL)
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var lastChecked: Date? = UserDefaults.standard.object(forKey: SettingsKey.updateLastCheck) as? Date

    /// Only a release signed by this team, with this bundle identifier, is ever installed.
    private static let teamID = "5UXXXESGMK"
    private static let requirement = "anchor apple generic and identifier \"com.pballada.forest\" and certificate leaf[subject.OU] = \"\(teamID)\""
    private static let interval: TimeInterval = 6 * 60 * 60

    private var timer: Task<Void, Never>?
    private var progressObservation: NSKeyValueObservation?

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Running from a real Forest.app (not `swift run`), so it can be replaced.
    static var isBundled: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    var automaticChecks: Bool {
        get { UserDefaults.standard.object(forKey: SettingsKey.updateAutomatically) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: SettingsKey.updateAutomatically)
            if newValue { startAutomaticChecks() } else { timer?.cancel() }
        }
    }

    func startAutomaticChecks() {
        guard Self.isBundled, automaticChecks else { return }
        timer?.cancel()
        timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            while !Task.isCancelled {
                guard let self else { return }
                let due = self.lastChecked.map { Date().timeIntervalSince($0) >= Self.interval } ?? true
                if due { await self.check(userInitiated: false) }
                try? await Task.sleep(for: .seconds(60 * 60))
            }
        }
    }

    func check(userInitiated: Bool) async {
        switch state {
        case .checking, .downloading, .installing, .ready: return
        default: break
        }
        state = .checking
        do {
            var request = URLRequest(url: UpdateFeed.latestRelease, timeoutInterval: 20)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200, let release = UpdateFeed.parse(data) else {
                throw UpdateError("Couldn't read the latest release from GitHub.")
            }
            lastChecked = Date()
            UserDefaults.standard.set(lastChecked, forKey: SettingsKey.updateLastCheck)
            let skipped = UserDefaults.standard.string(forKey: SettingsKey.updateSkippedVersion)
            if UpdateFeed.isNewer(release.version, than: Self.currentVersion), userInitiated || release.version != skipped {
                if automaticChecks && Self.canReplaceItself {
                    // Fetch and verify quietly; it's installed when Forest quits.
                    await prepare(release)
                } else {
                    state = .available(release)
                    if !userInitiated { WindowOpener.openWindow?(id: "update") }
                }
            } else {
                state = userInitiated ? .upToDate : .idle
            }
        } catch {
            state = userInitiated ? .failed(error.localizedDescription) : .idle
        }
    }

    func skip(_ release: AppRelease) {
        UserDefaults.standard.set(release.version, forKey: SettingsKey.updateSkippedVersion)
        state = .idle
    }

    func dismiss() {
        switch state {
        case .downloading, .installing, .ready: return
        default: state = .idle
        }
    }

    static var canReplaceItself: Bool {
        isBundled && FileManager.default.isWritableFile(atPath: Bundle.main.bundleURL.deletingLastPathComponent().path)
    }

    /// The downloaded, verified update, if one is waiting.
    var readyRelease: AppRelease? {
        if case .ready(let release, _) = state { return release }
        return nil
    }

    /// Downloads and verifies now, then relaunches into the new version.
    func install(_ release: AppRelease) async {
        guard Self.isBundled else {
            NSWorkspace.shared.open(release.page)
            return
        }
        guard Self.canReplaceItself else {
            state = .failed("Forest can't replace itself in \(Bundle.main.bundleURL.deletingLastPathComponent().path). Download the update from GitHub instead.")
            return
        }
        await prepare(release)
        restartToUpdate()
    }

    /// Swaps in the waiting update and opens the new version.
    func restartToUpdate() {
        guard case .ready(_, let app) = state else { return }
        try? swap(in: app, reopen: true)
        NSApp.terminate(nil)
    }

    /// Called as Forest quits: a waiting update replaces the app once this process has exited.
    func installOnQuit() {
        guard case .ready(_, let app) = state else { return }
        try? swap(in: app, reopen: false)
    }

    /// Downloads the release and checks its signature, notarization and version.
    private func prepare(_ release: AppRelease) async {
        state = .downloading(release, progress: 0)
        do {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ForestUpdate-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let zip = folder.appendingPathComponent("Forest.zip")
            try await download(release.archive, to: zip, release: release)

            state = .installing(release)
            let extracted = folder.appendingPathComponent("extracted")
            try await run("/usr/bin/ditto", ["-x", "-k", zip.path, extracted.path], failure: "The download couldn't be unpacked.")
            let app = extracted.appendingPathComponent("Forest.app")
            guard FileManager.default.fileExists(atPath: app.path) else { throw UpdateError("The download doesn't contain Forest.app.") }
            try await run("/usr/bin/codesign", ["--verify", "--deep", "--strict", "-R=\(Self.requirement)", app.path],
                          failure: "The update isn't signed by Forest's developer, so it wasn't installed.")
            try await run("/usr/sbin/spctl", ["--assess", "--type", "execute", app.path],
                          failure: "macOS didn't accept the update's notarization, so it wasn't installed.")
            let version = Bundle(url: app)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            guard version == release.version else { throw UpdateError("The download is version \(version ?? "?"), not \(release.version).") }
            state = .ready(release, app: app)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func download(_ url: URL, to destination: URL, release: AppRelease) async throws {
        let (location, response): (URL, URLResponse) = try await withCheckedThrowingContinuation { continuation in
            let task = URLSession.shared.downloadTask(with: url) { location, response, error in
                if let location, let response {
                    // The file is deleted when this handler returns, so move it now.
                    let kept = destination.deletingLastPathComponent().appendingPathComponent("download.tmp")
                    do {
                        try FileManager.default.moveItem(at: location, to: kept)
                        continuation.resume(returning: (kept, response))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                } else {
                    continuation.resume(throwing: error ?? UpdateError("The download failed."))
                }
            }
            progressObservation = task.progress.observe(\.fractionCompleted) { progress, _ in
                let fraction = progress.fractionCompleted
                Task { @MainActor in
                    if case .downloading = self.state { self.state = .downloading(release, progress: fraction) }
                }
            }
            task.resume()
        }
        progressObservation = nil
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError("GitHub refused the download.") }
        try FileManager.default.moveItem(at: location, to: destination)
    }

    private func run(_ executable: String, _ arguments: [String], failure: String) async throws {
        let result = try await ProcessRunner.run(executable: executable, arguments: arguments,
                                                 directory: FileManager.default.temporaryDirectory, timeout: 120)
        guard result.exitCode == 0 else { throw UpdateError(failure) }
    }

    /// Hands over to a small shell script that waits for Forest to quit, swaps the bundles and, with `reopen`,
    /// opens the new version. If the swap fails, the old app is put back.
    private func swap(in app: URL, reopen: Bool) throws {
        let script = """
        while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
        backup="$2.previous-$$"
        if mv "$2" "$backup"; then
          if mv "$3" "$2"; then rm -rf "$backup"; else mv "$backup" "$2"; fi
        fi
        if [ "$4" = 1 ]; then open "$2"; fi
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "forest-update", String(ProcessInfo.processInfo.processIdentifier),
                             Bundle.main.bundleURL.path, app.path, reopen ? "1" : "0"]
        try process.run()
    }
}

struct UpdateError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
