#!/usr/bin/env bash
# Run Claude as the other-model reviewer of one PR head when Grok wrote the change
# (claude/commands/review-pr.md, "Claude review"): the counterpart of grok-review.sh.
#
#   claude-review.sh <repo-dir> <head-sha> <prompt-file> <output-file>
#
# Claude runs headless from a disposable worktree of the PR head with the PR's agent
# configuration removed, so the hooks, rules and servers the PR carries do not load. It gets
# read-only tools and no MCP servers, and the prompt arrives on stdin, so a large diff cannot
# hit the argument-length limit. It still runs with the user's own login and ~/.claude
# settings: `--bare` would skip those, but it reads only ANTHROPIC_API_KEY, never a
# subscription login. So it is less isolated than grok-review.sh, and review-pr asks first
# before using it on someone else's PR. There is no credential check on the output: the
# login lives in the keychain, which the read-only tools cannot reach.
#
# Exit status: 0 review written; 1 the run failed, wrote nothing, or the head could not be
# checked out (output not usable);
# 3 claude is not installed; 64 usage.
#
# CLAUDE_BIN overrides the claude binary (tests).
set -euo pipefail

usage() {
  echo "usage: claude-review.sh <repo-dir> <head-sha> <prompt-file> <output-file>" >&2
  exit 64
}

[[ $# -eq 4 ]] || usage
repo="$1"
head_sha="$2"
prompt="$3"
output="$4"
[[ -d "$repo" && -f "$prompt" && -n "$head_sha" ]] || usage
# Absolute: cleanup runs `git -C "$repo"` after `cd /`, where a relative path would miss.
repo="$(cd "$repo" && pwd -P)"

claude_bin="${CLAUDE_BIN:-$(command -v claude || true)}"
if [[ -z "$claude_bin" || ! -x "$claude_bin" ]]; then
  echo "claude review unavailable: claude is not installed" >&2
  exit 3
fi

run="$(mktemp -d "${TMPDIR:-/tmp}/claude-review.XXXXXX")"
wt="$run/wt"
cleanup() {
  cd /
  git -C "$repo" worktree remove --force "$wt" >/dev/null 2>&1 || true
  trash "$run" >/dev/null 2>&1 || true
}
trap cleanup EXIT

if ! git -C "$repo" worktree add --quiet --detach "$wt" "$head_sha"; then
  echo "claude review failed: cannot check out $head_sha in $repo" >&2
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

status=0
(cd "$wt" && "$claude_bin" -p --tools Read,Grep,Glob --strict-mcp-config \
  --permission-mode plan) <"$prompt" >"$run/review.txt" 2>"$run/review.err" || status=$?

if [[ "$status" -ne 0 || ! -s "$run/review.txt" ]]; then
  echo "claude review failed (exit $status); its output is not used. stderr:" >&2
  head -c 2000 "$run/review.err" >&2
  exit 1
fi

cp "$run/review.txt" "$output"
echo "claude review written to $output"
