#!/usr/bin/env bash
# SubagentStop (matcher rust-style-reviewer): when the reviewer finishes, snapshot every
# changed .rs file of the repos the session works in. review-gate.sh then asks for a new
# review only when the code moved far enough from what was reviewed, so the small fixes
# that follow a review do not trigger another one.
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
