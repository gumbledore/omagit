#!/bin/bash
# Shared fixtures for helper tests. Sourced by each *-test.sh.
#
# Every test runs against a throwaway HOME so ~/.config/gumbledore.omagit is never
# touched, with the stub gh/herdr on PATH ahead of the real ones.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf -- "$TMP"' EXIT

export HOME="$TMP/home"
mkdir -p "$HOME"
export OMAGIT_CONFIG_DIR="$HOME/.config/gumbledore.omagit"
export OMAGIT_PLUGIN_DIR="$ROOT"
export PATH="$ROOT/tests/stubs:$ROOT/bin:$PATH"
export GIT_CONFIG_GLOBAL="$TMP/gitconfig"
export GIT_CONFIG_NOSYSTEM=1
export STUB_LOG="$TMP/stub.log"
export STUB_DIR="$TMP/stubstate"
mkdir -p "$STUB_DIR"
git config --global user.name "omagit tests"
git config --global user.email "omagit-tests@example.invalid"
git config --global init.defaultBranch main

PASS=0
FAIL=0
TEST_NAME=${TEST_NAME:-$(basename -- "$0" .sh)}

pass() { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $*" >&2; }

assert_eq() { # expected actual label
  if [[ $1 == "$2" ]]; then pass; else fail "$3: expected [$1] got [$2]"; fi
}
assert_contains() { # haystack needle label
  if [[ $1 == *"$2"* ]]; then pass; else fail "$3: [$2] not found in: $1"; fi
}
assert_not_contains() {
  if [[ $1 != *"$2"* ]]; then pass; else fail "$3: [$2] unexpectedly found in: $1"; fi
}
assert_file() { if [[ -f $1 ]]; then pass; else fail "$2: missing file $1"; fi }
assert_no_file() { if [[ ! -e $1 ]]; then pass; else fail "$2: unexpected file $1"; fi }

finish() {
  echo "$TEST_NAME: $PASS passed, $FAIL failed"
  [[ $FAIL -eq 0 ]]
}

# make_repo <path> [branch]: init a repo with one commit.
make_repo() {
  local path=$1 branch=${2:-main}
  mkdir -p "$path"
  git -C "$path" init -q -b "$branch"
  printf 'hello\n' > "$path/README.md"
  git -C "$path" add README.md
  git -C "$path" commit -qm "initial"
}

# make_origin <path> [branch]: bare repo with one commit on <branch> and
# HEAD pointing at it (so origin/HEAD resolves after clone).
make_origin() {
  local bare=$1 branch=${2:-main} seed="$TMP/seed-$RANDOM$RANDOM"
  git init -q --bare -b "$branch" "$bare"
  make_repo "$seed" "$branch"
  git -C "$seed" remote add origin "$bare"
  git -C "$seed" push -q -u origin "$branch"
  rm -rf -- "$seed"
}

# clone_repo <origin> <path>
clone_repo() { git clone -q "$1" "$2"; }

# commit_to_origin <origin> <branch> <file> <content>: push a new commit to the bare
# origin from a scratch clone, so a checkout becomes "behind".
commit_to_origin() {
  local bare=$1 branch=$2 file=$3 content=$4 scratch="$TMP/scratch-$RANDOM$RANDOM"
  git clone -q -b "$branch" "$bare" "$scratch"
  printf '%s\n' "$content" > "$scratch/$file"
  git -C "$scratch" add -A
  git -C "$scratch" commit -qm "origin: $file"
  git -C "$scratch" push -q origin "$branch"
  rm -rf -- "$scratch"
}

# Install a pre-receive hook in a bare origin that rejects pushes to <branch>.
protect_branch() {
  local bare=$1 branch=$2
  cat > "$bare/hooks/pre-receive" <<HOOK
#!/bin/bash
while read -r old new ref; do
  if [[ \$ref == refs/heads/$branch ]]; then
    echo "remote: branch $branch is protected" >&2
    exit 1
  fi
done
exit 0
HOOK
  chmod +x "$bare/hooks/pre-receive"
}

# Last RESULT line of an action helper run: "OK\tmsg" or "ERR\tmsg".
result_line() { grep -P '^RESULT\t' <<<"$1" | tail -n1 | cut -f2-; }
