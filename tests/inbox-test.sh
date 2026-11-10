#!/bin/bash
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
omagit-config settings >/dev/null

export OMAGIT_CACHE_DIR="$TMP/cache"
CACHE="$OMAGIT_CACHE_DIR/inbox.tsv"
T0=1800000000
rec()  { grep -P "^$2\t" <<<"$1" || true; }   # rec <output> <TYPE>
sec()  { grep -P "^SECTION\t$2\t" <<<"$1" || true; }   # sec <output> <section>
fetch() { OMAGIT_NOW=$T0 omagit-inbox fetch "$@"; }

U=https://github.com/example
# tracked repos: https origin (mixed case), scp-style ssh origin, ssh:// origin
A="$TMP/a"; make_repo "$A"; git -C "$A" remote add origin https://github.com/Example/Alpha.git
B="$TMP/b"; make_repo "$B"; git -C "$B" remote add origin git@github.com:example/beta
C="$TMP/c"; make_repo "$C"; git -C "$C" remote add origin ssh://git@github.com/example/gamma.git

cat > "$STUB_DIR/graphql.json" <<JSON
{"data":{
 "reviews":{"nodes":[
  {"number":1,"title":"Review me","url":"$U/alpha/pull/1","isDraft":false,"updatedAt":"2026-11-01T00:00:00Z","author":{"login":"alice"},"repository":{"nameWithOwner":"example/alpha","isArchived":false},"commits":{"nodes":[]}},
  {"number":2,"title":"Draft one","url":"$U/alpha/pull/2","isDraft":true,"updatedAt":"2026-11-01T00:00:00Z","author":{"login":"bob"},"repository":{"nameWithOwner":"example/alpha","isArchived":false},"commits":{"nodes":[]}},
  {"number":3,"title":"Archived","url":"$U/old/pull/3","isDraft":false,"updatedAt":"2026-11-01T00:00:00Z","author":{"login":"bob"},"repository":{"nameWithOwner":"example/old","isArchived":true},"commits":{"nodes":[]}},
  {"number":4,"title":"Tab\there","url":"$U/other/pull/4","isDraft":false,"updatedAt":"2026-11-02T00:00:00Z","author":null,"repository":{"nameWithOwner":"example/other","isArchived":false},"commits":{"nodes":[]}}
 ]},
 "prs":{"nodes":[
  {"number":10,"title":"ok","url":"$U/beta/pull/10","isDraft":false,"updatedAt":"2026-11-03T00:00:00Z","repository":{"nameWithOwner":"example/beta","isArchived":false},"commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"SUCCESS"}}}]}},
  {"number":11,"title":"fail","url":"$U/gamma/pull/11","isDraft":true,"updatedAt":"2026-11-03T00:00:00Z","repository":{"nameWithOwner":"example/gamma","isArchived":false},"commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"FAILURE"}}}]}},
  {"number":12,"title":"err","url":"$U/x/pull/12","isDraft":false,"updatedAt":"2026-11-03T00:00:00Z","repository":{"nameWithOwner":"example/x","isArchived":false},"commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"ERROR"}}}]}},
  {"number":13,"title":"pend","url":"$U/x/pull/13","isDraft":false,"updatedAt":"2026-11-03T00:00:00Z","repository":{"nameWithOwner":"example/x","isArchived":false},"commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"PENDING"}}}]}},
  {"number":14,"title":"exp","url":"$U/x/pull/14","isDraft":false,"updatedAt":"2026-11-03T00:00:00Z","repository":{"nameWithOwner":"example/x","isArchived":false},"commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"EXPECTED"}}}]}},
  {"number":15,"title":"null","url":"$U/x/pull/15","isDraft":false,"updatedAt":"2026-11-03T00:00:00Z","repository":{"nameWithOwner":"example/x","isArchived":false},"commits":{"nodes":[{"commit":{"statusCheckRollup":null}}]}},
  {"number":16,"title":"archived pr","url":"$U/old/pull/16","isDraft":false,"updatedAt":"2026-11-03T00:00:00Z","repository":{"nameWithOwner":"example/old","isArchived":true},"commits":{"nodes":[]}}
 ]},
 "issues":{"nodes":[
  {"number":20,"title":"Bug\tone","url":"$U/alpha/issues/20","updatedAt":"2026-11-04T00:00:00Z","repository":{"nameWithOwner":"example/alpha","isArchived":false}},
  {"number":21,"title":"Old archived issue","url":"$U/old/issues/21","updatedAt":"2026-11-04T00:00:00Z","repository":{"nameWithOwner":"example/old","isArchived":true}},
  {"number":22,"title":"Elsewhere","url":"$U/x/issues/22","updatedAt":"2026-11-05T00:00:00Z","repository":{"nameWithOwner":"example/x","isArchived":false}}
 ]}}}
JSON
cat > "$STUB_DIR/notifications.json" <<JSON
[
 {"id":"101","unread":true,"reason":"review_requested","updated_at":"2026-11-05T10:00:00Z","subject":{"title":"Fix\tthing","url":"https://api.github.com/repos/example/alpha/pulls/7","type":"PullRequest"},"repository":{"full_name":"example/alpha","html_url":"$U/alpha"}},
 {"id":"102","unread":true,"reason":"mention","updated_at":"2026-11-05T09:00:00Z","subject":{"title":"An issue","url":"https://api.github.com/repos/example/other/issues/8","type":"Issue"},"repository":{"full_name":"example/other","html_url":"$U/other"}},
 {"id":"103","unread":true,"reason":"subscribed","updated_at":"2026-11-05T10:00:00Z","subject":{"title":"A discussion","url":null,"type":"Discussion"},"repository":{"full_name":"example/beta","html_url":"$U/beta"}},
 {"id":"104","unread":true,"reason":"ci_activity","updated_at":"2026-11-04T10:00:00Z","subject":{"title":"A commit","url":"https://api.github.com/repos/example/other/commits/abc123","type":"Commit"},"repository":{"full_name":"example/other","html_url":"$U/other"}}
]
JSON

cp "$STUB_DIR/graphql.json" "$TMP/gql.full"

# --- happy path ----------------------------------------------------------------
out=$(fetch "$A" "$B" "$C")
assert_eq $'GH\tok\t\t' "$(rec "$out" GH)" "gh status record"
assert_eq "GH" "$(head -n1 <<<"$out" | cut -f1)" "GH first"
assert_eq $'LOGIN\toctocat' "$(rec "$out" LOGIN)" "login record"
assert_eq $'INBOXDONE\t'"$T0" "$(rec "$out" INBOXDONE)" "inbox terminator"
assert_eq "INBOXDONE" "$(tail -n1 <<<"$out" | cut -f1)" "terminator last"
rv=$(rec "$out" REVIEW)
assert_eq "2" "$(wc -l <<<"$rv")" "drafts and archived dropped from reviews"
assert_contains "$rv" $'REVIEW\texample/alpha\t1\tReview me\t'"$U/alpha/pull/1"$'\talice\t2026-11-01T00:00:00Z\t'"$A" "review record, localPath via https origin (case-insensitive)"
assert_contains "$rv" $'\t4\tTab here\t'"$U/other/pull/4"$'\t\t2026-11-02T00:00:00Z\t' "tab flattened, no author, untracked path empty"
assert_not_contains "$rv" "Draft one" "draft review dropped"
assert_not_contains "$out" "Archived" "archived review dropped"
pr=$(rec "$out" MYPR)
assert_eq "6" "$(wc -l <<<"$pr")" "archived PR dropped, six remain"
assert_contains "$pr" $'MYPR\texample/beta\t10\tok\t'"$U/beta/pull/10"$'\tpassing\t2026-11-03T00:00:00Z\t'"$B"$'\t0' "passing + scp-style ssh origin match"
assert_contains "$pr" $'\t11\tfail\t'"$U/gamma/pull/11"$'\tfailing\t2026-11-03T00:00:00Z\t'"$C"$'\t1' "failing, ssh:// match, draft flag"
assert_contains "$pr" $'\t12\terr\t'"$U/x/pull/12"$'\tfailing\t' "ERROR -> failing"
assert_contains "$pr" $'\t13\tpend\t'"$U/x/pull/13"$'\tpending\t' "PENDING"
assert_contains "$pr" $'\t14\texp\t'"$U/x/pull/14"$'\tpending\t' "EXPECTED -> pending"
assert_contains "$pr" $'\t15\tnull\t'"$U/x/pull/15"$'\tnone\t2026-11-03T00:00:00Z\t\t0' "null rollup -> none, untracked"
assert_not_contains "$out" "archived pr" "archived PR dropped"
assert_eq $'SECTION\treviews\tOK\t2' "$(sec "$out" reviews)" "reviews section ok"
assert_eq $'SECTION\tprs\tOK\t6' "$(sec "$out" prs)" "prs section ok"
assert_eq "SECTION	notifications" "$(grep -P '^SECTION\t' <<<"$out" | sed -n 1p | cut -f1,2)" "notifications section first"
assert_eq "reviews prs issues actions" "$(grep -P '^SECTION\t' <<<"$out" | sed -n '2,5p' | cut -f2 | paste -sd' ')" "section order"

# 08: notifications
nf=$(rec "$out" NOTIF)
assert_eq "4" "$(wc -l <<<"$nf")" "four notifications"
assert_contains "$nf" $'NOTIF\t101\texample/alpha\tFix thing\treview_requested\tPullRequest\t'"$U/alpha/pull/7"$'\t2026-11-05T10:00:00Z\t'"$A" "PR notification: url converted, tab flattened, tracked localPath"
assert_contains "$nf" $'NOTIF\t102\texample/other\tAn issue\tmention\tIssue\t'"$U/other/issues/8"$'\t2026-11-05T09:00:00Z\t' "issue notification url"
assert_contains "$nf" $'NOTIF\t103\texample/beta\tA discussion\tsubscribed\tDiscussion\t'"$U/beta"$'\t2026-11-05T10:00:00Z\t'"$B" "null subject url falls back to repo url"
assert_contains "$nf" $'\t'"$U/other/commit/abc123"$'\t' "commit url"
assert_eq $'SECTION\tnotifications\tOK\t4' "$(sec "$out" notifications)" "notifications section ok"
assert_contains "$(cat "$STUB_LOG")" "gh api notifications?per_page=50" "notifications call"

# 09: issues
is=$(rec "$out" ISSUE)
assert_eq "2" "$(wc -l <<<"$is")" "archived issue dropped"
assert_contains "$is" $'ISSUE\texample/alpha\t20\tBug one\t'"$U/alpha/issues/20"$'\t2026-11-04T00:00:00Z\t'"$A" "issue record"
assert_not_contains "$out" "Old archived issue" "archived issue gone"
assert_eq $'SECTION\tissues\tOK\t2' "$(sec "$out" issues)" "issues section ok"
assert_eq $'SECTION\tactions\tOK\t0' "$(sec "$out" actions)" "actions ok with nothing running"
assert_contains "$(cat "$STUB_LOG")" "assignee:@me" "issues query"
assert_eq "1" "$(grep -c 'gh api graphql' "$STUB_LOG")" "one graphql call"
assert_contains "$(cat "$STUB_LOG")" "review-requested:@me" "review query"

# --- cache ---------------------------------------------------------------------
assert_file "$CACHE" "cache written"
assert_eq $'CACHE\toctocat\t'"$T0" "$(head -n1 "$CACHE")" "cache header"
assert_eq "$(grep -P '^(NOTIF|REVIEW|MYPR|ISSUE|RUN|SECTION)\t' <<<"$out")" "$(tail -n +2 "$CACHE")" "cache holds item and section records"
: > "$STUB_LOG"
cached=$(omagit-inbox cached)
assert_eq "$(cat "$CACHE")" "$cached" "cached prints the cache for the same login"
assert_not_contains "$(cat "$STUB_LOG")" "gh api" "cached makes no gh api call"
echo OctoCat > "$STUB_DIR/login"
assert_eq "$(cat "$CACHE")" "$(omagit-inbox cached)" "login compare is case-insensitive"
echo someoneelse > "$STUB_DIR/login"
assert_eq "" "$(omagit-inbox cached)" "cached prints nothing after login change"
assert_no_file "$CACHE" "cache deleted after login change"
omagit-inbox cached >/dev/null; assert_eq "0" "$?" "cached exits 0 without a cache"
rm "$STUB_DIR/login"

# --- partial failure: errors + null alias -----------------------------------------
fetch "$A" "$B" "$C" >/dev/null
cp "$CACHE" "$TMP/cache.before"
cat > "$STUB_DIR/graphql.json" <<JSON
{"data":{"reviews":null,"issues":{"nodes":[]},"prs":{"nodes":[
 {"number":10,"title":"ok","url":"$U/beta/pull/10","isDraft":false,"updatedAt":"2026-11-03T00:00:00Z","repository":{"nameWithOwner":"example/beta","isArchived":false},"commits":{"nodes":[]}}]}},
 "errors":[{"message":"Could not resolve review search","path":["reviews"]}]}
JSON
out=$(OMAGIT_NOW=$((T0 + 100)) omagit-inbox fetch "$B")
assert_eq $'SECTION\treviews\tERR\tCould not resolve review search' "$(sec "$out" reviews)" "failed section is ERR with message"
assert_eq $'SECTION\tprs\tOK\t1' "$(sec "$out" prs)" "other section intact"
assert_eq "1" "$(rec "$out" MYPR | wc -l)" "other section's items emitted"
assert_eq "INBOXDONE" "$(tail -n1 <<<"$out" | cut -f1)" "still terminates"
assert_eq "$(cat "$TMP/cache.before")" "$(cat "$CACHE")" "cache not rewritten on partial failure"

# --- total failure -----------------------------------------------------------------
touch "$STUB_DIR/graphql-fail"
out=$(fetch "$B")
assert_eq $'SECTION\treviews\tERR\tgh: graphql: connection reset' "$(sec "$out" reviews)" "no body: reviews ERR"
assert_contains "$(sec "$out" prs)" $'SECTION\tprs\tERR' "no body: prs ERR"
for n in notifications issues actions; do assert_contains "$(sec "$out" $n)" $'SECTION\t'"$n"$'\tERR' "no body: $n ERR"; done
assert_eq "$(cat "$TMP/cache.before")" "$(cat "$CACHE")" "cache untouched after total failure"
rm "$STUB_DIR/graphql-fail"
echo '{"errors":[{"message":"boom"}]}' > "$STUB_DIR/graphql.json"
out=$(fetch "$B")
assert_eq $'SECTION\treviews\tERR\tboom' "$(sec "$out" reviews)" "errors without data: ERR"
rm "$STUB_DIR/graphql.json"

# --- gh states: no graphql call ------------------------------------------------------
: > "$STUB_LOG"
touch "$STUB_DIR/gh-logged-out"
out=$(fetch "$B")
assert_eq $'GH\tlogged-out\t\tgh is logged out' "$(rec "$out" GH)" "logged-out GH record"
assert_eq $'SECTION\treviews\tSKIP\tgh logged-out' "$(sec "$out" reviews)" "reviews skipped"
assert_eq $'SECTION\tprs\tSKIP\tgh logged-out' "$(sec "$out" prs)" "prs skipped"
for n in notifications issues actions; do assert_eq $'SECTION\t'"$n"$'\tSKIP\tgh logged-out' "$(sec "$out" $n)" "$n skipped when logged out"; done
assert_contains "$out" $'INBOXDONE\t' "terminates"
assert_not_contains "$(cat "$STUB_LOG")" "graphql" "no graphql call when logged out"
rm "$STUB_DIR/gh-logged-out"
echo '{"resources":{"core":{"limit":60,"remaining":0,"reset":1893456000},"graphql":{"limit":5000,"remaining":10,"reset":1}}}' > "$STUB_DIR/rate_limit.json"
: > "$STUB_LOG"
out=$(fetch "$B")
assert_eq $'GH\trate-limited\t1893456000\tGitHub rate limit reached' "$(rec "$out" GH)" "rate-limited GH record"
assert_eq $'SECTION\tprs\tSKIP\tgh rate-limited' "$(sec "$out" prs)" "prs skipped"
assert_not_contains "$(cat "$STUB_LOG")" "graphql" "no graphql call when rate limited"
assert_not_contains "$(cat "$STUB_LOG")" "api user" "no login call when rate limited"
rm "$STUB_DIR/rate_limit.json"
assert_eq "$(cat "$TMP/cache.before")" "$(cat "$CACHE")" "cache untouched when skipped"

# --- 08: notifications failure modes ---------------------------------------------------
cp "$TMP/gql.full" "$STUB_DIR/graphql.json"
rm -f "$CACHE"; touch "$STUB_DIR/notifications-forbidden"
out=$(fetch "$A" "$B")
assert_eq $'GH\tmissing-scope\t\tnotifications' "$(grep -P '^GH\tmissing-scope' <<<"$out")" "missing-scope GH record"
assert_eq $'SECTION\tnotifications\tSKIP\tmissing notifications scope' "$(sec "$out" notifications)" "notifications skipped"
assert_eq $'SECTION\treviews\tOK\t2' "$(sec "$out" reviews)" "reviews still render"
assert_eq "6" "$(rec "$out" MYPR | wc -l)" "prs still render"
assert_file "$CACHE" "missing scope does not block the cache write"
rm "$STUB_DIR/notifications-forbidden"
fetch "$A" "$B" >/dev/null; cp "$CACHE" "$TMP/cache.before"
touch "$STUB_DIR/notifications-fail"
out=$(OMAGIT_NOW=$((T0 + 100)) omagit-inbox fetch "$A" "$B")
assert_eq $'SECTION\tnotifications\tERR\tgh: HTTP 500: server error' "$(sec "$out" notifications)" "generic failure is ERR"
assert_eq $'SECTION\treviews\tOK\t2' "$(sec "$out" reviews)" "reviews intact"
assert_eq "6" "$(rec "$out" MYPR | wc -l)" "prs intact"
assert_eq "$(cat "$TMP/cache.before")" "$(cat "$CACHE")" "cache not rewritten on notifications ERR"
rm "$STUB_DIR/notifications-fail"

# --- 08: mark-read ----------------------------------------------------------------------
fetch "$A" "$B" >/dev/null
: > "$STUB_LOG"
out=$(omagit-inbox mark-read 102); rc=$?
assert_eq "0" "$rc" "mark-read exit 0"
assert_eq $'OK\tmarked read' "$(result_line "$out")" "mark-read RESULT OK"
assert_eq "gh api --method PATCH notifications/threads/102" "$(cat "$STUB_LOG")" "exact PATCH call"
assert_not_contains "$(cat "$CACHE")" $'NOTIF\t102\t' "thread removed from cache"
assert_contains "$(cat "$CACHE")" $'NOTIF\t101\t' "other threads stay cached"
assert_contains "$(cat "$CACHE")" $'SECTION\tnotifications\tOK\t3' "cached count fixed"
: > "$STUB_LOG"
out=$(omagit-inbox mark-read "1; rm") && fail "invalid id should exit 1"
assert_eq "ERR" "$(result_line "$out" | cut -f1)" "invalid id RESULT ERR"
assert_eq "" "$(cat "$STUB_LOG")" "invalid id makes no gh call"
out=$(omagit-inbox mark-read) && fail "missing id should exit 1"
assert_eq "ERR" "$(result_line "$out" | cut -f1)" "missing id RESULT ERR"
cp "$CACHE" "$TMP/cache.before"; touch "$STUB_DIR/patch-fail"
out=$(omagit-inbox mark-read 101) && fail "failed PATCH should exit 1"
assert_eq $'ERR\tgh: HTTP 500: patch failed' "$(result_line "$out")" "PATCH failure reported"
assert_eq "$(cat "$TMP/cache.before")" "$(cat "$CACHE")" "cache unchanged after failed mark-read"
rm "$STUB_DIR/patch-fail"

# --- 08: mark-all -----------------------------------------------------------------------
fetch "$A" "$B" >/dev/null
: > "$STUB_LOG"
out=$(omagit-inbox mark-all 2026-11-05T09:00:00Z 102); rc=$?
assert_eq "0" "$rc" "mark-all exit 0"
assert_eq "OK" "$(result_line "$out" | cut -f1)" "mark-all RESULT OK"
assert_eq $'gh api --method PUT notifications -f last_read_at=2026-11-05T08:59:59Z\ngh api --method PATCH notifications/threads/102' "$(cat "$STUB_LOG")" "bulk PUT one second before, then PATCH per id"
assert_not_contains "$(cat "$CACHE")" $'NOTIF\t102\t' "boundary thread pruned"
assert_not_contains "$(cat "$CACHE")" $'NOTIF\t104\t' "older thread pruned"
assert_contains "$(cat "$CACHE")" $'NOTIF\t101\t' "newer thread stays"
assert_contains "$(cat "$CACHE")" $'NOTIF\t103\t' "newer thread stays (2)"
assert_contains "$(cat "$CACHE")" $'SECTION\tnotifications\tOK\t2' "count fixed after mark-all"
: > "$STUB_LOG"
omagit-inbox mark-all 2026-11-05T10:00:00Z 101 103 >/dev/null
assert_eq "3" "$(wc -l < "$STUB_LOG")" "PUT + two PATCH"
assert_contains "$(cat "$STUB_LOG")" "notifications/threads/103" "second id patched"
fetch "$A" "$B" >/dev/null; cp "$CACHE" "$TMP/cache.before"; : > "$STUB_LOG"
touch "$STUB_DIR/put-fail"
out=$(omagit-inbox mark-all 2026-11-05T10:00:00Z 101 103) && fail "PUT failure should exit 1"
assert_eq "ERR" "$(result_line "$out" | cut -f1)" "PUT failure ERR"
assert_not_contains "$(cat "$STUB_LOG")" "PATCH" "no PATCH after PUT failure"
assert_eq "$(cat "$TMP/cache.before")" "$(cat "$CACHE")" "cache untouched after PUT failure"
rm "$STUB_DIR/put-fail"
touch "$STUB_DIR/patch-fail"
out=$(omagit-inbox mark-all 2026-11-05T10:00:00Z 101 103) && fail "PATCH failure should exit 1"
assert_contains "$(result_line "$out")" "2 of 2" "PATCH failures counted"
assert_no_file "$CACHE" "cache deleted when state is uncertain"
rm "$STUB_DIR/patch-fail"
: > "$STUB_LOG"
for args in "2026-11-05 101" "2026-11-05T10:00:00Z" "2026-11-05T10:00:00Z abc"; do
  # shellcheck disable=SC2086
  out=$(omagit-inbox mark-all $args) && fail "mark-all $args should exit 1"
  assert_eq "ERR" "$(result_line "$out" | cut -f1)" "mark-all $args ERR"
done
assert_eq "" "$(cat "$STUB_LOG")" "invalid mark-all makes no gh call"

# --- 09: issues alias error isolated ----------------------------------------------------
cat > "$STUB_DIR/graphql.json" <<JSON
{"data":{"reviews":{"nodes":[]},"prs":{"nodes":[]},"issues":null},
 "errors":[{"message":"Could not resolve issue search","path":["issues"]}]}
JSON
out=$(fetch "$A")
assert_eq $'SECTION\tissues\tERR\tCould not resolve issue search' "$(sec "$out" issues)" "issues ERR"
assert_eq $'SECTION\treviews\tOK\t0' "$(sec "$out" reviews)" "reviews unaffected by issues error"
assert_eq $'SECTION\tnotifications\tOK\t4' "$(sec "$out" notifications)" "notifications unaffected"
cp "$TMP/gql.full" "$STUB_DIR/graphql.json"

# --- 09: Actions runs ---------------------------------------------------------------------
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
run() { # id wf_id name status conclusion|- branch updated_offset created_offset
  local concl=null; [[ $5 != - ]] && concl="\"$5\""
  printf '{"id":%s,"workflow_id":%s,"name":"%s","display_title":"title %s","html_url":"%s/alpha/actions/runs/%s","status":"%s","conclusion":%s,"head_branch":"%s","updated_at":"%s","created_at":"%s"}' \
    "$1" "$2" "$3" "$1" "$U" "$1" "$4" "$concl" "$6" "$(iso $((T0 - $7)))" "$(iso $((T0 - $8)))"
}
{
  echo '{"workflow_runs":['
  run 1 1 CI in_progress - main 100 200; echo ,
  run 2 2 Lint queued - feat 50 60; echo ,
  run 3 3 Deploy completed failure main 1000 1100; echo ,
  run 4 4 Tests completed failure feat 5000 5100; echo ,
  run 5 4 Tests completed success feat 1000 1100; echo ,
  run 6 6 Old completed failure main $((4 * 86400)) $((4 * 86400 + 60)); echo ,
  run 7 7 Fine completed success main 900 950; echo ,
  run 8 8 Slow completed timed_out main 2000 2100; echo ,
  run 9 9 Cancelled completed cancelled main 800 850
  echo ']}'
} > "$STUB_DIR/runs-example-alpha.json"
{ echo '{"workflow_runs":['; run 20 20 CI waiting - main 10 20; echo ']}'; } > "$STUB_DIR/runs-example-beta.json"
D="$TMP/d"; make_repo "$D"; git -C "$D" remote add origin https://gitlab.com/example/delta
A2="$TMP/a2"; make_repo "$A2"; git -C "$A2" remote add origin git@github.com:example/alpha.git
: > "$STUB_LOG"
out=$(fetch "$A" "$B" "$D" "$A2")
runs=$(rec "$out" RUN)
assert_eq "5" "$(wc -l <<<"$runs")" "running + failed runs only"
assert_eq "2 1 3 8 20" "$(cut -f3 <<<"$runs" | paste -sd' ')" "sorted by repo then newest first"
assert_eq $'RUN\texample/alpha\t2\tLint\ttitle 2\t'"$U/alpha/actions/runs/2"$'\trunning\tfeat\t'"$(iso $((T0 - 50)))"$'\t'"$A" "$(sed -n 1p <<<"$runs")" "running run record"
assert_contains "$runs" $'RUN\texample/alpha\t3\tDeploy\ttitle 3\t' "failed run present"
assert_contains "$runs" $'\tfailed\tmain\t'"$(iso $((T0 - 1000)))"$'\t'"$A" "failed record fields, first tracked path wins"
assert_contains "$runs" $'RUN\texample/beta\t20\tCI\ttitle 20\t' "waiting counts as running"
assert_not_contains "$runs" $'\t4\tTests' "superseded failure dropped"
assert_not_contains "$runs" $'\t6\tOld' "failure older than 3 days dropped"
assert_not_contains "$runs" $'\t7\tFine' "successful run dropped"
assert_not_contains "$runs" $'\t9\tCancelled' "cancelled run dropped"
assert_eq $'SECTION\tactions\tOK\t5' "$(sec "$out" actions)" "actions section count"
assert_eq "2" "$(grep -c 'actions/runs' "$STUB_LOG")" "one call per distinct tracked github repo"
assert_contains "$(cat "$STUB_LOG")" "gh api repos/example/alpha/actions/runs?per_page=30" "alpha queried"
assert_contains "$(cat "$STUB_LOG")" "gh api repos/example/beta/actions/runs?per_page=30" "beta queried"
assert_not_contains "$(cat "$STUB_LOG")" "delta" "non-github tracked repo not queried"
assert_not_contains "$(cat "$STUB_LOG")" "example/other/actions" "untracked repo not queried"
: > "$STUB_LOG"
out=$(fetch)
assert_eq $'SECTION\tactions\tOK\t0' "$(sec "$out" actions)" "no tracked repos: actions OK 0"
assert_eq "0" "$(grep -c 'actions/runs' "$STUB_LOG" || true)" "no tracked repos: no runs call"
touch "$STUB_DIR/runs-fail-example-beta"
out=$(fetch "$A" "$B")
assert_eq $'SECTION\tactions\tOK\t4' "$(sec "$out" actions)" "one repo failing is skipped silently"
rm "$STUB_DIR/runs-fail-example-beta"
touch "$STUB_DIR/runs-fail"
rm -f "$CACHE"
out=$(fetch "$A" "$B")
assert_eq $'SECTION\tactions\tERR\tgh: HTTP 500: server error' "$(sec "$out" actions)" "all calls failing: ERR"
assert_eq $'SECTION\treviews\tOK\t2' "$(sec "$out" reviews)" "other sections intact"
assert_eq "4" "$(rec "$out" NOTIF | wc -l)" "notifications intact"
assert_no_file "$CACHE" "actions ERR blocks the cache write"
rm "$STUB_DIR/runs-fail"

finish
