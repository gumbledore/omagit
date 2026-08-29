# omagit

Omarchy shell plugin (bar widget + popup) that tracks many git repos — a root
directory of projects plus any other explicit paths — and exposes housekeeping actions from the bar.

## Key directories

- `BarWidget.qml`, `Panel.qml`, `panel/` — QML: renders and dispatches only.
- `bin/` — bash helpers that do all git/gh/herdr/filesystem work and stream
  tab-separated records (`config`, `state`, `remote`, `action`, `watch`, `herdr`).
- `lib/common.sh` — shared env (no prompts ever), settings reader, branch helpers.
- `defaults/settings.json` — shipped defaults, merged into `~/.config/gumbledore.omagit/settings.json`.
- `tests/` — fixture-repo tests for every helper; `tests/stubs/` fakes `gh`, `herdr`, launchers.

## How to run

- Tests: `tests/run.sh` (no shell, no network).
- Dev install: `ln -sfn "$PWD" ~/.config/omarchy/plugins/gumbledore.omagit && omarchy plugin enable gumbledore.omagit right`.
- After editing QML the shell may serve a stale compile cache: clear
  `~/.cache/quickshell/qmlcache` and `omarchy-restart-shell`.
- Validate manifest: `omarchy plugin validate "$PWD"` (use the real path, not the symlink).

## Conventions

- Logic goes in `bin/`, with a test; QML never shells out to git directly.
- Helper output contract: `OUT<TAB>line…` then `RESULT<TAB>OK|ERR<TAB>message`.
- No automatic network: fetch and PR lookups only run from Fetch buttons.
- Nerd-font glyphs in QML must be Material Design codepoints written as surrogate-pair escapes (e.g. `"\udb81\ude2c"` = U+F062C source-branch), never literals.
