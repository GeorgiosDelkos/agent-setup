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
# A file keeps a snapshot per reviewed version (changes.sh review_dir), so reviews of one
# file on parallel branches do not replace each other. Per .rs file in the diff: none when a
# snapshot holds its version at the head commit; else the fewest lines that differ between
# any of its snapshots and the head commit; without one, its lines added plus removed in the
# diff.
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

# git's blob id of an empty file (`git hash-object /dev/null`).
EMPTY_BLOB=e69de29bb2d1d6434b8b29ae775ad8c2e48c5391

# Unit separator: the field and word separator below. Unlike a tab it is not IFS whitespace,
# so `read` keeps an empty field instead of shifting the rest left.
US=$'\x1f'

# The simple commands of shell text $1, one per line, their words joined by US. Quotes are
# resolved as the shell would, heredoc bodies are dropped, and an operator inside quotes does
# not end a command, so a `gh pr ready` written in a commit message or a PR comment is not
# read as one that runs. Not a shell parser: no expansions, and an unclosed quote runs to
# the end of the text.
simple_commands() {
  perl -0777 -ne '
    s/<<-?[ \t]*([\x27"]?)(\w+)\1([^\n]*)\n.*?^\t*\2[ \t]*$/$3/gms;
    my (@words, $word, $open);
    my $end_word = sub { push @words, $word if $open; ($word, $open) = ("", 0) };
    my $end_command = sub { $end_word->(); print join("\x1f", @words), "\n" if @words;
      @words = () };
    ($word, $open) = ("", 0);
    while (length) {
      if (s/^(?:&&|\|\||[;|()&\n])//) { $end_command->() }
      elsif (s/^[ \t]+//) { $end_word->() }
      elsif (s/^\x27([^\x27]*)(?:\x27|\z)//) { ($word, $open) = ($word . $1, 1) }
      elsif (s/^"((?:[^"\\]|\\.)*)(?:"|\z)//s) { ($word, $open) = ($word . $1, 1) }
      elsif (s/^\\(.)//s) { ($word, $open) = ($word . $1, 1) }
      elsif (s/^([^\s\x27"\\;&|()]+)//) { ($word, $open) = ($word . $1, 1) }
      else { s/^.//s }
    }
    $end_command->();' <<<"$1"
}

# OWNER/REPO of a GitHub repository given as `gh -R` takes it (OWNER/REPO, HOST/OWNER/REPO,
# or a URL), lowercased.
repo_name() {
  printf '%s' "$1" | sed -E 's#^[a-z]+://##; s#\.git$##; s#/$##' | awk -F/ '{
    print tolower($(NF - 1) "/" $NF) }'
}

# The gated `gh pr` call in command $1, as `dir verb pr base head` joined by US: the directory
# it runs in (after any `cd`), `ready` or `create`, the PR argument of `gh pr ready`, and the
# `--base` and `--head` of `gh pr create`. Leading `VAR=value`, `command` and `env` words run
# the same gh. Nothing when the command makes no such call; a draft create, `ready --undo`,
# `--web` and `--dry-run` are skipped, and so is `-R` naming another repository, whose code is
# not here to diff.
gated_call() {
  local words dir i word verb pr base head repo skip
  dir="$(hook_field '.cwd')"
  while IFS="$US" read -r -a words; do
    while [[ ${#words[@]} -gt 0 ]] && [[ "${words[0]}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ||
      "${words[0]}" == command || "${words[0]}" == env ]]; do
      words=("${words[@]:1}")
    done
    if [[ ${#words[@]} -eq 0 ]]; then
      continue
    fi
    if [[ "${words[0]}" == cd ]]; then
      word="${words[1]:-$HOME}"
      dir="$(cd "$dir" 2>/dev/null && cd "${word/#\~/$HOME}" 2>/dev/null && pwd || true)"
      continue
    fi
    if [[ ${#words[@]} -lt 3 || "${words[0]}" != gh || "${words[1]}" != pr ]] ||
      [[ "${words[2]}" != ready && "${words[2]}" != create ]]; then
      continue
    fi
    verb="${words[2]}" pr="" base="" head="" repo="" skip=""
    for ((i = 3; i < ${#words[@]}; i++)); do
      word="${words[i]}"
      case "$word" in
      -d | --draft | --undo | --web | -w | --dry-run) skip=1 ;;
      -R | --repo) i=$((i + 1)) repo="${words[i]:-}" ;;
      -B | --base) i=$((i + 1)) base="${words[i]:-}" ;;
      -H | --head) i=$((i + 1)) head="${words[i]:-}" ;;
      --repo=*) repo="${word#--repo=}" ;;
      --base=*) base="${word#--base=}" ;;
      --head=*) head="${word#--head=}" ;;
      -*) ;;
      *) if [[ "$verb" == ready && -z "$pr" ]]; then pr="$word"; fi ;;
      esac
    done
    if [[ -n "$repo" ]] && [[ "$(repo_name "$repo")" != "$(this_repo "$dir")" ]]; then
      skip=1
    fi
    if [[ -z "$skip" ]]; then
      printf '%s\n' "$dir$US$verb$US$pr$US$base$US$head"
      return 0
    fi
  done < <(simple_commands "$1")
}

# OWNER/REPO of the repository in directory $1, lowercased; nothing without gh.
this_repo() {
  local name
  if command -v gh >/dev/null &&
    name="$(cd "$1" 2>/dev/null && gh repo view --json nameWithOwner -q .nameWithOwner)"; then
    repo_name "$name"
  fi
}

# `head base-branch` of the pull request (joined by US), for root $1 and a gated call's verb,
# PR, base and head:
#   - `gh pr ready`: the PR's head commit and base branch from `gh pr view`, which a stacked
#     PR needs (its base is not the default branch). When gh cannot say, HEAD and the
#     default branch.
#   - `gh pr create`: the `--head` branch when it exists here, else HEAD; the `--base` given,
#     else the default branch.
# Fails, saying so, when the PR's head commit is not in this clone: judging HEAD instead could
# judge another branch.
pr_range() {
  local root="$1" verb="$2" pr="$3" base="$4" head="$5" view args=()
  if [[ "$verb" == ready ]]; then
    head=""
    if [[ -n "$pr" ]]; then
      args=("$pr")
    fi
    if command -v gh >/dev/null &&
      view="$(cd "$root" && gh pr view ${args[@]+"${args[@]}"} \
        --json headRefOid,baseRefName -q '.headRefOid + "\u001f" + .baseRefName' 2>/dev/null)"; then
      head="${view%%"$US"*}"
      base="${view#*"$US"}"
      if ! git -C "$root" cat-file -e "$head^{commit}" 2>/dev/null; then
        echo "review gate: the PR's head commit $head is not in this clone; fetch it to have" \
          "the PR checked" >&2
        return 1
      fi
    fi
  elif [[ -n "$head" ]]; then
    head="$(git -C "$root" rev-parse -q --verify "${head##*:}^{commit}" || true)"
  fi
  printf '%s\n' "${head:-$(git -C "$root" rev-parse HEAD)}$US$base"
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
# not yet reviewed (see the header), never more than the file's own lines in the diff, so a
# snapshot from an older review of the file cannot charge the PR for others' changes.
unreviewed_lines() {
  local root="$1" from="$2" to="$3" count blob file key snapshot content since
  # --raw gives each file's blob id at $3, printed before the --numstat lines. A deleted file
  # has the all-zero id; its reviewed state is the empty snapshot.
  git -C "$root" -c core.quotepath=off diff --raw --numstat --no-abbrev --no-renames \
    "$from" "$to" -- '*.rs' | awk -F '\t' -v empty="$EMPTY_BLOB" '
      /^:/ { split($1, raw, " "); blob[$2] = raw[4] ~ /^0+$/ ? empty : raw[4]; next }
      { print ($1 == "-" ? 0 : $1) + ($2 == "-" ? 0 : $2) "\t" blob[$3] "\t" $3 }' |
    review_keys "$root" | while IFS=$'\t' read -r count blob file key; do
    if [[ -f "$key.$blob" ]]; then
      count=0
    fi
    content=""
    # `$key*` also matches the one unsuffixed snapshot per path that earlier versions wrote.
    for snapshot in "$key"*; do
      if ((count == 0)); then
        break
      fi
      # No match leaves the pattern itself; a concurrent prune can remove a match.
      if [[ ! -f "$snapshot" ]]; then
        continue
      fi
      # Read once per file, not per snapshot. The trailing `.` keeps trailing newlines,
      # which command substitution would strip.
      if [[ -z "$content" ]]; then
        content="$(
          git -C "$root" show "$to:$file" 2>/dev/null || true
          echo .
        )"
      fi
      since="$(diff "$snapshot" <(printf '%s' "${content%.}") | grep -c '^[<>]' || true)"
      if ((since < count)); then
        count="$since"
      fi
    done
    printf '%s\t%s\n' "$count" "$file"
  done
}

call="$(gated_call "$command")"
if [[ -z "$call" ]]; then
  exit 0
fi
IFS="$US" read -r dir verb pr base head <<<"$call"
root="$(git_root "${dir:-.}")"
if [[ -z "$root" ]]; then
  exit 0
fi
if ! range="$(pr_range "$root" "$verb" "$pr" "$base" "$head")"; then
  exit 0
fi
IFS="$US" read -r head base <<<"$range"
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
# Thousands of files would bury the message; the first few name the area. awk, not head:
# head exits early and pipefail would turn the block into exit 141, which lets the call run.
awk -F '\t' '$1 > 0 && ++n <= 50 { print "  " $2 " (" $1 " lines)" }' <<<"$lines" >&2
exit 2
