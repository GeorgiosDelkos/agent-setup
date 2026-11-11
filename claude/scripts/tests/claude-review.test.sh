#!/usr/bin/env bash
# Tests for claude/scripts/claude-review.sh, with a stub claude (CLAUDE_BIN) and a throwaway
# repository whose head carries agent configuration.
set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/claude-review.sh"
WORK="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/claude-review-test.XXXXXX")" && pwd -P)"
trap 'trash "$WORK"' EXIT
pass=0
fail=0

check() {
  local name="$1" ok="$2"
  if [[ "$ok" == yes ]]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL: %s\n' "$name"
  fi
}
yes_if() {
  if "$@"; then echo yes; else echo no; fi
}

repo="$WORK/repo"
git init -q "$repo"
mkdir -p "$repo/.claude"
printf '{}\n' >"$repo/.claude/settings.json"
printf 'rules\n' >"$repo/CLAUDE.md"
printf 'code\n' >"$repo/main.txt"
git -C "$repo" add -A
git -C "$repo" -c user.name=t -c user.email=t@t commit -qm init
sha="$(git -C "$repo" rev-parse HEAD)"
prompt="$WORK/prompt.md"
printf 'review this\n' >"$prompt"

# The stub logs its arguments, working directory and stdin, and records whether the agent
# configuration was stripped and the code kept. STUB_MODE picks its behaviour.
stub="$WORK/claude"
cat >"$stub" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$STUB_LOG.args"
pwd -P >"$STUB_LOG.cwd"
cat >"$STUB_LOG.stdin"
if [[ ! -e .claude && ! -e CLAUDE.md && -f main.txt ]]; then
  echo stripped >"$STUB_LOG.tree"
fi
case "${STUB_MODE:-ok}" in
ok) echo "finding: clean" ;;
fail) echo "boom" >&2; exit 7 ;;
empty) : ;;
esac
EOF
chmod +x "$stub"

# run MODE: runs the script with the stub; sets $code.
run() {
  code=0
  STUB_MODE="$1" STUB_LOG="$WORK/log" CLAUDE_BIN="$stub" TMPDIR="$WORK/tmp/" \
    bash "$SCRIPT" "$repo" "$sha" "$prompt" "$WORK/out" >/dev/null 2>"$WORK/err" || code=$?
}
mkdir -p "$WORK/tmp"

run ok
check "ok: exit 0" "$(yes_if test "$code" -eq 0)"
check "ok: output written" "$(yes_if grep -qx 'finding: clean' "$WORK/out")"
check "ok: prompt on stdin" "$(yes_if grep -qx 'review this' "$WORK/log.stdin")"
check "ok: agent config stripped, code kept" "$(yes_if test -f "$WORK/log.tree")"
check "ok: runs in a worktree, not the repo" \
  "$(yes_if grep -q "$WORK/tmp/claude-review" "$WORK/log.cwd")"
args="$(tr '\n' ' ' <"$WORK/log.args")"
check "ok: read-only tools, no MCP, plan mode" "$(yes_if grep -qF -- \
  '-p --tools Read,Grep,Glob --strict-mcp-config --permission-mode plan' <<<"$args")"
check "ok: worktree removed" "$(yes_if test "$(git -C "$repo" worktree list | wc -l)" -eq 1)"
check "ok: run dir removed" "$(yes_if test -z "$(ls -A "$WORK/tmp")")"

trash "$WORK/out"
run fail
check "fail: exit 1" "$(yes_if test "$code" -eq 1)"
check "fail: stderr shown" "$(yes_if grep -q boom "$WORK/err")"
check "fail: no output" "$(yes_if test ! -e "$WORK/out")"

run empty
check "empty: exit 1" "$(yes_if test "$code" -eq 1)"
check "empty: no output" "$(yes_if test ! -e "$WORK/out")"

code=0
CLAUDE_BIN="$WORK/missing" bash "$SCRIPT" "$repo" "$sha" "$prompt" "$WORK/out" \
  >/dev/null 2>&1 || code=$?
check "missing claude: exit 3" "$(yes_if test "$code" -eq 3)"
code=0
bash "$SCRIPT" "$repo" >/dev/null 2>&1 || code=$?
check "usage: exit 64" "$(yes_if test "$code" -eq 64)"

printf '%d passed, %d failed\n' "$pass" "$fail"
((fail == 0))
