#!/usr/bin/env bash
# SubagentStop: every subagent records how many paths it had recorded when it stopped, since
# review-gate.sh counts a subagent's work only once it is handed back. A stop while a task
# the subagent started still runs is a pause, not a hand-back, and records nothing. When the
# rust-style-reviewer finishes, this also snapshots every changed .rs file of the repos the
# session works in: review-gate.sh then asks for a new review only when the code moved far
# enough from what was reviewed, so the small fixes that follow a review do not trigger
# another one.
#
# SubagentStop, not PostToolUse on the Agent tool: the reviewer usually runs in the
# background, and PostToolUse fires at spawn time, before it has read anything. The agent
# type field is `agent_type` in Claude Code and `subagentType` in Grok. A Grok reviewer runs
# in its own session, so the files snapshotted are those changed since any session's
# baseline in the repo, which covers the parent's. Never blocks.
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
read_hook_input
need_tools fail-open jq git shasum
# shellcheck source-path=SCRIPTDIR source=changes.sh
source "$(dirname "${BASH_SOURCE[0]}")/changes.sh"

# Whether the stopping subagent has only paused: a task it started (a background command, a
# child agent, a monitor) is still running, so it will resume and keep changing files when
# that task reports. SubagentStop fires on such a pause too, and the input has no flag for
# it. `background_tasks` lists every running task of the whole session, including the
# stopping agent itself, so a task counts as this agent's when its id appears in the agent's
# own transcript, where its launch result names it. Grok sends no `background_tasks`, so a
# Grok subagent never reads as paused.
has_paused() {
  local transcript self id
  transcript="$(hook_field '.agent_transcript_path')"
  self="$(hook_field '.agent_id')"
  if [[ ! -f "$transcript" ]]; then
    return 1
  fi
  while IFS= read -r id; do
    if [[ -n "$id" && "$id" != "$self" ]] && grep -qF -- "$id" "$transcript"; then
      return 0
    fi
  done < <(jq -r '.background_tasks[]? | select(.status == "running") | .id // empty' \
    <<<"$HOOK_INPUT")
  return 1
}

# Every subagent that is done for now: how many paths it had recorded when it stopped.
# review-gate.sh judges those and leaves paths recorded after a resume until the next stop.
# A pause keeps the count of the last real stop, so work done before it waits as well.
touched="$(agent_file touched)"
if [[ -f "$touched" ]] && ! has_paused; then
  wc -l <"$touched" | tr -d ' ' >"$(agent_file finished)"
fi

if [[ "$(hook_field '.agent_type // .subagentType')" != "rust-style-reviewer" ]]; then
  exit 0
fi

lists=()
while IFS= read -r list; do
  lists+=("$list")
done < <(session_touched_lists)

# Every baseline any session recorded for root $1, plus this session's diff base.
all_bases() {
  local root="$1" key
  key="$(basename "$(baseline_file "$root")" | sed 's/^[^.]*\.//')"
  {
    cat /dev/null "$RUST_HOOKS_STATE"/*."$key" 2>/dev/null | cut -f 1
    diff_base "$root"
    echo
  } | grep -v '^$' | sort -u
}

stop_roots ${lists[@]+"${lists[@]}"} | while IFS= read -r root; do
  mkdir -p "$(review_dir "$root")"
  # When: commits made after it are the unreviewed ones (review_base).
  if is_git_root "$root"; then
    date +%s >"$(review_time_file "$root")"
  fi
  {
    if is_git_root "$root"; then
      all_bases "$root" | while IFS= read -r base; do
        changed_files "$root" "$base" ${lists[@]+"${lists[@]}"}
      done
    else
      changed_files "$root" "" ${lists[@]+"${lists[@]}"}
    fi
  } | grep '\.rs$' | sort -u | review_snapshots "$root" |
    while IFS=$'\t' read -r file snapshot; do
      # A file missing at review time snapshots as empty.
      cat "$file" 2>/dev/null >"$snapshot" || true
    done || true
done
