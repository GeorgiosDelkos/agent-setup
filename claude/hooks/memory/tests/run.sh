#!/usr/bin/env bash
# Tests for the team-memory hooks in the directory above this one. Each hook is fed Claude
# and Grok JSON inputs with HOME and TMPDIR pointed at scratch directories, so the real
# ~/.claude.json, ~/.grok and hook state are never read. A stdio registration stands for a
# live server (the gate cannot probe one); an HTTP url on a closed port stands for a daemon
# that is down.
set -euo pipefail

HOOKS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/memory-hooks-test.XXXXXX")" && pwd -P)"
trap 'trash "$WORK"' EXIT
pass=0
fail=0

REPO="$WORK/repo"
git init -q "$REPO"
OUTSIDE="$WORK/plain/notes.txt"
mkdir -p "$WORK/plain"
FAKE_HOME="$WORK/home"
STATE_TMP="$WORK/tmp"
mkdir -p "$FAKE_HOME/.grok" "$STATE_TMP"

check() {
  local name="$1" ok="$2" detail="${3:-}"
  if [[ "$ok" == yes ]]; then
    pass=$((pass + 1))
    return
  fi
  fail=$((fail + 1))
  printf 'FAIL: %s\n' "$name"
  if [[ -n "$detail" ]]; then
    printf '%s\n' "$detail" | sed 's/^/    /'
  fi
}

# Registration in the fake home: none, stdio (counts as up), down (HTTP on a closed port),
# or grok (only Grok's config names the server).
register() {
  trash "$FAKE_HOME/.claude.json" "$FAKE_HOME/.grok/config.toml" 2>/dev/null || true
  case "$1" in
  stdio) echo '{"mcpServers": {"hippius-mem": {"command": "hippius-mem"}}}' ;;
  down) echo '{"mcpServers": {"hippius-mem": {"url": "http://127.0.0.1:1/mcp"}}}' ;;
  *) echo '{}' ;;
  esac >"$FAKE_HOME/.claude.json"
  if [[ "$1" == grok ]]; then
    printf '[mcp_servers.hippius-mem]\nurl = "http://127.0.0.1:1/mcp"\n' \
      >"$FAKE_HOME/.grok/config.toml"
  fi
}

# Runs hook $1 with JSON $2, extra environment in $3... Sets $code and $out (stderr, plus
# the deny reason of a JSON deny on stdout, which counts as exit 2).
run_hook() {
  local hook="$1" input="$2" stdout
  shift 2
  code=0
  stdout="$(env HOME="$FAKE_HOME" TMPDIR="$STATE_TMP" "$@" bash "$HOOKS/$hook" \
    <<<"$input" 2>"$WORK/stderr")" || code=$?
  out="$(cat "$WORK/stderr")"
  if [[ "$stdout" == *'"permissionDecision"'* ]]; then
    code=2
    out="$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$stdout")"$'\n'"$out"
  fi
}

# expect NAME CODE HOOK JSON NEEDLE [ENV...]: exit code is CODE and output contains NEEDLE.
expect() {
  local name="$1" want="$2" hook="$3" input="$4" needle="${5:-}"
  shift 5
  run_hook "$hook" "$input" "$@"
  local ok=no
  if [[ "$code" -eq "$want" && "$out" == *"$needle"* ]]; then
    ok=yes
  fi
  check "$name" "$ok" "exit $code, want $want; output: $out"
}

edit() {
  jq -nc --arg s "$1" --arg p "$2" \
    '{session_id: $s, tool_name: "Edit", tool_input: {file_path: $p}}'
}
grok_edit() {
  jq -nc --arg s "$1" --arg p "$2" \
    '{session_id: $s, tool_name: "search_replace", tool_input: {target_file: $p}}'
}
tool_call() {
  jq -nc --arg s "$1" --arg t "$2" '{session_id: $s, tool_name: $t, tool_input: {}}'
}
stop() {
  local extra="${2:-}"
  if [[ -z "$extra" ]]; then
    extra="{}"
  fi
  jq -nc --arg s "$1" --argjson extra "$extra" \
    '{session_id: $s, hook_event_name: "Stop"} + $extra'
}

