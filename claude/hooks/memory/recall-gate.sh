#!/usr/bin/env bash
# PreToolUse (file edits): hippius-mem is the team's shared memory, and AGENTS.md (Team
# memory) makes recalling it before acting mandatory. This gate makes that checkable: an edit
# to a file inside a git work tree is denied until this session has called the hippius-mem
# `recall` tool within RECALL_WINDOW_SECS. recall-seen.sh records the call.
#
# It fails open, with a message, whenever recalling is impossible, because a gate that cannot
# be satisfied stops all work. A team note records a server-down deadlock with upstream's
# gate that cost about twelve hours of agent time. So the edit goes ahead when hippius-mem is
# not registered for Claude or Grok, or when the registered HTTP daemon does not answer
# within a second. A registered stdio server cannot be probed without starting it, so it
# counts as up.
#
# Not gated: paths outside any git work tree, the Claude scratchpad (common.sh
# scratch_exempt), and sessions with HIPPIUS_MEM_HOOKS_BYPASS=1 (upstream's name, so one
# switch turns off both this gate and the gate `hippius-mem init` installs in a repo).
#
# The recall is session-wide: a Claude subagent shares its parent's session id and rides the
# parent's recall, while a Grok subagent has its own session and recalls for itself. Subagent
# prompts carry the recall directive (AGENTS.md) either way.
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=../rust/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../rust/common.sh"

# Upstream's default refresh window (HIPPIUS_MEM_RECALL_WINDOW_SECS, 1800 s), so a session
# recalls again on a long task the same way in a provisioned repo and anywhere else.
RECALL_WINDOW_SECS="${HIPPIUS_MEM_RECALL_WINDOW_SECS:-1800}"

read_hook_input
need_tools fail-open jq

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

recall_file="$(session_file memory-recall)"
if [[ -s "$recall_file" ]]; then
  age=$(($(date +%s) - $(cat "$recall_file")))
  if ((age < RECALL_WINDOW_SECS)); then
    touch "$(session_file memory-edited)"
    exit 0
  fi
fi

# The Claude registration: an HTTP url, or a stdio command. Empty when not registered.
claude_entry=""
if [[ -f "$HOME/.claude.json" ]]; then
  claude_entry="$(jq -r '.mcpServers["hippius-mem"] | .url // .command // empty' \
    "$HOME/.claude.json" 2>/dev/null || true)"
fi
grok_registered=no
if grep -qF '[mcp_servers.hippius-mem]' "$HOME/.grok/config.toml" 2>/dev/null; then
  grok_registered=yes
fi

fail_open() {
  echo "hippius-mem recall gate: $1, so this edit is not gated. Team memory is still" \
    "mandatory: recall before acting once it is back (AGENTS.md, Team memory)." >&2
  touch "$(session_file memory-edited)"
  exit 1
}
if [[ -z "$claude_entry" && "$grok_registered" == no ]]; then
  fail_open "hippius-mem is not registered for Claude or Grok (run install.sh)"
fi
if [[ "$claude_entry" == http* ]] && ! curl -s -o /dev/null -m 1 "$claude_entry"; then
  fail_open "the hippius-mem daemon at $claude_entry does not answer"
fi

reason="BLOCKED: recall team memory before editing $path. Call the hippius-mem recall tool"
reason+=" (mcp__hippius-mem__recall) with a query naming what you are about to change, read"
reason+=" the summaries, get the relevant notes, then retry the edit. One recall opens edits"
reason+=" for $((RECALL_WINDOW_SECS / 60)) minutes. If recall itself fails, report it; the"
reason+=" owner can set HIPPIUS_MEM_HOOKS_BYPASS=1."
if [[ -s "$recall_file" ]]; then
  reason+=" (Last recall was $((age / 60)) minutes ago.)"
fi
jq -n --arg reason "$reason" '{hookSpecificOutput: {hookEventName: "PreToolUse",
  permissionDecision: "deny", permissionDecisionReason: $reason}}'
echo "BLOCKED: recall hippius-mem before editing $path" >&2
