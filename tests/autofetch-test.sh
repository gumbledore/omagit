#!/bin/bash
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
omagit-config settings >/dev/null

export OMAGIT_CACHE_DIR="$TMP/cache"
STATE="$OMAGIT_CACHE_DIR/autofetch.state"
LOCK="$OMAGIT_CACHE_DIR/fetch.lock"
T0=1800000000

due()  { OMAGIT_NOW=$1 omagit-autofetch due; }
rec()  { grep -P "^$2\t" <<<"$1"; }          # rec <output> <TYPE>
setmin() { jq --argjson m "$1" '.autoFetchMinutes = $m' "$OMAGIT_CONFIG_DIR/settings.json" > "$TMP/s.json"; mv "$TMP/s.json" "$OMAGIT_CONFIG_DIR/settings.json"; }

ORIGIN="$TMP/origin.git"; make_origin "$ORIGIN"
R="$TMP/repo"; clone_repo "$ORIGIN" "$R"

# --- never fetched -> due ------------------------------------------------------
out=$(due $T0)
assert_eq $'DUE\tyes\tdue\t' "$(rec "$out" DUE)" "never fetched is due"
assert_eq $'LAST\t\t\t\t' "$(rec "$out" LAST)" "empty LAST when never fetched"

# --- a run records state; not-yet until the interval passes --------------------
commit_to_origin "$ORIGIN" main up.txt v2
out=$(OMAGIT_NOW=$T0 omagit-autofetch run auto --inbox "$R")
assert_contains "$out" $'FETCH\t'"$R"$'\tOK' "run streams omagit-remote records"
assert_eq $'AUTOFETCH\tok\t\t' "$(rec "$out" AUTOFETCH)" "ok result"
assert_eq "1" "$(git -C "$R" rev-list --count HEAD..origin/main)" "origin/main advanced"
out=$(due $((T0 + 60)))
assert_eq $'DUE\tno\tnot-yet\t'$((T0 + 1800)) "$(rec "$out" DUE)" "not-yet with next_epoch"
assert_eq $'LAST\t'"$T0"$'\tok\tauto\t' "$(rec "$out" LAST)" "LAST after ok run"
assert_eq $'DUE\tno\tnot-yet\t'$((T0 + 1800)) "$(rec "$(due $((T0 + 1799)))" DUE)" "still not due 1s early"
assert_eq $'DUE\tyes\tdue\t' "$(rec "$(due $((T0 + 1800)))" DUE)" "due after the interval"

# --- settings: disabled and custom interval ------------------------------------
setmin 0
assert_eq $'DUE\tno\tdisabled\t' "$(rec "$(due $((T0 + 99999)))" DUE)" "0 disables"
setmin 5
assert_eq $'DUE\tno\tnot-yet\t'$((T0 + 300)) "$(rec "$(due $((T0 + 100)))" DUE)" "user interval honored"
assert_eq $'DUE\tyes\tdue\t' "$(rec "$(due $((T0 + 300)))" DUE)" "due at user interval"
jq '.autoFetchMinutes = "soon"' "$OMAGIT_CONFIG_DIR/settings.json" > "$TMP/s.json"; mv "$TMP/s.json" "$OMAGIT_CONFIG_DIR/settings.json"
assert_eq $'DUE\tno\tdisabled\t' "$(rec "$(due $((T0 + 99999)))" DUE)" "non-numeric disables"
setmin 30

# --- state survives restart (fresh process reads the same values) ---------------
assert_file "$STATE" "state file written"
assert_eq $'LAST\t'"$T0"$'\tok\tauto\t' "$(rec "$(due $((T0 + 5)))" LAST)" "LAST survives restart"
assert_no_file "$STATE.tmp" "no tmp file left behind"

