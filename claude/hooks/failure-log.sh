#!/usr/bin/env bash
# The log of hook failures. Sourced by every hook (through rust/common.sh, or directly by
# guards/bash-guard.sh), not executed.
#
# A hook that cannot do its job lets the tool call through: blocking every edit on a broken
# install would trap the agent with no way out. The cost is that enforcement is off with no
# trace beyond one stderr line in one session, which is how a renamed hook input field or an
# uninstalled tool can go unnoticed for weeks. So every such exit appends one line here, and
# the status line (claude/statusline.sh) shows how many the last 24 hours hold.
#
# One line per failure, tab-separated: UTC time, hook file name, message. Beside the settings
# record install.sh keeps, because both are this setup's own state on the machine.
# session-baseline.sh trims the file once a day.
HOOK_FAILURE_LOG="$HOME/.local/state/agent-setup/hook-failures.log"
HOOK_FAILURE_LOGGED=0

# Appends the failure $* of the running hook. Never fails: a hook must not die of its own log.
log_hook_failure() {
  local message="$*"
  HOOK_FAILURE_LOGGED=1
  mkdir -p "$(dirname "$HOOK_FAILURE_LOG")" 2>/dev/null || return 0
  printf '%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(basename "$0")" \
    "${message//[$'\t\n']/ }" >>"$HOOK_FAILURE_LOG" 2>/dev/null || true
}

# Exit 0 passes and exit 2 blocks; both are a hook doing its job. Any other status lets the
# tool call through without a verdict. Where the hook named the reason it is logged already;
# what is left is a crash (`set -e` on a command that failed, a tool that is not installed).
log_unexplained_exit() {
  local status="$1"
  if [[ "$status" -ne 0 && "$status" -ne 2 && "$HOOK_FAILURE_LOGGED" -eq 0 ]]; then
    log_hook_failure "exited $status without a verdict, so the tool call was not checked"
  fi
}
trap 'log_unexplained_exit "$?"' EXIT
