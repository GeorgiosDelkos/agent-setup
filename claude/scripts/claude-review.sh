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
# Exit status: 0 review written; 1 the run failed or wrote nothing (output not usable);
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

git -C "$repo" worktree add --quiet --detach "$wt" "$head_sha"
# Claude loads hooks, rules and servers from these at the root it starts in. Their changes,
# if any, are in the diff the prompt carries; the copies here must not run. The same list
# as grok-review.sh.
for entry in .claude .grok .cursor .agents .mcp.json AGENTS.md AGENT.md CLAUDE.md \
  CLAUDE.local.md; do
  if [[ -e "$wt/$entry" || -L "$wt/$entry" ]]; then
    trash "$wt/$entry"
  fi
done

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
