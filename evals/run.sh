#!/usr/bin/env bash
# Scores the setup deployed on this machine on fixed Rust tasks, so a rules change or a new
# model can be compared with the run before it. For each task: a headless Claude session
# writes the code in a fresh crate that has opted in to the house rules, then the crate is
# scored by its own tests, clippy under the house lint table, house-check.pl, and a
# rust-style-reviewer session.
#
# Usage: bash evals/run.sh [task...]      (default: every file in evals/tasks/)
# Output: <out>/results.tsv, one row per task, and each crate with its transcripts beside it.
#   <out> is $EVALS_OUT/<UTC time>, by default under ~/.cache/agent-setup-evals: outside the
#   repo, because the deployed copy must not get files written into it.
# Environment: EVALS_MODEL passes --model; CLAUDE_BIN replaces the claude binary (tests).
#
# The sessions run with this machine's ~/.claude, so they measure the deployed commit, not
# the checkout this script is in; only the lint table and house-check.pl come from here. A
# score is one sample from a model, not a measurement: compare runs by several tasks moving
# the same way, never by one number.
set -euo pipefail

EVALS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATES="$EVALS_DIR/../claude/skills/rust-style/templates"
HOUSE_CHECK="$EVALS_DIR/../claude/hooks/rust/house-check.pl"
claude_bin="${CLAUDE_BIN:-claude}"
# Expanded as ${model_args[@]+...} below: bash 3.2 (macOS) treats a plain expansion of an
# empty array as an unset variable under `set -u`.
model_args=()
if [[ -n "${EVALS_MODEL:-}" ]]; then
  model_args=(--model "$EVALS_MODEL")
fi
# The reviewer agent ends with "clean" or counts in its own words; this line is what the
# harness parses.
REVIEW_PROMPT='Review the uncommitted changes in this crate. End your report with exactly
one line of this form, with zeros when there are none:
findings: blocker=<n> major=<n> minor=<n>'

out="${EVALS_OUT:-$HOME/.cache/agent-setup-evals}/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$out"
# No shared CARGO_TARGET_DIR: a session that runs cargo mutants leaves mutated artifacts in
# it, and the scoring `cargo test` then runs a stale build (seen in the first real run).
results="$out/results.tsv"

# A fresh library crate at $1 with the house lint table and the opt-in, committed, so the
# agent's work is the uncommitted change the hooks and the reviewer look at.
seed_crate() {
  local dir="$1"
  cargo init -q --lib --name "$(basename "$dir")" "$dir"
  printf '\n[package.metadata.house-check]\nbaseline = true\n\n' >>"$dir/Cargo.toml"
  cat "$TEMPLATES/Cargo.lints.toml" >>"$dir/Cargo.toml"
  cp "$TEMPLATES/clippy.toml" "$dir/"
  git -C "$dir" init -q
  git -C "$dir" add -A
  git -C "$dir" -c user.name=evals -c user.email=evals@localhost commit -qm seed
}

# Number of clippy and rustc diagnostics in the crate at $1, or ? when clippy did not run.
clippy_count() {
  (cd "$1" && cargo clippy -q --all-targets --message-format=json 2>/dev/null) |
    jq -s '[.[] | select(.reason == "compiler-message" and .message.code != null)] | length' ||
    echo '?'
}

# Runs one task and appends its row. A session that fails or changes nothing gets a row of
# dashes: scoring the untouched seed crate would report a clean result for no work.
run_task() {
  local name="$1" dir="$out/$1" tests=fail house blocker='?' major='?' minor='?' files
  seed_crate "$dir"
  (cd "$dir" && "$claude_bin" -p --output-format json ${model_args[@]+"${model_args[@]}"}) \
    <"$EVALS_DIR/tasks/$name.md" >"$dir.agent.json" 2>"$dir.agent.err" || true
  if [[ -z "$(git -C "$dir" status --porcelain)" ]]; then
    printf '%s\tno-change\t-\t-\t-\t-\t-\t-\t-\n' "$name" >>"$results"
    return
  fi

  if (cd "$dir" && cargo test -q) >"$dir.test.log" 2>&1; then
    tests=pass
  fi
  files="$(find "$dir" -name target -prune -o \( -name '*.rs' -o -name Cargo.toml \) -print)"
  # house-check exits 1 when it has findings; its output is the count.
  # shellcheck disable=SC2086 # one path per word; the paths hold no spaces
  house="$({ perl "$HOUSE_CHECK" $files || true; } | grep -c . || true)"
  (cd "$dir" && "$claude_bin" -p --agent rust-style-reviewer ${model_args[@]+"${model_args[@]}"}) \
    <<<"$REVIEW_PROMPT" >"$dir.review.md" 2>"$dir.review.err" || true
  if [[ "$(tail -n 5 "$dir.review.md")" =~ blocker=([0-9]+)\ major=([0-9]+)\ minor=([0-9]+) ]]; then
    blocker="${BASH_REMATCH[1]}" major="${BASH_REMATCH[2]}" minor="${BASH_REMATCH[3]}"
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$tests" "$(clippy_count "$dir")" \
    "$house" "$blocker" "$major" "$minor" \
    "$(jq -r '.num_turns // "?"' "$dir.agent.json" 2>/dev/null || echo '?')" \
    "$(jq -r '.total_cost_usd // "?"' "$dir.agent.json" 2>/dev/null || echo '?')" >>"$results"
}

tasks=("$@")
if [[ ${#tasks[@]} -eq 0 ]]; then
  for file in "$EVALS_DIR"/tasks/*.md; do
    tasks+=("$(basename "$file" .md)")
  done
fi
deployed="$(git -C "$HOME/.claude/skills" rev-parse --short HEAD 2>/dev/null || echo unknown)"
{
  echo "# setup $deployed, model ${EVALS_MODEL:-default}, $("$claude_bin" --version)"
  printf 'task\ttests\tclippy\thouse\tblocker\tmajor\tminor\tturns\tcost_usd\n'
} >"$results"
for task in "${tasks[@]}"; do
  if [[ ! -f "$EVALS_DIR/tasks/$task.md" ]]; then
    echo "evals: no task $task (expected $EVALS_DIR/tasks/$task.md)" >&2
    exit 2
  fi
  echo "running $task" >&2
  run_task "$task"
done
column -t -s $'\t' "$results"
echo "results: $results"
