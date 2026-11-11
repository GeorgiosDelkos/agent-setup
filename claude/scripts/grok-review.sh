#!/usr/bin/env bash
# Run Grok as a locked-down adversarial reviewer of one PR head (claude/commands/review-pr.md,
# "Grok review"). A PR is untrusted input, so Grok runs with read-only tools, from the
# separate home ~/.grok-review (its own login), under the kernel-enforced pr-review sandbox
# profile, with a private TMPDIR, on a disposable worktree inside that home.
#
#   grok-review.sh <repo-dir> <head-sha> <prompt-file> <output-file>
#
# The prompt can live anywhere: it is copied into the run directory, the only place outside
# the worktree the sandbox can read. The output is written only when the review succeeded.
#
# Exit status: 0 review written; 1 the run failed (output not usable); 2 the output held
# material from the review home's credential and was deleted; 3 Grok is unavailable (not
# installed, review home missing, not signed in, sign-in could not be refreshed); 64 usage.
#
# GROK_BIN and GROK_REVIEW_HOME override the grok binary and the review home (tests).
set -euo pipefail

usage() {
  echo "usage: grok-review.sh <repo-dir> <head-sha> <prompt-file> <output-file>" >&2
  exit 64
}

unavailable() {
  echo "grok review unavailable: $1" >&2
  exit 3
}

