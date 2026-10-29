#!/usr/bin/env bash
# PostToolUse (Bash): record that this session ran Rust tests, for check-on-stop.sh, which
# asks for a test run when Rust changed after the last one. A failing run counts: the agent
# has seen the result. The record is the modification time of one session file, so any
# agent's run counts for the session.
#
# Matched on the text of the command, so a commit message that mentions `cargo test` also
# counts. That errs toward not asking, which is the cheap side: the ask is a reminder, and
# CI runs the tests anyway.
set -euo pipefail

input="$(cat)"
# Every other command leaves here, before jq starts.
if [[ "$input" != *cargo* ]]; then
  exit 0
fi
# shellcheck source-path=SCRIPTDIR source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
HOOK_INPUT="$input"
need_tools fail-open jq

runs_tests='(^|[^[:alnum:]_-])cargo([[:space:]]+\+[^[:space:]]+)?([[:space:]]+miri)?'
runs_tests+='[[:space:]]+(test|t|nextest|mutants)([[:space:]]|$)'
if grep -qE "$runs_tests" <<<"$(hook_field '.tool_input.command')"; then
  touch "$(session_file tests-ran)"
fi
