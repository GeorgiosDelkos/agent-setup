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
# The sign-in refresh is the call with `-p`; the review is the one with `--prompt-file`.
if printf '%s\n' "$@" | grep -qx -- '-p'; then
  echo signin >>"$log.order"
  printf '%s\n' "$@" >"$log.signin.args"
  env >"$log.signin.env"
  # Whether any PR worktree is on disk while the unsandboxed call runs.
  if compgen -G "$GROK_HOME/runs/*/wt" >/dev/null; then
    echo present >"$log.signin.wt"
  else
    echo absent >"$log.signin.wt"
  fi
  case "$(cat "$dir/stub.signin")" in
    fail)
      echo '{"message": "rejected (401)"}' >&2
      exit 1
      ;;
    leak)
      echo "refresh failed for $STUB_SECRET" >&2
      exit 1
      ;;
    hang) exec sleep 60 ;;
  esac
  echo OK
  exit 0
fi
echo review >>"$log.order"
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
  compacted)
    echo "finding: compacted"
    printf 'Auto-compacting conversation (93%% full)...\nConversation compacted.\n' >&2
    ;;
  compacted-and-warning)
    echo "finding"
    printf 'Conversation compacted.\nwarning: sandbox could not be applied\n' >&2
    ;;
  warning-ending-in-notice)
    echo "finding"
    echo "warning: sandbox could not be applied; Conversation compacted." >&2
    ;;
  notice-then-text)
    echo "finding"
    echo "Auto-compacting conversation (93% full)... error" >&2
    ;;
  binary-warning)
    echo "finding"
    printf 'warning: sandbox\0 could not be applied\n' >&2
    ;;
  empty) ;;
  leak) echo "the key is $STUB_SECRET" ;;
esac
EOF
chmod +x "$stub"

printf '%s\n' "$secret" >"$WORK/stub.secret"
printf 'ok\n' >"$WORK/stub.signin"

run() {
  local mode="$1" out="$2"
  local code=0
  printf '%s\n' "$mode" >"$WORK/stub.mode"
  rm -f "$WORK/log.args" "$WORK/log.env" "$WORK/log.order" "$WORK/log.signin.args" \
    "$WORK/log.signin.env" "$WORK/log.signin.wt"
  GH_TOKEN=leak-me GROK_BIN="$stub" GROK_REVIEW_HOME="$home" GROK_SIGNIN_LIMIT_SECS=3 \
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

# The sign-in refresh runs first, outside the sandbox, so it must be given nothing from the
# PR: no worktree on disk yet, an empty working directory and HOME, a fixed prompt, one
# listing tool, one turn, no web, no subagents.
signin="$(cat "$WORK/log.signin.args" 2>/dev/null || true)"
order="$(tr '\n' ' ' <"$WORK/log.order")"
check "signin: runs before the review" "$([[ "$order" == "signin review " ]] &&
  echo yes || echo no)"
check "signin: no PR worktree on disk" "$([[ "$(cat "$WORK/log.signin.wt")" == absent ]] &&
  echo yes || echo no)"
signin_cwd="$(grep -A1 -xF -- '--cwd' <<<"$signin" | tail -1)"
check "signin: own working directory" "$([[ "$signin_cwd" == "$home"/runs/pr-*/signin ]] &&
  echo yes || echo no)"
check "signin: nothing from the PR in its arguments" "$(grep -qE -- \
  '--prompt-file|--add-dir|prompt\.md|/wt$' <<<"$signin" && echo no || echo yes)"
for flag in "--tools" "list_dir" "--disallowed-tools" "search_tool,use_tool" \
  "--disable-web-search" "--no-subagents" "--max-turns"; do
  check "signin: passes $flag" "$(grep -qxF -- "$flag" <<<"$signin" && echo yes || echo no)"
done
check "signin: one turn" "$(grep -A1 -xF -- '--max-turns' <<<"$signin" | tail -1 |
  grep -qx 1 && echo yes || echo no)"
