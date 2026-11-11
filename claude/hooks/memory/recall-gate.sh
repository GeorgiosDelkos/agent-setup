#!/usr/bin/env bash
# PreToolUse (file edits): hippius-mem is the team's shared memory, and AGENTS.md (Team
# memory) makes recalling it before acting mandatory. This gate makes that checkable: an edit
# to a file inside a git work tree is denied until this session has called the hippius-mem
# `recall` tool within RECALL_WINDOW_SECS. recall-seen.sh records the calls.
#
# A gate that cannot be satisfied stops all work: a team note records a server-down deadlock
# with upstream's gate that cost about twelve hours of agent time. So the edit goes ahead, with
# a message to the user, whenever this agent cannot recall:
#   - the editing agent (Grok sends camelCase `toolName`, Claude does not) has no hippius-mem
#     registration; the other agent's registration does not count;
#   - that registration is an HTTP url that does not accept a connection within a second
#     (any HTTP status, a 401 included, means the daemon is up);
#   - this session's last recall attempt failed (PostToolUseFailure);
#   - MAX_DENIALS edits were denied since the last recall. That covers what a hook cannot
#     see: a session started while the daemon was down has no recall tool at all, and a
#     stdio server cannot be probed without starting it. The cost is that an agent that
#     retries instead of recalling gets through after MAX_DENIALS tries; the message shows the
#     user when that happens.
#
# Not gated: paths outside any git work tree, the Claude scratchpad (common.sh
# scratch_exempt), and sessions with HIPPIUS_MEM_HOOKS_BYPASS=1 (upstream's name, so one
# switch turns off both this gate and the gate `hippius-mem init` installs in a repo). Shell
# writes do not pass through edit tools and are not checked.
#
# The recall is session-wide: a Claude subagent shares its parent's session id and rides the
# parent's recall, while a Grok subagent has its own session and recalls for itself.
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=../rust/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../rust/common.sh"

# Upstream's default refresh window (HIPPIUS_MEM_RECALL_WINDOW_SECS, 1800 s), so a session
# recalls again on a long task the same way in a provisioned repo and anywhere else.
RECALL_WINDOW_SECS="${HIPPIUS_MEM_RECALL_WINDOW_SECS:-1800}"
# Arbitrary: enough for an agent to read the deny and recall, few enough that a session
# without the tool loses only a couple of turns.
MAX_DENIALS=3

read_hook_input
need_tools fail-open jq curl

if [[ "${HIPPIUS_MEM_HOOKS_BYPASS:-0}" == 1 ]]; then
  exit 0
fi

path="$(tool_path)"
if [[ -z "$path" ]] || scratch_exempt "$path"; then
  exit 0
fi
dir="$path"
while [[ ! -d "$dir" ]]; do
  dir="$(dirname "$dir")"
done
if ! git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  exit 0
fi

# Epoch seconds stored in session file $1, or 0.
stamp() {
  local file
  file="$(session_file "$1")"
  if [[ -s "$file" ]]; then
    cat "$file"
  else
    echo 0
  fi
}

# Counts one more allowed edit, for remember-checkpoint.sh.
allow() {
  echo $(($(stamp memory-edited) + 1)) >"$(session_file memory-edited)"
  exit "$1"
}

recalled="$(stamp memory-recall)"
now="$(date +%s)"
if ((now - recalled < RECALL_WINDOW_SECS)); then
  allow 0
fi

# This agent's registration: an HTTP url, `stdio`, or nothing.
registration() {
  if [[ -n "$(hook_field '.toolName')" ]]; then
    awk '/^\[/ { in_table = ($0 == "[mcp_servers.hippius-mem]") }
      in_table && /^url *=/ { gsub(/^url *= *"|"$/, ""); print; exit }
      in_table && /^command *=/ { print "stdio"; exit }' "$HOME/.grok/config.toml" \
      2>/dev/null || true
  elif [[ -f "$HOME/.claude.json" ]]; then
    jq -r '.mcpServers["hippius-mem"] | if .url then .url elif .command then "stdio"
      else empty end' "$HOME/.claude.json" 2>/dev/null || true
  fi
}

fail_open() {
  echo "hippius-mem recall gate: $*, so this edit is not gated. Team memory is still" \
    "mandatory: recall before acting once it works (AGENTS.md, Team memory)." >&2
  allow 1
}
entry="$(registration)"
if [[ -z "$entry" ]]; then
  fail_open "hippius-mem is not registered for this agent (run install.sh)"
fi
if [[ "$entry" == http* ]] && ! curl -s --noproxy '*' -o /dev/null -m 1 "$entry"; then
  fail_open "the hippius-mem daemon at $entry does not answer"
fi
if (($(stamp memory-recall-failed) > recalled)); then
  fail_open "the last recall in this session failed"
fi
denials_file="$(session_file memory-denials)"
denials="$(awk -v since="$recalled" '$1 > since { n++ } END { print n + 0 }' \
  "$denials_file" 2>/dev/null || echo 0)"
if ((denials >= MAX_DENIALS)); then
  fail_open "$denials edits were denied without a recall, so the recall tool looks" \
    "unavailable to this session (restart it, or run /mcp in Claude, to reconnect)"
fi
echo "$now" >>"$denials_file"

reason="BLOCKED: recall team memory before editing $path. Call the hippius-mem recall tool"
reason+=" (mcp__hippius-mem__recall in Claude, hippius-mem__recall in Grok) with a query"
reason+=" naming what you are about to change, read the summaries, get the relevant notes,"
reason+=" then retry the edit. One recall opens edits for $((RECALL_WINDOW_SECS / 60)) minutes."
reason+=" If the tool is missing or fails, say so: the gate then lets edits through."
if ((recalled > 0)); then
  reason+=" (Last recall was $(((now - recalled) / 60)) minutes ago.)"
fi
jq -n --arg reason "$reason" '{hookSpecificOutput: {hookEventName: "PreToolUse",
  permissionDecision: "deny", permissionDecisionReason: $reason}}'
echo "BLOCKED: recall hippius-mem before editing $path" >&2
