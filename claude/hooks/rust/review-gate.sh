#!/usr/bin/env bash
# PreToolUse (Bash): block `gh pr ready` and a non-draft `gh pr create` while the pull
# request changes 20 or more lines of Rust that no rust-style-reviewer run has seen. The
# reviewer covers what no tool checks: design principles, data structures, API shape, error
# design, docs.
#
# The pull request is the boundary: it is the unit that gets reviewed and merged, and its
# diff is plain git (merge-base with the base branch to the head commit), the same for the
# main agent, a subagent in a worktree, a later session, or Grok. An earlier gate on Stop
# had to work out which agent of which session wrote which lines, and kept breaking on
# subagents that paused, resumed, or edited by shell. A draft PR passes: drafts are opened
# so the review can be posted on them (AGENTS.md, Git). Pushes to a PR that is already
# ready are not gated.
#
# Reviewed lines come from the snapshots review-done.sh takes when the reviewer finishes.
# Per .rs file in the diff: with a snapshot, the lines that differ between it and the head
# commit; without one, the file's lines added plus removed in the diff.
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
read_hook_input
command="$(hook_field '.tool_input.command' 2>/dev/null || true)"
# Every other shell command leaves here, before any git or gh call.
if [[ "$command" != *gh*pr* ]]; then
  exit 0
fi
need_tools fail-open jq git perl shasum
# shellcheck source-path=SCRIPTDIR source=changes.sh
source "$(dirname "${BASH_SOURCE[0]}")/changes.sh"

# Below this many changed lines (added + removed) a review costs more than it finds: clippy
# and house-check already cover a small edit, and a typo fix should not need a design review.
MIN_REVIEW_LINES=20

# The gated `gh pr` call in command $1, as `dir<TAB>verb<TAB>pr<TAB>base`: the directory it
# runs in (after any `cd`), `ready` or `create`, the PR argument of `gh pr ready` (empty for
# the current branch's), and the `--base` of `gh pr create`. Nothing when the command makes
# no such call: a draft create, `ready --undo`, or another repository (`-R`), whose code is
# not here to diff.
gated_call() {
  local segment tokens dir i token verb pr base
  dir="$(hook_field '.cwd')"
  # One simple command per line (perl: BSD sed writes `\n` in a replacement as `n`).
  while IFS= read -r segment; do
    read -ra tokens <<<"$segment"
    if [[ ${#tokens[@]} -eq 0 ]]; then
      continue
    fi
    if [[ "${tokens[0]}" == cd ]]; then
      dir="$(cd "$dir" 2>/dev/null && cd "${tokens[1]/#\~/$HOME}" 2>/dev/null && pwd || true)"
      continue
    fi
    if [[ ${#tokens[@]} -lt 3 || "${tokens[0]}" != gh || "${tokens[1]}" != pr ]] ||
      [[ "${tokens[2]}" != ready && "${tokens[2]}" != create ]]; then
      continue
    fi
    verb="${tokens[2]}" pr="" base=""
    for ((i = 3; i < ${#tokens[@]}; i++)); do
      token="${tokens[i]}"
      case "$token" in
      -d | --draft | --undo | -R | --repo | --repo=* | --web | -w) return 0 ;;
      -B | --base)
        i=$((i + 1))
        base="${tokens[i]:-}"
        ;;
      --base=*) base="${token#--base=}" ;;
      -*) ;;
      *) [[ "$verb" == ready && -z "$pr" ]] && pr="$token" ;;
      esac
    done
    printf '%s\t%s\t%s\t%s\n' "$dir" "$verb" "$pr" "$base"
    return 0
  done < <(perl -pe 's/(&&|\|\||[;|()])/\n/g' <<<"$1")
}

# `head<TAB>base-branch` of the pull request: for `gh pr ready <pr>`, the PR's head commit
# and base from GitHub; otherwise HEAD of root $1 and the given base (empty: default branch).
# Falls back to HEAD when gh cannot say or the head commit is not in this clone.
pr_range() {
  local root="$1" verb="$2" pr="$3" base="$4" head="" view
  if [[ "$verb" == ready && -n "$pr" ]] && command -v gh >/dev/null &&
    view="$(cd "$root" && gh pr view "$pr" --json headRefOid,baseRefName \
      -q '.headRefOid + "\t" + .baseRefName' 2>/dev/null)"; then
    head="${view%%$'\t'*}"
    base="${view#*$'\t'}"
    if ! git -C "$root" cat-file -e "$head^{commit}" 2>/dev/null; then
      head=""
    fi
  fi
  printf '%s\t%s\n' "${head:-$(git -C "$root" rev-parse HEAD)}" "$base"
}

# The ref to diff branch $2 of root $1 against: its origin copy when there is one.
base_ref() {
  local root="$1" branch="$2"
  if [[ -z "$branch" ]]; then
    default_branch "$root"
  elif git -C "$root" rev-parse -q --verify "refs/remotes/origin/$branch" >/dev/null; then
    printf 'origin/%s' "$branch"
  else
    printf '%s' "$branch"
  fi
}

# `count<TAB>file` for every .rs file changed between commits $2 and $3 of root $1: the lines
# not yet reviewed (see the header).
unreviewed_lines() {
  local root="$1" from="$2" to="$3" count file snapshot
  git -C "$root" -c core.quotepath=off diff --numstat --no-renames "$from" "$to" -- '*.rs' |
    awk -F '\t' '{ print ($1 == "-" ? 0 : $1) + ($2 == "-" ? 0 : $2) "\t" $3 }' |
    while IFS=$'\t' read -r count file; do
      snapshot="$(printf '%s\n' "$file" | review_snapshots "$root" | cut -f 2)"
      if [[ -f "$snapshot" ]]; then
        count="$(diff "$snapshot" <(git -C "$root" show "$to:$file" 2>/dev/null) |
          grep -c '^[<>]' || true)"
      fi
      printf '%s\t%s\n' "$count" "$file"
    done
}

call="$(gated_call "$command")"
if [[ -z "$call" ]]; then
  exit 0
fi
IFS=$'\t' read -r dir verb pr base <<<"$call"
root="$(git_root "${dir:-.}")"
if [[ -z "$root" ]]; then
  exit 0
fi
IFS=$'\t' read -r head base <<<"$(pr_range "$root" "$verb" "$pr" "$base")"
ref="$(base_ref "$root" "$base")"
if [[ -z "$ref" ]] || ! from="$(git -C "$root" merge-base "$head" "$ref" 2>/dev/null)"; then
  exit 0
fi

lines="$(unreviewed_lines "$root" "$from" "$head")"
total="$(awk -F '\t' '{ n += $1 } END { print n + 0 }' <<<"$lines")"
if ((total < MIN_REVIEW_LINES)); then
  exit 0
fi
echo "BLOCKED: this pull request changes $total lines of Rust that no rust-style-reviewer" \
  "run has seen. Run the rust-style-reviewer agent on it (git diff $ref...HEAD), fix every" \
  "blocker and major finding (or state why not), commit and push, then retry. Apply a minor" \
  "finding only when it makes the code smaller or clearer. Unreviewed:" >&2
# Thousands of files would bury the message; the first few name the area.
awk -F '\t' '$1 > 0 { print "  " $2 " (" $1 " lines)" }' <<<"$lines" | head -n 50 >&2
exit 2