check "signin: empty HOME, not the user's" "$(grep -qE "^HOME=$home/runs/pr-[^/]+/signin-home\$" \
  "$WORK/log.signin.env" && echo yes || echo no)"
check "signin: forces the refresh" "$(grep -qxF GROK_AUTH_EARLY_INVALIDATION_SECS=86400 \
  "$WORK/log.signin.env" && echo yes || echo no)"
check "review: no forced refresh" "$(grep -q GROK_AUTH_EARLY_INVALIDATION_SECS \
  "$WORK/log.env" && echo no || echo yes)"
check "review: the user's HOME, which the profile's ~ denies are written against" \
  "$(grep -qxF "HOME=$HOME" "$WORK/log.env" && echo yes || echo no)"
check "signin: GROK_HOME is the review home" "$(grep -qxF "GROK_HOME=$home" \
  "$WORK/log.signin.env" && echo yes || echo no)"
check "signin: tokens stay out of the env" "$(grep -q GH_TOKEN "$WORK/log.signin.env" &&
  echo no || echo yes)"

# ---- a sign-in that cannot be refreshed stops before the review ---------------------------
printf 'fail\n' >"$WORK/stub.signin"
out="$WORK/review-signin.txt"
code="$(run ok "$out")"
printf 'ok\n' >"$WORK/stub.signin"
check "signin fails: exit 3" "$([[ "$code" == 3 ]] && echo yes || echo no)"
check "signin fails: review not run" "$([[ ! -e "$WORK/log.args" ]] && echo yes || echo no)"
check "signin fails: no output" "$([[ ! -e "$out" ]] && echo yes || echo no)"
check "signin fails: says to sign in" "$(grep -q 'grok login' "$WORK/stderr" &&
  echo yes || echo no)"
check "signin fails: worktree removed" "$(git -C "$repo" worktree list | grep -q runs &&
  echo no || echo yes)"

# A sign-in that waits (an interactive fallback) is stopped at the limit.
printf 'hang\n' >"$WORK/stub.signin"
start=$SECONDS
code="$(run ok "$WORK/review-hang.txt")"
elapsed=$((SECONDS - start))
printf 'ok\n' >"$WORK/stub.signin"
check "signin hangs: exit 3" "$([[ "$code" == 3 ]] && echo yes || echo no)"
check "signin hangs: stopped at the limit" "$([[ "$elapsed" -lt 20 ]] && echo yes || echo no)"
check "signin hangs: review not run" "$([[ ! -e "$WORK/log.args" ]] && echo yes || echo no)"
check "signin hangs: no stub left running" "$(pgrep -f "sleep 60" >/dev/null &&
  echo no || echo yes)"

# A failed sign-in's stderr is not echoed when it holds the credential.
printf 'leak\n' >"$WORK/stub.signin"
code="$(run ok "$WORK/review-signin-leak.txt")"
printf 'ok\n' >"$WORK/stub.signin"
check "signin leak: exit 3" "$([[ "$code" == 3 ]] && echo yes || echo no)"
check "signin leak: secret not printed" "$(grep -qF "$secret" "$WORK/stdout" "$WORK/stderr" &&
  echo no || echo yes)"

# ---- compaction notices on stderr are not a failure ----------------------------------------
out="$WORK/review-compacted.txt"
code="$(run compacted "$out")"
check "compacted: exit 0" "$([[ "$code" == 0 ]] && echo yes || echo no)"
check "compacted: output written" "$([[ "$(cat "$out" 2>/dev/null)" == "finding: compacted" ]] &&
  echo yes || echo no)"

# ---- failed runs --------------------------------------------------------------------------
# The last three pin the filter's anchoring and its binary handling: a warning that ends with
# a notice, a notice with text after it, and a warning holding a NUL byte.
for mode in fail stderr empty compacted-and-warning warning-ending-in-notice \
  notice-then-text binary-warning; do
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
