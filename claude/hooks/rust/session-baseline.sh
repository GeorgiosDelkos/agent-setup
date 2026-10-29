#!/usr/bin/env bash
# UserPromptSubmit: record this session's baseline for the repo it works in (the first
# prompt only; later prompts find it recorded). The baseline is HEAD plus a hash of the
# repo's state before the agent acts, so the stop hooks can measure the session's changes
# even after a commit, and can tell a repo this session changed from one that was already
# dirty (changes.sh). Never blocks a prompt.
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
read_hook_input
need_tools fail-open jq git shasum
# shellcheck source-path=SCRIPTDIR source=changes.sh
source "$(dirname "${BASH_SOURCE[0]}")/changes.sh"

# When the session started, for the stop check's "changed after the last test run": one stamp
# for the session, since a repo's own baseline is written only when the session first touches
# it, after the edit that touched it.
started="$(session_file started)"
if [[ ! -f "$started" ]]; then
  touch "$started"
fi
cwd="$(hook_field '.cwd')"
if [[ -n "$cwd" && -d "$cwd" ]]; then
  root="$(git_root "$cwd")"
  if [[ -n "$root" ]]; then
    ensure_baseline "$root"
  fi
fi
