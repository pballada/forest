# Roadmap

## Shipped in 0.4

- One workspace window for every project; native git worktrees are gone, Claude worktrees are the unit of work
- Embedded Ghostty terminals (libghostty built from source), themed by Forest, one per worktree plus an optional shell
- Session index read incrementally from Claude Code transcripts; continue the last or any earlier conversation in a
  click, also after relaunching Forest; agent state (working / waiting for you / open / not running) in the sidebar
- Live changes inspector; Compare for branches, worktrees and arbitrary files
- One theme system for window, diffs and terminal, with Forest Night / Day and more schemes
- Codex, Gemini CLI or a custom command as the agent, besides Claude Code
- Locked worktrees can be removed (#1)

## Next for the workspace

- Keep sessions alive when Forest quits (daemon or `claude --bg`), not just resumable
- Quick-look diff popover from the live changes panel; per-file "who touched it" from the transcript
- Drag a worktree onto another to compare; compare working trees including uncommitted files

## Shipped in 0.2

- Custom AppKit diff canvas: draws only visible rows; unified and side-by-side; word-level highlights; syntax colours;
  wrap; whole-file and hide-whitespace options; overview ruler; next/previous change; line selection by click and drag
- `project.pbxproj` summaries, collapsed lockfiles, image comparison (2-up and swipe)
- Claude helpers: commit messages, commit explanations, agent reviews, conflict resolution hand-off, feedback to agents
- Agent review sheet (changes vs base, including uncommitted work)
- Undo for commits, discards, checkouts, branch deletes, merges, rebases, cherry-picks, reverts, pulls, resets and stashes
- Pull requests and CI status through `gh`
- Drag-to-merge and drag-to-rebase, "show only this branch", per-file line counts, file filter
- Forest-green theme, leaf toasts, commit celebration, friendlier empty and welcome screens

## Claude ideas, by value

1. **Split my changes into commits.** Claude groups the working copy into logical commits (hunk-level), shows the plan
   as draggable cards, and Forest stages and commits each group.
2. **Agent timeline.** Read the transcript to show what the agent did and when (files touched, commands run, test
   results) alongside the diff, so review starts from intent instead of lines.
3. **Inline review comments to the agent.** Select lines in the review diff, type a comment, and send all comments as
   one structured message into the agent's session.
4. **PR descriptions.** Generate the title and body from the branch's commits and diff when pushing an agent's work.
5. **Explain this hunk.** Right-click a hunk in any diff and ask why it changed, using the commit message and nearby
   history as context.
6. **Conflict assistant in-app.** Show Claude's proposed resolution per conflict as a three-way diff you accept or
   edit, instead of handing the whole job to the terminal.
7. **Agent fleet view.** Start several agents on variations of the same task and compare their diffs side by side.
8. **Branch cleanup.** Claude suggests which merged or stale agent branches and worktrees to delete, with reasons.
9. **Natural-language history search.** "When did we change the login timeout?" becomes a pickaxe/log query.
10. **Absorb.** Fold staged fixes into the right earlier commits automatically (fixup + autosquash), with a preview.

## Git & UI

- Interactive rebase: reorder, squash, fixup and reword by drag and drop
- Blame and file history views
- Three-way merge editor
- Stacked branches (a branch per agent step, rebased together)
- Image onion-skin and difference modes; folder comparison
- Launchpad: PRs, reviews and agents across all open repositories
