# Competitive analysis

Researched October 2026. Forest's goal is to be the most beautiful native Git client on macOS, and the
first one built around parallel work: worktrees and AI coding agents.

## The field

| | **Fork** | **Tower** | **Sourcetree** | **GitKraken** | **Sublime Merge** |
|---|---|---|---|---|---|
| Tech | Native (AppKit) | Native (AppKit) | Native, aging | Electron | Custom native |
| Price | $60 once | Subscription | Free | Freemium / sub | $99 once |
| Speed | Excellent | Good | Slow on big repos | Heavy | Excellent |
| Visual polish | Clean, utilitarian | Polished, dense | Dated | Flashy, non-native | Minimal, text-first |
| Commit graph | Very good | Good | Good | Very good | Good |
| Hunk / line staging | ✓ / ✓ | ✓ / ✓ | ✓ / ✓ | ✓ / ✓ | ✓ / ✓ |
| Interactive rebase | ✓ (drag & drop) | ✓ (drag & drop) | ✓ (basic) | ✓ | ✓ |
| Worktrees | Create/delete (2.41+), dialog in 2.63 | Supported | ✗ | ✓ | ✗ |
| AI | Commit messages via agents (2.70) | AI commit messages (16), `gittower` CLI for reviewing agent work (18) | ✗ | AI commits, PR summaries | ✗ |
| Agent worktree awareness | ✗ | Partial (branch parent tracking) | ✗ | ✗ | ✗ |

### Fork
The developer favorite: native, fast, one-time price. Strong graph and interactive rebase with
drag-and-drop squashing, a Quick Launch palette, and since 2024 worktree create/delete (with a dedicated dialog in
2.63, Feb 2026). Worktrees are a list of folders; it doesn't tell you what's happening inside them.

### Tower
The most complete feature set (workflows, undo, conflict wizard, PR integration). Recent releases lean into AI:
AI commit messages with Claude Code or Codex as the provider (Tower 16) and a `gittower` CLI meant for reviewing
changes made by coding agents (Tower 18). Dense UI and subscription pricing.

### Sourcetree
Free and familiar, but visibly aging: slow on large repositories, an inconsistent UI, and no worktree support.

### GitKraken / Sublime Merge
GitKraken has the best-known graph but is Electron and feels foreign on macOS. Sublime Merge is extremely fast
and keyboard-first, but spartan, with no worktree support.

## The gap Forest targets

1. **Agents work in worktrees now.** `claude --worktree` puts each agent in `.claude/worktrees/<name>`. No client
   shows, at a glance, which agents exist, what each was asked to do, whether it's working right now, what it changed,
   and how to land or discard its work. Tools like Treebar (a notch app for Codex worktrees) show the demand, but
   they're read-only and single-purpose.
2. **Worktrees are second-class everywhere.** Even where they're supported, they're a list of paths. They should be a
   dashboard: dirty state, ahead/behind, last commit, unmerged commits, one-click open/terminal/editor.
3. **Native beauty without density fatigue.** Tower is powerful but busy; Fork is fast but plain. There's room for
   a client that feels like a first-party Apple app: vibrancy, generous spacing, color-coded lanes that carry
   through to ref badges, and motion that confirms what happened.

## Forest's answer (v0.1)

- **Worktrees dashboard**: cards for main, Claude agents, and native worktrees, with live status from FSEvents.
- **Claude agent cards**: Forest reads Claude Code's own transcripts (`~/.claude/projects`) to show the session's AI
  title, the original task, a "working now" pulse, session count, and any PR the agent opened.
- **New Claude Agent**: describe a task → Forest creates `.claude/worktrees/<slug>` on `worktree-<slug>` (the same
  layout as `claude --worktree`), excludes the folder locally, and launches Claude Code in your terminal with the task.
- **Land or discard**: merge an agent's branch into main, push it and open a PR, or remove the worktree and branch.
- **Everything else you expect**: graph history, hunk *and line* staging/unstaging/discarding, intra-line diff
  highlights, commit/amend/commit & push, branches, remotes, tags, stashes, merge/rebase/cherry-pick/revert/reset,
  conflict resolution (ours/theirs/mark resolved), a ⌘K command palette, and full keyboard shortcuts.

## Next up

- Interactive rebase (reorder / squash / fixup / reword by drag and drop)
- Blame and file history views
- Side-by-side diff and syntax highlighting
- Agent review mode: a combined diff of everything an agent changed against its base
- Commit message generation through Claude
- GitHub/GitLab PR status on branches and worktree cards

## Sources

- [Fork release notes](https://fork.dev/releasenotes) · [Fork on Softantenna](https://softantenna.com/softwares/7462-fork)
- [Tower 16 launch (AlternativeTo)](https://alternativeto.net/news/2026/5/tower-16-for-mac-launches-with-ai-commit-messages-redesigned-working-copy-view-and-more/) · [Tower 18 overview](https://chatgate.ai/post/tower-18-for-mac)
- [Tower: best Git clients](https://www.git-tower.com/blog/best-git-client)
- [Toolradar: Treebar vs Tower](https://toolradar.com/compare/treebar-vs-tower)
- [Claude Code worktree guide](https://www.heyuan110.com/posts/ai/2026-02-28-claude-code-worktree-guide/)
