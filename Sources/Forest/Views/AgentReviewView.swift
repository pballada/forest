import ForestCore
import SwiftUI

/// Everything an agent (or any worktree) changed relative to its base, in one place:
/// commits, files, diffs, a Claude review, and a way to send the agent feedback.
@Observable @MainActor
final class AgentReview {
    let worktree: Worktree
    let store: RepoStore
    let base: String
    let repository: Repository

    var mergeBase: String?
    var commits: [Commit] = []
    var files: [FileChange] = []
    var selected: FileChange?
    var diff: FileDiff?
    var includeUncommitted = true
    var note: ClaudeNote?
    var feedback = ""
    var loading = true
    var error: String?

    init(worktree: Worktree, store: RepoStore) {
        self.worktree = worktree
        self.store = store
        self.base = store.mainWorktree?.branch ?? "main"
        self.repository = Repository(root: worktree.url)
    }

    var additions: Int { files.compactMap(\.additions).reduce(0, +) }
    var deletions: Int { files.compactMap(\.deletions).reduce(0, +) }
    private var target: String? { includeUncommitted ? nil : "HEAD" }

    func load() async {
        loading = true
        defer { loading = false }
        do {
            let mergeBase = try await repository.mergeBase(base, "HEAD")
            self.mergeBase = mergeBase
            commits = (try? await repository.log(limit: 200, revisions: ["\(base)..HEAD"])) ?? []
            files = try await repository.changedFiles(from: mergeBase, to: target)
            if let current = selected, let match = files.first(where: { $0.path == current.path }) {
                await select(match)
            } else {
                await select(files.first)
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func select(_ file: FileChange?) async {
        selected = file
        guard let file, let mergeBase else { diff = nil; return }
        diff = try? await repository.diff(of: file, from: mergeBase, to: target, options: store.diffOptions)
    }

    func images(for file: FileChange) -> ImagePairLoader {
        let repo = repository
        let mergeBase = mergeBase ?? base
        let uncommitted = includeUncommitted
        return {
            let before = await repo.blob("\(mergeBase):\(file.originalPath ?? file.path)")
            let after = uncommitted ? try? Data(contentsOf: repo.root.appendingPathComponent(file.path)) : await repo.blob("HEAD:\(file.path)")
            return (before, after)
        }
    }

    func askClaude() {
        guard let mergeBase else { return }
        note = ClaudeNote(title: "Claude's review")
        let repo = repository
        let uncommitted = includeUncommitted
        Task {
            do {
                let patch = try await repo.patchForReview(from: mergeBase, includeWorkingTree: uncommitted)
                let text = try await ClaudeHeadless.run(prompt: ClaudeHeadless.reviewPrompt, input: patch, directory: repo.root,
                                                        executable: store.claudeExecutable, model: Preferences.claudeModel, timeout: 240)
                note?.text = text
            } catch {
                note?.error = error.localizedDescription
            }
        }
    }

    /// Sends the review (or the user's own words) back to the agent.
    func sendFeedback() {
        var message = feedback.trimmingCharacters(in: .whitespacesAndNewlines)
        if message.isEmpty, let review = note?.text { message = "Please address this review of your changes:\n\n" + review }
        guard !message.isEmpty else { return }
        store.sendFeedback(message, to: worktree)
        feedback = ""
    }
}

struct AgentReviewView: View {
    @State private var review: AgentReview
    @Environment(\.dismiss) private var dismiss

    init(worktree: Worktree, store: RepoStore) {
        _review = State(initialValue: AgentReview(worktree: worktree, store: store))
    }

    private var store: RepoStore { review.store }
    private var session: ClaudeSessionInfo? { store.claudeSessions[review.worktree.path] }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                sidebar
                    .frame(minWidth: 260, idealWidth: 310, maxWidth: 420)
                DiffView(diff: review.diff, mode: .readOnly, store: store,
                         images: review.selected.map { review.images(for: $0) },
                         emptyTitle: review.loading ? "Loading…" : "Nothing to review")
                    .frame(minWidth: 480)
            }
            Divider()
            footer
        }
        .frame(minWidth: 1000, idealWidth: 1180, minHeight: 640, idealHeight: 780)
        .task { await review.load() }
        .onChange(of: review.includeUncommitted) { _, _ in Task { await review.load() } }
    }

