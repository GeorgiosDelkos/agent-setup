#!/usr/bin/env bash
# Scores the setup deployed on this machine on fixed Rust tasks, so a rules change or a new
# model can be compared with the run before it. For each task: a headless Claude session
# writes the code in a fresh crate that has opted in to the house rules, then the crate is
# scored by its own tests, by rustc and clippy under the house lint table, by house-check.pl,
# by a rust-style-reviewer session, and last by the task's oracle: tests the session never
# saw, where the task has them.
#
# Usage: bash evals/run.sh [task...]      (default: every directory in evals/tasks/)
# A task is evals/tasks/<name>/prompt.md, with an optional oracle.rs beside it.
# Output: <out>/results.tsv, one row per task, and each crate with its transcripts beside it.
#   <out> is $EVALS_OUT/<UTC time>, by default under ~/.cache/agent-setup-evals: outside the
#   repo, because the deployed copy must not get files written into it.
# Environment: EVALS_MODEL passes --model; EVALS_EFFORT passes --effort (default high) to
#   every session; CLAUDE_BIN replaces the claude binary (tests);
#   EVALS_ARM picks what the task session runs with:
#     setup  (default) this machine's deployed rules, skills, hooks and plugins;
#     bare   `claude --safe-mode`: none of them, with the same login and model.
#   The reviewer session and every other score always run with the setup, so two arms
#   differ only in who wrote the code.
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
# Every session is given its effort by flag. Left to the settings file, the setup arm ran at
# the machine's `effortLevel` and the bare arm, which reads no settings, at the default: the
# first pilot (2026-11-17) compared two efforts as well as two arms. `high` is arbitrary.
effort="${EVALS_EFFORT:-high}"
common_args=(--effort "$effort")
if [[ -n "${EVALS_MODEL:-}" ]]; then
  common_args+=(--model "$EVALS_MODEL")
fi
# Both arbitrary: an hour is the limit the review scripts give a model session, and fifteen
# minutes is far beyond what a small crate's build and tests take. Without them one
# deadlocked test (the actor task can write one) hangs the run with no row for its task.
SESSION_LIMIT_SECS=3600
CARGO_LIMIT_SECS=900

# The task session's extra arguments. The bare arm names its permission mode: safe mode
# does not read the settings file that sets it, and a headless session in the default mode
# can approve nothing, so it would write no code.
arm="${EVALS_ARM:-setup}"
case "$arm" in
setup) arm_args=() ;;
bare) arm_args=(--safe-mode --permission-mode auto) ;;
*)
  echo "evals: no arm $arm (EVALS_ARM is setup or bare)" >&2
  exit 2
  ;;
esac

tasks=("$@")
if [[ ${#tasks[@]} -eq 0 ]]; then
  for file in "$EVALS_DIR"/tasks/*/prompt.md; do
    tasks+=("$(basename "$(dirname "$file")")")
  done
fi
for task in "${tasks[@]}"; do
  if [[ ! -f "$EVALS_DIR/tasks/$task/prompt.md" ]]; then
    echo "evals: no task $task (expected $EVALS_DIR/tasks/$task/prompt.md)" >&2
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
    limit "$SESSION_LIMIT_SECS" "$claude_bin" -p "$@" "${common_args[@]}")
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

# The oracle of task $1 run in the crate at $2: `passed/total`, `build` when the oracle does
# not compile against what the session wrote (it missed the entry points the prompt names),
# `?` when the run gave no result (a hung test), or `-` for a task without an oracle.
# Call it after every other score: it adds tests/eval_oracle.rs to the crate, which the crate's
# own test score, the lint counts and the reviewer must not see.
oracle_score() {
  local oracle="$EVALS_DIR/tasks/$1/oracle.rs" dir="$2" log="$2.oracle.log"
  if [[ ! -f "$oracle" ]]; then
    echo -
    return
  fi
  mkdir -p "$dir/tests"
  cp "$oracle" "$dir/tests/eval_oracle.rs"
  score_cargo "$dir" test --test eval_oracle >"$log" 2>&1 || true
  if grep -q '^test result:' "$log"; then
    awk '/^test result:/ { passed += $4; failed += $6 }
      END { print passed "/" passed + failed }' "$log"
  elif grep -q '^error: could not compile' "$log"; then
    echo build
  else
    echo '?'
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

# The model the session whose JSON result is $1 ran on, as that session reported it, or ?.
# The header can only name the model that was asked for, and with none asked for each arm
# takes its own default: the setup arm from the settings file, the bare arm, which reads no
# settings, from the CLI. This column is what shows whether two rows used the same one.
session_model() {
  jq -r '.modelUsage // {} | keys | if length == 0 then "?" else join("+") end' "$1" \
    2>/dev/null || echo '?'
}

# Runs one task and appends its row. A session that wrote no Rust gets a row of dashes:
# scoring the untouched seed crate would report a clean result for no work.
run_task() {
  local name="$1" dir="$out/$1" seed blocker major minor tests diagnostics house
  seed="$(seed_crate "$dir")"
  session "$dir" --output-format json ${arm_args[@]+"${arm_args[@]}"} \
    <"$EVALS_DIR/tasks/$name/prompt.md" >"$dir.agent.json" 2>"$dir.agent.err" || true
  if ! session_wrote_code "$dir" "$seed"; then
    printf '%s\tno-change\t-\t-\t-\t-\t-\t-\t-\t-\t-\n' "$name" >>"$results"
    return
  fi

  session "$dir" --agent rust-style-reviewer >"$dir.review.md" 2>"$dir.review.err" <<EOF || true
Review every change in this crate since commit $seed, committed or not: \`git diff $seed\`
plus the untracked files. End your report with exactly one line of this form, with zeros
when there are none:
findings: blocker=<n> major=<n> minor=<n>
EOF
  read -r blocker major minor <<<"$(review_counts "$dir.review.md")"
  # Bound before the row is printed, so the oracle, which printf would otherwise run in
  # argument order, is copied in only after these three have read the crate.
  tests="$(test_score "$dir")"
  diagnostics="$(diagnostics_count "$dir")"
  house="$(house_count "$dir")"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$tests" \
    "$(oracle_score "$name" "$dir")" "$diagnostics" "$house" "$blocker" "$major" "$minor" \
    "$(session_model "$dir.agent.json")" \
    "$(jq -r '.num_turns // "?"' "$dir.agent.json" 2>/dev/null || echo '?')" \
    "$(jq -r '.total_cost_usd // "?"' "$dir.agent.json" 2>/dev/null || echo '?')" >>"$results"
}

# HEAD of the deployed checkout and of this one. In a synced folder the files can be ahead
# of HEAD (agents/SETUP.md, Version control), so a commit names what git knows, no more.
deployed="$(git -C "$HOME/.claude/skills" rev-parse --short HEAD 2>/dev/null || echo unknown)"
checkers="$(git -C "$EVALS_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
{
  echo "# arm $arm, deployed $deployed, checkers $checkers," \
    "model ${EVALS_MODEL:-default}, effort $effort, $("$claude_bin" --version)"
  printf 'task\ttests\toracle\tdiagnostics\thouse\tblocker\tmajor\tminor\tmodel\tturns\tcost_usd\n'
} >"$results"
for task in "${tasks[@]}"; do
  echo "running $task" >&2
  run_task "$task"
done
column -t -s $'\t' "$results"
echo "results: $results"
