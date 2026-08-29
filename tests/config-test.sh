#!/bin/bash
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

# --- settings bootstrap -------------------------------------------------------
assert_no_file "$OMAGIT_CONFIG_DIR/settings.json" "no settings before first load"
out=$(omagit-config settings)
assert_file "$OMAGIT_CONFIG_DIR/settings.json" "settings created on first load"
for key in schemaVersion launcher mergeStrategy deleteBranchOnMerge pruneGoneAfterMerge branchPrefix fallbackRefreshSeconds debounceMs scanDepth ignoreDirs openFileCommand ghPrLimit; do
  assert_eq "true" "$(jq --arg k "$key" 'has($k)' "$OMAGIT_CONFIG_DIR/settings.json")" "settings has $key"
done
assert_eq "squash" "$(jq -r .mergeStrategy <<<"$out")" "settings printed to stdout"
assert_no_file "$OMAGIT_CONFIG_DIR/tracking.json" "tracking not created by settings load"

# User edits survive; deleted keys come back; unknown keys are kept.
jq '.mergeStrategy = "rebase" | .custom = 1 | del(.ghPrLimit)' "$OMAGIT_CONFIG_DIR/settings.json" > "$TMP/s.json"
mv "$TMP/s.json" "$OMAGIT_CONFIG_DIR/settings.json"
out=$(omagit-config settings)
assert_eq "rebase" "$(jq -r .mergeStrategy <<<"$out")" "user value preserved on merge"
assert_eq "20" "$(jq -r .ghPrLimit <<<"$out")" "missing key restored from defaults"
assert_eq "1" "$(jq -r .custom <<<"$out")" "unknown key kept"
assert_eq "1" "$(jq -r .schemaVersion <<<"$out")" "schemaVersion recorded"
before=$(stat -c %Y "$OMAGIT_CONFIG_DIR/settings.json")
sleep 1
omagit-config settings >/dev/null
assert_eq "$before" "$(stat -c %Y "$OMAGIT_CONFIG_DIR/settings.json")" "no rewrite when nothing to merge"

# Corrupt settings file: fall back to defaults without clobbering the file.
printf '{ not json' > "$OMAGIT_CONFIG_DIR/settings.json"
out=$(omagit-config settings 2>/dev/null)
assert_eq "squash" "$(jq -r .mergeStrategy <<<"$out")" "corrupt settings yield defaults"
assert_eq "{ not json" "$(cat "$OMAGIT_CONFIG_DIR/settings.json")" "corrupt settings left for the user to fix"
rm "$OMAGIT_CONFIG_DIR/settings.json"; omagit-config settings >/dev/null

# --- tracking ------------------------------------------------------------------
out=$(omagit-config tracking)
assert_eq '{"roots":[],"repos":[],"excluded":[]}' "$(jq -c . <<<"$out")" "empty tracking when file absent"
assert_no_file "$OMAGIT_CONFIG_DIR/tracking.json" "tracking still absent after read"

NUC="$TMP/nucleus"
make_repo "$NUC/alpha"
make_repo "$NUC/group/beta"
make_repo "$NUC/group/beta/inner"          # nested inside a repo: must not appear
make_repo "$NUC/node_modules/junk"          # ignore dir
make_repo "$NUC/.hidden/dot"                # dotfolder
make_repo "$NUC/a/b/c/d/deep"               # depth 5 > scanDepth 4
make_repo "$NUC/a/b/c/edge"                 # depth 4: included
mkdir -p "$TMP/elsewhere"; make_repo "$TMP/elsewhere/linked"
ln -s "$TMP/elsewhere/linked" "$NUC/symlinked"   # symlink: skipped
mkdir -p "$NUC/plain"                        # not a repo
make_repo "$TMP/solo"