    private var header: some View {
        HStack(spacing: 12) {
            if review.worktree.isClaude { ClaudeMark(size: 34) } else {
                Image(systemName: "square.stack.3d.up.fill").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 34, height: 34).background(Circle().fill(Theme.leafGradient))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(session?.title ?? review.worktree.name).font(.system(size: 16, weight: .semibold, design: .rounded))
                HStack(spacing: 5) {
                    Image(systemName: "arrow.triangle.branch").font(.system(size: 9.5, weight: .bold))
                    Text(review.worktree.branch ?? "detached").font(Theme.monoSmall)
                    Image(systemName: "arrow.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary)
                    Text(review.base).font(Theme.monoSmall)
                }
                .foregroundStyle(.secondary)
            }
            Spacer()
            Chip(text: "\(review.commits.count) commit\(review.commits.count == 1 ? "" : "s")", systemImage: "circle.circle")
            Chip(text: "\(review.files.count) file\(review.files.count == 1 ? "" : "s")", systemImage: "doc.on.doc")
            HStack(spacing: 5) {
                Text("+\(review.additions)").foregroundStyle(Theme.added)
                Text("−\(review.deletions)").foregroundStyle(Theme.removed)
            }
            .font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
            if let pr = store.pullRequest(for: review.worktree.branch) {
                PullRequestChip(pullRequest: pr)
            }
            Toggle("Include uncommitted", isOn: $review.includeUncommitted)
                .toggleStyle(.switch)
                .controlSize(.small)
                .help("Also show changes the agent hasn't committed yet")
            Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 17)) }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(LinearGradient(colors: [Theme.claude.opacity(0.08), Theme.leaf.opacity(0.04)], startPoint: .leading, endPoint: .trailing))
    }

    private var sidebar: some View {
        List(selection: Binding(get: { review.selected?.id }, set: { id in
            Task { await review.select(review.files.first { $0.id == id }) }
        })) {
            if let task = session?.task {
                Section("Task") {
                    Text("“\(task)”").font(.system(size: 12)).italic().foregroundStyle(.secondary).lineLimit(6)
                }
            }
            if !review.commits.isEmpty {
                Section("Commits") {
                    ForEach(review.commits.prefix(30)) { commit in
                        HStack(spacing: 6) {
                            Avatar(name: commit.authorName, email: commit.authorEmail, size: 16)
                            Text(commit.subject).lineLimit(1)
                            Spacer(minLength: 4)
                            Text(Format.ago(commit.commitDate)).font(.caption).foregroundStyle(.tertiary)
                        }
                        .font(.system(size: 12))
                        .selectionDisabled()
                    }
                }
            }
            Section("Files") {
                ForEach(review.files) { file in
                    HStack(spacing: 7) {
                        StatusIcon(status: file.status)
                        FilePathLabel(change: file)
                        Spacer(minLength: 4)
                        if let additions = file.additions, let deletions = file.deletions {
                            DiffStatBar(additions: additions, deletions: deletions)
                        }
                    }
                    .tag(file.id)
                }
            }
            if let error = review.error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let note = review.note {
                ClaudeNoteView(note: note) { review.note = nil }
                    .frame(maxHeight: 200)
            }
            HStack(spacing: 8) {
                Button { review.askClaude() } label: { Label("Review with Claude", systemImage: "sparkles") }
                    .disabled(review.note?.loading == true || review.files.isEmpty)
                    .help("Claude reads the whole change and points out problems")
                HStack(spacing: 6) {
                    Image(systemName: "bubble.left.fill").foregroundStyle(Theme.claude)
                    TextField("Tell the agent what to change…", text: $review.feedback)
                        .textFieldStyle(.plain)
                        .onSubmit { review.sendFeedback() }
                    Button("Send") { review.sendFeedback() }
                        .buttonStyle(.borderless)
                        .disabled(review.feedback.trimmingCharacters(in: .whitespaces).isEmpty && review.note?.text == nil)
                        .help(review.feedback.isEmpty && review.note?.text != nil ? "Send Claude's review to the agent" : "Continue the agent's session with this message")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
                Spacer(minLength: 12)
                Button(role: .destructive) {
                    dismiss()
                    store.discardAgent(review.worktree)
                } label: { Text("Discard…") }
                Button("Push & Open PR") {
                    store.pushAndOpenPullRequest(review.worktree)
                }
                if review.worktree.branch != review.base {
                    Button {
                        dismiss()
                        store.mergeIntoMain(review.worktree)
                    } label: { Label("Merge into \(review.base)", systemImage: "arrow.triangle.merge") }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.leaf)
                }
            }
        }
        .padding(14)
        .background(.bar)
    }
}

/// Claude's prose: a loading shimmer, the text, or what went wrong.
struct ClaudeNoteView: View {
    let note: ClaudeNote
    var close: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ClaudeMark(size: 16)
                Text(note.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Spacer()
                if let text = note.text {
                    HoverButton(systemImage: "doc.on.doc", help: "Copy") { copy(text) }
                }
                if let close { HoverButton(systemImage: "xmark", help: "Close", action: close) }
            }
            if let text = note.text {
                ScrollView {
                    Text(text)
                        .font(.system(size: 12.5))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if let error = note.error {
                Label(error, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Claude is reading the changes…").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.claude.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.claude.opacity(0.2)))
    }
}

/// `#42 ✓` — a pull request with its CI state, opening it on click.
struct PullRequestChip: View {
    let pullRequest: PullRequest

    var body: some View {
        Button { Launcher.openURL(pullRequest.url) } label: {
            HStack(spacing: 4) {
                Image(systemName: pullRequest.isDraft ? "circle.dashed" : "arrow.triangle.pull").font(.system(size: 9.5, weight: .bold))
                Text("#\(pullRequest.number)").font(.system(size: 11, weight: .semibold)).monospacedDigit()
                checkIcon
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .foregroundStyle(color)
            .background(Capsule().fill(color.opacity(0.13)))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    @ViewBuilder private var checkIcon: some View {
        switch pullRequest.checks {
        case .passing: Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy))
        case .failing: Image(systemName: "xmark").font(.system(size: 9, weight: .heavy))
        case .pending: Image(systemName: "clock").font(.system(size: 9, weight: .bold))
        case .none: EmptyView()
        }
    }

    private var color: Color {
        if pullRequest.isDraft { return .secondary }
        switch pullRequest.checks {
        case .failing: return Theme.removed
        case .pending: return Theme.sun
        default: return pullRequest.changesRequested ? .orange : Theme.leaf
        }
    }

    private var help: String {
        var parts = ["\(pullRequest.title) (#\(pullRequest.number))"]
        if pullRequest.isDraft { parts.append("Draft") }
        switch pullRequest.checks {
        case .passing: parts.append("Checks passing")
        case .failing: parts.append("Checks failing")
        case .pending: parts.append("Checks running")
        case .none: break
        }
        if pullRequest.isApproved { parts.append("Approved") }
        if pullRequest.changesRequested { parts.append("Changes requested") }
        return parts.joined(separator: " · ")
    }
}
