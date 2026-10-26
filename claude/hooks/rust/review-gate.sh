#!/usr/bin/env bash
# Stop (main agent only): when this session changed enough Rust, block the stop once and
# ask for a rust-style-reviewer run. The reviewer covers what no tool checks: design
# principles, data structures, API shape, error design, docs.
#
# Only repos this session changed count (changes.sh `session_caused`), so a Q&A session in
# a dirty checkout passes. Changed files come from git, measured from changes.sh `diff_base`
# (so commits made before stopping still count) plus the paths the session's agents recorded
# (a subagent's only once it has stopped; see judged_lists). Per file, the changed lines
# are the smaller of:
#   - the session's own lines: changes from changes.sh `diff_base`, which leaves out commits
#     that only arrived (a pull, a checkout of main after a merge),
#   - lines changed since the snapshot review-done.sh took when the reviewer last finished,
#   - lines changed by commits made after that review (changes.sh `review_base`).
# The first keeps other people's work out; the second keeps fixes for a fresh review from
# demanding another; the third does the same when a pull after the review moved the
# snapshot's files.
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
read_hook_input
need_tools block-stop jq git shasum
# shellcheck source-path=SCRIPTDIR source=changes.sh
source "$(dirname "${BASH_SOURCE[0]}")/changes.sh"

# Below this many changed lines (added + removed) a review costs more than it finds: clippy
# and house-check already cover a small edit, and a typo fix should not trigger a full
# design review.
MIN_REVIEW_LINES=20

# `count<TAB>file` for the files $3... under root $1: lines added plus removed since base $2
# from one `git diff --numstat`; an untracked file, or any file outside git, counts every
# line, since all of it is new.
lines_since_base() {
  local root="$1" base="$2"
  shift 2
  {
    if is_git_root "$root"; then
      git -C "$root" -c core.quotepath=off diff --numstat "$base" -- "$@" | sed 's/^/S\t/'
      git -C "$root" -c core.quotepath=off ls-files --others --exclude-standard -- "$@" |
        sed 's/^/U\t/'
    else
      printf 'N\n'
    fi
    printf 'F\t%s\n' "$@"
  } | awk -F '\t' -v root="$root/" '
    $1 == "N" { nongit = 1; next }
    $1 == "S" { changed[root $4] = ($2 == "-" ? 0 : $2) + ($3 == "-" ? 0 : $3); next }
    $1 == "U" { untracked[root $2] = 1; next }
    $1 == "F" {
      file = $2
      n = 0
      if (file in changed) n = changed[file]
      else if (nongit || file in untracked) {
        while ((getline line < file) > 0) n++
        close(file)
      }
      printf "%d\t%s\n", n, file
    }'
}

if is_subagent || stop_is_exempt; then
  exit 0
fi

# The lists this stop judges: the main agent's whole `touched` list, and of each subagent
# only the paths it had recorded at its last SubagentStop (the count review-done.sh writes
# to its `finished` file, so settings.json runs it for every subagent), copied to a
# `judged` file. A subagent that is still running is mid-change: its parent reviews the
# work once it is handed back, and asking on every parent stop meanwhile only repeats a
# request that cannot be met yet. Only recorded paths wait: a running subagent's edits in
# a git checkout the session works in show in git's changes and count at once, so the wait
# matters for files outside git and for a subagent's own worktree, found only through its
# paths. A subagent that never stops (killed, or the session ends first) is never judged.
judged_lists() {
  local list finished count
  while IFS= read -r list; do
    if [[ "$list" == *.main.touched ]]; then
      printf '%s\n' "$list"
      continue
    fi
    finished="${list%.touched}.finished"
    count="$(cat "$finished" 2>/dev/null || true)"
    # A missing or unreadable count means the subagent has not stopped yet.
    if [[ "$count" =~ ^[0-9]+$ ]]; then
      head -n "$count" "$list" >"${list%.touched}.judged"
      printf '%s\n' "${list%.touched}.judged"
    fi
  done < <(session_touched_lists)
}

lists=()
while IFS= read -r list; do
  lists+=("$list")
done < <(judged_lists)

# Diff base of root $1: the session baseline logic for a git root, nothing otherwise.
base_of() {
  if is_git_root "$1"; then
    diff_base "$1"
  fi
}

