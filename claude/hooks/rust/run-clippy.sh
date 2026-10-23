#!/usr/bin/env bash
# Run clippy over the packages of one cargo workspace that a change touched, for
# check-on-stop.sh, and print its diagnostics, one per line:
#   /abs/path:LINE:COL: LEVEL[CODE]: MESSAGE      a diagnostic with a primary span
#   error: ... (plus its `Caused by:` and indented lines)   cargo's own errors, verbatim
#
# Usage: run-clippy.sh WORKSPACE_ROOT [CRATE_DIR...]
#
# - Packages: every member whose directory is a CRATE_DIR, plus every member that depends on
#   one of them (transitively, dev and build dependencies included), so a changed signature
#   still reports the callers it breaks. The whole workspace when no CRATE_DIR is given or one
#   is not a member (a virtual manifest's directory): a root manifest change affects every
#   member. A clippy run over a large workspace outlasts the hook's timeout, which turns the
#   check off without a word; scoping keeps it inside.
# - Lint levels are capped at warn (`--cap-lints warn`), so a deny-level lint never stops
#   cargo before it reaches the targets that depend on the failing one; `--keep-going`
#   builds every target it can.
# - Lints: the repo's own [lints] tables and clippy.toml, plus minimal-lints.toml for every
#   lint the repo does not set (baseline-lints.pl merges them; the repo wins). Never the house
#   template: what the hook checks is exactly what `cargo clippy` and CI check, so an
#   `#[expect]` written for one satisfies the other. A repo that opted in (`baseline = true`
#   under [workspace.metadata.house-check]) commits the house lint table itself (REPO-1); one
#   that opted in without it gets a finding saying so. A member with its own [lints] table
#   (not `workspace = true`) gets its own clippy run with its own merged flags, because clippy
#   args apply to every package of a run.
# - Features: default, unless the repo sets them in the same metadata (house-metadata.pl).
# - JSON output, so paths with spaces survive.
set -euo pipefail
export LC_ALL=C

root="$1"
shift
crate_dirs=("$@")
hooks_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lint_template="$hooks_dir/minimal-lints.toml"

# An opted-in repo without its own lint table would be checked by the hook against nothing
# but the minimal set, while the house rules claim to apply: say so instead.
if perl "$hooks_dir/house-metadata.pl" baseline "$root/Cargo.toml" &&
  ! grep -qE '^[[:space:]]*\[[[:space:]]*(workspace\.)?lints[].]' "$root/Cargo.toml"; then
  echo "house-check: $root/Cargo.toml opts in (baseline = true) but has no [workspace.lints]" \
    "or [lints] table: merge ~/.claude/skills/rust-style/templates/Cargo.lints.toml and copy" \
    "templates/clippy.toml (rust-style topics/repo.md REPO-1)"
fi

# One-line diagnostics from cargo's JSON stream on stdin. A message without a primary span
# (`aborting due to ...` excepted) is printed without a location.
diagnostics_from_json() {
  jq -r --arg root "$root/" '
    select(.reason == "compiler-message") | .message
    | select(.message | test("^aborting due to") | not)
    | ([.spans[] | select(.is_primary)][0]) as $span
    | (if .code.code then "\(.level)[\(.code.code)]" else .level end) as $level
    | if $span == null then "\($level): \(.message)"
      else
        (if ($span.file_name | startswith("/")) then "" else $root end) as $prefix
        | "\($prefix)\($span.file_name):\($span.line_start):\($span.column_start): "
          + "\($level): \(.message)"
      end'
}

# Cargo's own errors from its stderr on stdin (manifest errors, build-script failures):
# each `error:` line with the `Caused by:` and indented lines that explain it.
cargo_errors() {
  awk '
    /^error: could not compile/ { keep = 0; next }
    /^error/ { keep = 1; print; next }
    keep && (/^Caused by:/ || /^[ \t]/ || /^$/) { if ($0 != "") print; next }
    { keep = 0 }'
}

