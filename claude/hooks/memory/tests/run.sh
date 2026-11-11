#!/usr/bin/env bash
# Tests for the team-memory hooks in the directory above this one. Each hook is fed Claude
# and Grok JSON inputs with HOME and TMPDIR pointed at scratch directories, so the real
# ~/.claude.json, ~/.grok and hook state are never read. A local server stands for a live
# daemon (any HTTP answer counts as up); a closed port stands for one that is down.
set -euo pipefail

HOOKS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/memory-hooks-test.XXXXXX")" && pwd -P)"
server_pid=""
cleanup() {
  if [[ -n "$server_pid" ]]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  trash "$WORK"
}
trap cleanup EXIT
pass=0
fail=0

REPO="$WORK/repo"
git init -q "$REPO"
mkdir -p "$WORK/plain"
OUTSIDE="$WORK/plain/notes.txt"
FILE="$REPO/src/new.rs"
FAKE_HOME="$WORK/home"
STATE_TMP="$WORK/tmp"
STATE="$STATE_TMP/claude-rust-hooks"
mkdir -p "$FAKE_HOME/.grok" "$STATE_TMP"

# A minimal HTTP server in Perl (already a hook dependency): it writes its port to a file,
# then answers every connection with 401, as the real daemon does without a token.
perl -MIO::Socket::INET -e '
  my $s = IO::Socket::INET->new(LocalAddr => "127.0.0.1", LocalPort => 0, Listen => 5,
    ReuseAddr => 1) or die $!;
  open my $f, ">", $ARGV[0] or die $!; print $f $s->sockport; close $f;
  while (my $c = $s->accept) {
    print $c "HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
    close $c;
  }' "$WORK/port" &
server_pid=$!
for _ in $(seq 50); do
  if [[ -s "$WORK/port" ]]; then
    break
  fi
  sleep 0.1
done
PORT="$(cat "$WORK/port")"
UP="http://127.0.0.1:$PORT/mcp"
DOWN="http://127.0.0.1:1/mcp"

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

# register CLAUDE GROK: each is none, stdio, or a url.
register() {
  case "$1" in
  none) echo '{}' ;;
  stdio) echo '{"mcpServers": {"hippius-mem": {"command": "hippius-mem"}}}' ;;
  *) jq -n --arg u "$1" '{mcpServers: {"hippius-mem": {url: $u}}}' ;;
  esac >"$FAKE_HOME/.claude.json"
  case "$2" in
  none) printf '[mcp_servers.other]\nurl = "%s"\n' "$UP" ;;
  stdio) printf '[mcp_servers.hippius-mem]\ncommand = "hippius-mem"\n' ;;
  *) printf '[mcp_servers.hippius-mem]\nbearer_token_file = "t"\nurl = "%s"\n' "$2" ;;
  esac >"$FAKE_HOME/.grok/config.toml"
}

# Runs hook $1 with JSON $2, extra environment in $3... Sets $code and $out (stderr, plus
# the reason of a JSON deny on stdout, which counts as exit 2).
run_hook() {
  local hook="$1" input="$2" stdout
  shift 2
  code=0
  stdout="$(env HOME="$FAKE_HOME" TMPDIR="$STATE_TMP" "$@" bash "$HOOKS/$hook" \
    <<<"$input" 2>"$WORK/stderr")" || code=$?
  out="$(cat "$WORK/stderr")"
  if [[ -n "$stdout" ]] &&
    [[ "$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$stdout")" == deny ]]; then
    code=2
    out="$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$stdout")"$'\n'"$out"
  fi
}

# expect NAME CODE HOOK JSON NEEDLE [ENV...]: exit code is CODE and output contains NEEDLE.
expect() {
  local name="$1" want="$2" hook="$3" input="$4" needle="$5"
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
# Grok sends camelCase fields plus Claude's snake_case aliases (agents/SETUP.md).
grok_edit() {
  jq -nc --arg s "$1" --arg p "$2" \
    '{sessionId: $s, toolName: "search_replace", session_id: $s, tool_name: "search_replace",
      tool_input: {target_file: $p}}'
}
grok_rel_edit() {
  jq -nc --arg s "$1" --arg p "$2" --arg c "$3" \
    '{session_id: $s, toolName: "write", tool_name: "write", cwd: $c,
      tool_input: {target_file: $p}}'
}
# tool_call SESSION TOOL [EVENT]
tool_call() {
  jq -nc --arg s "$1" --arg t "$2" --arg e "${3:-PostToolUse}" \
    '{session_id: $s, hook_event_name: $e, tool_name: $t, tool_input: {}}'
}
recall() {
  run_hook recall-seen.sh "$(tool_call "$1" mcp__hippius-mem__recall)"
}
stop() {
  local extra="${2:-}"
  if [[ -z "$extra" ]]; then
    extra="{}"
  fi
  jq -nc --arg s "$1" --argjson extra "$extra" \
    '{session_id: $s, hook_event_name: "Stop"} + $extra'
}

# ---- recall-gate.sh: what is gated ------------------------------------------------------

register stdio "$UP"
expect "gate: Claude edit in a git repo before recall is denied" 2 recall-gate.sh \
  "$(edit a1 "$FILE")" "mcp__hippius-mem__recall in Claude"
expect "gate: Grok edit before recall is denied" 2 recall-gate.sh \
  "$(grok_edit g1 "$FILE")" "hippius-mem__recall in Grok"
expect "gate: relative Grok path inside the repo is denied" 2 recall-gate.sh \
  "$(grok_rel_edit g3 src/x.rs "$REPO")" "recall team memory"
