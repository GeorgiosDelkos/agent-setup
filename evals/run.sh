#!/usr/bin/env bash
# Scores the setup deployed on this machine on fixed Rust tasks, so a rules change or a new
# model can be compared with the run before it. For each task: a headless Claude session
# writes the code in a fresh crate that has opted in to the house rules, then the crate is
# scored by its own tests, by rustc and clippy under the house lint table, by house-check.pl,
# and by a rust-style-reviewer session.
#
# Usage: bash evals/run.sh [task...]      (default: every file in evals/tasks/)
# Output: <out>/results.tsv, one row per task, and each crate with its transcripts beside it.
#   <out> is $EVALS_OUT/<UTC time>, by default under ~/.cache/agent-setup-evals: outside the
#   repo, because the deployed copy must not get files written into it.
# Environment: EVALS_MODEL passes --model; CLAUDE_BIN replaces the claude binary (tests).
#
# The sessions run with this machine's ~/.claude, so they measure the deployed setup, not
# the checkout this script is in; the lint table and house-check.pl do come from this
# checkout, and the header of results.tsv names both commits. A session has the user's
# permissions, and the scoring runs the code it wrote: run this only where you would let an
# agent work on such a task. A score is one sample from a model, not a measurement: compare
# runs by several tasks moving the same way, never by one number.
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
# Both arbitrary: an hour is the limit the review scripts give a model session, and fifteen
# minutes is far beyond what a small crate's build and tests take. Without them one
# deadlocked test (the actor task can write one) hangs the run with no row for its task.
SESSION_LIMIT_SECS=3600
CARGO_LIMIT_SECS=900

