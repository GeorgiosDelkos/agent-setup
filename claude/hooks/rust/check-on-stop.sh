#!/usr/bin/env bash
# Stop and SubagentStop: check what changed and block the stop once with the findings.
#
# What is checked:
#   - Main agent: every repo this session changed (changes.sh `session_caused`): git's
#     changes since the branch's base (changes.sh `diff_base`), untracked files, and the
#     paths it recorded, so Bash edits and commits made before stopping are covered. A repo
#     that was only read (a Q&A session in a dirty checkout) is skipped.
#   - Subagent: only the paths it recorded itself; it never answers for the parent's work.
#     Nothing recorded, nothing checked.
# Checks: clippy (run-clippy.sh, over the changed packages and their workspace dependents:
# compiler errors always, from any of those packages for the main agent and in its own files
# for a subagent; lint warnings on changed lines only), then, in a repo that opted in to the
# house rules (house_opted_in), house-check.pl and the column limit on changed lines. Changed
# lines are the hunks since that base; an untracked or non-git file counts as all changed.
# Last, Rust files this session modified after its last test run (tests-ran.sh) ask for one,
# and Python, TypeScript, shell, and workflow files modified after that language's last
# check ask for one. The two are separate state (`checked` and `checked-lang`): a language
# edit does not re-run clippy or repeat Rust findings already shown.
# A file a checkout, reset, clean merge, rebase or pull wrote, and nothing changed since, is
# not counted (not_written_by_git).
# A root under the session scratchpad is skipped unless it is on a git branch (scratch_exempt).
#
# A state that was already checked is not checked again, and a second stop in a row always
# passes. Exit 2 only for findings; a hook's own failure is reported loudly and exits 1, so
# it never blocks the stop.
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
read_hook_input
# cargo is required only when this stop has Rust to check. A Python-only machine must
# not hear "the Rust checks are off" on every stop.
need_tools block-stop jq git perl shasum
# shellcheck source-path=SCRIPTDIR source=changes.sh
source "$(dirname "${BASH_SOURCE[0]}")/changes.sh"

if stop_is_exempt; then
  exit 0
fi
edited="$(agent_file edited)"
# Findings shown when truncating; compiler errors are always all shown.
MAX_FINDINGS=60

lists=()
while IFS= read -r list; do
  lists+=("$list")
done < <(session_touched_lists)

# rust for .rs and Cargo.toml, lang for lang_skill_for, nothing for a vendor tree.
# A .rs inside one of those trees stays rust: clippy still sees it.
pair_kind() {
  case "$1" in
  *.rs | */Cargo.toml)
    printf '%s' rust
    return 0
    ;;
  esac
  if [[ -n "$(lang_skill_for "$1")" ]]; then
    printf '%s' lang
  fi
  return 0
}

# kind<TAB>root<TAB>file rows, each file once, under its deepest root. A recorded path
# inside a nested git repo also lies under any directory root above it; counted under
# both, it was reported twice and diffed as all-new under the outer one.
deepest_tagged() {
  awk -F '\t' '{
    if (!($3 in best) || length($2) > length(best[$3])) {
      best[$3] = $2
      kind[$3] = $1
    }
  }
  END { for (f in best) printf "%s\t%s\t%s\n", kind[f], best[f], f }' | sort
}

# One walk. session_caused and diff_base run once per root; the caller splits the rows
# into Rust and language. A subagent's list never holds an exempt path: fmt-on-edit.sh
# does not record one. Nothing recorded, nothing checked.
changed_pairs() {
  local root base file kind
  if is_subagent; then
    if [[ -f "$edited" ]]; then
      sort -u "$edited" | while IFS= read -r file; do
        [[ -f "$file" ]] || continue
        kind="$(pair_kind "$file")"
        [[ -n "$kind" ]] || continue
        root="$(state_root_of "$(dirname "$file")")"
        printf '%s\t%s\t%s\n' "$kind" "${root:-$(dirname "$file")}" "$file"
      done | deepest_tagged
    fi
    return 0
  fi
  # Per root, not per file: a root is a git top level or a crate or directory outside git,
  # so every file under it shares its answer.
  stop_roots "$edited" | while IFS= read -r root; do
    if scratch_exempt "$root/" ||
      ! session_caused "$root" ${lists[@]+"${lists[@]}"} "$edited"; then
      continue
    fi
    base="$(diff_base "$root" 2>/dev/null || true)"
    changed_matching "$root" "$base" "$SCAN_RE" "$edited" |
      while IFS= read -r file; do
        [[ -f "$file" ]] || continue
        kind="$(pair_kind "$file")"
        [[ -n "$kind" ]] || continue
        printf '%s\t%s\t%s\n' "$kind" "$root" "$file"
      done
  done | deepest_tagged
}

