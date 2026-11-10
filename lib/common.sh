#!/bin/bash
# Shared setup for every omagit helper. Sourced, never executed.
#
# Nothing here may block on a prompt: git, ssh, and gh are all told to fail
# instead of asking. GIT_OPTIONAL_LOCKS=0 keeps read-only commands (status,
# log) from rewriting .git/index, which would otherwise feed the inotify
# watcher its own echo.

set -o pipefail

export GIT_TERMINAL_PROMPT=0
export GIT_OPTIONAL_LOCKS=0
export GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o BatchMode=yes}"
export GH_PROMPT_DISABLED=1
export GH_NO_UPDATE_NOTIFIER=1
export LC_ALL=C.UTF-8

OMAGIT_PLUGIN_DIR="${OMAGIT_PLUGIN_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"
OMAGIT_CONFIG_DIR="${OMAGIT_CONFIG_DIR:-$HOME/.config/gumbledore.omagit}"
# one-time move of the pre-namespace config dir (plugin id used to be plain "omagit")
if [[ -d $HOME/.config/omagit && ! -e $OMAGIT_CONFIG_DIR ]]; then mv "$HOME/.config/omagit" "$OMAGIT_CONFIG_DIR"; fi
OMAGIT_SETTINGS="$OMAGIT_CONFIG_DIR/settings.json"
OMAGIT_TRACKING="$OMAGIT_CONFIG_DIR/tracking.json"
OMAGIT_DEFAULTS="$OMAGIT_PLUGIN_DIR/defaults/settings.json"
OMAGIT_CACHE_DIR="${OMAGIT_CACHE_DIR:-$HOME/.cache/gumbledore.omagit}"
OMAGIT_TIMEOUT="${OMAGIT_TIMEOUT:-60}"

# Current epoch seconds; tests inject time through OMAGIT_NOW.
now() { printf '%s\n' "${OMAGIT_NOW:-$(date +%s)}"; }

die() { echo "omagit: $*" >&2; exit 1; }

# Print one tab-separated record. Tabs and newlines inside a field would split
# the record on the QML side, so they are flattened to spaces.
tsv() {
  local out="" f first=1
  for f in "$@"; do
    f=${f//$'\t'/ }
    f=${f//$'\n'/ }
    f=${f//$'\r'/}
    if (( first )); then out=$f; first=0; else out+=$'\t'$f; fi
  done
  printf '%s\n' "$out"
}

# Read one settings key as a raw jq value (string, number, bool, or JSON for
# arrays). Falls back to the shipped defaults when the user file lacks it.
setting() {
  local key=$1 v
  if [[ -f $OMAGIT_SETTINGS ]]; then
    v=$(jq -r --arg k "$key" 'if has($k) then .[$k] | (if type=="array" or type=="object" then tojson else tostring end) else "__unset__" end' "$OMAGIT_SETTINGS" 2>/dev/null || echo "__unset__")
    [[ $v != "__unset__" ]] && { printf '%s\n' "$v"; return; }
  fi
  jq -r --arg k "$key" '.[$k] | (if type=="array" or type=="object" then tojson else tostring end)' "$OMAGIT_DEFAULTS"
}

# Run a command with the helper timeout so a hung network call can never
# freeze the panel. Output and exit code pass through.
is_github() { git -C "$1" config --get remote.origin.url 2>/dev/null | grep -q "github\.com"; }
with_timeout() { timeout --foreground -k 5 "$OMAGIT_TIMEOUT" "$@"; }

# Classify an error string from a real gh call: prints logged-out,
# rate-limited, or nothing.
gh_classify_error() {
  if grep -qiE 'HTTP 401|bad credentials|authentication|gh auth login|not logged' <<<"$1"; then echo logged-out
  elif grep -qiE 'rate limit|HTTP 429' <<<"$1"; then echo rate-limited
  fi
}

# One record: GH<TAB>ok|missing|logged-out|rate-limited<TAB>reset_epoch<TAB>message
# Preflight technique borrowed from robzolkos/omarchy-github (MIT).
# Failures that are neither auth nor rate limit (e.g. offline) count as ok so
# they keep surfacing per row.
gh_status() {
  local out rc reset
  if ! command -v gh >/dev/null 2>&1; then tsv GH missing "" "gh not found"; return; fi
  out=$(with_timeout gh api rate_limit 2>&1); rc=$?
  if (( rc != 0 )); then
    if [[ $(gh_classify_error "$out") == logged-out ]]; then tsv GH logged-out "" "gh is logged out"; return; fi
  else
    reset=$(jq -r '[.resources.core, .resources.graphql] | map(select(.remaining == 0)) | .[0].reset // empty' <<<"$out" 2>/dev/null)
    if [[ -n $reset ]]; then tsv GH rate-limited "$reset" "GitHub rate limit reached"; return; fi
  fi
  tsv GH ok "" ""
}

# Current branch name, or "" when HEAD is detached / unborn.
current_branch() { git -C "$1" symbolic-ref --short -q HEAD 2>/dev/null || true; }

# Default branch: origin/HEAD if set, else main, else master.
default_branch() {
  local repo=$1 ref
  ref=$(git -C "$repo" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [[ -n $ref ]]; then printf '%s\n' "${ref#origin/}"; return; fi
  if git -C "$repo" show-ref -q --verify refs/heads/main 2>/dev/null; then echo main; return; fi
  if git -C "$repo" show-ref -q --verify refs/heads/master 2>/dev/null; then echo master; return; fi
  echo main
}

is_main_branch() { [[ $1 == main || $1 == master ]]; }

# Absolute, symlink-free path. Missing paths are returned normalized as-is.
abspath() { realpath -m -- "$1"; }
