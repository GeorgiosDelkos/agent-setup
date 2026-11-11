#!/usr/bin/env bash
# PostToolUse and PostToolUseFailure (Bash): record that this session ran Rust tests, for
# check-on-stop.sh, which asks for a test run when Rust changed after the last one. A failing
# run counts, since the agent has seen the result; Claude Code reports a command that exits
# non-zero only to PostToolUseFailure, with the same tool_input. The record is the
# modification time of one session file, so any agent's run counts for the session.
#
# Matched on the text of the command, so a commit message that mentions `cargo test` also
# counts. That errs toward not asking, which is the cheap side: the ask is a reminder, and
# CI runs the tests anyway. A Python, TypeScript, shell, or Actions check is recorded the
# same way, including the repo's own tool when it has not adopted the house one (eslint,
# mypy): the reminder is that something checked the change. A formatter does not count
# (`ruff format`, `shfmt -w`): it rewrites and does not check. `shfmt -d` does, and so
# does `ruff format` with `--check` or `--diff` anywhere in that simple command.
# A project runner counts on that same cheap side: `check.sh`
# for shell, npm/pnpm/yarn/bun and `node --test` for TypeScript, tox, nox, and unittest
# for Python. `make` and `just` with test, lint, or check stamp every language skill.
# They do not stamp the Rust test run: make test is not cargo test.
set -euo pipefail

input="$(cat)"
# Every other command leaves here, before jq starts. Matched on the input up to the tool's
# output when the output comes after the command, so output that mentions `make` or `npm`
# does not start jq; otherwise on the whole input. The key cannot match inside the command:
# there its quotes are escaped. *npm* already matches pnpm, so a pnpm arm could never match.
scan="$input"
if [[ "$input" == *'"tool_input"'*'"tool_response"'* ]]; then
  scan="${input%%\"tool_response\"*}"
fi
case "$scan" in
*cargo* | *pytest* | *ruff* | *pyright* | *mypy* | *vitest* | *oxlint* | *eslint* | \
  *jest* | *shellcheck* | *shfmt* | *bats* | *actionlint* | *zizmor* | *tsc* | \
  *"ty check"* | *tox* | *nox* | *unittest* | *check.sh* | *npm* | *yarn* | *bun* | \
  *make* | *just* | *"node --test"*) ;;
*) exit 0 ;;
esac
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

# $1 is the skill, $2 a regex on the command text. Boundaries keep `ty check` from matching
# inside `city check`, `pytest` from matching `pytest-cov`, and `make` from matching `cmake`.
record_check() {
  if grep -qE "$2" <<<"$command"; then
    touch "$(session_file "checks-$1")"
  fi
}
bound='(^|[^[:alnum:]_-])'
end='([^[:alnum:]_-]|$)'

# ruff format rewrites. ruff format --check and any other ruff command judge.
ruff_counts() {
  local rest
  rest="$(perl -pe 's/(^|[^[:alnum:]_-])ruff[[:space:]]+format(?![^;&|\n]*--(check|diff))//g' \
    <<<"$command")"
  grep -qE "${bound}ruff${end}" <<<"$rest"
}

# shfmt -d/--diff checks. shfmt -w/--write rewrites, unless -d is there too. Neither flag
# is the default check.
shfmt_counts() {
  grep -qE "${bound}shfmt${end}" <<<"$command" || return 1
  if grep -qE "${bound}(-d|--diff)${end}" <<<"$command"; then
    return 0
  fi
  if grep -qE "${bound}(-w|--write)${end}" <<<"$command"; then
    return 1
  fi
  return 0
}

# make and just name no language. One of them stamps every language skill, not the
# Rust test run: the reminder errs toward not asking.
runner="${bound}(make|just)[[:space:]]+(test|lint|check)${end}"
node_run="${bound}(npm|pnpm|yarn|bun)[[:space:]]+(run[[:space:]]+)?(test|lint|check)${end}"
node_run+="|${bound}"'node[[:space:]]+--test'"${end}"

py_check="${bound}(pytest|pyright|mypy|tox|nox|unittest)${end}"
py_check+="|${bound}"'ty[[:space:]]+check'"${end}"
py_check+="|$runner"
if ruff_counts; then
  py_check+="|${bound}ruff${end}"
fi
record_check python-style "$py_check"

ts_check="${bound}(vitest|oxlint|tsc|jest|eslint)${end}|$node_run|$runner"
record_check ts-style "$ts_check"

bash_check="${bound}(shellcheck|bats)${end}|${bound}"'check\.sh'"${end}|$runner"
if shfmt_counts; then
  bash_check+="|${bound}shfmt${end}"
fi
record_check bash-style "$bash_check"

record_check gh-actions-style "${bound}(actionlint|zizmor)${end}|$runner"
