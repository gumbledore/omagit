#!/bin/bash
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

ORIGIN="$TMP/origin.git"; make_origin "$ORIGIN"
R="$TMP/repo"; clone_repo "$ORIGIN" "$R"

rec() { grep -P "^REPO\t\Q$1\E\t" <<<"$2"; }

# Clean, in sync
out=$(omagit-state "$R")
line=$(rec "$R" "$out")
assert_eq "main" "$(cut -f3 <<<"$line")" "branch"
assert_eq "0" "$(cut -f4 <<<"$line")" "dirty count clean"
assert_eq "0" "$(cut -f5 <<<"$line")" "ahead 0"
assert_eq "0" "$(cut -f6 <<<"$line")" "behind 0"
assert_eq "yes" "$(cut -f7 <<<"$line")" "has upstream"
assert_contains "$(cut -f8 <<<"$line")" "ago" "relative age"
assert_eq "initial" "$(cut -f9 <<<"$line")" "last subject"

# Dirty: modified, added, deleted, renamed, untracked, quoted path
printf 'changed\n' >> "$R/README.md"
printf 'x\n' > "$R/added.txt"; git -C "$R" add added.txt
printf 'y\n' > "$R/todelete.txt"; git -C "$R" add todelete.txt
printf 'z\n' > "$R/old.txt"; git -C "$R" add old.txt
git -C "$R" commit -qm "more files"
git -C "$R" rm -q todelete.txt
git -C "$R" mv old.txt new.txt
printf 'u\n' > "$R/untracked.txt"
mkdir -p "$R/sub dir"; printf 'q\n' > "$R/sub dir/we\"ird.txt"
printf 'a\n' > "$R/added2.txt"; git -C "$R" add added2.txt
out=$(omagit-state "$R")
line=$(rec "$R" "$out")
files=$(grep -P "^FILE\t" <<<"$out" | cut -f3,4)
assert_eq "6" "$(cut -f4 <<<"$line")" "dirty count"
assert_eq "1" "$(cut -f5 <<<"$line")" "ahead after local commit"
assert_contains "$files" $'M\tREADME.md' "modified"
assert_contains "$files" $'A\tadded2.txt' "added"
assert_contains "$files" $'D\ttodelete.txt' "deleted"
assert_contains "$files" $'R\tnew.txt' "renamed reports new path"
assert_contains "$files" $'?\tuntracked.txt' "untracked"
assert_contains "$files" $'?\tsub dir/we"ird.txt' "quoted path unquoted"

# Behind
commit_to_origin "$ORIGIN" main upstream.txt v2
git -C "$R" fetch -q origin
line=$(rec "$R" "$(omagit-state "$R")")
assert_eq "1" "$(cut -f6 <<<"$line")" "behind after fetch"

# No upstream branch
git -C "$R" switch -q -c feature
line=$(rec "$R" "$(omagit-state "$R")")
assert_eq "feature" "$(cut -f3 <<<"$line")" "feature branch"
assert_eq "none" "$(cut -f7 <<<"$line")" "no upstream"
assert_eq "0" "$(cut -f5 <<<"$line")" "ahead blank without upstream"

# No remote at all
L="$TMP/local"; make_repo "$L"
line=$(rec "$L" "$(omagit-state "$L")")
assert_eq "noremote" "$(cut -f7 <<<"$line")" "no remote"

# Detached HEAD and unborn branch
git -C "$L" checkout -q --detach
line=$(rec "$L" "$(omagit-state "$L")")
assert_contains "$(cut -f3 <<<"$line")" "detached" "detached marker"
E="$TMP/empty"; mkdir -p "$E"; git -C "$E" init -q -b main
line=$(rec "$E" "$(omagit-state "$E")")
assert_eq "main" "$(cut -f3 <<<"$line")" "unborn branch name"
assert_eq "" "$(cut -f9 <<<"$line")" "no subject when unborn"

# Multiple repos in one call; missing path reported as ERR not a crash
out=$(omagit-state "$R" "$L" "$TMP/missing")
assert_eq "2" "$(grep -c -P '^REPO\t' <<<"$out")" "two repo records"
assert_contains "$out" $'ERR\t'"$TMP/missing" "missing repo reported"
assert_eq "3" "$(grep -c -P '^END\t' <<<"$out")" "END per input"

finish
