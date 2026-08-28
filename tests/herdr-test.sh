#!/bin/bash
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
omagit-config settings >/dev/null
R="$TMP/repo"; make_repo "$R"
O="$TMP/other"; make_repo "$O"

# status: agents keyed by cwd
cat > "$STUB_DIR/agents.json" <<JSON
[{"agent":"claude","agent_status":"working","cwd":"$R","workspace_id":"wA","pane_id":"wA:p2"},
 {"agent":"claude","agent_status":"idle","cwd":"$O","workspace_id":"wB","pane_id":"wB:p1"}]
JSON
out=$(omagit-herdr status)
assert_contains "$out" $'STATUS\t'"$R"$'\tworking' "working status by cwd"
assert_contains "$out" $'STATUS\t'"$O"$'\tidle' "idle status by cwd"
echo '[]' > "$STUB_DIR/agents.json"

# terminal: create then reuse
out=$(omagit-herdr terminal "$R" "repo")
assert_contains "$(result_line "$out")" "OK" "create ok"
assert_contains "$(cat "$STUB_LOG")" "workspace create --cwd $R --label repo --focus" "created with cwd/label/focus"
: > "$STUB_LOG"
out=$(omagit-herdr terminal "$R" "repo")
assert_contains "$(cat "$STUB_LOG")" "workspace focus w1" "second call focuses existing"
assert_not_contains "$(cat "$STUB_LOG")" "workspace create" "no duplicate workspace"

# agent: existing workspace with a free pane -> start in that pane
: > "$STUB_LOG"
out=$(omagit-herdr agent "$R" "repo" claude)
assert_contains "$(result_line "$out")" "OK" "agent start ok"
assert_contains "$(cat "$STUB_LOG")" "agent start repo --kind claude --pane w1:p1" "started in free pane"
# pane now busy -> new tab in same workspace
cat > "$STUB_DIR/agents.json" <<JSON
[{"agent":"claude","agent_status":"working","cwd":"$R","workspace_id":"w1","pane_id":"w1:p1"}]
JSON
: > "$STUB_LOG"
out=$(omagit-herdr agent "$R" "repo" claude)
assert_contains "$(cat "$STUB_LOG")" "tab create --workspace w1 --cwd $R" "new tab when pane busy"
assert_contains "$(cat "$STUB_LOG")" "--pane w1:p2" "agent started in new tab pane"
# no workspace -> create, start in root pane
: > "$STUB_LOG"
out=$(omagit-herdr agent "$O" "other" claude)
assert_contains "$(cat "$STUB_LOG")" "workspace create --cwd $O" "workspace created for agent"
assert_contains "$(cat "$STUB_LOG")" "--pane w2:p1" "agent started in root pane"
# label sanitized into a valid agent name
: > "$STUB_LOG"
omagit-herdr agent "$O" "Data Analysis/Neuronchat" claude >/dev/null
assert_contains "$(cat "$STUB_LOG")" "agent start data-analysis-neuronchat --kind" "agent name sanitized"
touch "$STUB_DIR/agent-start-fail"
res=$(result_line "$(omagit-herdr agent "$O" "other" claude || true)")
assert_contains "$res" "ERR" "agent start failure reported"
rm "$STUB_DIR/agent-start-fail"

# server down
touch "$STUB_DIR/herdr-down"
res=$(result_line "$(omagit-herdr terminal "$R" "repo" || true)")
assert_contains "$res" "herdr" "down: message names herdr"
assert_contains "$res" "not running" "down: clear status"
assert_eq "" "$(omagit-herdr status || true)" "down: status silent"

finish
