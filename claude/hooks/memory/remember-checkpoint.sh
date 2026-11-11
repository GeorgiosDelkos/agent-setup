#!/usr/bin/env bash
# Stop: the "remember after" half of the team-memory mandate (AGENTS.md, Team memory). When
# the session made edits since it was last asked and since its last remember, the stop is
# blocked with one question: is there a durable decision, gotcha, convention or reference to
# record? A hook cannot judge that, so it forces the decision, not a write.
#
# State is counts, not a once-per-session flag: recall-gate.sh counts allowed edits, and
# this hook and recall-seen.sh store the count they saw. So a session is asked again after
# later work, and a Stop that another hook blocked in the same round (the clippy check) does
# not use up the question: the agent fixes that, which edits, and is asked at the next stop.
# Not asked: sessions that never recalled (hippius-mem was unavailable, so remember would
# fail too), sessions that only answered questions, subagents, a hook-driven continuation
# (common.sh stop_is_exempt, the loop guard), and HIPPIUS_MEM_HOOKS_BYPASS=1.
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=../rust/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../rust/common.sh"
read_hook_input
need_tools fail-open jq

if [[ "${HIPPIUS_MEM_HOOKS_BYPASS:-0}" == 1 ]] || stop_is_exempt || is_subagent; then
  exit 0
fi

# The number stored in session file $1, or 0.
count() {
  local value
  value="$(cat "$(session_file "$1")" 2>/dev/null || true)"
  echo "${value:-0}"
}

edits="$(count memory-edited)"
if [[ ! -s "$(session_file memory-recall)" ]] || ((edits <= $(count memory-asked))) ||
  ((edits <= $(count memory-remembered))); then
  exit 0
fi
echo "$edits" >"$(session_file memory-asked)"

cat >&2 <<'EOF'
hippius-mem remember checkpoint: did this work produce a durable, team-relevant learning
(a decision, gotcha, convention or reference) that a teammate's agent would need and that the
code and git history do not already show? If yes, call the hippius-mem remember tool now: one
self-contained fact per note, with a keyword-rich summary. If not, say "no durable learning to
record" and stop.
EOF
exit 2
