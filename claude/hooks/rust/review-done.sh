#!/usr/bin/env bash
# SubagentStop: when the rust-style-reviewer finishes, snapshot every changed .rs file of the
# repos the session works in (changes.sh review_dir). review-gate.sh then lets a pull request
# go ready only when its Rust is close to what was reviewed, so the fixes that follow a
# review do not ask for another. Never blocks.
#
# SubagentStop, not PostToolUse on the Agent tool: the reviewer usually runs in the
# background, and PostToolUse fires at spawn time, before it has read anything. The agent
# type field is `agent_type` in Claude Code and `subagentType` in Grok. A Grok reviewer runs
# in its own session, so the repos are found from its cwd alone.
#
# Every changed file of those repos is snapshotted, whether the reviewer was asked about it or
# not, and a reviewer that was cancelled counts like one that finished: the hook cannot tell
# what the reviewer read. The gate is a reminder against forgetting the review, not proof
# that one happened.
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
read_hook_input
if [[ "$(hook_field '.agent_type // .subagentType')" != "rust-style-reviewer" ]]; then
  exit 0
fi
need_tools fail-open jq git shasum perl
# shellcheck source-path=SCRIPTDIR source=changes.sh
source "$(dirname "${BASH_SOURCE[0]}")/changes.sh"

lists=()
while IFS= read -r list; do
  lists+=("$list")
done < <(session_touched_lists)

stop_roots ${lists[@]+"${lists[@]}"} | while IFS= read -r root; do
  if ! is_git_root "$root"; then
    continue
  fi
  mkdir -p "$(review_dir "$root")"
  changed_files "$root" "$(diff_base "$root")" ${lists[@]+"${lists[@]}"} |
    { grep '\.rs$' || true; } |
    awk -v prefix="$root/" 'index($0, prefix) == 1 { print substr($0, length(prefix) + 1) }' |
    review_snapshots "$root" | while IFS=$'\t' read -r file snapshot; do
    # A file deleted by review time snapshots as empty.
    cat "$root/$file" 2>/dev/null >"$snapshot" || : >"$snapshot"
  done
done