omagit-config add-root "$NUC" >/dev/null
assert_file "$OMAGIT_CONFIG_DIR/tracking.json" "tracking created on first add"
omagit-config add-repo "$TMP/solo" >/dev/null
omagit-config add-repo "$TMP/solo" >/dev/null
assert_eq "1" "$(jq '.repos | length' "$OMAGIT_CONFIG_DIR/tracking.json")" "add-repo is idempotent"
out=$(omagit-config add-repo "$NUC/plain" 2>&1 || true)
assert_contains "$out" "not a git repo" "add-repo refuses non-repo"
out=$(omagit-config add-root "$TMP/nope" 2>&1 || true)
assert_contains "$out" "not a directory" "add-root refuses missing dir"

disc=$(omagit-config discover)
paths=$(cut -f1 <<<"$disc")
assert_contains "$paths" "$NUC/alpha" "root repo discovered"
assert_contains "$paths" "$NUC/group/beta" "nested path repo discovered"
assert_contains "$paths" "$NUC/a/b/c/edge" "depth-4 repo discovered"
assert_not_contains "$paths" "inner" "repo inside a repo not descended"
assert_not_contains "$paths" "node_modules" "ignore dir skipped"
assert_not_contains "$paths" ".hidden" "dotfolder skipped"
assert_not_contains "$paths" "deep" "beyond scanDepth skipped"
assert_not_contains "$paths" "symlinked" "symlink skipped"
assert_not_contains "$paths" "$TMP/elsewhere" "symlink target not reached"
assert_contains "$paths" "$TMP/solo" "explicit repo listed"
assert_eq "group/beta" "$(grep -P "^$NUC/group/beta\t" <<<"$disc" | cut -f2)" "discovered label relative to root"
assert_eq "solo" "$(grep -P "^$TMP/solo\t" <<<"$disc" | cut -f2)" "explicit label is basename"
assert_eq "root" "$(grep -P "^$NUC/alpha\t" <<<"$disc" | cut -f4)" "discovered kind"
assert_eq "repo" "$(grep -P "^$TMP/solo\t" <<<"$disc" | cut -f4)" "explicit kind"

# Untrack semantics
omagit-config untrack "$NUC/alpha" >/dev/null
assert_eq "$NUC/alpha" "$(jq -r '.excluded[0]' "$OMAGIT_CONFIG_DIR/tracking.json")" "discovered repo goes to excluded"
assert_not_contains "$(omagit-config discover | cut -f1)" "$NUC/alpha" "excluded repo hidden on rescan"
omagit-config untrack "$TMP/solo" >/dev/null
assert_eq "0" "$(jq '.repos | length' "$OMAGIT_CONFIG_DIR/tracking.json")" "explicit repo removed"
assert_eq "1" "$(jq '.excluded | length' "$OMAGIT_CONFIG_DIR/tracking.json")" "explicit repo not added to excluded"
[[ -d $TMP/solo/.git ]] && pass || fail "untrack must not touch disk"
omagit-config untrack-root "$NUC" >/dev/null
assert_eq "0" "$(jq '.roots | length' "$OMAGIT_CONFIG_DIR/tracking.json")" "root removed"
assert_eq "" "$(omagit-config discover)" "nothing tracked after root removal"
[[ -d $NUC/group/beta/.git ]] && pass || fail "untrack-root must not touch disk"

# Tilde and relative paths are normalized to absolute.
( cd "$TMP" && omagit-config add-repo "./solo" >/dev/null )
assert_eq "$TMP/solo" "$(jq -r '.repos[0]' "$OMAGIT_CONFIG_DIR/tracking.json")" "relative path made absolute"

finish

# --- pre-namespace config dir is moved once ------------------------------------
rm -rf "$OMAGIT_CONFIG_DIR" "$HOME/.config/omagit"
mkdir -p "$HOME/.config/omagit"; echo '{"repos":["/x"]}' > "$HOME/.config/omagit/tracking.json"
omagit-config settings >/dev/null
assert_no_file "$HOME/.config/omagit/tracking.json" "old config dir moved away"
assert_eq "/x" "$(jq -r '.repos[0]' "$OMAGIT_CONFIG_DIR/tracking.json")" "old tracking carried over"
