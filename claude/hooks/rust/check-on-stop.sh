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
# Last, Rust files this session modified after its last test run (tests-ran.sh) ask for one.
#
# A state that was already checked is not checked again, and a second stop in a row always
# passes. Exit 2 only for findings; a hook's own failure is reported loudly and exits 1, so
# it never blocks the stop.
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
read_hook_input
need_tools block-stop jq git perl shasum cargo
# shellcheck source-path=SCRIPTDIR source=changes.sh
source "$(dirname "${BASH_SOURCE[0]}")/changes.sh"

if stop_is_exempt; then
  exit 0
fi
edited="$(agent_file edited)"
checked="$(agent_file checked)"
# Findings shown when truncating; compiler errors are always all shown.
MAX_FINDINGS=60

lists=()
while IFS= read -r list; do
  lists+=("$list")
done < <(session_touched_lists)

# `root<TAB>file` for every existing file to check, sorted.
files_to_check() {
  local root base file
  if is_subagent; then
    sort -u "$edited" 2>/dev/null | while IFS= read -r file; do
      if [[ -f "$file" ]]; then
        root="$(state_root_of "$(dirname "$file")")"
        printf '%s\t%s\n' "${root:-$(dirname "$file")}" "$file"
      fi
    done
    return 0
  fi
  stop_roots "$edited" | while IFS= read -r root; do
    if ! session_caused "$root" ${lists[@]+"${lists[@]}"} "$edited"; then
      continue
    fi
    base="$(diff_base "$root" 2>/dev/null || true)"
    changed_files "$root" "$base" "$edited" | while IFS= read -r file; do
      if [[ -f "$file" ]]; then
        printf '%s\t%s\n' "$root" "$file"
      fi
    done
  done | deepest_root
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

# The .rs files among the `root<TAB>file` pairs $1 modified after this session started (its
# first prompt, session-baseline.sh; without one, the root's baseline, or ever outside git)
# and after the session's last test run (tests-ran.sh), one per line. Sub-second times: an
# edit and a test run often share a second.
untested_files() {
  local root file start
  while IFS=$'\t' read -r root file; do
    if [[ "$file" == *.rs ]]; then
      start="$(session_file started)"
      if [[ ! -f "$start" ]]; then
        start="$(baseline_file "$root")"
      fi
      printf '%s\t%s\n' "$start" "$file"
    fi
  done <<<"$1" | STAMP="$(session_file tests-ran)" perl -MTime::HiRes=stat -F'\t' -lane '
    my $since = (stat $F[0])[9] // 0;
    my $run = (stat $ENV{STAMP})[9];
    $since = $run if defined $run && $run > $since;
    my $modified = (stat $F[1])[9];
    print $F[1] if defined $modified && $modified > $since;'
}

pairs="$(files_to_check)"
files=()
while IFS= read -r file; do
  if [[ -n "$file" ]]; then
    files+=("$file")
  fi
done < <(cut -f 2 <<<"$pairs" | sort -u)

if [[ ${#files[@]} -eq 0 ]]; then
  : >"$edited"
  exit 0
fi
state="$(fingerprint "${files[@]}")"
if [[ -f "$checked" && "$(cat "$checked")" == "$state" ]]; then
  exit 0
fi
ranges="$(ranges_for "$pairs")"
internal=0

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
printf '%s' "$state" >"$checked"

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

untested="$(untested_files "$pairs")"
if [[ -z "$findings" && -z "$untested" ]]; then
  : >"$edited"
  exit "$internal"
fi
if [[ -n "$findings" ]]; then
  echo "Checks failed: compiler errors and clippy, house-check, or column-limit findings on" \
    "lines you changed. Fix them, or for a finding that is wrong here use" \
    "#[expect(lint, reason = \"...\")] or // house-check: allow(ID): <reason>:" >&2
  printf '%s\n' "$findings" >&2
fi
if [[ -n "$untested" ]]; then
  echo "No test run since this Rust changed: run the tests of the changed packages" \
    "(cargo nextest run, or cargo test), or say why not:" >&2
  awk 'NR <= 20 { print "  " $0 } END { if (NR > 20) print "  ... and " NR - 20 " more" }' \
    <<<"$untested" >&2
fi
exit 2