# Clippy over packages $2... (cargo -p/--workspace/--exclude args) with the lints of
# manifest $1; prints diagnostics.
clippy_run() {
  local manifest="$1" flags features lint_args=(--cap-lints warn) feature_args=()
  shift
  flags="$(perl "$hooks_dir/baseline-lints.pl" "$lint_template" "$manifest")"
  features="$(perl "$hooks_dir/house-metadata.pl" features "$root/Cargo.toml")"
  while IFS= read -r arg; do
    if [[ -n "$arg" ]]; then lint_args+=("$arg"); fi
  done <<<"$flags"
  while IFS= read -r arg; do
    if [[ -n "$arg" ]]; then feature_args+=("$arg"); fi
  done <<<"$features"

  # stdout (JSON, one object per line) and stderr (cargo's text) in one capture: JSON lines
  # start with `{`, cargo's text lines never do.
  local output
  output="$(cd "$root" && cargo clippy "$@" --all-targets \
    ${feature_args[@]+"${feature_args[@]}"} --keep-going --quiet --message-format=json -- \
    "${lint_args[@]}" 2>&1 || true)"
  grep '^{' <<<"$output" | diagnostics_from_json || true
  grep -v '^{' <<<"$output" | cargo_errors || true
}

# A broken manifest makes this fail; the hook then reports cargo's error from clippy_run.
metadata="$(cd "$root" && cargo metadata --no-deps --format-version 1 2>/dev/null || echo '{}')"

# Names of the packages to check, one per line, or `*` for the whole workspace.
selected_packages() {
  if [[ ${#crate_dirs[@]} -eq 0 ]]; then
    echo '*'
    return 0
  fi
  jq -r --args '
    [.packages[]? | {name, dir: (.manifest_path | rtrimstr("/Cargo.toml")),
      deps: [.dependencies[].path // empty]}] as $members
    | def closure($dirs):
        ([$members[] | select(.dir as $d | any($dirs[]; . == $d)
            or any(.deps[]; . as $p | any($dirs[]; . == $p))) | .dir] | unique) as $next
        | if ($next | length) == ($dirs | length) then $dirs else closure($next) end;
    if any($ARGS.positional[]; . as $d | all($members[]; .dir != $d)) then "*"
    else closure($ARGS.positional | unique) as $dirs
      | $members[] | select(.dir as $d | any($dirs[]; . == $d)) | .name
    end' "${crate_dirs[@]}" <<<"$metadata"
}

# Members with their own lint table: name<TAB>directory.
own_lint_members() {
  jq -r --arg root "$root/Cargo.toml" \
    '.packages[]? | select(.manifest_path != $root) | "\(.name)\t\(.manifest_path)"' \
    <<<"$metadata" | while IFS=$'\t' read -r name manifest; do
    # Own entries only (an empty template): non-empty means the member sets its own lints.
    if [[ -n "$(perl "$hooks_dir/baseline-lints.pl" /dev/null "$manifest")" ]]; then
      printf '%s\t%s\n' "$name" "$(dirname "$manifest")"
    fi
  done
}

# Keep warnings inside (or, with `outside`, outside) directories $2...; errors always.
filter_dirs() {
  local mode="$1"
  shift
  if [[ $# -eq 0 ]]; then
    if [[ "$mode" == outside ]]; then cat; fi
    return 0
  fi
  DIRS="$(printf '%s/\n' "$@")" awk -v mode="$mode" '
    BEGIN { n = split(ENVIRON["DIRS"], dir, "\n") }
    {
      if ($0 !~ /^\/.*:[0-9]+:[0-9]+: warning/) { print; next }
      inside = 0
      for (i = 1; i <= n; i++) if (dir[i] != "" && index($0, dir[i]) == 1) inside = 1
      if ((mode == "inside") == inside) print
    }'
}

# True when package $1 is among the selected ones.
is_selected() {
  [[ "$selected" == '*' ]] || grep -qxF -- "$1" <<<"$selected"
}

selected="$(selected_packages)"
members="$(own_lint_members)"
own_names="$(cut -f 1 <<<"$members")"
package_args=()
member_dirs=()
if [[ "$selected" == '*' ]]; then
  package_args=(--workspace)
fi
while IFS=$'\t' read -r name dir; do
  if [[ -n "$name" ]]; then
    member_dirs+=("$dir")
    if [[ "$selected" == '*' ]]; then package_args+=(--exclude "$name"); fi
  fi
done <<<"$members"
if [[ "$selected" != '*' ]]; then
  while IFS= read -r name; do
    if [[ -n "$name" ]] && ! grep -qxF -- "$name" <<<"$own_names"; then
      package_args+=(-p "$name")
    fi
  done <<<"$selected"
fi

if [[ ${#package_args[@]} -gt 0 ]]; then
  clippy_run "$root/Cargo.toml" "${package_args[@]}" |
    filter_dirs outside ${member_dirs[@]+"${member_dirs[@]}"}
fi
while IFS=$'\t' read -r name dir; do
  if [[ -n "$name" ]] && is_selected "$name"; then
    clippy_run "$dir/Cargo.toml" -p "$name" | filter_dirs inside "$dir"
  fi
done <<<"$members"