[[ $# -eq 4 ]] || usage
repo="$1"
head_sha="$2"
prompt="$3"
output="$4"
[[ -d "$repo" && -f "$prompt" && -n "$head_sha" ]] || usage
# Absolute: cleanup runs `git -C "$repo"` after `cd /`, where a relative path would miss.
repo="$(cd "$repo" && pwd -P)"

home="${GROK_REVIEW_HOME:-$HOME/.grok-review}"
grok_bin="${GROK_BIN:-$(command -v grok || true)}"
[[ -n "$grok_bin" && -x "$grok_bin" ]] || unavailable "grok is not installed"
[[ -d "$home" && ! -L "$home" ]] || unavailable "no review home at $home (run install.sh)"
[[ -f "$home/sandbox.toml" && ! -L "$home/sandbox.toml" ]] ||
  unavailable "no pr-review profile in $home (run install.sh)"
# A regular, non-empty file; never read here, so the credential stays out of any output.
[[ -f "$home/auth.json" && ! -L "$home/auth.json" && -s "$home/auth.json" ]] ||
  unavailable "the review home is not signed in: GROK_HOME=$home grok login"

# How long each step may take before it is stopped (seconds), overridable for tests:
# - signin_limit: a refresh is one token request and one short model turn; past this it is
#   waiting on something else, such as an interactive sign-in.
# - review_limit: arbitrary, far above a normal review, so only a hung run reaches it. A
#   review that hangs would otherwise hold the lock below, and every later review behind it.
# - lock_limit: how long to wait for another review to finish: its sign-in and review
#   limits, plus a minute for its checkout and cleanup (arbitrary).
signin_limit="${GROK_SIGNIN_LIMIT_SECS:-120}"
review_limit="${GROK_REVIEW_LIMIT_SECS:-3600}"
lock_limit="${GROK_LOCK_LIMIT_SECS:-$((signin_limit + review_limit + 60))}"

# Whether `file` holds any string of 20 or more characters from the review home's
# credential, matched without printing it.
holds_credential() {
  local file="$1" secret
  while IFS= read -r secret; do
    if grep -qaF -- "$secret" "$file"; then
      return 0
    fi
  done < <(jq -r '.. | strings | select(length >= 20)' "$home/auth.json" 2>/dev/null || true)
  return 1
}

# Print up to 2000 bytes of a failed call's stderr, unless it holds credential material.
echo_stderr() {
  local file="$1"
  if holds_credential "$file"; then
    echo "(stderr withheld: it holds credential material)" >&2
  else
    head -c 2000 "$file" >&2
  fi
}

# Run a command in the background and stop it after `limit` seconds: its exit status, or
# 124 when it was stopped. In the background so a signal to this script is handled at once
# (bash defers traps while a foreground child runs) and stops it too (on_signal).
child=""
run_limited() {
  local limit="$1" waited=0 status=0
  shift
  "$@" &
  child=$!
  while kill -0 "$child" 2>/dev/null && [[ "$waited" -lt "$limit" ]]; do
    sleep 1
    waited=$((waited + 1))
  done
  if kill -0 "$child" 2>/dev/null; then
    stop_child
    return 124
  fi
  wait "$child" || status=$?
  child=""
  return "$status"
}

# Stop the running child: TERM, then KILL when it is still alive after 10 seconds (an
# arbitrary grace), so a child that ignores TERM cannot keep the run, and the lock, forever.
stop_child() {
  local waited=0
  kill "$child" 2>/dev/null || true
  while kill -0 "$child" 2>/dev/null && [[ "$waited" -lt 10 ]]; do
    sleep 1
    waited=$((waited + 1))
  done
  kill -9 "$child" 2>/dev/null || true
  wait "$child" 2>/dev/null || true
  child=""
}

# One review at a time. Every run and session in this home is readable to the review that
# runs in it (the sandbox allows the home: Grok writes its session there), and cleanup
# empties sessions/. With two at once, one review could read another PR's prompt and code,
# and its cleanup would delete the other's live session (seen 2026-11-11).
#
# The lock is flock(2) on review.lock, through fd 9, which this script and every process it
# starts hold open. The kernel drops it when the last of them exits, so a review killed
# with SIGKILL leaves no stale lock to take over, and a Grok it left running keeps the lock
# until it ends. A mkdir lock with a pid file was tried first: taking over a dead holder's
# lock is a check and then a delete, and two waiters could both get in. The file is never
# deleted: a waiter holds the old file open and would lock it while a new run locks a new one.
lock="$home/review.lock"
take_lock() {
  local waited=0 status
  exec 9>>"$lock"
  while true; do
    status=0
    perl -MFcntl=:flock -e 'open(my $fh, ">&=", 9) or die "cannot reopen fd 9: $!\n";
      flock($fh, LOCK_EX | LOCK_NB) or exit 1' || status=$?
    if [[ "$status" -eq 0 ]]; then
      return 0
    fi
    if [[ "$status" -ne 1 ]]; then
      echo "grok review failed: cannot lock $lock" >&2
      exit 1
    fi
    if [[ "$waited" -ge "$lock_limit" ]]; then
      echo "grok review failed: another review still runs after ${lock_limit}s;" \
        "retry when it ends" >&2
      exit 1
    fi
    sleep 5
    waited=$((waited + 5))
  done
}

# Remove what a killed review left: its run directory (prompt, code, worktree) and its
# worktree's registration in the repository it came from, named in the run's `repo` file.
# Runs from before that file existed leave a registration that `git worktree prune` clears.
purge_runs() {
  local dir
  for dir in "$home/runs"/*; do
    [[ -d "$dir" ]] || continue
    if [[ -f "$dir/repo" ]]; then
      git -C "$(cat "$dir/repo")" worktree remove --force "$dir/wt" >/dev/null 2>&1 || true
    fi
    trash "$dir" >/dev/null 2>&1 || true
  done
  if [[ -d "$home/sessions" ]]; then
    find "$home/sessions" -mindepth 1 -maxdepth 1 -exec trash {} + >/dev/null 2>&1 || true
  fi
}

mkdir -p "$home/runs" "$home/tmp"
run=""
locked=""
cleanup() {
  cd /
  if [[ -n "$run" ]]; then
    git -C "$repo" worktree remove --force "$run/wt" >/dev/null 2>&1 || true
  fi
  if [[ -n "$locked" ]]; then
    # Past reviews' transcripts would be readable to the next review; keep none. The lock
    # goes with fd 9 when this script exits.
    purge_runs
  fi
}
on_signal() {
  if [[ -n "$child" ]]; then
    stop_child
  fi
  exit 143
}
trap cleanup EXIT
trap on_signal TERM INT HUP

take_lock
locked=1
purge_runs
run="$(mktemp -d "$home/runs/pr-XXXXXX")"
printf '%s\n' "$repo" >"$run/repo"
wt="$run/wt"

# Refresh the review home's sign-in before the review. Under the pr-review sandbox Grok
# cannot refresh it: a review started after the access token expired (about four hours
# after the last refresh) got 401s for 45 minutes and then stopped, while the same call
# outside the sandbox refreshed it (seen 2026-11-05, grok 1.0.70). So this one call runs
# outside the sandbox, before anything from the PR is on disk, and is given nothing:
# - a fixed prompt, one listing tool, one turn, no web, no subagents, no stdin;
# - an empty working directory and an empty HOME, so none of the user's plugins, hooks,
#   MCP servers or skills load (GROK_HOME still points at the login);
# - GROK_AUTH_EARLY_INVALIDATION_SECS above the token's lifetime, so Grok treats the
#   token as expiring and refreshes it now. With the default (300 s) a token with 20
#   minutes left is not refreshed, and a longer review then fails part way.
# It is stopped after `signin_limit` seconds: with no usable refresh token Grok falls back
# to an interactive sign-in, which must not wait or open a browser here.
mkdir "$run/signin" "$run/signin-home"
signin_status=0
run_limited "$signin_limit" env -i HOME="$run/signin-home" PATH="/usr/bin:/bin" \
  TMPDIR="$home/tmp/" \
  GROK_HOME="$home" GROK_MEMORY=0 GROK_AUTH_EARLY_INVALIDATION_SECS=86400 \
  "$grok_bin" --cwd "$run/signin" \
  --tools list_dir --disallowed-tools search_tool,use_tool \
  --disable-web-search --no-subagents --max-turns 1 \
  -p "Reply with the single word OK." </dev/null >/dev/null 2>"$run/signin.err" ||
  signin_status=$?
if [[ "$signin_status" -eq 124 ]]; then
  echo "the sign-in refresh did not finish in ${signin_limit}s and was stopped" >&2
fi
if [[ "$signin_status" -ne 0 ]]; then
  echo_stderr "$run/signin.err"
  unavailable "the sign-in could not be refreshed (network, or the login expired:
GROK_HOME=$home grok login)"
fi

if ! git -C "$repo" worktree add --quiet --detach "$wt" "$head_sha"; then
  echo "grok review failed: cannot check out $head_sha in $repo" >&2
  exit 1
fi
# Claude and Grok load hooks, rules and servers from these: at the root they start in, and
# rule files from any directory they read (a nested CLAUDE.md or AGENTS.md). Their changes,
# if any, are in the diff the prompt carries; no copy here may run.
while IFS= read -r -d '' entry; do
  trash "$entry"
done < <(find "$wt" -path "$wt/.git" -prune -o \( -name .claude -o -name .grok -o -name .cursor \
  -o -name .agents -o -name .mcp.json -o -name AGENTS.md -o -name AGENT.md -o -name CLAUDE.md \
  -o -name CLAUDE.local.md \) -prune -print0)
cp "$prompt" "$run/prompt.md"

# The user's HOME, unlike the sign-in: the profile's `~` denies and strict's own runtime
# socket denies resolve against it. With an empty HOME the sandbox refuses to start,
# because /var/run/docker.sock links into ~/.docker (grok 1.0.77). Asked from inside, a
# review run this way saw none of ~/.claude's skills, rules, plugin hooks or MCP servers,
# only Grok's bundled skills (checked 2026-11-11), though `grok inspect` lists them.
status=0
run_limited "$review_limit" env -i HOME="$HOME" PATH="/usr/bin:/bin" TMPDIR="$home/tmp/" \
  GROK_HOME="$home" GROK_MEMORY=0 \
  "$grok_bin" --cwd "$wt" --sandbox pr-review \
  --tools read_file,grep,list_dir --disallowed-tools search_tool,use_tool \
  --disable-web-search --no-subagents \
  --prompt-file "$run/prompt.md" </dev/null >"$run/review.txt" 2>"$run/review.err" ||
  status=$?
if [[ "$status" -eq 124 ]]; then
  echo "the review did not finish in ${review_limit}s and was stopped" >&2
fi

# Grok prints these two lines to stderr when a long review compacts its own context and
# carries on; the review still completes (seen 2026-11-05, grok 1.0.70). Any other line,
# such as a sandbox that could not be applied, still fails the run. `-a`: GNU grep would
# otherwise treat stderr holding a NUL or an invalid byte as binary and print no lines.
# Exit 1 means every line was a notice; 2 is an error, which fails the run.
filter=0
grep -avxE -e 'Auto-compacting conversation \([0-9]+% full\)\.\.\.' \
  -e 'Conversation compacted\.' "$run/review.err" >"$run/review.err.unexpected" || filter=$?

if [[ "$status" -ne 0 || "$filter" -gt 1 || -s "$run/review.err.unexpected" ||
  ! -s "$run/review.txt" ]]; then
  echo "grok review failed (exit $status); its output is not used. stderr:" >&2
  echo_stderr "$run/review.err"
  exit 1
fi

if holds_credential "$run/review.txt"; then
  echo "grok review output contains credential material; deleted unread" >&2
  exit 2
fi

cp "$run/review.txt" "$output"
echo "grok review written to $output"
