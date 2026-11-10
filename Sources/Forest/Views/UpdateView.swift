import ForestCore
import SwiftUI

/// The Software Update window: what's new, and a one-click install that relaunches Forest.
struct UpdateView: View {
    @Environment(\.dismissWindow) private var dismissWindow
    private let updater = Updater.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                AppGlyph(size: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.title2.weight(.semibold))
                    Text(subtitle).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            if let release {
                ScrollView {
                    ReleaseNotes(markdown: release.notes)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                }
                .frame(height: 240)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
            }
            footer
        }
        .padding(22)
        .frame(width: 520)
        .task {
            if case .idle = updater.state { await updater.check(userInitiated: true) }
        }
    }

    private var release: AppRelease? {
        switch updater.state {
        case .available(let release), .downloading(let release, _), .installing(let release), .ready(let release, _): release
        default: nil
        }
    }

    private var title: String {
        switch updater.state {
        case .idle, .checking: "Checking for updates…"
        case .upToDate: "Forest is up to date"
        case .available(let release), .downloading(let release, _), .installing(let release), .ready(let release, _):
            "Forest \(release.version) is here 🌲"
        case .failed: "Couldn't update"
        }
    }

    private var subtitle: String {
        switch updater.state {
        case .idle, .checking: "Looking at the latest release on GitHub."
        case .upToDate: "You have the latest version, \(Updater.currentVersion)."
        case .available: "You have \(Updater.currentVersion). The update is signed and notarized, and Forest relaunches when it's done."
        case .downloading: "Downloading…"
        case .installing: "Checking the signature…"
        case .ready: "It's downloaded and verified, and installs itself when you quit Forest. Restart now to use it right away; your agents' sessions can be continued afterwards."
        case .failed(let message): message
        }
    }

    @ViewBuilder private var footer: some View {
        HStack {
            switch updater.state {
            case .checking, .idle:
                ProgressView().controlSize(.small)
                Spacer()
            case .available(let release):
                Button("Skip This Version") { updater.skip(release); dismissWindow() }
                Spacer()
                Button("Later") { updater.dismiss(); dismissWindow() }
                    .keyboardShortcut(.cancelAction)
                Button("Install and Relaunch") { Task { await updater.install(release) } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            case .downloading(_, let progress):
                ProgressView(value: progress).tint(Theme.leaf)
            case .installing:
                ProgressView().progressViewStyle(.linear).tint(Theme.leaf)
            case .ready:
                Spacer()
                Button("Later") { dismissWindow() }
                    .keyboardShortcut(.cancelAction)
                Button("Restart to Update") { updater.restartToUpdate() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            case .upToDate, .failed:
                if case .failed = updater.state {
                    Link("Open the releases page", destination: URL(string: "https://github.com/pballada/forest/releases/latest")!)
                }
                Spacer()
                Button("OK") { updater.dismiss(); dismissWindow() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

/// Renders the small subset of Markdown used in release notes: headings, bullets and inline styles.
private struct ReleaseNotes: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                if line.hasPrefix("#") {
                    inline(line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces))
                        .font(.headline)
                        .padding(.top, 6)
                } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "leaf.fill").font(.caption2).foregroundStyle(Theme.leaf)
                        inline(String(line.dropFirst(2)))
                    }
                } else {
                    inline(line)
                }
            }
        }
        .textSelection(.enabled)
    }

    private var lines: [String] {
        markdown.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("![") }
    }

    private func inline(_ text: String) -> Text {
        Text((try? AttributedString(markdown: text)) ?? AttributedString(text))
    }
}
