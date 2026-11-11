#!/usr/bin/env bash
# PostToolUse (hippius-mem recall and remember): records the call for this session.
# recall-gate.sh reads the recall time; remember-checkpoint.sh skips its question when the
# session already called remember. Claude names the tools mcp__hippius-mem__<tool>, Grok
# hippius-mem__<tool>. PostToolUse fires only after a call that succeeded.
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=../rust/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../rust/common.sh"
read_hook_input
need_tools fail-open jq

case "$(hook_field '.tool_name // .toolName')" in
*hippius-mem__recall)
  date +%s >"$(session_file memory-recall)"
  ;;
*hippius-mem__remember)
  touch "$(session_file memory-remembered)"
  ;;
esac
