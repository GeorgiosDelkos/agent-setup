#!/usr/bin/env bash
# PostToolUse and PostToolUseFailure (hippius-mem recall and remember): records the call for
# this session. recall-gate.sh reads the time of the last recall and of the last failed one;
# remember-checkpoint.sh reads the edit count at the last remember. Hooks see the tool as
# mcp__hippius-mem__<tool> in Claude and hippius-mem__<tool> in Grok, also when Grok routes
# the call through its use_tool dispatcher.
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=../rust/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../rust/common.sh"
read_hook_input
need_tools fail-open jq

failed=no
if [[ "$(hook_field '.hook_event_name // .hookEventName')" == PostToolUseFailure ]]; then
  failed=yes
fi
case "$(hook_field '.tool_name // .toolName'):$failed" in
*hippius-mem__recall:no)
  date +%s >"$(session_file memory-recall)"
  ;;
*hippius-mem__recall:yes)
  date +%s >"$(session_file memory-recall-failed)"
  ;;
*hippius-mem__remember:no)
  edited="$(session_file memory-edited)"
  cat "$edited" 2>/dev/null >"$(session_file memory-remembered)" || true
  ;;
esac
