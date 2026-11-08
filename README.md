<p align="center"><img src="Resources/AppIcon.png" width="128" alt="Forest icon"></p>

<h1 align="center">Forest</h1>
<p align="center"><b>One window for your Claude Code agents: their terminals, their changes, and a native Git client.</b></p>

![Worktrees dashboard](docs/screenshots/worktrees.png)

Forest replaces a terminal tab per worktree, a separate Git app and a separate diff tool. Every project lives in one
window: the sidebar lists the main checkout and each Claude worktree (`.claude/worktrees/<name>`) with what its agent
is doing, the middle shows that worktree's terminal, changes or history, and the right panel shows files changing as
Claude writes them.

## Features

**Agents and sessions**
- **One window, every project**: projects and their agents in the sidebar, each row showing whether Claude is working,
  waiting for you, open or not running, plus the conversation's title and the number of changed files. ⌘1…⌘9 and
  ⌃Tab jump between them like terminal tabs
- **Embedded Ghostty terminal** per worktree (libghostty, Metal-rendered), using your Ghostty config for fonts and
  keys, coloured by Forest's theme. ⌘D adds a shell underneath
- **Continue sessions easily**: a worktree without a running terminal offers to continue its last conversation
  (`claude --resume <id>`), pick an earlier one, or start a new one with a task. After a relaunch everything is one
  click (or ↩) away
- **New Agent** (⌘N): describe a task and Forest creates `.claude/worktrees/<name>` on `worktree-<name>` and starts
  Claude there with that task
- **Live changes**: files appear in the right panel the moment they're written, freshest first and briefly lit,
  with what the branch already committed on top of main, and Review / Merge at hand
- **Review an agent's work**: every commit and file it changed against main (uncommitted work included), a one-click
  Claude review, and feedback typed straight into the agent's running session
- Dock badge and a "!" on the row when an agent rings the bell or posts a notification
- Merge into main, push & open a PR, lock, or remove the worktree and branch in one step

**Claude helpers** (use your Claude Code login, run with tools disabled)
- ✨ **Write the commit message** from the staged changes, following your repo's conventions (⌥⌘M)
- **Explain a commit**: what it does and what to watch out for, right in History
- **Resolve conflicts with Claude**: hands the conflicted files to Claude Code; you review before continuing

**Diffs that stay fast**
- A custom renderer draws only what's on screen: 100 000-line files scroll smoothly
- Unified or side-by-side, word-level highlights, syntax colours, wrap, whole-file view, hide whitespace
- Overview ruler and next/previous change (⌥⌘↓ / ⌥⌘↑)
- **Xcode projects in plain words**: `project.pbxproj` changes are summarised as files added and removed, target membership, packages and build settings (old → new)
- Lockfiles (`Package.resolved`, `package-lock.json`, `yarn.lock`, …) collapse by default
- Images compare side by side or with a swipe slider
- Stage, unstage or discard hunks or **individual lines**: click, drag or ⇧-click lines, then use the hunk buttons or right-click

