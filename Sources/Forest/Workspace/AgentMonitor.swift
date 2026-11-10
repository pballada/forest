import AppKit
import ForestCore
import UserNotifications

/// Watches every agent's state and tells you when one needs you or finishes: a sound, an optional
/// notification, the Dock badge and a bounce. Sounds and notifications are set in Settings › Agents.
@MainActor
final class AgentMonitor {
    static let shared = AgentMonitor()

    private var last: [String: AgentState] = [:]
    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
            MainActor.assumeIsolated { AgentMonitor.shared.tick() }
        }
    }

    private func tick() {
        let workspace = WorkspaceStore.shared
        var current: [String: AgentState] = [:]
        for project in workspace.projects {
            for worktree in project.worktrees {
                let state = project.state(for: worktree.path)
                current[worktree.path] = state
                guard let previous = last[worktree.path], previous != state else { continue }
                let name = worktree.isMain ? project.name : worktree.name
                if state == .needsInput {
                    let detail = project.terminal(for: worktree.path)?.lastNotification
                    alert(.needsInput, title: "\(name) needs you", body: detail ?? "The agent is waiting for your answer.")
                } else if previous == .working, state == .idle || state == .dormant {
                    let title = project.currentSession(for: worktree.path)?.displayTitle
                    alert(.finished, title: "\(name) finished", body: title ?? "The agent finished its turn.")
                }
            }
        }
        last = current
        workspace.updateDockBadge()
    }

    enum Event { case needsInput, finished }

    private func alert(_ event: Event, title: String, body: String) {
        let quietWhenActive = AlertPreferences.onlyInBackground && NSApp.isActive
        let sound = event == .needsInput ? AlertPreferences.needsInputSound : AlertPreferences.finishedSound
        if !quietWhenActive { AlertPreferences.play(sound) }
        if event == .needsInput, !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
        if AlertPreferences.notifications, !NSApp.isActive, Bundle.main.bundleIdentifier != nil {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}

/// How Forest gets your attention.
enum AlertPreferences {
    /// macOS system sounds in /System/Library/Sounds, plus "None".
    static let sounds = ["None", "Glass", "Ping", "Tink", "Pop", "Purr", "Hero", "Submarine", "Funk", "Bottle", "Morse", "Frog", "Blow", "Basso", "Sosumi"]

    static var needsInputSound: String { UserDefaults.standard.string(forKey: SettingsKey.soundNeedsInput) ?? "Glass" }
    static var finishedSound: String { UserDefaults.standard.string(forKey: SettingsKey.soundFinished) ?? "None" }
    static var onlyInBackground: Bool { UserDefaults.standard.bool(forKey: SettingsKey.soundOnlyInBackground) }
    static var notifications: Bool { UserDefaults.standard.bool(forKey: SettingsKey.agentNotifications) }

    static func play(_ name: String) {
        guard name != "None", let sound = NSSound(named: NSSound.Name(name)) else { return }
        sound.stop()
        sound.play()
    }

    /// Asks macOS for permission the first time notifications are turned on.
    static func requestNotificationPermission() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
}
