#!/usr/bin/env bash
# PostToolUse and PostToolUseFailure (Bash): record that this session ran Rust tests, for
# check-on-stop.sh, which asks for a test run when Rust changed after the last one. A failing
# run counts, since the agent has seen the result; Claude Code reports a command that exits
# non-zero only to PostToolUseFailure, with the same tool_input. The record is the
# modification time of one session file, so any agent's run counts for the session.
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

# cargo, its toolchain and global flags (+nightly, -q, --locked), a wrapping subcommand that
# runs the tests (miri, hack, llvm-cov, insta), then the test subcommand. A run that only
# builds or lists the tests (--no-run, nextest list) is no test run.
runs_tests='(^|[^[:alnum:]_-])cargo([[:space:]]+(\+|-)[^[:space:]]+)*'
runs_tests+='([[:space:]]+(miri|hack|llvm-cov|insta))?'
runs_tests+='[[:space:]]+(test|t|nextest|mutants)([[:space:]]|$)'
only_builds='[[:space:]]--no-run([[:space:]]|$)|nextest[[:space:]]+list([[:space:]]|$)'
command="$(hook_field '.tool_input.command')"
if grep -qE "$runs_tests" <<<"$command" && ! grep -qE "$only_builds" <<<"$command"; then
  touch "$(session_file tests-ran)"
fi
