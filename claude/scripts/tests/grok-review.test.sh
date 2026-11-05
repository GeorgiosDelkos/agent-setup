#!/usr/bin/env bash
# Tests for claude/scripts/grok-review.sh, with a stub grok (GROK_BIN) and a throwaway review
# home (GROK_REVIEW_HOME) and repository. The real sandbox is checked by the SETUP.md probe.
set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/grok-review.sh"
WORK="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/grok-review-test.XXXXXX")" && pwd -P)"
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

# A repository whose head carries agent configuration at its root.
repo="$WORK/repo"
git init -q "$repo"
mkdir -p "$repo/.claude"
printf '{}\n' >"$repo/.claude/settings.json"
printf 'rules\n' >"$repo/AGENTS.md"
printf 'code\n' >"$repo/main.txt"
git -C "$repo" add -A
git -C "$repo" -c user.name=t -c user.email=t@t commit -qm init
sha="$(git -C "$repo" rev-parse HEAD)"

secret="sk-test-0123456789abcdefghijklmnop"
home="$WORK/home"
mkdir -p "$home/sessions/old-session"
printf '[profiles.pr-review]\n' >"$home/sandbox.toml"
printf '{"api_key": "%s"}\n' "$secret" >"$home/auth.json"
prompt="$WORK/prompt.md"
printf 'review this\n' >"$prompt"

# The stub records its arguments and environment, checks what it can see in the worktree,
# then behaves as the files beside it say. Not environment variables: the script runs grok
# under `env -i`, which is one of the things tested.
stub="$WORK/grok"
cat >"$stub" <<'EOF'
#!/usr/bin/env bash
dir="$(dirname "$0")"
log="$dir/log"
STUB_MODE="$(cat "$dir/stub.mode")"
STUB_SECRET="$(cat "$dir/stub.secret")"
printf '%s\n' "$@" >"$log.args"
env >"$log.env"
cwd=""
while [[ $# -gt 0 ]]; do
  if [[ "$1" == --cwd ]]; then cwd="$2"; fi
  shift
done
seen="clean"
[[ -e "$cwd/AGENTS.md" || -e "$cwd/.claude" ]] && seen="config-present"
[[ -f "$cwd/main.txt" ]] || seen="no-code"
case "$STUB_MODE" in
  ok) echo "finding: $seen" ;;
  fail) echo "partial"; exit 1 ;;
  stderr) echo "finding"; echo "warning: sandbox could not be applied" >&2 ;;
  empty) ;;
  leak) echo "the key is $STUB_SECRET" ;;
esac
EOF
chmod +x "$stub"

printf '%s\n' "$secret" >"$WORK/stub.secret"

run() {
  local mode="$1" out="$2"
  local code=0
  printf '%s\n' "$mode" >"$WORK/stub.mode"
  rm -f "$WORK/log.args" "$WORK/log.env"
  GH_TOKEN=leak-me GROK_BIN="$stub" GROK_REVIEW_HOME="$home" \
    bash "$SCRIPT" "$repo" "$sha" "$prompt" "$out" >"$WORK/stdout" 2>"$WORK/stderr" || code=$?
  echo "$code"
}

# ---- success ------------------------------------------------------------------------------
out="$WORK/review-ok.txt"
code="$(run ok "$out")"
check "ok: exit 0" "$([[ "$code" == 0 ]] && echo yes || echo no)"
check "ok: output written" "$([[ "$(cat "$out" 2>/dev/null)" == "finding: clean" ]] &&
  echo yes || echo no)"
check "ok: agent config stripped, code kept" "$(grep -qx 'finding: clean' "$out" &&
  echo yes || echo no)"
args="$(cat "$WORK/log.args")"
for flag in "--sandbox" "pr-review" "--tools" "read_file,grep,list_dir" "--disallowed-tools" \
  "search_tool,use_tool" "--disable-web-search" "--no-subagents" "--prompt-file"; do
  check "ok: passes $flag" "$(grep -qxF -- "$flag" <<<"$args" && echo yes || echo no)"
done
check "ok: no plan mode" "$(grep -q -- 'plan' <<<"$args" && echo no || echo yes)"
check "ok: GROK_HOME is the review home" "$(grep -qxF "GROK_HOME=$home" "$WORK/log.env" &&
  echo yes || echo no)"
check "ok: private TMPDIR" "$(grep -qxF "TMPDIR=$home/tmp/" "$WORK/log.env" &&
  echo yes || echo no)"
check "ok: tokens stay out of the env" "$(grep -q GH_TOKEN "$WORK/log.env" &&
  echo no || echo yes)"
check "ok: worktree removed" "$(git -C "$repo" worktree list | grep -q runs &&
  echo no || echo yes)"
check "ok: run dirs removed" "$([[ -z "$(ls -A "$home/runs")" ]] && echo yes || echo no)"
check "ok: sessions emptied" "$([[ -z "$(ls -A "$home/sessions")" ]] && echo yes || echo no)"

# ---- failed runs --------------------------------------------------------------------------
for mode in fail stderr empty; do
  out="$WORK/review-$mode.txt"
  code="$(run "$mode" "$out")"
  check "$mode: exit 1" "$([[ "$code" == 1 ]] && echo yes || echo no)"
  check "$mode: no output" "$([[ ! -e "$out" ]] && echo yes || echo no)"
  check "$mode: worktree removed" "$(git -C "$repo" worktree list | grep -q runs &&
    echo no || echo yes)"
done

# ---- credential in the output -------------------------------------------------------------
out="$WORK/review-leak.txt"
code="$(run leak "$out")"
check "leak: exit 2" "$([[ "$code" == 2 ]] && echo yes || echo no)"
check "leak: no output" "$([[ ! -e "$out" ]] && echo yes || echo no)"
check "leak: secret not printed" "$(grep -qF "$secret" "$WORK/stdout" "$WORK/stderr" &&
  echo no || echo yes)"

# ---- unavailable --------------------------------------------------------------------------
mv "$home/auth.json" "$WORK/auth.json"
code="$(run ok "$WORK/x.txt")"
check "no login: exit 3" "$([[ "$code" == 3 ]] && echo yes || echo no)"
ln -s "$WORK/auth.json" "$home/auth.json"
code="$(run ok "$WORK/x.txt")"
check "symlinked login: exit 3" "$([[ "$code" == 3 ]] && echo yes || echo no)"
rm "$home/auth.json"
mv "$WORK/auth.json" "$home/auth.json"
mv "$home" "$WORK/home-real"
ln -s "$WORK/home-real" "$home"
code="$(run ok "$WORK/x.txt")"
check "symlinked home: exit 3" "$([[ "$code" == 3 ]] && echo yes || echo no)"
rm "$home"
mv "$WORK/home-real" "$home"
code=0
bash "$SCRIPT" "$repo" >/dev/null 2>&1 || code=$?
check "usage: exit 64" "$([[ "$code" == 64 ]] && echo yes || echo no)"

printf '%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
