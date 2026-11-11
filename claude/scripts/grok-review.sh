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

# How long the sign-in refresh may take before it is stopped (seconds). A refresh is one
# token request and one short model turn; past this it is waiting on something else, such
# as an interactive sign-in. Overridable for tests.
signin_limit="${GROK_SIGNIN_LIMIT_SECS:-120}"

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

mkdir -p "$home/runs" "$home/tmp"
run="$(mktemp -d "$home/runs/pr-XXXXXX")"
wt="$run/wt"
cleanup() {
  cd /
  git -C "$repo" worktree remove --force "$wt" >/dev/null 2>&1 || true
  trash "$run" >/dev/null 2>&1 || true
  # Past reviews' transcripts would be readable to the next review; keep none.
  if [[ -d "$home/sessions" ]]; then
    find "$home/sessions" -mindepth 1 -maxdepth 1 -exec trash {} + >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

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
env -i HOME="$run/signin-home" PATH="/usr/bin:/bin" TMPDIR="$home/tmp/" \
  GROK_HOME="$home" GROK_MEMORY=0 GROK_AUTH_EARLY_INVALIDATION_SECS=86400 \
  "$grok_bin" --cwd "$run/signin" \
  --tools list_dir --disallowed-tools search_tool,use_tool \
  --disable-web-search --no-subagents --max-turns 1 \
  -p "Reply with the single word OK." </dev/null >/dev/null 2>"$run/signin.err" &
signin_pid=$!
waited=0
while kill -0 "$signin_pid" 2>/dev/null && [[ "$waited" -lt "$signin_limit" ]]; do
  sleep 1
  waited=$((waited + 1))
done
signin_status=0
if kill -0 "$signin_pid" 2>/dev/null; then
  kill "$signin_pid" 2>/dev/null || true
  wait "$signin_pid" 2>/dev/null || true
  echo "the sign-in refresh did not finish in ${signin_limit}s and was stopped" >&2
  signin_status=124
else
  wait "$signin_pid" || signin_status=$?
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

status=0
env -i HOME="$HOME" PATH="/usr/bin:/bin" TMPDIR="$home/tmp/" \
  GROK_HOME="$home" GROK_MEMORY=0 \
  "$grok_bin" --cwd "$wt" --sandbox pr-review \
  --tools read_file,grep,list_dir --disallowed-tools search_tool,use_tool \
  --disable-web-search --no-subagents \
  --prompt-file "$run/prompt.md" </dev/null >"$run/review.txt" 2>"$run/review.err" ||
  status=$?

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
