#!/bin/bash
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
omagit-config settings >/dev/null

export OMAGIT_CACHE_DIR="$TMP/cache"
CACHE="$OMAGIT_CACHE_DIR/inbox.tsv"
T0=1800000000
rec()  { grep -P "^$2\t" <<<"$1" || true; }   # rec <output> <TYPE>
sec()  { grep -P '^SECTION\t' <<<"$1" | sed -n "$2p"; }   # sec <output> <nth>
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
 ]}}}
JSON

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
assert_eq $'SECTION\treviews\tOK\t2' "$(sec "$out" 1)" "reviews section ok"
assert_eq $'SECTION\tprs\tOK\t6' "$(sec "$out" 2)" "prs section ok"
assert_eq "1" "$(grep -c 'gh api graphql' "$STUB_LOG")" "one graphql call"
assert_contains "$(cat "$STUB_LOG")" "review-requested:@me" "review query"

# --- cache ---------------------------------------------------------------------
assert_file "$CACHE" "cache written"
assert_eq $'CACHE\toctocat\t'"$T0" "$(head -n1 "$CACHE")" "cache header"
assert_eq "$(grep -P '^(REVIEW|MYPR|SECTION)\t' <<<"$out")" "$(tail -n +2 "$CACHE")" "cache holds item and section records"
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
{"data":{"reviews":null,"prs":{"nodes":[
 {"number":10,"title":"ok","url":"$U/beta/pull/10","isDraft":false,"updatedAt":"2026-11-03T00:00:00Z","repository":{"nameWithOwner":"example/beta","isArchived":false},"commits":{"nodes":[]}}]}},
 "errors":[{"message":"Could not resolve review search","path":["reviews"]}]}
JSON
out=$(OMAGIT_NOW=$((T0 + 100)) omagit-inbox fetch "$B")
assert_eq $'SECTION\treviews\tERR\tCould not resolve review search' "$(sec "$out" 1)" "failed section is ERR with message"
assert_eq $'SECTION\tprs\tOK\t1' "$(sec "$out" 2)" "other section intact"
assert_eq "1" "$(rec "$out" MYPR | wc -l)" "other section's items emitted"
assert_eq "INBOXDONE" "$(tail -n1 <<<"$out" | cut -f1)" "still terminates"
assert_eq "$(cat "$TMP/cache.before")" "$(cat "$CACHE")" "cache not rewritten on partial failure"

# --- total failure -----------------------------------------------------------------
touch "$STUB_DIR/graphql-fail"
out=$(fetch "$B")
assert_eq $'SECTION\treviews\tERR\tgh: graphql: connection reset' "$(sec "$out" 1)" "no body: reviews ERR"
assert_contains "$(sec "$out" 2)" $'SECTION\tprs\tERR' "no body: prs ERR"
assert_eq "$(cat "$TMP/cache.before")" "$(cat "$CACHE")" "cache untouched after total failure"
rm "$STUB_DIR/graphql-fail"
echo '{"errors":[{"message":"boom"}]}' > "$STUB_DIR/graphql.json"
out=$(fetch "$B")
assert_eq $'SECTION\treviews\tERR\tboom' "$(sec "$out" 1)" "errors without data: ERR"
rm "$STUB_DIR/graphql.json"

# --- gh states: no graphql call ------------------------------------------------------
: > "$STUB_LOG"
touch "$STUB_DIR/gh-logged-out"
out=$(fetch "$B")
assert_eq $'GH\tlogged-out\t\tgh is logged out' "$(rec "$out" GH)" "logged-out GH record"
assert_eq $'SECTION\treviews\tSKIP\tgh logged-out' "$(sec "$out" 1)" "reviews skipped"
assert_eq $'SECTION\tprs\tSKIP\tgh logged-out' "$(sec "$out" 2)" "prs skipped"
assert_contains "$out" $'INBOXDONE\t' "terminates"
assert_not_contains "$(cat "$STUB_LOG")" "graphql" "no graphql call when logged out"
rm "$STUB_DIR/gh-logged-out"
echo '{"resources":{"core":{"limit":60,"remaining":0,"reset":1893456000},"graphql":{"limit":5000,"remaining":10,"reset":1}}}' > "$STUB_DIR/rate_limit.json"
: > "$STUB_LOG"
out=$(fetch "$B")
assert_eq $'GH\trate-limited\t1893456000\tGitHub rate limit reached' "$(rec "$out" GH)" "rate-limited GH record"
assert_eq $'SECTION\tprs\tSKIP\tgh rate-limited' "$(sec "$out" 2)" "prs skipped"
assert_not_contains "$(cat "$STUB_LOG")" "graphql" "no graphql call when rate limited"
assert_not_contains "$(cat "$STUB_LOG")" "api user" "no login call when rate limited"
rm "$STUB_DIR/rate_limit.json"
assert_eq "$(cat "$TMP/cache.before")" "$(cat "$CACHE")" "cache untouched when skipped"

finish
