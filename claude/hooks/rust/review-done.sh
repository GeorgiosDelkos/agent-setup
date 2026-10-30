#!/usr/bin/env bash
# SubagentStop: when the rust-style-reviewer finishes, snapshot every changed .rs file of the
# repos the session works in, in every worktree of each (changes.sh review_dir).
# review-gate.sh then lets a pull request go ready only when its Rust is close to what was
# reviewed, so the fixes that follow a review do not ask for another. Never blocks.
#
# SubagentStop, not PostToolUse on the Agent tool: the reviewer usually runs in the
# background, and PostToolUse fires at spawn time, before it has read anything. The agent
# type field is `agent_type` in Claude Code and `subagentType` in Grok. A Grok reviewer runs
# in its own session, so the repos are found from its cwd alone.
#
# Every worktree, not only the session's roots: a reviewer started from the main session has
# the main checkout as its root, while the branch it reviewed is checked out in a subagent's
# worktree. Every changed file of those worktrees is snapshotted, whether the reviewer was
# asked about it or not, and a reviewer that was cancelled counts like one that finished: the
# hook cannot tell what the reviewer read. The gate is a reminder against forgetting the
# review, not proof that one happened.
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

# Physical paths of every worktree of the git repos among the roots on stdin, one per line,
# sorted. A bare repository has no files to snapshot, and a worktree whose directory is gone
# (prunable) has nothing to read.
worktrees() {
  local root dir
  while IFS= read -r root; do
    if is_git_root "$root"; then
      git -C "$root" worktree list --porcelain | awk '
        /^worktree / { if (dir != "") print dir; dir = substr($0, 10) }
        /^bare$/ { dir = "" }
        END { if (dir != "") print dir }'
    fi
  done | while IFS= read -r dir; do
    if [[ -d "$dir" ]]; then
      (cd "$dir" && pwd -P)
    fi
  done | sort -u
}

# Commit worktree $1's changes are measured from: its merge-base with the default branch, the
# base the gate measures a pull request from; else HEAD; else the empty tree. Not diff_base:
# that records a session baseline, and hashes the repo's whole state, in every worktree the
# review visits, which this session may never touch.
review_base() {
  local root="$1" branch
  branch="$(default_branch "$root")"
  if [[ -n "$branch" ]] && git -C "$root" merge-base HEAD "$branch" 2>/dev/null; then
    return 0
  fi
  git -C "$root" rev-parse -q --verify HEAD || printf '%s' "$EMPTY_TREE"
}

lists=()
while IFS= read -r list; do
  lists+=("$list")
done < <(session_touched_lists)

stop_roots ${lists[@]+"${lists[@]}"} | worktrees | while IFS= read -r root; do
  mkdir -p "$(review_dir "$root")"
  changed_files "$root" "$(review_base "$root")" ${lists[@]+"${lists[@]}"} |
    { grep '\.rs$' || true; } |
    awk -v prefix="$root/" 'index($0, prefix) == 1 { print substr($0, length(prefix) + 1) }' |
    review_keys "$root" | save_review_snapshots "$root"
done