# --- failure: unreachable origin ------------------------------------------------
F="$TMP/broken"; clone_repo "$ORIGIN" "$F"
git -C "$F" remote set-url origin "$TMP/does-not-exist.git"
out=$(OMAGIT_NOW=$((T0 + 2000)) omagit-autofetch run manual --inbox "$F")
assert_contains "$out" $'FETCH\t'"$F"$'\tERR' "fetch error streamed"
assert_eq $'AUTOFETCH\terr\t1 repo failed to fetch\t' "$(rec "$out" AUTOFETCH)" "err result summary"
out=$(due $((T0 + 2001)))
assert_eq $'LAST\t'$((T0 + 2000))$'\terr\tmanual\t1 repo failed to fetch' "$(rec "$out" LAST)" "LAST records the failure"
assert_eq $'DUE\tno\tnot-yet\t'$((T0 + 2000 + 1800)) "$(rec "$out" DUE)" "failure still waits a full interval"

# --- rate limit: backoff until the server's reset, even past the interval -------
G="$TMP/gh"; clone_repo "$ORIGIN" "$G"
git -C "$G" remote set-url origin https://github.com/example/repo.git
git -C "$G" config url."$ORIGIN".insteadOf https://github.com/example/repo.git
echo '[]' > "$STUB_DIR/prs.json"
T1=$((T0 + 10000)); RESET=$((T1 + 7200))
echo '{"resources":{"core":{"limit":60,"remaining":0,"reset":'$RESET'},"graphql":{"limit":5000,"remaining":10,"reset":1}}}' > "$STUB_DIR/rate_limit.json"
out=$(OMAGIT_NOW=$T1 omagit-autofetch run auto --inbox "$G")
assert_contains "$out" $'GH\trate-limited\t'"$RESET" "GH record streamed"
assert_eq $'AUTOFETCH\terr\tGitHub rate limit reached\t'"$RESET" "$(rec "$out" AUTOFETCH)" "rate-limited result carries backoff"
assert_eq $'DUE\tno\tbackoff\t'"$RESET" "$(rec "$(due $((T1 + 3600)))" DUE)" "backoff beyond the interval"
assert_eq $'DUE\tyes\tdue\t' "$(rec "$(due $((RESET + 1)))" DUE)" "due after backoff ends"
rm "$STUB_DIR/rate_limit.json"
out=$(OMAGIT_NOW=$((RESET + 1)) omagit-autofetch run auto --inbox "$G")
assert_eq $'AUTOFETCH\tok\t\t' "$(rec "$out" AUTOFETCH)" "later run is ok"
assert_eq $'DUE\tno\tnot-yet\t'$((RESET + 1 + 1800)) "$(rec "$(due $((RESET + 2)))" DUE)" "success clears backoff"

# rate limit with no reset epoch (pr list limited): backoff = now + interval
touch "$STUB_DIR/pr-list-limited"
T2=$((RESET + 5000))
out=$(OMAGIT_NOW=$T2 omagit-autofetch run auto --inbox "$G")
assert_eq $'AUTOFETCH\terr\tGitHub rate limit reached\t'$((T2 + 1800)) "$(rec "$out" AUTOFETCH)" "no reset -> now + interval"
rm "$STUB_DIR/pr-list-limited"

# gh logged out is an err without backoff
touch "$STUB_DIR/gh-logged-out"
out=$(OMAGIT_NOW=$((T2 + 5000)) omagit-autofetch run auto --inbox "$G")
assert_eq $'AUTOFETCH\terr\tgh logged-out\t' "$(rec "$out" AUTOFETCH)" "logged-out result"
rm "$STUB_DIR/gh-logged-out"

# --- lock: a held lock blocks both due and run ----------------------------------
OMAGIT_NOW=$T0 omagit-autofetch run auto --inbox "$R" >/dev/null     # ensure lock file + state exist
( exec 9>"$LOCK"; flock -n 9; exec sleep 30 ) & holder=$!
for _ in $(seq 100); do flock -n "$LOCK" true 2>/dev/null || break; sleep 0.05; done
before=$(cksum < "$STATE"); : > "$STUB_LOG"
assert_eq $'DUE\tno\trunning\t' "$(rec "$(due $((T0 + 99999)))" DUE)" "held lock reads as running"
out=$(OMAGIT_NOW=$((T0 + 99999)) omagit-autofetch run manual --inbox "$R")
assert_eq "BUSY" "$out" "run prints BUSY only"
assert_eq "$before" "$(cksum < "$STATE")" "BUSY run leaves state untouched"
assert_eq "" "$(cat "$STUB_LOG")" "BUSY run calls no gh"
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null || true
assert_eq "yes" "$(rec "$(due $((T0 + 99999)))" DUE | cut -f2)" "due again once the lock is released"

