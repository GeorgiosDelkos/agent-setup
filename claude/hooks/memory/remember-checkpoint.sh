#!/usr/bin/env bash
# Stop: the "remember after" half of the team-memory mandate (AGENTS.md, Team memory). When
# the session made edits since it was last asked and since its last remember, the stop is
# blocked with one question: is there a durable decision, gotcha, convention or reference to
# record? A hook cannot judge that, so it forces the decision, not a write.
#
# State is counts, not a once-per-session flag: recall-gate.sh counts allowed edits, and
# this hook and recall-seen.sh store the count they saw. So a session is asked again after
# later work, at most every ASK_INTERVAL_SECS. The downside of the interval, taken to cut
# the extra turns (2026-11-11): the fix for a stop another hook blocked in the same round
# (the clippy check), and edits in a session's last half hour, may go unasked. The rule in
# AGENTS.md still asks the agent to remember them.
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

# Asked at most once per ASK_INTERVAL_SECS: each ask costs the agent a turn, and in a session
# that edits on every prompt an ask per stop came to one extra turn per prompt. Edits made
# since are asked about at the next stop past the interval. The recall window's length
# (recall-gate.sh), so one ask covers about one recall's worth of work.
ASK_INTERVAL_SECS=1800
edits="$(count memory-edited)"
now="$(date +%s)"
if [[ ! -s "$(session_file memory-recall)" ]] || ((edits <= $(count memory-asked))) ||
  ((edits <= $(count memory-remembered))) ||
  ((now - $(count memory-asked-at) < ASK_INTERVAL_SECS)); then
  exit 0
fi
echo "$edits" >"$(session_file memory-asked)"
echo "$now" >"$(session_file memory-asked-at)"

cat >&2 <<'EOF'
hippius-mem remember checkpoint: did this work produce a durable, team-relevant learning
(a decision, gotcha, convention or reference) that a teammate's agent would need and that the
code and git history do not already show? If yes, call the hippius-mem remember tool now: one
self-contained fact per note, with a keyword-rich summary. If not, say "no durable learning to
record" and stop.
EOF
exit 2
