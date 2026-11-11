#!/usr/bin/env bash
# Stop: the "remember after" half of the team-memory mandate (AGENTS.md, Team memory). Once
# per session, and only when the session edited files in a git repo (recall-gate.sh records
# that) and has not called remember, the stop is blocked with one question: is there a
# durable decision, gotcha, convention or reference to record? A hook cannot judge that, so
# it forces the decision, not a write. Sessions that only answered questions are not asked.
#
# Loop safety: the marker is written before the block, so the agent is asked at most once,
# and a stop that is already a hook-driven continuation passes (common.sh stop_is_exempt).
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=../rust/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../rust/common.sh"
read_hook_input
need_tools fail-open jq

if [[ "${HIPPIUS_MEM_HOOKS_BYPASS:-0}" == 1 ]] || stop_is_exempt || is_subagent; then
  exit 0
fi
asked="$(session_file memory-asked)"
if [[ ! -f "$(session_file memory-edited)" || -f "$(session_file memory-remembered)" ||
-f "$asked" ]]; then
  exit 0
fi
touch "$asked"

cat >&2 <<'EOF'
hippius-mem remember checkpoint: did this session produce a durable, team-relevant learning
(a decision, gotcha, convention or reference) that a teammate's agent would need and that the
code and git history do not already show? If yes, call the hippius-mem remember tool now: one
self-contained fact per note, with a keyword-rich summary. If not, say "no durable learning to
record" and stop. Asked once per session.
EOF
exit 2