expect "gate: relative Grok path outside git passes" 0 recall-gate.sh \
  "$(grok_rel_edit g3 notes.txt "$WORK/plain")" ""
expect "gate: edit outside any git repo passes" 0 recall-gate.sh "$(edit a1 "$OUTSIDE")" ""
expect "gate: bypass passes" 0 recall-gate.sh "$(edit a1 "$FILE")" "" \
  HIPPIUS_MEM_HOOKS_BYPASS=1

# ---- recall-seen.sh and the window ------------------------------------------------------

recall b1
expect "gate: edit after recall passes" 0 recall-gate.sh "$(edit b1 "$FILE")" ""
expect "gate: another session still has to recall" 2 recall-gate.sh "$(edit b2 "$FILE")" ""
run_hook recall-seen.sh "$(tool_call g4 hippius-mem__recall)"
expect "gate: Grok edit after a Grok recall passes" 0 recall-gate.sh \
  "$(grok_edit g4 "$FILE")" ""
run_hook recall-seen.sh "$(tool_call b3 mcp__hippius-mem__get)"
expect "gate: get is not a recall" 2 recall-gate.sh "$(edit b3 "$FILE")" ""

echo $(($(date +%s) - 3600)) >"$STATE/b4.memory-recall"
expect "gate: recall older than the window is denied" 2 recall-gate.sh \
  "$(edit b4 "$FILE")" "60 minutes ago"
expect "gate: a longer window accepts it" 0 recall-gate.sh "$(edit b4 "$FILE")" "" \
  HIPPIUS_MEM_RECALL_WINDOW_SECS=7200

# ---- recall-gate.sh: failing open -------------------------------------------------------

register none "$UP"
expect "gate: Claude without its own registration fails open" 1 recall-gate.sh \
  "$(edit c1 "$FILE")" "not registered for this agent"
register "$UP" none
expect "gate: Grok without its own registration fails open" 1 recall-gate.sh \
  "$(grok_edit c2 "$FILE")" "not registered for this agent"
expect "gate: Claude with a live daemon is enforced" 2 recall-gate.sh \
  "$(edit c3 "$FILE")" "recall team memory"
register "$DOWN" "$DOWN"
expect "gate: Claude daemon down fails open" 1 recall-gate.sh \
  "$(edit c4 "$FILE")" "does not answer"
expect "gate: Grok daemon down fails open" 1 recall-gate.sh \
  "$(grok_edit c5 "$FILE")" "does not answer"
register stdio stdio
expect "gate: Grok stdio registration is enforced" 2 recall-gate.sh \
  "$(grok_edit c6 "$FILE")" "recall team memory"

run_hook recall-seen.sh "$(tool_call c7 mcp__hippius-mem__recall PostToolUseFailure)"
expect "gate: a failed recall fails open" 1 recall-gate.sh "$(edit c7 "$FILE")" \
  "last recall in this session failed"
sleep 1
recall c7
expect "gate: a later successful recall opens normally" 0 recall-gate.sh \
  "$(edit c7 "$FILE")" ""

for i in 1 2 3; do
  expect "gate: denial $i without a recall" 2 recall-gate.sh "$(edit c8 "$FILE")" ""
done
expect "gate: after three denials the tool counts as unavailable" 1 recall-gate.sh \
  "$(edit c8 "$FILE")" "looks unavailable"

# ---- remember-checkpoint.sh -------------------------------------------------------------

register stdio stdio
expect "checkpoint: session without edits stops" 0 remember-checkpoint.sh "$(stop d1)" ""
register none none
run_hook recall-gate.sh "$(edit d2 "$FILE")"
expect "checkpoint: session that never recalled is not asked" 0 remember-checkpoint.sh \
  "$(stop d2)" ""
register stdio stdio

recall d3
run_hook recall-gate.sh "$(edit d3 "$FILE")"
expect "checkpoint: session that edited is asked" 2 remember-checkpoint.sh "$(stop d3)" \
  "remember checkpoint"
expect "checkpoint: not asked again without new edits" 0 remember-checkpoint.sh \
  "$(stop d3)" ""
run_hook recall-gate.sh "$(edit d3 "$FILE")"
expect "checkpoint: not asked again within the interval" 0 remember-checkpoint.sh \
  "$(stop d3)" ""
echo $(($(date +%s) - 1801)) >"$STATE/d3.memory-asked-at"
expect "checkpoint: asked again after later edits, past the interval" 2 \
  remember-checkpoint.sh "$(stop d3)" "remember checkpoint"
run_hook recall-gate.sh "$(edit d3 "$FILE")"
run_hook recall-seen.sh "$(tool_call d3 hippius-mem__remember)"
expect "checkpoint: not asked after a remember" 0 remember-checkpoint.sh "$(stop d3)" ""

recall d4
run_hook recall-gate.sh "$(edit d4 "$FILE")"
expect "checkpoint: hook-driven continuation passes" 0 remember-checkpoint.sh \
  "$(stop d4 '{"stop_hook_active": true}')" ""
expect "checkpoint: Grok shutdown stop passes" 0 remember-checkpoint.sh \
  "$(stop d4 '{"reason": "shutdown"}')" ""
expect "checkpoint: subagent stop passes" 0 remember-checkpoint.sh \
  "$(stop d4 '{"agent_id": "x"}')" ""
expect "checkpoint: bypass passes" 0 remember-checkpoint.sh "$(stop d4)" "" \
  HIPPIUS_MEM_HOOKS_BYPASS=1
expect "checkpoint: the same session is still asked" 2 remember-checkpoint.sh \
  "$(stop d4)" "remember checkpoint"

printf '%d passed, %d failed\n' "$pass" "$fail"
((fail == 0))