# `root<TAB>file` for every changed .rs file of the roots this session changed, each file
# under its deepest root only.
claimed="$(stop_roots ${lists[@]+"${lists[@]}"} | while IFS= read -r root; do
  if session_caused "$root" ${lists[@]+"${lists[@]}"}; then
    changed_files "$root" "$(base_of "$root")" ${lists[@]+"${lists[@]}"} |
      { grep '\.rs$' || true; } | awk -v root="$root" '{ print root "\t" $0 }'
  fi
done | deepest_root)"

total=0
files=""
reviewed=""
while IFS= read -r root; do
  base="$(base_of "$root")"
  root_files=()
  while IFS= read -r file; do
    root_files+=("$file")
  done < <(awk -F '\t' -v root="$root" '$1 == root { print $2 }' <<<"$claimed")
  # Snapshot lookups only when this repo has a review at all.
  snapshots=""
  if [[ -d "$(review_dir "$root")" ]]; then
    snapshots="$(printf '%s\n' "${root_files[@]}" | review_snapshots "$root")"
  fi
  # The snapshots also differ by whatever arrived after the review (a pull, a checkout of
  # main); counted from review_base, only commits made after the review add to a file.
  after_review=""
  if is_git_root "$root"; then
    rbase="$(review_base "$root")"
    if [[ -n "$rbase" ]]; then
      after_review="$(lines_since_base "$root" "$rbase" "${root_files[@]}")"
    fi
  fi
  while IFS=$'\t' read -r count file after snapshot; do
    if [[ "$after" != - ]]; then
      reviewed=1
      if ((after < count)); then
        count="$after"
      fi
    fi
    if [[ -n "$snapshot" && -f "$snapshot" ]]; then
      reviewed=1
      current="$file"
      if [[ ! -f "$current" ]]; then
        current=/dev/null
      fi
      since_review="$(diff "$snapshot" "$current" | grep -c '^[<>]' || true)"
      if ((since_review < count)); then
        count="$since_review"
      fi
    fi
    # A recorded file that was deleted outside git has nothing left to review.
    if ((count == 0)); then
      continue
    fi
    total=$((total + count))
    files+="$file"$'\n'
  done < <(lines_since_base "$root" "$base" "${root_files[@]}" |
    SNAPSHOTS="$snapshots" AFTER="$after_review" awk -F '\t' '
      BEGIN {
        n = split(ENVIRON["SNAPSHOTS"], row, "\n")
        for (i = 1; i <= n; i++) if (split(row[i], f, "\t") == 2) snap[f[1]] = f[2]
        n = split(ENVIRON["AFTER"], row, "\n")
        for (i = 1; i <= n; i++) if (split(row[i], f, "\t") == 2) after[f[2]] = f[1]
      }
      # The after-review count sits before the snapshot path, which may be empty: read
      # splits on tabs as whitespace, so an empty field in the middle would shift the rest.
      { printf "%s\t%s\t%s\t%s\n", $1, $2, ($2 in after ? after[$2] : "-"), snap[$2] }')
done < <(cut -f 1 <<<"$claimed" | { grep -v '^$' || true; } | sort -u)

if ((total < MIN_REVIEW_LINES)); then
  exit 0
fi

# Once per state of the changed files: a later stop with no further Rust change (a question
# answered, a background task reported) passes instead of asking again every turn.
blocked="$(agent_file review-blocked)"
file_list=()
while IFS= read -r file; do
  if [[ -n "$file" ]]; then
    file_list+=("$file")
  fi
done <<<"$files"
state="$(fingerprint "${file_list[@]}")"
if [[ -f "$blocked" && "$(cat "$blocked")" == "$state" ]]; then
  exit 0
fi
printf '%s' "$state" >"$blocked"
since="since this session started"
if [[ -n "$reviewed" ]]; then
  since="since the last review"
fi
echo "This session changed $total lines of Rust $since. Run the rust-style-reviewer agent" \
  "on these files, then fix every blocker and major finding (or state why not); apply a" \
  "minor one only when it makes the code smaller or clearer:" >&2
# Thousands of files would bury the message; the first few name the area.
head -n 50 <<<"$files" | sed 's/^/  /' >&2
listed="$(grep -c . <<<"$files" || true)"
if ((listed > 50)); then
  echo "  ... and $((listed - 50)) more" >&2
fi
exit 2
