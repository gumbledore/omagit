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
assert_not_contains "$(cat "$STUB_LOG" 2>/dev/null)" "gh pr list" "gh not called for non-github"

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

# gh failure: one-line error, still finishes
touch "$STUB_DIR/gh-fail"
out=$(omagit-remote "$G")
assert_contains "$out" $'PRS\t'"$G"$'\tERR' "gh failure reported"
assert_contains "$out" "authentication" "gh stderr captured"
rm "$STUB_DIR/gh-fail"

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
