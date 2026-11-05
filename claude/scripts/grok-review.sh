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
# installed, review home missing, not signed in); 64 usage.
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

home="${GROK_REVIEW_HOME:-$HOME/.grok-review}"
grok_bin="${GROK_BIN:-$(command -v grok || true)}"
[[ -n "$grok_bin" && -x "$grok_bin" ]] || unavailable "grok is not installed"
[[ -d "$home" && ! -L "$home" ]] || unavailable "no review home at $home (run install.sh)"
[[ -f "$home/sandbox.toml" && ! -L "$home/sandbox.toml" ]] ||
  unavailable "no pr-review profile in $home (run install.sh)"
# A regular, non-empty file; never read here, so the credential stays out of any output.
[[ -f "$home/auth.json" && ! -L "$home/auth.json" && -s "$home/auth.json" ]] ||
  unavailable "the review home is not signed in: GROK_HOME=$home grok login"

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

git -C "$repo" worktree add --quiet --detach "$wt" "$head_sha"
# Grok loads hooks, rules, skills and servers from these at the root it starts in. Their
# changes, if any, are in the diff the prompt carries; the copies here must not run.
for entry in .claude .grok .cursor .agents .mcp.json AGENTS.md AGENT.md CLAUDE.md \
  CLAUDE.local.md; do
  if [[ -e "$wt/$entry" || -L "$wt/$entry" ]]; then
    trash "$wt/$entry"
  fi
done
cp "$prompt" "$run/prompt.md"

status=0
env -i HOME="$HOME" PATH="/usr/bin:/bin" TMPDIR="$home/tmp/" \
  GROK_HOME="$home" GROK_MEMORY=0 \
  "$grok_bin" --cwd "$wt" --sandbox pr-review \
  --tools read_file,grep,list_dir --disallowed-tools search_tool,use_tool \
  --disable-web-search --no-subagents \
  --prompt-file "$run/prompt.md" >"$run/review.txt" 2>"$run/review.err" || status=$?

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
  head -c 2000 "$run/review.err" >&2
  exit 1
fi

# Any credential string of 20 or more characters, matched without printing it.
leaked=no
while IFS= read -r secret; do
  if grep -qF -- "$secret" "$run/review.txt"; then
    leaked=yes
  fi
done < <(jq -r '.. | strings | select(length >= 20)' "$home/auth.json" 2>/dev/null || true)
if [[ "$leaked" == yes ]]; then
  echo "grok review output contains credential material; deleted unread" >&2
  exit 2
fi

cp "$run/review.txt" "$output"
echo "grok review written to $output"
