# omagit

Multi-repo git dashboard for the [Omarchy](https://omarchy.org) bar. Track scan
roots (every git repo found under them) and individual repos; see branch, dirty
count, ahead/behind, open PRs with CI color, and last-commit age on one line
each; and do the housekeeping — quick commit, branch ops, create/merge PR,
fast-forward main, prune gone branches, open a terminal or your default coding
agent — without leaving the bar.

Local state is live (inotify-driven, fallback timer). Nothing touches the
network unless you press **Fetch all** or a per-repo **Fetch**.

## Install

```bash
omarchy plugin add https://github.com/gumbledore/omagit.git --enable
```

Or by hand: clone anywhere and symlink it in (this is also the dev setup —
edits are picked up by the shell):

```bash
git clone https://github.com/gumbledore/omagit.git ~/Nucleus/local-apps/omagit
ln -sfn ~/Nucleus/local-apps/omagit ~/.config/omarchy/plugins/gumbledore.omagit
omarchy plugin enable gumbledore.omagit right
```

If the shell keeps showing old QML after an edit, clear its compile cache and
restart: `rm -rf ~/.cache/quickshell/qmlcache && omarchy-restart-shell`.

Requirements (all present on Omarchy): `bash`, `git`, `gh` (logged in for
GitHub repos), `jq`, `inotifywait`. Optional: [herdr](https://herdr.dev) when
`launcher = "herdr"`.

### Keybind

Add to `~/.config/hypr/bindings.conf`:

```
bindd = SUPER CTRL, G, omagit, exec, omarchy-shell omagit toggle
```

IPC target `omagit` also accepts `open`, `close`, `refresh`, and
`expand <label>` (opens the panel with that repo expanded).

## Using it

- **Bar icon** — git-branch glyph with a badge counting repos that are dirty,
  ahead, or behind (hidden at zero). Left-click toggles the panel, right-click
  refreshes.
- **Header** — Fetch all · Refresh · **+** (add root / add repo, manage roots)
  · settings (opens `settings.json` in the Omarchy default editor). The summary shows
  the repo count, attention count, and "fetched N min ago".
- **Rows** — `label  branch  ●dirty  ↑ahead↓behind  PR n  age  ×`. Repos found
  under a root are labeled by their path relative to it
  (`data-analysis/Neuronchat`); explicit repos by basename. Rows needing
  attention are tinted. Repos without an upstream or remote say so instead of
  erroring. **×** untracks (explicit repo → removed; discovered repo → added
  to `excluded`; nothing on disk changes).
- **Expanded row** (click a row) — dirty files with status letters (click one
  to open it with `openFileCommand`), open PRs (click to open in the browser,
  **Merge** button per PR), and the action strip:
  - **Commit** — inline form: message prefilled from the changed files, target
    branch prefilled `branchPrefix + date` when on main/master (else the current
    branch), and a "Commit to main" toggle. Stages all, commits, pushes with
    upstream. If a push to main is rejected, the commit is moved to a new
    prefixed branch, main is reset to origin, the branch is pushed, and a PR is
    opened with `gh pr create --fill`.
  - **Branch** — new branch from an inline name field. **Switch** — local
    branches as inline buttons.
  - **PR** — refused on main/master; otherwise pushes and opens the PR form in
    the browser (an existing PR is opened instead).
  - **FF main** — fast-forwards the default branch (from `origin/HEAD`) whether
    or not it is checked out; a diverged main is reported and nothing changes.
  - **Fetch** — this repo only. **Diff** — read-only stat + per-file diff inline.
  - **Term** / **agent** — terminal or `omarchy-default-agent` rooted in the
    repo, via the native launchers or herdr (see `launcher`). With no default
    agent set the button says so.
  - **Merge** on a PR runs `gh pr merge --<mergeStrategy> [--delete-branch]`,
    then fast-forwards main and prunes local branches whose upstream is gone.
    A failing-CI PR turns the button red and needs a second click.
  - Every action writes a one-line status; a failed one expands to the captured
    output on click.
- **Footer** — Uninstall (arms on first click, confirms on the second within a
  few seconds): removes `~/.config/gumbledore.omagit` and runs
  `omarchy plugin remove gumbledore.omagit --yes`.

## Settings

`~/.config/gumbledore.omagit/settings.json` is created from the shipped defaults the first
time the plugin loads and re-merged on every load: missing keys are added,
your values are never overwritten, and `schemaVersion` is recorded. Edits apply
live. There are no option menus in the panel.

| Key | Default | Meaning |
|-----|---------|---------|
| `schemaVersion` | `1` | Managed by the plugin |
| `launcher` | `"native"` | `"native"` (`xdg-terminal-exec`, `omarchy-agent`) or `"herdr"` (one workspace per repo — Terminal focuses it, each agent click opens a new tab; agent-status dot on rows) |
| `mergeStrategy` | `"squash"` | `squash` \| `merge` \| `rebase` |
| `deleteBranchOnMerge` | `true` | Pass `--delete-branch` to `gh pr merge` |
| `pruneGoneAfterMerge` | `true` | Delete local branches whose upstream is gone after a merge |
| `branchPrefix` | `"work/"` | Prefix for suggested branches (`work/2026-08-28`) |
| `fallbackRefreshSeconds` | `300` | Full re-read + root re-scan + watcher restart interval |
| `debounceMs` | `500` | Per-repo debounce for filesystem events |
| `scanDepth` | `4` | How deep a root is scanned for repos |
| `ignoreDirs` | `["node_modules", ".venv", "venv", "dist", "build", "__pycache__", ".obsidian", "target"]` | Never entered during discovery and excluded from the watcher (dotfolders and symlinks are always skipped) |
| `openFileCommand` | `"omarchy-launch-editor"` | Command that receives an absolute path (default: the Omarchy default editor); e.g. `"zeditor"` for Zed |
| `ghPrLimit` | `20` | `--limit` for `gh pr list` |

Tracking lives in `~/.config/gumbledore.omagit/tracking.json` (`roots`, `repos`,
`excluded`; absolute paths). It is created on the first add.

## Caveats

- **gh credential helper pin.** `gh auth setup-git` writes the helper path with
  the exact mise-installed `gh` version. After a `gh` upgrade, non-TTY pushes
  fail until you rerun `gh auth setup-git`. omagit shows this as a push error.
- `Claude-sync` under `~/Nucleus` is a real repo and will be discovered; untrack
  it (×) if you do not want it listed.
- Zed's binary on Omarchy is `zeditor`; use that as `openFileCommand`.
- Repos whose `origin` is not on github.com skip the PR lookup silently.

## Removing

The in-panel **Uninstall** cleans up everything. If you remove the plugin with
`omarchy plugin remove gumbledore.omagit` or omaplug instead, delete the config yourself:

```bash
rm -rf ~/.config/gumbledore.omagit
```

and drop the keybind from `bindings.conf`.

## Development

```bash
tests/run.sh                      # helper tests against fixture repos; no shell, no network
omarchy plugin validate "$PWD"    # manifest check (real path, not the symlink)
```

All git/gh/herdr logic lives in `bin/` and is exercised by `tests/` with stub
`gh`/`herdr`/launchers on `PATH`; QML only renders records. See `CLAUDE.md`.