# ---- recall-gate.sh ---------------------------------------------------------------------

register stdio
file="$REPO/src/new.rs"
expect "gate: edit in a git repo before recall is denied" 2 recall-gate.sh \
  "$(edit s1 "$file")" "recall team memory"
expect "gate: Grok edit before recall is denied" 2 recall-gate.sh \
  "$(grok_edit s1 "$file")" "mcp__hippius-mem__recall"
expect "gate: edit outside any git repo passes" 0 recall-gate.sh "$(edit s1 "$OUTSIDE")" ""
expect "gate: bypass passes" 0 recall-gate.sh "$(edit s1 "$file")" "" HIPPIUS_MEM_HOOKS_BYPASS=1

expect "seen: Claude recall is recorded" 0 recall-seen.sh \
  "$(tool_call s1 mcp__hippius-mem__recall)" ""
expect "gate: edit after recall passes" 0 recall-gate.sh "$(edit s1 "$file")" ""
expect "gate: another session still has to recall" 2 recall-gate.sh "$(edit s2 "$file")" ""

expect "seen: Grok recall is recorded" 0 recall-seen.sh "$(tool_call s3 hippius-mem__recall)" ""
expect "gate: Grok edit after Grok recall passes" 0 recall-gate.sh "$(grok_edit s3 "$file")" ""
expect "seen: another tool records nothing" 0 recall-seen.sh \
  "$(tool_call s4 mcp__hippius-mem__get)" ""
expect "gate: get is not a recall" 2 recall-gate.sh "$(edit s4 "$file")" ""

echo $(($(date +%s) - 3600)) >"$STATE_TMP/claude-rust-hooks/s5.memory-recall"
expect "gate: recall older than the window is denied" 2 recall-gate.sh \
  "$(edit s5 "$file")" "60 minutes ago"
expect "gate: a longer window accepts it" 0 recall-gate.sh "$(edit s5 "$file")" "" \
  HIPPIUS_MEM_RECALL_WINDOW_SECS=7200

register grok
expect "gate: registered for Grok only is still enforced" 2 recall-gate.sh \
  "$(edit s6 "$file")" "recall team memory"
register none
expect "gate: not registered fails open with a message" 1 recall-gate.sh \
  "$(edit s6 "$file")" "not registered"
register down
expect "gate: daemon down fails open with a message" 1 recall-gate.sh \
  "$(edit s6 "$file")" "does not answer"
register stdio

# ---- remember-checkpoint.sh -------------------------------------------------------------

expect "checkpoint: session without edits stops" 0 remember-checkpoint.sh "$(stop s7)" ""
expect "checkpoint: denied edit does not count as an edit" 0 remember-checkpoint.sh \
  "$(stop s2)" ""

run_hook recall-seen.sh "$(tool_call s8 mcp__hippius-mem__recall)"
run_hook recall-gate.sh "$(edit s8 "$file")"
expect "checkpoint: session that edited is asked" 2 remember-checkpoint.sh "$(stop s8)" \
  "remember checkpoint"
expect "checkpoint: asked only once" 0 remember-checkpoint.sh "$(stop s8)" ""

run_hook recall-seen.sh "$(tool_call s9 mcp__hippius-mem__recall)"
run_hook recall-gate.sh "$(edit s9 "$file")"
expect "checkpoint: hook-driven continuation passes" 0 remember-checkpoint.sh \
  "$(stop s9 '{"stop_hook_active": true}')" ""
expect "checkpoint: Grok shutdown stop passes" 0 remember-checkpoint.sh \
  "$(stop s9 '{"reason": "shutdown"}')" ""
expect "seen: remember is recorded" 0 recall-seen.sh "$(tool_call s9 hippius-mem__remember)" ""
expect "checkpoint: session that remembered is not asked" 0 remember-checkpoint.sh \
  "$(stop s9)" ""

register none
run_hook recall-gate.sh "$(edit s10 "$file")"
expect "checkpoint: fail-open edit still counts" 2 remember-checkpoint.sh "$(stop s10)" \
  "remember checkpoint"

printf '%d passed, %d failed\n' "$pass" "$fail"
((fail == 0))
