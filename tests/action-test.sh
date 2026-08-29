#!/bin/bash
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
omagit-config settings >/dev/null

# --- diff ----------------------------------------------------------------------
ORIGIN="$TMP/origin.git"; make_origin "$ORIGIN"
R="$TMP/repo"; clone_repo "$ORIGIN" "$R"
printf 'hello\nworld\n' > "$R/README.md"
printf 'new\n' > "$R/added.txt"; git -C "$R" add added.txt
printf 'untracked\n' > "$R/loose.txt"
out=$(omagit-action diff "$R")
assert_not_contains "$out" "+++ 2/" "untracked diff drops git header"
assert_contains "$out" "README.md" "diff stat lists modified"
assert_contains "$out" "+world" "diff shows modified hunk"
assert_contains "$out" "+new" "diff shows staged added file"
assert_contains "$out" "new file: loose.txt" "untracked labeled new file"
assert_contains "$out" "+untracked" "untracked content shown"
git -C "$R" reset -q --hard; rm -f "$R/loose.txt"

# --- suggest -------------------------------------------------------------------
printf 'x\n' >> "$R/README.md"
out=$(omagit-action suggest "$R")
assert_eq "Update README.md" "$(grep -P '^MSG\t' <<<"$out" | cut -f2)" "single-file message"
assert_eq "work/$(date +%F)" "$(grep -P '^BRANCH\t' <<<"$out" | cut -f2)" "branch suggested on main"
mkdir -p "$R/docs"; printf 'a\n' > "$R/docs/a.md"; printf 'b\n' > "$R/docs/b.md"
out=$(omagit-action suggest "$R")
assert_contains "$(grep -P '^MSG\t' <<<"$out" | cut -f2)" "3 files" "multi-file message counts"
git -C "$R" switch -q -c feat
assert_eq "feat" "$(omagit-action suggest "$R" | grep -P '^BRANCH\t' | cut -f2)" "branch keeps current when not main"
git -C "$R" switch -q main; git -C "$R" branch -q -D feat

# --- commit: empty message / nothing to commit ----------------------------------
res=$(result_line "$(omagit-action commit "$R" "" "" || true)")
assert_contains "$res" "ERR" "empty message refused"
head_before=$(git -C "$R" rev-parse HEAD)
git -C "$R" stash -q -u
res=$(result_line "$(omagit-action commit "$R" "msg" "" || true)")
assert_contains "$res" "Nothing to commit" "clean tree refused"
assert_eq "$head_before" "$(git -C "$R" rev-parse HEAD)" "no mutation on refusal"
git -C "$R" stash pop -q

# --- commit: branch-first from main ------------------------------------------
out=$(omagit-action commit "$R" "Update docs" "work/2026-01-01")
assert_contains "$(result_line "$out")" "OK" "branch-first commit ok"
assert_eq "work/2026-01-01" "$(current_branch_of() { git -C "$1" symbolic-ref --short HEAD; }; current_branch_of "$R")" "switched to target branch"
assert_eq "Update docs" "$(git -C "$R" log -1 --format=%s)" "commit message used"
assert_eq "work/2026-01-01" "$(git -C "$R" rev-parse --abbrev-ref @{u} | sed 's|origin/||')" "upstream set on push"
assert_eq "0" "$(git -C "$R" status --porcelain | wc -l)" "tree clean after commit"

# --- commit on current feature branch ---------------------------------------
printf 'more\n' >> "$R/README.md"
out=$(omagit-action commit "$R" "More" "")
assert_contains "$(result_line "$out")" "OK" "commit on current branch ok"
assert_eq "0" "$(git -C "$R" rev-list --count @{u}..HEAD)" "pushed: ahead 0"

# --- commit to main directly when allowed ---------------------------------------
git -C "$R" switch -q main
printf 'direct\n' >> "$R/README.md"
out=$(omagit-action commit "$R" "Direct to main" "")
assert_contains "$(result_line "$out")" "OK" "direct main push ok when allowed"
assert_eq "main" "$(git -C "$R" symbolic-ref --short HEAD)" "still on main"
assert_eq "$(git -C "$R" rev-parse HEAD)" "$(git -C "$ORIGIN" rev-parse main)" "origin main updated"

