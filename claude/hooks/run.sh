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
# whose wrapper is killed with SIGKILL, and a hook that exits 0 or 2 on wrong grounds, such
# as an input field a tool renamed that reads as empty. A hook file that does not parse is
# in that last group: bash exits 2 on a syntax error, which blocks, loudly.
#
# This file stands in front of every hook, so it moves together with settings.json. If it
# is missing, every hook exits 127 and nothing is checked or logged; if it does not parse,
# every hook exits 2 and every tool call is blocked. Either way, restore the file by hand
# (`git -C <checkout> checkout -- claude/hooks/run.sh`) or run install.sh from a good
# checkout.
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
# Characters of the hook's last stderr line kept as the reason. Arbitrary: enough for a
# message, short enough that a log line stays one small write among concurrent writers.
REASON_CHARS=300

hook="${1:?usage: run.sh <hook file, relative to this directory>}"

# The hook's stderr goes to a file of this process's own, to find the reason, and is
# replayed whole below: the tools show it to the user, or to the agent on exit 2. A file,
# not a pipe: a pipe would keep this script waiting for every process the hook leaves
# behind that still holds it.
stderr_file="${TMPDIR:-/tmp}/agent-setup-hook-stderr.$$"

# In the background, with `wait`, because bash runs a trap only between commands: a hook
# run in the foreground would finish before the trap below could act. Without the trap, a
# tool that ends this process at the hook's timeout leaves the hook running. For
# check-on-stop.sh that means a check which records its result after the stop went ahead,
# with findings nobody reads, so the next stop reports nothing. `<&0` because bash gives a
# background command /dev/null as its input.
bash "$(dirname "${BASH_SOURCE[0]}")/$hook" <&0 2>"$stderr_file" &
child=$!
killed=0
trap 'killed=1; kill "$child" 2>/dev/null' TERM INT HUP
wait "$child"
status=$?
if [[ "$killed" -eq 1 ]]; then
  # The first wait returned for the signal, with 128 plus its number; this one reaps the
  # hook. The hook's own children (a cargo run) are not signalled, as before this wrapper.
  wait "$child" 2>/dev/null
  echo "$hook: stopped by a signal before it finished (its timeout?)" >>"$stderr_file"
fi

if [[ -s "$stderr_file" ]]; then
  cat "$stderr_file" >&2
fi
reason="$(tail -n 1 "$stderr_file" 2>/dev/null)"
rm -f "$stderr_file"

# Without HOME there is nowhere to log; the hook's own verdict still stands.
if [[ "$status" -ne 0 && "$status" -ne 2 && -n "${HOME:-}" ]]; then
  # Every step is allowed to fail: a log that cannot be written must not change the status.
  {
    mkdir -p "$(dirname "$LOG")" &&
      printf '%s\t%s\texit %s: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$hook" "$status" \
        "${reason:0:REASON_CHARS}" >>"$LOG" &&
      if [[ "$(wc -l <"$LOG")" -gt "$TRIM_ABOVE_LINES" ]]; then
        # Through a rename of a file of this process's own, so the status line never reads
        # a half-written log and two hooks trimming at once do not write into each other.
        # Lines other hooks append between the `tail` and the `mv` are lost, and several
        # hooks trimming at once each replace the file: a burst of failures at the limit
        # keeps only some of its lines (24 of 40 in one test). The log is a count for the
        # status line, not a record of every failure.
        tail -n "$KEEP_LINES" "$LOG" >"$LOG.$$" && mv "$LOG.$$" "$LOG"
      fi
  } 2>/dev/null
fi
exit "$status"