**Everything Git**
- Commit graph with colored lanes, ref badges, search, keyboard navigation, and "show only this branch"
- Commit, amend, and commit & push, with a little celebration
- **Undo** (⌥⌘Z, or the toast's Undo button) for commits, discards, checkouts, branch deletes, merges, rebases, cherry-picks, reverts, pulls, resets and stashes
- Drag a branch onto the current one to merge it, or the current branch onto another to rebase
- Branches, remotes, tags and stashes; merge, rebase, cherry-pick, revert and reset
- Conflict banner with ours/theirs/mark resolved, plus continue/abort
- Fetch, pull (ff-only, merge or rebase), push with automatic upstream or force-with-lease
- ⌘K command palette, live refresh through FSEvents, clone/init/open, drag-and-drop folders
- **Compare** (⌥⌘C) two branches or two agents' worktrees (fully, or only since they diverged), or any two files on disk
- Themes for the whole window, diffs and terminal: Forest Night and Day (Automatic follows the system), Solarized Dark
  (default) and Light, Tokyo Night, Catppuccin Mocha and Latte, Rosé Pine, Nord, Gruvbox, Dracula, One Dark, Monokai,
  GitHub Dark and Light
- Updates itself from GitHub Releases, installing only builds signed by the same developer and notarized by Apple

| Xcode project, side by side | Reviewing an agent |
|---|---|
| ![Xcode project diff](docs/screenshots/xcode-project-split.png) | ![Agent review](docs/screenshots/agent-review.png) |

| History | Image diff |
|---|---|
| ![History](docs/screenshots/history.png) | ![Image diff](docs/screenshots/image-diff.png) |

## Build & run

Requires macOS 14+, Xcode 16+ (Swift 6 toolchain) and [Zig](https://ziglang.org) for libghostty (`brew install zig`;
the version Ghostty's `build.zig.zon` asks for).

```sh
scripts/build-ghosttykit.sh   # once: builds libghostty from Ghostty's official source into Vendor/
scripts/build-app.sh          # builds build/Forest.app (release; runs the step above if needed)
open build/Forest.app
open build/Forest.app --args ~/code/my-repo   # open a repo directly
```

To ship a signed, notarized build (`build/Forest-<version>.dmg` and `.zip`), you need a Developer ID Application
certificate and a `notary` keychain profile (`xcrun notarytool store-credentials notary …`). Then run:

```sh
scripts/release.sh
```

The version comes from the latest `v*` tag (default 0.2.0); the build number is the commit count.

For development, `swift run Forest` (after `scripts/build-ghosttykit.sh`), or open `Package.swift` in Xcode. Run tests
with `swift test`.

Optional: install the [GitHub CLI](https://cli.github.com) (`gh auth login`) to see pull requests and CI status.

## Architecture

```
Sources/ForestCore      Git engine: runs the system git binary, parses porcelain output, lays out the commit
                        graph and diffs, builds partial-staging patches, summarises Xcode projects, indexes
                        Claude Code sessions (incrementally), runs headless Claude and gh
Sources/ForestTerminal  The only code that talks to libghostty: the shared app and config, the surface view
                        (keyboard with IME, mouse, clipboard) and TerminalSession, which outlives its views
Sources/Forest          SwiftUI app: WorkspaceStore (projects, selection) → ProjectStore (worktrees, terminals,
                        agent state) → RepoStore (one per worktree: status, history, actions), views, diff canvas
Vendor/                 GhosttyKit.xcframework and Ghostty's shell integration + terminfo (built, not committed)
Tests/                  Swift Testing suites, many against real temporary repositories
```

Forest shells out to your own `git`, so hooks, credential helpers, LFS, signing and config work exactly as they do on
the command line.

## Keyboard shortcuts

| | |
|---|---|
| ⌘N | New agent |
| ⌘1 … ⌘9 · ⌃Tab / ⌃⇧Tab | Go to worktree n · next / previous |
| ⌥⌘1 / ⌥⌘2 / ⌥⌘3 | Terminal / Changes / History |
| ⇧⌘↩ | Continue the last session |
| ⌘D | Shell under the terminal |
| ⌥⌘0 | Show or hide live changes |
| ⌥⌘C | Compare |
| ⇧⌘R | Review agent |
| ⌘K | Command palette |
| ⌘↩ | Commit |
| ⌥⌘M | Write commit message with Claude |
| ⌥⌘Z | Undo last action |
| ⌥⌘↓ / ⌥⌘↑ | Next / previous change in a diff |
| ⇧⌘F / ⇧⌘P / ⇧⌘U | Fetch / Pull / Push |
| ⇧⌘B | New branch |
| ⌥⌘S | Stash |
| Space / double-click | Stage or unstage selected files |
| Esc | Clear the line selection in a diff |

See [docs/ROADMAP.md](docs/ROADMAP.md) for what's next.

The embedded terminal is [Ghostty](https://ghostty.org)'s libghostty (MIT licensed); its licence ships in the app
bundle.