# --- single-repo run (no --inbox) streams but leaves the schedule alone ----------
before=$(cat "$STATE")
out=$(OMAGIT_NOW=$((T0 + 300000)) omagit-autofetch run manual "$R")
assert_contains "$out" $'FETCH\t'"$R"$'\tOK' "single-repo run streams"
assert_eq $'AUTOFETCH\tok\t\t' "$(rec "$out" AUTOFETCH)" "single-repo run reports a result"
assert_eq "$before" "$(cat "$STATE")" "single-repo run leaves the state file alone"
assert_not_contains "$out" $'LOGIN\t' "no inbox without --inbox"
assert_contains "$(omagit-autofetch run auto 2>&1 || true)" "usage" "zero repos without --inbox is a usage error"

# --- --inbox streams inbox records after remote records ---------------------------
out=$(OMAGIT_NOW=$((T0 + 300000)) omagit-autofetch run manual --inbox "$R")
assert_eq "FETCH" "$(grep -n -P '^(FETCH|LOGIN)\t' <<<"$out" | head -n1 | cut -d: -f2 | cut -f1)" "remote records first"
assert_eq "LOGIN" "$(grep -P '^(DONE|LOGIN|INBOXDONE)\t' <<<"$out" | sed -n 2p | cut -f1)" "inbox records follow the remote DONE"
assert_contains "$out" $'INBOXDONE\t' "inbox terminator streamed"
assert_eq $'LAST\t'$((T0 + 300000))$'\tok\tmanual\t' "$(rec "$(due $((T0 + 300001)))" LAST)" "full run updates the schedule"
out=$(OMAGIT_NOW=$((T0 + 300100)) omagit-autofetch run auto --inbox)
assert_contains "$out" $'SECTION\treviews\tOK' "--inbox with zero repos runs only the inbox"
assert_eq "" "$(rec "$out" FETCH)" "no remote records without repos"
assert_eq $'AUTOFETCH\tok\t\t' "$(rec "$out" AUTOFETCH)" "zero-repo full run ok"

# inbox section ERR -> err result
touch "$STUB_DIR/graphql-fail"
out=$(OMAGIT_NOW=$((T0 + 300200)) omagit-autofetch run auto --inbox "$R")
assert_eq $'AUTOFETCH\terr\tinbox reviews failed; inbox prs failed\t' "$(rec "$out" AUTOFETCH)" "inbox ERR sections count as err"
rm "$STUB_DIR/graphql-fail"

# --- working tree untouched -----------------------------------------------------
W="$TMP/behind"; clone_repo "$ORIGIN" "$W"
commit_to_origin "$ORIGIN" main more.txt v3
head0=$(git -C "$W" rev-parse HEAD); br0=$(git -C "$W" rev-parse main); st0=$(git -C "$W" status --porcelain)
tip0=$(git -C "$W" rev-parse origin/main)
OMAGIT_NOW=$((T0 + 200000)) omagit-autofetch run auto --inbox "$W" >/dev/null
assert_eq "$head0" "$(git -C "$W" rev-parse HEAD)" "HEAD unchanged"
assert_eq "$br0" "$(git -C "$W" rev-parse main)" "checked-out branch tip unchanged"
assert_eq "$st0" "$(git -C "$W" status --porcelain)" "status unchanged"
assert_eq "main" "$(git -C "$W" symbolic-ref --short HEAD)" "still on main"
[[ $(git -C "$W" rev-parse origin/main) != "$tip0" ]] && pass || fail "origin/main should have advanced"

finish
