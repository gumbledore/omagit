#!/bin/bash
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
omagit-config settings >/dev/null

ORIGIN="$TMP/origin.git"; make_origin "$ORIGIN"
R="$TMP/repo"; clone_repo "$ORIGIN" "$R"
commit_to_origin "$ORIGIN" main up.txt v2

# Local-path origin: fetch works, PR lookup skipped silently.
out=$(omagit-remote "$R")
assert_contains "$out" $'FETCH\t'"$R"$'\tOK' "fetch ok"
assert_eq "1" "$(git -C "$R" rev-list --count HEAD..origin/main)" "behind after fetch"
assert_contains "$out" $'PRS\t'"$R"$'\tSKIP' "non-github remote skips PRs"
assert_not_contains "$(cat "$STUB_LOG" 2>/dev/null)" "gh " "gh not called for non-github"
assert_not_contains "$out" $'GH\t' "no GH record without a github remote"

# GitHub remote: PRs listed with rollup mapping.
G="$TMP/gh"; clone_repo "$ORIGIN" "$G"
git -C "$G" remote set-url origin https://github.com/example/repo.git
git -C "$G" config url."$ORIGIN".insteadOf https://github.com/example/repo.git
cat > "$STUB_DIR/prs.json" <<'JSON'
[
 {"number":1,"title":"Passing","url":"https://github.com/example/repo/pull/1","headRefName":"a","statusCheckRollup":[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"},{"__typename":"StatusContext","state":"SUCCESS"}]},
 {"number":2,"title":"Failing","url":"https://github.com/example/repo/pull/2","headRefName":"b","statusCheckRollup":[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"},{"__typename":"CheckRun","status":"COMPLETED","conclusion":"FAILURE"}]},
 {"number":3,"title":"Pending","url":"https://github.com/example/repo/pull/3","headRefName":"c","statusCheckRollup":[{"__typename":"CheckRun","status":"IN_PROGRESS","conclusion":null},{"__typename":"StatusContext","state":"PENDING"}]},
 {"number":4,"title":"No CI\twith tab","url":"https://github.com/example/repo/pull/4","headRefName":"d","statusCheckRollup":[]}
]
JSON
out=$(omagit-remote "$G")
prs=$(grep -P "^PR\t" <<<"$out")
assert_eq "4" "$(wc -l <<<"$prs")" "four PRs"
assert_contains "$prs" $'\t1\tPassing\thttps://github.com/example/repo/pull/1\tpassing\ta' "passing rollup"
assert_contains "$prs" $'\t2\tFailing\t'"https://github.com/example/repo/pull/2"$'\tfailing\tb' "failing rollup"
assert_contains "$prs" $'\t3\tPending\t'"https://github.com/example/repo/pull/3"$'\tpending\tc' "pending rollup"
assert_contains "$prs" $'\t4\tNo CI with tab\t'"https://github.com/example/repo/pull/4"$'\tnone\td' "none rollup, tab flattened"
assert_contains "$out" $'PRS\t'"$G"$'\tOK' "PR lookup ok"
assert_contains "$(cat "$STUB_LOG")" "--limit 20" "ghPrLimit passed"
assert_contains "$out" $'FETCH\t'"$G"$'\tOK' "fetch ok for github-style remote"
assert_eq $'GH\tok\t\t' "$(grep -P '^GH\t' <<<"$out")" "healthy gh emits one ok record"
assert_eq "GH" "$(head -n1 <<<"$out" | cut -f1)" "GH record comes first"

# gh logged out: one GH record, rows skip the PR lookup
: > "$STUB_LOG"
touch "$STUB_DIR/gh-logged-out"
out=$(omagit-remote "$G")
assert_contains "$out" $'GH\tlogged-out\t\t' "logged-out GH record"
assert_contains "$out" $'PRS\t'"$G"$'\tSKIP\tgh logged-out' "PR lookup skipped when logged out"
assert_not_contains "$out" $'PRS\t'"$G"$'\tERR' "no per-row gh error"
assert_not_contains "$(cat "$STUB_LOG")" "gh pr list" "gh pr list not called when logged out"
assert_contains "$out" $'DONE\t'"$G" "still finishes"
rm "$STUB_DIR/gh-logged-out"

# gh-fail knob (everything fails with an auth message) also reads as logged out
touch "$STUB_DIR/gh-fail"
out=$(omagit-remote "$G")
assert_contains "$out" $'GH\tlogged-out' "gh-fail classified as logged out"
rm "$STUB_DIR/gh-fail"

# rate limited: reset epoch carried in the record
echo '{"resources":{"core":{"limit":60,"remaining":0,"reset":1893456000},"graphql":{"limit":5000,"remaining":10,"reset":1}}}' > "$STUB_DIR/rate_limit.json"
: > "$STUB_LOG"
out=$(omagit-remote "$G")
assert_contains "$out" $'GH\trate-limited\t1893456000\t' "rate-limited GH record with reset"
assert_contains "$out" $'PRS\t'"$G"$'\tSKIP\tgh rate-limited' "PR lookup skipped when rate limited"
assert_not_contains "$(cat "$STUB_LOG")" "gh pr list" "gh pr list not called when rate limited"
echo '{"resources":{"core":{"limit":5000,"remaining":5,"reset":1},"graphql":{"limit":5000,"remaining":0,"reset":1893456001}}}' > "$STUB_DIR/rate_limit.json"
assert_contains "$(omagit-remote "$G")" $'GH\trate-limited\t1893456001' "graphql exhaustion detected"
rm "$STUB_DIR/rate_limit.json"

# preflight ok but the pr list call itself is rate limited: SKIP + GH record, not ERR
touch "$STUB_DIR/pr-list-limited"
out=$(omagit-remote "$G")
assert_contains "$out" $'GH\trate-limited' "pr list rate limit reported as GH record"
assert_contains "$out" $'PRS\t'"$G"$'\tSKIP\tgh rate-limited' "pr list rate limit skips the row"
rm "$STUB_DIR/pr-list-limited"

# gh missing: hermetic PATH with only the tools the helper needs
BIN="$TMP/nogh-bin"; mkdir -p "$BIN"
for t in bash git jq timeout grep xargs realpath dirname cat mkdir mv rm sed tr sort cut date; do
  p=$(command -v "$t" 2>/dev/null) && ln -sf "$p" "$BIN/$t"
done
out=$(PATH="$BIN" "$ROOT/bin/omagit-remote" "$G")
assert_contains "$out" $'GH\tmissing' "missing gh GH record"
assert_contains "$out" $'PRS\t'"$G"$'\tSKIP\tgh missing' "PR lookup skipped without gh"
assert_contains "$out" $'FETCH\t'"$G"$'\tOK' "fetch still works without gh"

# fetch auth failure on a github origin gets the credential-helper hint
cat > "$TMP/deny-upload-pack" <<'SH'
#!/bin/bash
echo "fatal: could not read Username for 'https://github.com': terminal prompts disabled" >&2
exit 128
SH
chmod +x "$TMP/deny-upload-pack"
git -C "$G" config remote.origin.uploadpack "$TMP/deny-upload-pack"
out=$(omagit-remote "$G")
assert_contains "$out" $'FETCH\t'"$G"$'\tERR' "fetch auth failure reported"
assert_contains "$out" "gh auth setup-git" "fetch auth failure hints at the credential helper"
git -C "$G" config --unset remote.origin.uploadpack

# parse failure
echo "not json" > "$STUB_DIR/prs.json"
out=$(omagit-remote "$G")
assert_contains "$out" $'PRS\t'"$G"$'\tERR' "parse failure reported"
assert_eq "0" "$(grep -c -P '^PR\t' <<<"$out" || true)" "no PR rows on parse failure"

# no remote at all
L="$TMP/local"; make_repo "$L"
out=$(omagit-remote "$L")
assert_contains "$out" $'FETCH\t'"$L"$'\tSKIP' "no-remote fetch skipped"

# several repos in one call, each terminated
out=$(omagit-remote "$R" "$G" "$L")
assert_eq "3" "$(grep -c -P '^DONE\t' <<<"$out")" "DONE per repo"

finish
