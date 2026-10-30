#!/usr/bin/env bash
# Shared helpers for the Rust hooks. Sourced, not executed. Written for the macOS system
# bash 3.2: no associative arrays, no mapfile, and empty arrays are expanded with
# ${a[@]+"${a[@]}"} because `set -u` rejects "${a[@]}" on an empty array.
#
# State is per agent: subagents share their parent's session id but report their own
# `agent_id`, and each has its own context, so a skill loaded by the parent is not loaded
# for a subagent, and a subagent's edits are checked when that subagent stops. State lives
# under $TMPDIR, so it is cleared on reboot and never leaks between sessions.

set -euo pipefail

# Byte-oriented text tools: a source file or path with invalid UTF-8 must not make macOS awk
# or sed fail (multibyte conversion errors). perl -CSD counts characters where that matters.
export LC_ALL=C

# The hooks and house-check.pl live side by side; resolve them from this file, not from
# $HOME, so a staging copy runs against itself.
# shellcheck disable=SC2034 # read by the hooks that source this file
RUST_HOOKS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC2034 # read by the hooks that source this file
RUST_STYLE_DIR="$HOME/.claude/skills/rust-style"
RUST_HOOKS_STATE="${TMPDIR:-/tmp}/claude-rust-hooks"
mkdir -p "$RUST_HOOKS_STATE"

# Hook input JSON arrives on stdin once; every hook calls read_hook_input first.
read_hook_input() {
  HOOK_INPUT="$(cat)"
}

# Exit unless every tool $2... is on PATH. A missing tool means the hook cannot judge
# anything, and a hook's own failure must never look like a finding:
#   block-stop  Stop hooks block once with the fix (the agent relays it); the next stop in a
#               row passes. stop_hook_active is read without jq, which may be the missing tool.
#   fail-open   Every other hook exits 1: the edit goes ahead and the message is shown.
#               Blocking every edit on a broken install would trap the agent with no way out.
need_tools() {
  local on_missing="$1" tool missing=""
  shift
  for tool in "$@"; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      missing+=" $tool"
    fi
  done
  if [[ -z "$missing" ]]; then
    return 0
  fi
  echo "Rust hooks ($(basename "$0")): missing tool(s):$missing. Install them" \
    "(~/.config/agents/SETUP.md, 'Install on a new machine'); the Rust checks are off" \
    "until then." >&2
  if [[ "$on_missing" == block-stop ]] &&
    ! grep -qE '"(stop_hook_active|stopHookActive)"[[:space:]]*:[[:space:]]*true' \
      <<<"$HOOK_INPUT"; then
    exit 2
  fi
  exit 1
}

# A hook's own failure (a crashed checker, unreadable output): loud on stderr, never a
# finding. Callers exit 1 when nothing else was found, so the stop is not blocked by it.
internal_error() {
  echo "Rust hooks ($(basename "$0")) internal error: $*" >&2
}

hook_field() {
  jq -r "$1 // empty" <<<"$HOOK_INPUT"
}

# Claude Code's per-session scratchpad, /tmp/claude-<uid>/<project>/<session>/scratchpad/
# (/private/tmp on macOS). Read only through scratch_exempt.
SCRATCH_RE='/tmp/claude-[0-9]+/[^/]+/[^/]+/scratchpad/'

# True when path $1 is throwaway scratch that no style gate or stop check judges: under the
# scratchpad and not in a git work tree there whose HEAD is a commit on a branch. A branch
# there can become a pull request: the main session builds merge batches in scratchpad
# worktrees, and scratchpad/batch-e on batch/2026-10-30-e skipped clippy, the test reminder,
# and the style gate before it was opened as one (hcfs, 2026-10-30). Exempt stay: a plain
# directory, a detached HEAD (a checkout to read old code), a branch with no commit yet (the
# repo `cargo new` makes), and a repo whose top level is above the scratchpad (a git-tracked
# TMPDIR must not un-exempt every scratch file). The review record (review-done.sh)
# snapshots every worktree whatever this says. $1 may not exist yet (a Write of a new file);
# the nearest existing directory at or above it is asked. One git call, and only for
# scratchpad paths.
scratch_exempt() {
  local dir="$1" out top branch
  if [[ ! "$dir" =~ $SCRATCH_RE ]]; then
    return 1
  fi
  while [[ ! -d "$dir" ]]; do
    dir="$(dirname "$dir")"
  done
  # The top level, then the branch name or `HEAD` when detached. Fails outside git and on an
  # unborn branch.
  out="$(git -C "$dir" rev-parse --show-toplevel --abbrev-ref HEAD 2>/dev/null)" || return 0
  top="${out%%$'\n'*}"
  branch="${out#*$'\n'}"
  [[ "$branch" == HEAD || ! "$top/" =~ $SCRATCH_RE ]]
}

