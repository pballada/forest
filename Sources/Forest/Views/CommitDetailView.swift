import ForestCore
import SwiftUI

struct CommitDetailView: View {
    @Bindable var store: RepoStore

    var body: some View {
        if let commit = store.selectedCommit {
            HSplitView {
                VStack(spacing: 0) {
                    CommitHeader(store: store, commit: commit, body: store.commitBody)
                    Divider()
                    CommitFileList(store: store)
                }
                .frame(minWidth: 280, idealWidth: 380, maxWidth: 560)
                DiffView(diff: store.commitDiff, mode: .readOnly, store: store)
                    .frame(minWidth: 360)
            }
        } else {
            EmptyState(title: "No commit selected", systemImage: "point.3.connected.trianglepath.dotted")
        }
    }
}

struct CommitHeader: View {
    let store: RepoStore
    let commit: Commit
    let body_: String

    init(store: RepoStore, commit: Commit, body: String) {
        self.store = store
        self.commit = commit
        self.body_ = body
    }

    var body: some View {
        let parts = body_.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let description = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        VStack(alignment: .leading, spacing: 10) {
            Text(commit.subject)
                .font(.system(size: 14.5, weight: .semibold))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if !description.isEmpty {
                ScrollView {
                    Text(description)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 110)
                .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Avatar(name: commit.authorName, email: commit.authorEmail, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(commit.authorName).font(.system(size: 12, weight: .medium))
                    Text("\(Format.absolute.string(from: commit.authorDate)) · \(Format.ago(commit.authorDate))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            HStack(spacing: 6) {
                ShaChip(sha: commit.sha, label: commit.shortSHA, icon: "number")
                ForEach(commit.parents, id: \.self) { parent in
                    Button {
                        store.jump(to: parent)
                    } label: {
                        ShaChip(sha: parent, label: String(parent.prefix(7)), icon: "arrow.turn.left.up", copies: false)
                    }
                    .buttonStyle(.plain)
                    .help("Go to parent \(parent.prefix(7))")
                }
                Spacer()
                if commit.committerName != commit.authorName {
                    Text("committed by \(commit.committerName)").font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(14)
    }
}

private struct ShaChip: View {
    let sha: String
    let label: String
    let icon: String
    var copies = true

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 9, weight: .bold))
            Text(label).font(Theme.monoSmall)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.primary.opacity(0.07)))
        .onTapGesture { if copies { copy(sha) } }
        .help(copies ? "Click to copy \(sha)" : sha)
    }
}

struct CommitFileList: View {
    @Bindable var store: RepoStore

    var body: some View {
        let files = store.commitFiles
        VStack(spacing: 0) {
            SectionHeader(title: "Files", count: files.count) {
                let adds = files.compactMap(\.additions).reduce(0, +)
                let dels = files.compactMap(\.deletions).reduce(0, +)
                HStack(spacing: 6) {
                    Text("+\(adds)").foregroundStyle(Theme.added)
                    Text("−\(dels)").foregroundStyle(Theme.removed)
                }
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
            }
            List(selection: Binding(get: { store.selectedCommitFile?.id }, set: { id in
                Task { await store.selectCommitFile(files.first { $0.id == id }) }
            })) {
                ForEach(files) { file in
                    HStack(spacing: 7) {
                        StatusIcon(status: file.status)
                        FilePathLabel(change: file)
                        Spacer(minLength: 4)
                        if let additions = file.additions, let deletions = file.deletions {
                            DiffStatBar(additions: additions, deletions: deletions)
                        }
                    }
                    .tag(file.id)
                    .contextMenu {
                        Button("Copy Path") { copy(file.path) }
                        Button("Open File") { Launcher.openInEditor(store.repository.root.appendingPathComponent(file.path)) }
                        Button("Reveal in Finder") { Launcher.revealInFinder(store.repository.root.appendingPathComponent(file.path)) }
                    }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        }
    }
}

/// GitHub-style five-block bar showing the ratio of additions to deletions.
struct DiffStatBar: View {
    let additions: Int
    let deletions: Int

    var body: some View {
        let total = max(additions + deletions, 1)
        let green = Int((Double(additions) / Double(total) * 5).rounded())
        HStack(spacing: 4) {
            Text("\(additions + deletions)")
                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            HStack(spacing: 1.5) {
                ForEach(0..<5, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(index < green ? Theme.added : (index < 5 && additions + deletions > 0 ? Theme.removed : Color.secondary.opacity(0.3)))
                        .frame(width: 6, height: 6)
                }
            }
        }
        .help("+\(additions) −\(deletions)")
    }
}

struct StashDetailView: View {
    let store: RepoStore
    let sha: String

    var body: some View {
        VStack(spacing: 0) {
            if let stash = store.stashes.first(where: { $0.sha == sha }) {
                HStack {
                    Image(systemName: "tray.full.fill").foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading) {
                        Text(stash.message).font(.headline)
                        Text("\(stash.ref) · \(Format.ago(stash.date))").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Drop…", role: .destructive) { store.drop(stash) }
                    Button("Apply") { store.apply(stash, pop: false) }
                    Button("Pop") { store.apply(stash, pop: true) }.buttonStyle(.borderedProminent)
                }
                .padding(14)
                Divider()
                HSplitView {
                    CommitFileList(store: store).frame(minWidth: 260, idealWidth: 340)
                    DiffView(diff: store.commitDiff, mode: .readOnly, store: store).frame(minWidth: 360)
                }
            } else {
                EmptyState(title: "Stash not found", systemImage: "tray")
            }
        }
        .task(id: sha) { await store.selectCommit(sha) }
    }
}
