#!/bin/bash
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

A="$TMP/a"; make_repo "$A"; mkdir -p "$A/node_modules/pkg" "$A/src"
B="$TMP/nest/b"; make_repo "$B"
mkdir -p "$TMP/linktarget"; ln -s "$TMP/linktarget" "$A/linked"

OUT="$TMP/events"; ERR="$TMP/watch.err"
omagit-watch "$A" "$B" >"$OUT" 2>"$ERR" &
WPID=$!
for _ in $(seq 1 50); do grep -q "Watches established" "$ERR" 2>/dev/null && break; sleep 0.1; done
grep -q "Watches established" "$ERR" || fail "watcher did not start: $(cat "$ERR")"

touch "$A/src/file.txt"
touch "$B/other.txt"
touch "$A/node_modules/pkg/index.js"
touch "$TMP/linktarget/viaLink.txt"
printf 'ref: refs/heads/x\n' > "$B/.git/HEAD.tmp"; mv "$B/.git/HEAD.tmp" "$B/.git/HEAD"
sleep 0.5
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null || true

events=$(sort -u "$OUT")
assert_contains "$events" "$A" "event inside repo A maps to A"
assert_contains "$events" "$B" "event inside nested repo B maps to B"
assert_eq "2" "$(wc -l <<<"$events")" "only tracked repo paths emitted"
assert_eq "0" "$(grep -c "node_modules" "$OUT" || true)" "ignore dir silent"
assert_eq "0" "$(grep -c "linktarget" "$OUT" || true)" "symlink target silent"

# .git/HEAD change counted (branch switch from a terminal)
head_events=$(grep -c "$B" "$OUT" || true)
[[ $head_events -ge 2 ]] && pass || fail ".git/HEAD change should emit (got $head_events events for B)"

# SIGKILL on the script (shell restart) must not orphan inotifywait
omagit-watch "$A" >/dev/null 2>"$TMP/err2" &
WPID=$!
for _ in $(seq 1 50); do grep -q "Watches established" "$TMP/err2" 2>/dev/null && break; sleep 0.1; done
kill -9 "$WPID"; wait "$WPID" 2>/dev/null || true
sleep 6
[[ -z $(pgrep -f "inotifywait.*$A") ]] && pass || fail "inotifywait orphaned after SIGKILL"

finish