# Path the tool acts on. Claude: file_path. Grok: target_file. Grok's Cursor preset: path.
# A relative path (Grok may send one) is resolved against the hook input's cwd, so the
# crate and repo lookups that walk up from it see the real directories.
tool_path() {
  local path cwd
  path="$(hook_field '.tool_input.file_path // .tool_input.target_file // .tool_input.path')"
  cwd="$(hook_field '.cwd')"
  if [[ -n "$path" && "$path" != /* && -n "$cwd" ]]; then
    path="$cwd/$path"
  fi
  printf '%s' "$path"
}

session_id() {
  local id
  id="$(hook_field '.session_id')"
  printf '%s' "${id:-unknown}"
}

# State file for the agent that triggered this hook: the main session or one subagent.
agent_file() {
  local agent_id
  agent_id="$(hook_field '.agent_id')"
  printf '%s/%s.%s.%s' "$RUST_HOOKS_STATE" "$(session_id)" "${agent_id:-main}" "$1"
}

# A subagent's event: Claude sends agent_id, Grok subagentType.
is_subagent() {
  [[ -n "$(hook_field '.agent_id // .subagentType')" ]]
}

# State file shared by every agent of this session.
session_file() {
  printf '%s/%s.%s' "$RUST_HOOKS_STATE" "$(session_id)" "$1"
}

# Grok fires an extra observe-only Stop at session end (reason "shutdown" or
# "channel_closed"); a second stop in a row means the agent already saw the findings once.
# Claude sends no reason and snake_case, Grok camelCase. Returns 0 when a Stop hook should
# let the stop through without checking.
stop_is_exempt() {
  local reason
  reason="$(hook_field '.reason')"
  if [[ -n "$reason" && "$reason" != "end_turn" ]]; then
    return 0
  fi
  [[ "$(hook_field '.stop_hook_active // .stopHookActive')" == "true" ]]
}

# Resolved path: cargo reports physical paths (/tmp is /private/tmp on macOS), and the stop
# hooks match diagnostics against the recorded list.
physical_path() {
  printf '%s/%s' "$(cd "$(dirname "$1")" && pwd -P)" "$(basename "$1")"
}

# The `touched` lists of every agent of this session (never cleared by the stop check, so the
# reviewer's snapshot still sees files whose clippy run already passed). Prints existing
# list files, one per line, for changes.sh to read.
session_touched_lists() {
  local list
  for list in "$RUST_HOOKS_STATE/$(session_id)".*.touched; do
    if [[ -f "$list" ]]; then
      printf '%s\n' "$list"
    fi
  done
}

# Nearest directory at or above $1 that contains a Cargo.toml, or nothing.
crate_dir_of() {
  local dir="$1"
  while :; do
    if [[ -f "$dir/Cargo.toml" ]]; then
      printf '%s' "$dir"
      return 0
    fi
    if [[ "$dir" == / || "$dir" == . ]]; then
      break
    fi
    dir="$(dirname "$dir")"
  done
}

# True when switch $1 (`baseline`, `low-level`) is `true` under [workspace.metadata.house-check]
# or [package.metadata.house-check] in a Cargo.toml at or above directory $2
# (house-metadata.pl).
house_switch() {
  local name="$1" dir="$2"
  while :; do
    if [[ -f "$dir/Cargo.toml" ]] &&
      perl "$RUST_HOOKS_DIR/house-metadata.pl" "$name" "$dir/Cargo.toml" 2>/dev/null; then
      return 0
    fi
    if [[ "$dir" == / || "$dir" == . ]]; then
      return 1
    fi
    dir="$(dirname "$dir")"
  done
}

# True when the repo around crate directory $1 opted in to the house rules.
house_opted_in() {
  house_switch baseline "$1"
}

# max_width from the nearest rustfmt.toml / .rustfmt.toml at or above $1, default 100.
max_width_for() {
  local dir="$1" config width
  while :; do
    for config in "$dir/rustfmt.toml" "$dir/.rustfmt.toml"; do
      if [[ -f "$config" ]]; then
        width="$(sed -nE 's/^[[:space:]]*max_width[[:space:]]*=[[:space:]]*([0-9]+).*/\1/p' \
          "$config" | head -n 1)"
        printf '%s' "${width:-100}"
        return 0
      fi
    done
    if [[ "$dir" == / || "$dir" == . ]]; then
      break
    fi
    dir="$(dirname "$dir")"
  done
  printf '100'
}

# Edition from the nearest Cargo.toml that states one (crate or workspace), default 2024.
edition_for() {
  local dir="$1" edition
  while :; do
    if [[ -f "$dir/Cargo.toml" ]]; then
      edition="$(sed -nE 's/^[[:space:]]*edition[[:space:]]*=[[:space:]]*"([0-9]{4})".*/\1/p' \
        "$dir/Cargo.toml" | head -n 1)"
      if [[ -n "$edition" ]]; then
        printf '%s' "$edition"
        return 0
      fi
    fi
    if [[ "$dir" == / || "$dir" == . ]]; then
      break
    fi
    dir="$(dirname "$dir")"
  done
  printf '2024'
}