tasks=("$@")
if [[ ${#tasks[@]} -eq 0 ]]; then
  for file in "$EVALS_DIR"/tasks/*.md; do
    tasks+=("$(basename "$file" .md)")
  done
fi
for task in "${tasks[@]}"; do
  if [[ ! -f "$EVALS_DIR/tasks/$task.md" ]]; then
    echo "evals: no task $task (expected $EVALS_DIR/tasks/$task.md)" >&2
    exit 2
  fi
done

out_root="${EVALS_OUT:-$HOME/.cache/agent-setup-evals}"
out="$out_root/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$out_root"
# Not -p: a second run in the same second must fail here, not write over the first.
mkdir "$out"
results="$out/results.tsv"

# Runs the command in $2.. and stops it after $1 seconds (macOS has no timeout(1)).
limit() {
  perl -e 'alarm shift; exec @ARGV or die "exec: $!\n"' "$@"
}

# One headless session in the crate at $1, with $2.. as extra arguments and the prompt on
# stdin. The memory hooks are off: an eval session would otherwise be asked, at its stop, to
# write what it learned into the team's shared memory.
session() {
  local dir="$1"
  shift
  (cd "$dir" && export HIPPIUS_MEM_HOOKS_BYPASS=1 &&
    limit "$SESSION_LIMIT_SECS" "$claude_bin" -p "$@" ${model_args[@]+"${model_args[@]}"})
}

# cargo $2.. in the crate at $1, built in a target directory of the harness's own. The
# session's builds must not be reused: a session that ran cargo mutants left a mutated
# artifact behind, and the scoring test run used it (first real run, 2026-11-14). A shared
# directory can also come from the environment or ~/.cargo/config.toml, so this sets one.
score_cargo() {
  local dir="$1"
  shift
  (cd "$dir" && export CARGO_TARGET_DIR="$dir.target" && limit "$CARGO_LIMIT_SECS" cargo "$@")
}

# A fresh library crate at $1 with the house lint table and the opt-in, committed. Prints
# the seed commit, which is what the session's work is compared with.
seed_crate() {
  local dir="$1"
  cargo init -q --lib --name "$(basename "$dir")" "$dir"
  printf '\n[package.metadata.house-check]\nbaseline = true\n\n' >>"$dir/Cargo.toml"
  cat "$TEMPLATES/Cargo.lints.toml" >>"$dir/Cargo.toml"
  cp "$TEMPLATES/clippy.toml" "$dir/"
  git -C "$dir" init -q
  git -C "$dir" add -A
  git -C "$dir" -c user.name=evals -c user.email=evals@localhost commit -qm seed
  git -C "$dir" rev-parse HEAD
}

# True when a Rust source file in the crate at $1 differs from the seed commit $2, committed
# or not. `git status` is the wrong test: a session that only ran cargo leaves a Cargo.lock,
# and one that committed its work leaves a clean tree.
session_wrote_code() {
  local dir="$1" seed="$2"
  ! git -C "$dir" diff --quiet "$seed" -- '*.rs' ||
    [[ -n "$(git -C "$dir" ls-files --others --exclude-standard -- '*.rs')" ]]
}

# pass, fail, or none for the crate's own tests. none: cargo test succeeded and ran no test,
# which a crate without tests does too.
test_score() {
  local dir="$1" passed
  if ! score_cargo "$dir" test >"$dir.test.log" 2>&1; then
    echo fail
    return
  fi
  passed="$(grep -Eo '[0-9]+ passed' "$dir.test.log" | awk '{ n += $1 } END { print n + 0 }')"
  if [[ "$passed" -eq 0 ]]; then
    echo none
  else
    echo pass
  fi
}

# Number of distinct rustc and clippy diagnostics in the crate at $1, errors included, or ?
# when the build did not get as far as reporting. Distinct by lint, file and line:
# --all-targets checks the library and its test harness separately and reports a finding in
# shared code once for each. cargo exits non-zero on a deny lint, which is still a count.
diagnostics_count() {
  local json
  json="$(score_cargo "$1" clippy -q --all-targets --message-format=json 2>/dev/null || true)"
  if ! grep -q '"reason":"build-finished"' <<<"$json"; then
    echo '?'
    return
  fi
  jq -s '[.[] | select(.reason == "compiler-message" and .message.code != null) | .message
    | [.code.code, .spans[0].file_name, .spans[0].line_start]] | unique | length' <<<"$json"
}

# Number of house-check.pl findings in the crate at $1 (one per output line), or ? when it
# could not read its input (exit 2). Exit 1 means it has findings.
house_count() {
  local dir="$1" files=() file found code=0
  while IFS= read -r -d '' file; do
    files+=("$file")
  done < <(find "$dir" -name target -prune -o \( -name '*.rs' -o -name Cargo.toml \) -print0)
  found="$(perl "$HOUSE_CHECK" "${files[@]}")" || code=$?
  if [[ "$code" -gt 1 ]]; then
    echo '?'
  else
    grep -c . <<<"$found" || true
  fi
}

# The reviewer's counts as "blocker major minor", from the last line of the review file $1
# that is exactly the line the prompt asks for, or "? ? ?" when there is none. The reviewer
# agent's own closing line ("clean", or counts in its words) cannot be parsed reliably.
review_counts() {
  local line
  line="$(grep -E '^findings: blocker=[0-9]+ major=[0-9]+ minor=[0-9]+[[:space:]]*$' "$1" |
    tail -n 1 || true)"
  if [[ "$line" =~ blocker=([0-9]+)\ major=([0-9]+)\ minor=([0-9]+) ]]; then
    echo "${BASH_REMATCH[1]} ${BASH_REMATCH[2]} ${BASH_REMATCH[3]}"
  else
    echo '? ? ?'
  fi
}

# Runs one task and appends its row. A session that wrote no Rust gets a row of dashes:
# scoring the untouched seed crate would report a clean result for no work.
run_task() {
  local name="$1" dir="$out/$1" seed blocker major minor
  seed="$(seed_crate "$dir")"
  session "$dir" --output-format json \
    <"$EVALS_DIR/tasks/$name.md" >"$dir.agent.json" 2>"$dir.agent.err" || true
  if ! session_wrote_code "$dir" "$seed"; then
    printf '%s\tno-change\t-\t-\t-\t-\t-\t-\t-\n' "$name" >>"$results"
    return
  fi

  session "$dir" --agent rust-style-reviewer >"$dir.review.md" 2>"$dir.review.err" <<EOF || true
Review every change in this crate since commit $seed, committed or not: \`git diff $seed\`
plus the untracked files. End your report with exactly one line of this form, with zeros
when there are none:
findings: blocker=<n> major=<n> minor=<n>
EOF
  read -r blocker major minor <<<"$(review_counts "$dir.review.md")"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$(test_score "$dir")" \
    "$(diagnostics_count "$dir")" "$(house_count "$dir")" "$blocker" "$major" "$minor" \
    "$(jq -r '.num_turns // "?"' "$dir.agent.json" 2>/dev/null || echo '?')" \
    "$(jq -r '.total_cost_usd // "?"' "$dir.agent.json" 2>/dev/null || echo '?')" >>"$results"
}

# HEAD of the deployed checkout and of this one. In a synced folder the files can be ahead
# of HEAD (agents/SETUP.md, Version control), so a commit names what git knows, no more.
deployed="$(git -C "$HOME/.claude/skills" rev-parse --short HEAD 2>/dev/null || echo unknown)"
checkers="$(git -C "$EVALS_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
{
  echo "# deployed $deployed, checkers $checkers, model ${EVALS_MODEL:-default}," \
    "$("$claude_bin" --version)"
  printf 'task\ttests\tdiagnostics\thouse\tblocker\tmajor\tminor\tturns\tcost_usd\n'
} >"$results"
for task in "${tasks[@]}"; do
  echo "running $task" >&2
  run_task "$task"
done
column -t -s $'\t' "$results"
echo "results: $results"
