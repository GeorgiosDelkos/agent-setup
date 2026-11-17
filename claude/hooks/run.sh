#!/usr/bin/env bash
# Runs one hook and records its failure. settings.json registers every hook through this
# file: `bash ~/.claude/hooks/run.sh rust/style-gate.sh`. Standard input and output pass
# through untouched, and so does the exit status.
#
# Exit 0 passes and exit 2 blocks; both are a hook doing its job. Any other status lets the
# tool call or the stop go ahead with no verdict: a missing tool, a recall gate that could
# not gate, a hook that crashed on an input it did not expect. The only trace used to be one
# stderr line in one session, so enforcement could be off for weeks unnoticed. Each such
# exit now appends one line to the log below, and the status line (claude/statusline.sh)
# shows how many the last 24 hours hold.
#
# The hook runs as a child, and this file reads its status from outside. An EXIT trap inside
# the hook cannot do that on the macOS system bash 3.2: with a trap installed, an
# unbound-variable abort exits with the status of the last command (usually 0) instead of
# 1, and the trap sees that 0, so the crash would be hidden where it used to be shown.
#
# Not seen: a hook the tool never starts (a registration lost from settings.json), a hook
# killed by its timeout (this process dies with it), and a hook that exits 0 or 2 on wrong
# grounds, such as an input field a tool renamed that reads as empty. A hook file that does
# not parse is in that last group: bash exits 2 on a syntax error, which blocks, loudly.
#
# No `set -e`: the child's failure is this script's subject, not its own error.
set -uo pipefail

# One line per failure, tab-separated: UTC time, hook, `exit N: last line of its stderr`.
# Beside the settings record install.sh keeps: both are this setup's state on the machine.
LOG="${HOME:-}/.local/state/agent-setup/hook-failures.log"
# Lines kept when the log is trimmed, and the size that triggers it. Arbitrary: a daemon
# that is down logs one line per edit, and the status line reads only the last 24 hours.
KEEP_LINES=500
TRIM_ABOVE_LINES=1000

hook="${1:?usage: run.sh <hook file, relative to this directory>}"

# Standard error is collected to find the reason, then replayed whole: the tools show it to
# the user, or to the agent on exit 2. Standard output goes straight through on fd 3.
{
  stderr="$(bash "$(dirname "${BASH_SOURCE[0]}")/$hook" 2>&1 1>&3 3>&-)"
  status=$?
} 3>&1
if [[ -n "$stderr" ]]; then
  printf '%s\n' "$stderr" >&2
fi

# Without HOME there is nowhere to log; the hook's own verdict still stands.
if [[ "$status" -ne 0 && "$status" -ne 2 && -n "${HOME:-}" ]]; then
  reason="$(tail -n 1 <<<"$stderr")"
  # Every step is allowed to fail: a log that cannot be written must not change the status.
  {
    mkdir -p "$(dirname "$LOG")" &&
      printf '%s\t%s\texit %s: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$hook" "$status" \
        "${reason//$'\t'/ }" >>"$LOG" &&
      if [[ "$(wc -l <"$LOG")" -gt "$TRIM_ABOVE_LINES" ]]; then
        # Through a rename of a file of this process's own, so the status line never reads
        # a half-written log and two hooks trimming at once do not write into each other.
        # A line another hook appends between the `tail` and the `mv` is lost.
        tail -n "$KEEP_LINES" "$LOG" >"$LOG.$$" && mv "$LOG.$$" "$LOG"
      fi
  } 2>/dev/null
fi
exit "$status"
