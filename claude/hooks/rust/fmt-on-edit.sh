#!/usr/bin/env bash
# PostToolUse (Edit|Write|MultiEdit|search_replace|write|hashline_edit): rustfmt the edited
# .rs file immediately and record it for the stop hooks. An edited Cargo.toml is recorded
# too (not formatted), so check-on-stop.sh runs clippy and house-check over the change.
#
# Two lists per agent: `edited` is cleared by check-on-stop.sh once clean; `touched` is never
# cleared and feeds review-gate.sh, which must still see files whose clippy run passed. The
# first edit in a repo also records the session's baseline there (changes.sh).
#
# The file is formatted through stdin, so rustfmt sees only this file: it cannot follow
# `mod x;` into child modules and reformat files the agent never touched, and stable rustfmt
# is enough. The repo's rustfmt.toml is passed explicitly (stdin mode has no path to search
# from) and the edition comes from Cargo.toml. The file is rewritten only when formatting
# succeeded and changed something.
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
read_hook_input
need_tools fail-open jq git shasum
# shellcheck source-path=SCRIPTDIR source=changes.sh
source "$(dirname "${BASH_SOURCE[0]}")/changes.sh"

# Nearest rustfmt.toml / .rustfmt.toml at or above directory $1, or nothing.
rustfmt_config_for() {
  local dir="$1" config
  while :; do
    for config in "$dir/rustfmt.toml" "$dir/.rustfmt.toml"; do
      if [[ -f "$config" ]]; then
        printf '%s' "$config"
        return 0
      fi
    done
    if [[ "$dir" == / || "$dir" == . ]]; then
      return 0
    fi
    dir="$(dirname "$dir")"
  done
}

file_path="$(tool_path)"
if [[ ! -f "$file_path" ]]; then
  exit 0
fi
case "$file_path" in
*.rs | */Cargo.toml | Cargo.toml) ;;
*) exit 0 ;;
esac

file_path="$(physical_path "$file_path")"
# Scratchpad files are formatted but never recorded, so no stop check or review counts them.
if ! is_scratch_path "$file_path"; then
  root="$(git_root "$(dirname "$file_path")")"
  if [[ -n "$root" ]]; then
    ensure_baseline "$root"
  fi
  printf '%s\n' "$file_path" >>"$(agent_file edited)"
  printf '%s\n' "$file_path" >>"$(agent_file touched)"
fi
if [[ "$file_path" != *.rs ]]; then
  exit 0
fi
need_tools fail-open rustfmt

dir="$(dirname "$file_path")"
args=(--edition "$(edition_for "$dir")" --emit stdout)
config="$(rustfmt_config_for "$dir")"
if [[ -n "$config" ]]; then
  args+=(--config-path "$config")
fi

# rustfmt's stderr (errors, config warnings) goes straight to ours.
if ! formatted="$(rustfmt "${args[@]}" <"$file_path")"; then
  # Exit 2 feeds this back to the agent: usually a syntax error in the edit just made.
  echo "rustfmt failed on $file_path (see above); the file was left as written." >&2
  exit 2
fi
# $(...) drops the trailing newline that rustfmt always writes; printf puts it back.
if [[ -n "$formatted" ]] && ! cmp -s <(printf '%s\n' "$formatted") "$file_path"; then
  printf '%s\n' "$formatted" >"$file_path"
fi