# --- create-pr on a non-GitHub remote: pushes, explains no browser ---------------
N="$TMP/nongh"; clone_repo "$ORIGIN" "$N"
git -C "$N" switch -q -c work/n; printf 'n\n' > "$N/n.txt"; git -C "$N" add n.txt; git -C "$N" commit -qm n
out=$(omagit-action create-pr "$N")
assert_contains "$(result_line "$out")" "OK" "create-pr ok on non-github"
assert_contains "$(result_line "$out")" "not a GitHub" "non-github remote explained"
assert_eq "$(git -C "$N" rev-parse HEAD)" "$(git -C "$ORIGIN" rev-parse work/n)" "non-github branch pushed"

# From here the fixture looks like GitHub (URL) while fetch/push stay local.
git -C "$R" remote set-url origin https://github.com/example/repo.git
git -C "$R" config url."$ORIGIN".insteadOf https://github.com/example/repo.git
: > "$STUB_LOG"

# --- commit to main rejected: fallback branch + PR ------------------------------
protect_branch "$ORIGIN" main
printf 'rejected\n' >> "$R/README.md"
out=$(omagit-action commit "$R" "Blocked change" "")
res=$(result_line "$out")
assert_contains "$res" "OK" "rejection fallback reports OK"
assert_contains "$res" "pull/42" "PR url reported"
nb=$(git -C "$R" symbolic-ref --short HEAD)
assert_contains "$nb" "work/" "moved onto prefixed branch"
assert_eq "Blocked change" "$(git -C "$R" log -1 --format=%s)" "commit preserved on new branch"
assert_eq "$(git -C "$ORIGIN" rev-parse main)" "$(git -C "$R" rev-parse main)" "local main reset to origin"
assert_eq "$(git -C "$R" rev-parse HEAD)" "$(git -C "$ORIGIN" rev-parse "$nb")" "new branch pushed"
assert_contains "$(cat "$STUB_LOG")" "gh pr create --fill" "PR created with --fill"
rm "$ORIGIN/hooks/pre-receive"

# --- push to main fails for a non-rejection reason: nothing is moved ------------
git -C "$R" switch -q main
mv "$ORIGIN" "$ORIGIN.off"
printf 'offline\n' >> "$R/README.md"
out=$(omagit-action commit "$R" "Offline change" "" || true)
assert_contains "$(result_line "$out")" "ERR" "non-rejection push failure errs"
assert_contains "$(result_line "$out")" "nothing moved" "non-rejection explained"
assert_eq "main" "$(git -C "$R" symbolic-ref --short HEAD)" "stays on main after network failure"
assert_eq "Offline change" "$(git -C "$R" log -1 --format=%s)" "commit kept on main"
mv "$ORIGIN.off" "$ORIGIN"
git -C "$R" reset -q --hard origin/main

# --- new-branch / switch / branches ------------------------------------------
git -C "$R" switch -q main
out=$(omagit-action new-branch "$R" "work/x")
assert_contains "$(result_line "$out")" "OK" "new-branch ok"
assert_eq "work/x" "$(git -C "$R" symbolic-ref --short HEAD)" "new branch checked out"
out=$(omagit-action switch "$R" "main")
assert_contains "$(result_line "$out")" "OK" "switch ok"
assert_eq "main" "$(git -C "$R" symbolic-ref --short HEAD)" "switched"
res=$(result_line "$(omagit-action switch "$R" "nope" || true)")
assert_contains "$res" "ERR" "switch to missing branch errs"
out=$(omagit-action branches "$R")
assert_contains "$out" $'BRANCH\tmain\t1' "current branch flagged"
assert_contains "$out" $'BRANCH\twork/x\t0' "other branch listed"
res=$(result_line "$(omagit-action new-branch "$R" "bad name" || true)")
assert_contains "$res" "ERR" "invalid branch name refused"

# --- create-pr ------------------------------------------------------------------
res=$(result_line "$(omagit-action create-pr "$R" || true)")
assert_contains "$res" "ERR" "create-pr refused on main"
assert_contains "$res" "main" "refusal names the branch"
git -C "$R" switch -q work/x
printf 'pr\n' >> "$R/README.md"; git -C "$R" commit -qam "pr work"
out=$(omagit-action create-pr "$R")
assert_contains "$(result_line "$out")" "OK" "create-pr ok on feature branch"
assert_eq "$(git -C "$R" rev-parse HEAD)" "$(git -C "$ORIGIN" rev-parse work/x)" "branch pushed before PR"
sleep 0.3
assert_contains "$(cat "$STUB_LOG")" "gh pr create --web" "PR form opened in browser"
printf '[{"number":5,"title":"x","url":"https://github.com/example/repo/pull/5","headRefName":"work/x","statusCheckRollup":[]}]' > "$STUB_DIR/prs.json"
out=$(omagit-action create-pr "$R")
assert_contains "$(result_line "$out")" "pull/5" "existing PR reported, not an error"
echo '[]' > "$STUB_DIR/prs.json"