# Changed line ranges for the `root<TAB>file` pairs $1, one git diff per root.
ranges_for() {
  local pairs="$1" root base
  cut -f 1 <<<"$pairs" | sort -u | while IFS= read -r root; do
    base=""
    if is_git_root "$root"; then
      base="$(diff_base "$root")"
    fi
    local root_files=()
    while IFS= read -r file; do
      root_files+=("$file")
    done < <(awk -F '\t' -v root="$root" '$1 == root { print $2 }' <<<"$pairs")
    # Never with no files: an empty pathspec would mean the whole repo.
    if [[ ${#root_files[@]} -gt 0 ]]; then
      changed_ranges "$root" "$base" "${root_files[@]}"
    fi
  done
}

# Lines over the max_width of the nearest rustfmt.toml. Lines with a URL are exempt: a URL
# cannot be broken.
column_findings() {
  local file="$1"
  # Perl with -CSD counts characters, not bytes; malformed UTF-8 only skews a count.
  FILE="$file" MAX="$(max_width_for "$(dirname "$file")")" perl -CSD -ne '
    no warnings;
    chomp;
    if (length > $ENV{MAX} && !m{https?://}) {
      printf "%s:%d: line is %d columns (limit %d)\n", $ENV{FILE}, $., length, $ENV{MAX};
    }' "$file" 2>/dev/null || true
}

# Clippy output for the files $@: cargo's own errors (unlocated), located compiler errors
# (all for the main agent, own files for a subagent), and located warnings (filtered to
# changed lines by the caller). One run per workspace, scoped to the crates of the files.
clippy_output() {
  local file crate workspace pairs=""
  while IFS= read -r crate; do
    # A broken manifest makes cargo fail here; its error (stderr, sent to fd 3 = this
    # function's output) is a finding, not something to swallow.
    { workspace="$(workspace_root_of "$crate" 2>&3)"; } 3>&1
    if [[ -n "$workspace" ]]; then
      pairs+="$workspace"$'\t'"$crate"$'\n'
    fi
  done < <(for file in "$@"; do
    crate_dir_of "$(dirname "$file")"
    echo
  done | { grep -v '^$' || true; } | sort -u)

  cut -f 1 <<<"$pairs" | { grep -v '^$' || true; } | sort -u | while IFS= read -r workspace; do
    local crates=()
    while IFS= read -r crate; do
      crates+=("$crate")
    done < <(awk -F '\t' -v ws="$workspace" '$1 == ws { print $2 }' <<<"$pairs")
    bash "$RUST_HOOKS_DIR/run-clippy.sh" "$workspace" "${crates[@]}" 2>&1 || true
  done
}

# The files among $@ whose repo opted in to the house rules, one per line. $@ is sorted, so
# files of one crate are adjacent and the opt-in lookup runs once per crate.
opted_in_files() {
  local file crate last_crate="" last_opted=false
  for file in "$@"; do
    crate="$(crate_dir_of "$(dirname "$file")")"
    if [[ -z "$crate" ]]; then
      continue
    fi
    if [[ "$crate" != "$last_crate" ]]; then
      last_crate="$crate"
      last_opted=false
      if house_opted_in "$crate"; then
        last_opted=true
      fi
    fi
    if $last_opted; then
      printf '%s\n' "$file"
    fi
  done
}

# Prints paths from `stamp<TAB>path` rows on stdin modified after that stamp and after the
# session file $1, when it exists, less the files git wrote since then (not_written_by_git
# over the `root<TAB>file` pairs $2). Sub-second times: an edit and a check often share a second.
newer_than() {
  STAMP="$1" perl -MTime::HiRes=stat -F'\t' -lane '
    my $since = (stat $F[0])[9] // 0;
    my $run = (stat $ENV{STAMP})[9];
    $since = $run if defined $run && $run > $since;
    my $modified = (stat $F[1])[9];
    print $F[1] if defined $modified && $modified > $since;' | not_written_by_git "$2" "$1"
}

# The files read on stdin (from the `root<TAB>file` pairs $1) less the ones git wrote and the
# session has not changed since: a checkout, reset, clean merge, rebase or pull rewrites
# every file it touches, so its mtime alone made reviewing a branch read as editing all of
# it. A file counts as git's when it matches HEAD, a HEAD move since the session's cutoff
# (its start or the check stamp $2) changed it (`git diff` of the move's old and new commit),
# HEAD still holds the content that move left (so a commit in the 1s of slack still asks),
# and it was last written no later than that move. The reflog keeps whole seconds, and a
# move logs after it writes, hence the 1s of slack. An ignored file is in no commit's diff,
# so it is never git's.
#
# A commit is not such a move: a file the session edited and then committed matches HEAD
# too, and is still untested; a later move that does not change it (`checkout -b`, a merge
# of an unrelated branch, `stash`, which logs a reset to HEAD) leaves it counted. Nor is a
# conflicted merge, which logs only its commit: the merged files are new code. Missed, as
# the cost of judging by what git wrote: a rebase or `pull --rebase` of the session's own
# commits, or switching away from them and back, rewrites its files with its own content,
# and they read as git's.
not_written_by_git() {
  local pairs="$1" stamp="$2" root start cutoff dirty written file commit rel
  local head_blob moved_blob
  local git_wrote=""
  # No associative array: the hooks run under macOS's bash 3.2.
  while IFS= read -r root; do
    if ! is_git_root "$root"; then
      continue
    fi
    start="$(session_file started)"
    if [[ ! -f "$start" ]]; then
      start="$(baseline_file "$root")"
    fi
    cutoff="$(perl -e 'my $m = 0; for (@ARGV) { my $t = (stat $_)[9];
      $m = $t if defined $t && $t > $m } print int($m)' "$start" "$stamp")"
    # `<time><TAB><commit><TAB><path>` for each file a move since the cutoff changed.
    written="$(git_moves_since "$root" "$cutoff")"
    if [[ -z "$written" ]]; then
      continue
    fi
    # Changed against HEAD, or not in it at all: an untracked file matches no commit.
    dirty="$(
      git -c core.quotepath=off -C "$root" diff --name-only HEAD 2>/dev/null || true
      git -c core.quotepath=off -C "$root" ls-files --others --exclude-standard \
        2>/dev/null || true
    )"
    # `<file><TAB><commit>` for each candidate: clean, changed by a move, written no later
    # than the latest move that changed it, whose new commit is named.
    while IFS=$'\t' read -r file commit; do
      # HEAD's content for the path must be what that move left, not a later commit's.
      rel="${file#"$root"/}"
      head_blob="$(git -C "$root" rev-parse -q --verify "HEAD:$rel" 2>/dev/null || true)"
      moved_blob="$(git -C "$root" rev-parse -q --verify "$commit:$rel" 2>/dev/null || true)"
      if [[ -n "$head_blob" && "$head_blob" == "$moved_blob" ]]; then
        git_wrote+="$file"$'\n'
      fi
    done < <(awk -F '\t' -v root="$root" '$1 == root { print $2 }' <<<"$pairs" |
      ROOT="$root" DIRTY="$dirty" WRITTEN="$written" perl -MTime::HiRes=stat -lne '
        BEGIN {
          %dirty = map { ("$ENV{ROOT}/$_" => 1) } split /\n/, $ENV{DIRTY};
          for (split /\n/, $ENV{WRITTEN}) {
            my ($time, $commit, $path) = split /\t/, $_, 3;
            next if defined $latest{$path} && $time <= $latest{$path};
            ($latest{$path}, $commit{$path}) = ($time, $commit);
          }
        }
        my $modified = (stat $_)[9];
        print "$_\t$commit{$_}" if defined $modified && !$dirty{$_} && defined $latest{$_}
          && $modified <= $latest{$_} + 1;')
  done < <(cut -f 1 <<<"$pairs" | sort -u)
  # Every line of stdin not in that list. The list always has a line (`%s\n`): an empty
  # first input would make `NR == FNR` hold for stdin too, and swallow it.
  awk 'NR == FNR { if ($0 != "") wrote[$0] = 1; next } !($0 in wrote)' \
    <(printf '%s\n' "$git_wrote") -
}

# `<time><TAB><new commit><TAB><root>/<path>` for each file a HEAD move (checkout, reset,
# clean merge, rebase,
# pull) in the reflog of $1 at or after epoch second $2 changed, from the diff of the move's
# old and new commit (the next older reflog entry's commit is the old one). Nothing for a
# repo with no reflog.
git_moves_since() {
  local root="$1" cutoff="$2" time old new
  while read -r time old new; do
    git -c core.quotepath=off -C "$root" diff --name-only "$old" "$new" 2>/dev/null |
      awk -v time="$time" -v new="$new" -v root="$root" \
        '{ print time "\t" new "\t" root "/" $0 }' || true
  done < <({ git -C "$root" reflog show --date=unix --format='%gd %H %gs' HEAD 2>/dev/null ||
    true; } | awk -v cutoff="$cutoff" '
      { sub(/^HEAD@\{/, "", $1); sub(/\}$/, "", $1)
        time[NR] = $1; sha[NR] = $2; move[NR] = ($3 ~ /^(checkout|reset|merge|rebase|pull)/) }
      END { for (i = 1; i < NR; i++)
              if (move[i] && time[i] >= cutoff) print time[i], sha[i + 1], sha[i] }')
}

# The files among the `root<TAB>file` pairs $1 that skill $2 covers, modified after this
# session started and after its last check of that skill (tests-ran.sh).
unchecked_files() {
  local root file since skill="$2" started
  # session_file runs jq. Read the path once; a missing stamp falls back per root.
  started="$(session_file started)"
  while IFS=$'\t' read -r root file; do
    if [[ "$skill" == rust && "$file" == *.rs ]] ||
      [[ "$skill" != rust && "$(lang_skill_for "$file")" == "$skill" ]]; then
      if [[ -f "$started" ]]; then
        since="$started"
      else
        since="$(baseline_file "$root")"
      fi
      printf '%s\t%s\n' "$since" "$file"
    fi
  done <<<"$1" | newer_than "$(session_file "$3")" "$1"
}

tagged="$(changed_pairs)"
pairs="$(awk -F '\t' '$1 == "rust" { printf "%s\t%s\n", $2, $3 }' <<<"$tagged")"
files=()
while IFS= read -r file; do
  if [[ -n "$file" ]]; then
    files+=("$file")
  fi
done < <(cut -f 2 <<<"$pairs" | sort -u)

lang="$(awk -F '\t' '$1 == "lang" { printf "%s\t%s\n", $2, $3 }' <<<"$tagged")"
lang_files=()
while IFS= read -r file; do
  if [[ -n "$file" ]]; then
    lang_files+=("$file")
  fi
done < <(cut -f 2 <<<"$lang" | sort -u)

if [[ ${#files[@]} -eq 0 && ${#lang_files[@]} -eq 0 ]]; then
  : >"$edited"
  exit 0
fi
# Separate fingerprints: a language edit must not re-run clippy on unchanged Rust.
checked="$(agent_file checked)"
checked_lang="$(agent_file checked-lang)"
rust_state="$(fingerprint ${files[@]+"${files[@]}"})"
lang_state="$(fingerprint ${lang_files[@]+"${lang_files[@]}"})"
run_rust=1
run_lang=1
if [[ -f "$checked" && "$(cat "$checked")" == "$rust_state" ]]; then
  run_rust=0
fi
if [[ -f "$checked_lang" && "$(cat "$checked_lang")" == "$lang_state" ]]; then
  run_lang=0
fi
if [[ "$run_rust" -eq 0 && "$run_lang" -eq 0 ]]; then
  exit 0
fi
internal=0
findings=""
# Missing cargo must not skip the language ask, and must not store a Rust
# fingerprint for a check that did not run.
cargo_missing=0
if [[ "$run_rust" -eq 1 ]]; then
  if [[ ${#files[@]} -gt 0 ]]; then
    if ! command -v cargo >/dev/null 2>&1; then
      echo "Rust hooks ($(basename "$0")): missing tool(s): cargo. Install them" \
        "(~/.config/agents/SETUP.md, 'Install on a new machine'); the Rust checks are off" \
        "until then." >&2
      cargo_missing=1
    else
      ranges="$(ranges_for "$pairs")"
      clippy="$(clippy_output "${files[@]}")"
      located='^/[^:]*:[0-9]+:[0-9]+: '
      # Cargo's own errors and unknown-lint warnings, in their original order (a build-script
      # failure's cause lines follow its `error:` line).
      unlocated="$(
        grep -vE "$located" <<<"$clippy" | grep -v '^warning: ' | grep -v '^$' || true
        grep -E '^warning: unknown lint' <<<"$clippy" || true
      )"
      errors="$(grep -E "$located"'error' <<<"$clippy" || true)"
      if is_subagent; then
        errors="$(printf '%s\n' "${files[@]}" | awk 'NR == FNR { own[$0] = 1; next }
    { path = $0; sub(/:[0-9]+:[0-9]+: .*$/, "", path); if (path in own) print }' - \
          <(printf '%s\n' "$errors"))"
      fi
      warnings="$(grep -E "$located"'warning' <<<"$clippy" | in_changed_lines "$ranges" || true)"

      # House rules only where the repo asked for them; elsewhere the repo's own conventions win.
      house=""
      house_files=()
      while IFS= read -r file; do
        house_files+=("$file")
      done < <(opted_in_files "${files[@]}")
      if [[ ${#house_files[@]} -gt 0 ]]; then
        code=0
        house="$(perl "$RUST_HOOKS_DIR/house-check.pl" "${house_files[@]}" 2>/dev/null)" || code=$?
        if [[ $code -gt 1 ]]; then
          internal_error "house-check.pl exited $code; its findings are missing from this check"
          internal=1
        fi
      fi
      for file in ${house_files[@]+"${house_files[@]}"}; do
        if [[ "$file" == *.rs ]]; then
          house+=$'\n'"$(column_findings "$file")"
        fi
      done
      house="$(in_changed_lines "$ranges" <<<"$house" || true)"

      # Located findings sorted: compiler errors first, then by file and line.
      sorted="$(printf '%s\n%s\n%s\n' "$errors" "$warnings" "$house" | grep -v '^$' | sort -u |
        awk '{
    rank = ($0 ~ /^[^:]*:[0-9]+:[0-9]+: error/) ? 0 : 1
    path = $0; sub(/:[0-9]+:.*$/, "", path)
    line = $0; sub(/^[^:]*:/, "", line); sub(/:.*$/, "", line)
    printf "%d\t%s\t%d\t%s\n", rank, path, line, $0
  }' | sort -t "$(printf '\t')" -k1,1n -k2,2 -k3,3n | cut -f 4- || true)"
      error_count="$(grep -cE '^[^:]*:[0-9]+:[0-9]+: error' <<<"$sorted" || true)"
      findings="$(
        if [[ -n "$unlocated" ]]; then printf '%s\n' "$unlocated"; fi
        if [[ -n "$sorted" ]]; then
          head -n "$((error_count > MAX_FINDINGS ? error_count : MAX_FINDINGS))" <<<"$sorted"
        fi
      )"
    fi
  fi
  if [[ "$cargo_missing" -eq 0 ]]; then
    printf '%s' "$rust_state" >"$checked"
  fi
fi
if [[ "$run_lang" -eq 1 ]]; then
  printf '%s' "$lang_state" >"$checked_lang"
fi

# Reminds once when files of skill $2 in the pairs $1 changed after session file $3.
# Returns 1 when it printed a reminder.
ask_unchecked() {
  local files heading
  files="$(unchecked_files "$1" "$2" "$3")"
  if [[ -z "$files" ]]; then
    return 0
  fi
  case "$2" in
  rust)
    heading="No test run since this Rust changed: run the tests of the changed"
    heading+=" packages (cargo nextest run, or cargo test), or say why not:"
    ;;
  python-style)
    heading="No check since this Python changed: run the project's tests and"
    heading+=" linters (pytest, ruff, ty check), or say why not:"
    ;;
  ts-style)
    heading="No check since this TypeScript changed: run the project's tests and"
    heading+=" linters (vitest run, oxlint, tsc --noEmit), or say why not:"
    ;;
  bash-style)
    heading="No check since this shell changed: run shellcheck and shfmt -d,"
    heading+=" or say why not:"
    ;;
  gh-actions-style)
    heading="No check since this workflow changed: run actionlint and zizmor,"
    heading+=" or say why not:"
    ;;
  *) return 0 ;;
  esac
  echo "$heading" >&2
  awk 'NR <= 20 { print "  " $0 } END { if (NR > 20) print "  ... and " NR - 20 " more" }' \
    <<<"$files" >&2
  return 1
}

untested=0
if [[ "$run_rust" -eq 1 ]]; then
  ask_unchecked "$pairs" rust tests-ran || untested=1
fi
if [[ "$run_lang" -eq 1 ]]; then
  ask_unchecked "$lang" python-style checks-python-style || untested=1
  ask_unchecked "$lang" ts-style checks-ts-style || untested=1
  ask_unchecked "$lang" bash-style checks-bash-style || untested=1
  ask_unchecked "$lang" gh-actions-style checks-gh-actions-style || untested=1
fi
if [[ "$cargo_missing" -eq 1 ]]; then
  exit 2
fi
# A language-only stop must not drop a Rust file whose check did not run. A subagent's
# next stop sees only `edited`, and its compiler errors are filtered to those files.
if [[ -z "$findings" && "$untested" -eq 0 ]]; then
  if [[ "$run_rust" -eq 1 ]]; then
    : >"$edited"
  fi
  exit "$internal"
fi
if [[ -n "$findings" ]]; then
  echo "Checks failed: compiler errors and clippy, house-check, or column-limit findings on" \
    "lines you changed. Fix them, or for a finding that is wrong here use" \
    "#[expect(lint, reason = \"...\")] or // house-check: allow(ID): <reason>:" >&2
  printf '%s\n' "$findings" >&2
fi
exit 2