# --- ff-main: feature checked out, then main checked out, then diverged ----------
git -C "$R" switch -q main
commit_to_origin "$ORIGIN" main ff1.txt one
git -C "$R" switch -q work/x
out=$(omagit-action ff-main "$R")
assert_contains "$(result_line "$out")" "OK" "ff-main while on feature"
assert_eq "$(git -C "$ORIGIN" rev-parse main)" "$(git -C "$R" rev-parse main)" "main updated without checkout"
assert_eq "work/x" "$(git -C "$R" symbolic-ref --short HEAD)" "still on feature"
git -C "$R" switch -q main
commit_to_origin "$ORIGIN" main ff2.txt two
out=$(omagit-action ff-main "$R")
assert_contains "$(result_line "$out")" "OK" "ff-main while on main"
assert_eq "$(git -C "$ORIGIN" rev-parse main)" "$(git -C "$R" rev-parse HEAD)" "main pulled"
printf 'local\n' > "$R/local.txt"; git -C "$R" add local.txt; git -C "$R" commit -qm "local only"
commit_to_origin "$ORIGIN" main ff3.txt three
local_head=$(git -C "$R" rev-parse HEAD)
out=$(omagit-action ff-main "$R" || true)
assert_contains "$(result_line "$out")" "ERR" "diverged main errs"
assert_eq "$local_head" "$(git -C "$R" rev-parse HEAD)" "diverged: no ref change"
git -C "$R" reset -q --hard origin/main

# --- prune-gone -----------------------------------------------------------------
git -C "$R" switch -q -c work/gone; git -C "$R" push -q -u origin work/gone; git -C "$R" switch -q main
git -C "$R" push -q origin --delete work/gone
out=$(omagit-action prune-gone "$R")
assert_contains "$(result_line "$out")" "work/gone" "pruned branch named"
assert_eq "" "$(git -C "$R" branch --list work/gone)" "gone branch deleted"
assert_contains "$(git -C "$R" branch --list work/x)" "work/x" "branch with live upstream kept"

# --- merge-pr: passing PR, squash + delete + ff + prune ------------------------------
printf '[{"number":7,"title":"Feature x","url":"https://github.com/example/repo/pull/7","headRefName":"work/x","statusCheckRollup":[]}]' > "$STUB_DIR/prs.json"
git -C "$R" switch -q main
out=$(omagit-action merge-pr "$R" 7)
res=$(result_line "$out")
assert_contains "$res" "OK" "merge ok"
assert_contains "$res" "#7" "merged number reported"
assert_contains "$(cat "$STUB_LOG")" "gh pr merge 7 --squash" "strategy flag"
assert_not_contains "$(cat "$STUB_LOG")" "--delete-branch" "gh never deletes the local branch"
assert_eq "" "$(git -C "$ORIGIN" branch --list work/x)" "remote branch deleted by action"
assert_eq "$(git -C "$ORIGIN" rev-parse main)" "$(git -C "$R" rev-parse main)" "main fast-forwarded after merge"
assert_eq "" "$(git -C "$R" branch --list work/x)" "local branch pruned after merge"
jq '.mergeStrategy = "rebase"' "$OMAGIT_CONFIG_DIR/settings.json" > "$TMP/s" && mv "$TMP/s" "$OMAGIT_CONFIG_DIR/settings.json"
git -C "$R" switch -q -c work/y; printf 'y\n' > "$R/y.txt"; git -C "$R" add y.txt; git -C "$R" commit -qm y; git -C "$R" push -q -u origin work/y; git -C "$R" switch -q main
printf '[{"number":8,"title":"y","url":"u","headRefName":"work/y","statusCheckRollup":[]}]' > "$STUB_DIR/prs.json"
omagit-action merge-pr "$R" 8 >/dev/null
assert_contains "$(tail -n 5 "$STUB_LOG")" "gh pr merge 8 --rebase" "settings change applied live"
git -C "$R" switch -q -c work/z; printf 'z\n' > "$R/z.txt"; git -C "$R" add z.txt; git -C "$R" commit -qm z; git -C "$R" push -q -u origin work/z; git -C "$R" switch -q main
printf 'local\n' >> "$R/README.md"; git -C "$R" commit -qam "local only"
printf '[{"number":10,"title":"z","url":"u","headRefName":"work/z","statusCheckRollup":[]}]' > "$STUB_DIR/prs.json"
res=$(result_line "$(omagit-action merge-pr "$R" 10)")
assert_contains "$res" "OK" "merge with diverged main still OK"
assert_contains "$res" "diverged" "diverged main reported after merge"
git -C "$R" reset -q --hard origin/main
printf '[{"number":9,"title":"w","url":"u","headRefName":"work/w","statusCheckRollup":[]}]' > "$STUB_DIR/prs.json"
touch "$STUB_DIR/merge-fail" "$STUB_DIR/pr-9-open"
res=$(result_line "$(omagit-action merge-pr "$R" 9 || true)")
assert_contains "$res" "ERR" "merge failure reported when PR still open"
rm "$STUB_DIR/pr-9-open"
res=$(result_line "$(omagit-action merge-pr "$R" 9 || true)")
assert_contains "$res" "OK" "gh exit 1 but PR MERGED is not a failure"
rm "$STUB_DIR/merge-fail"

# --- prune-gone with worktrees: clean removed, dirty kept ---------------------------
for b in work/wt-clean work/wt-dirty; do
  git -C "$R" branch -q "$b" main; git -C "$R" push -q -u origin "$b"
  git -C "$R" worktree add -q "$TMP/${b##*/}" "$b"
  git -C "$R" push -q origin --delete "$b"
done
printf 'dirty\n' > "$TMP/wt-dirty/dirty.txt"
res=$(result_line "$(omagit-action prune-gone "$R")")
assert_contains "$res" "Pruned work/wt-clean" "clean worktree branch pruned"
assert_no_file "$TMP/wt-clean" "clean worktree removed"
assert_contains "$res" "kept work/wt-dirty (dirty worktree wt-dirty)" "dirty worktree reported"
assert_file "$TMP/wt-dirty/dirty.txt" "dirty worktree kept"
assert_contains "$(git -C "$R" branch --list work/wt-dirty)" "work/wt-dirty" "dirty worktree branch kept"
git -C "$R" worktree remove --force "$TMP/wt-dirty"; git -C "$R" branch -q -D work/wt-dirty

# --- open-file with configured command ----------------------------------------------
omagit-action open-file "$R" "README.md" >/dev/null
assert_contains "$(tail -n1 "$STUB_LOG")" "omarchy-launch-editor $R/README.md" "default open command"
jq '.openFileCommand = "zeditor"' "$OMAGIT_CONFIG_DIR/settings.json" > "$TMP/s" && mv "$TMP/s" "$OMAGIT_CONFIG_DIR/settings.json"
omagit-action open-file "$R" "README.md" >/dev/null; sleep 0.2
assert_contains "$(tail -n1 "$STUB_LOG")" "zeditor $R/README.md" "configured open command"

# --- launchers: native ------------------------------------------------------------------
out=$(omagit-action open-terminal "$R" "repo"); sleep 0.2
assert_contains "$(result_line "$out")" "OK" "terminal launch ok"
assert_contains "$(tail -n1 "$STUB_LOG")" "xdg-terminal-exec --dir=$R" "terminal rooted in repo"
res=$(result_line "$(omagit-action launch-agent "$R" "repo" || true)")
assert_contains "$res" "no default agent" "missing default agent reported"
mkdir -p "$HOME/.config/omarchy/defaults"; echo claude > "$HOME/.config/omarchy/defaults/agent"
out=$(omagit-action launch-agent "$R" "repo"); sleep 0.2
assert_contains "$(result_line "$out")" "claude" "agent launch names the agent"
assert_contains "$(tail -n1 "$STUB_LOG")" "omarchy-agent  cwd=$R" "agent launched via omarchy-agent in repo"
assert_eq "claude" "$(omagit-action agent-name)" "agent-name reports default"

# --- launchers: herdr routing ---------------------------------------------------------------
jq '.launcher = "herdr"' "$OMAGIT_CONFIG_DIR/settings.json" > "$TMP/s" && mv "$TMP/s" "$OMAGIT_CONFIG_DIR/settings.json"
out=$(omagit-action open-terminal "$R" "repo")
assert_contains "$(cat "$STUB_LOG")" "herdr workspace create --cwd $R --label repo --focus" "herdr create when no workspace"
out=$(omagit-action launch-agent "$R" "repo")
assert_contains "$(cat "$STUB_LOG")" "herdr agent start" "herdr agent start routed"

finish
