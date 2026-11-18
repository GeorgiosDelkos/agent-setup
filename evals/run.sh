#!/usr/bin/env bash
# Scores the setup deployed on this machine on fixed Rust tasks, so a rules change or a new
# model can be compared with the run before it. For each task: a headless Claude session
# writes the code in a fresh crate that has opted in to the house rules, then the crate is
# scored by its own tests, by rustc and clippy under the house lint table, by house-check.pl,
# by a rust-style-reviewer session, and last by the task's oracle: tests the session never
# saw, where the task has them.
#
# Usage: bash evals/run.sh [task...]      (default: every directory in evals/tasks/)
# A task is evals/tasks/<name>/prompt.md, with an optional oracle.rs beside it, and an
# optional follow-up: followup.md, a change asked of the finished crate, and
# followup-oracle.rs, the tests of the crate after that change.
# Output: <out>/results.tsv, one row per task, and each crate with its transcripts beside it.
#   <out> is $EVALS_OUT/<UTC time>, by default under ~/.cache/agent-setup-evals: outside the
#   repo, because the deployed copy must not get files written into it.
# Environment: EVALS_MODEL passes --model; EVALS_EFFORT passes --effort (default high) to
#   every session; CLAUDE_BIN replaces the claude binary (tests);
#   EVALS_ARM picks what the task session runs with:
#     setup  (default) this machine's deployed rules, skills, hooks and plugins;
#     bare   `claude --safe-mode`: none of them, with the same login and model;
#     grok   Grok Build with the same deployed setup (GROK_BIN replaces the binary,
#            EVALS_GROK_MODEL passes --model to it).
#   The reviewer session, the follow-up session and every other score are the same in
#   every arm, so two arms differ only in who wrote the code.
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
BARE_ARGS=(--safe-mode --permission-mode auto)
arm="${EVALS_ARM:-setup}"
grok_bin="${GROK_BIN:-grok}"
case "$arm" in
setup) arm_args=() ;;
bare) arm_args=("${BARE_ARGS[@]}") ;;
grok)
  if ! command -v "$grok_bin" >/dev/null; then
    echo "evals: the grok arm needs $grok_bin on PATH (or GROK_BIN)" >&2
    exit 2
  fi
  # Auto, as the Claude arms run: a headless Grok session in the default mode can approve
  # nothing. The effort is given by flag for the reason common_args gives.
  arm_args=(--output-format json --permission-mode auto --effort "$effort")
  if [[ -n "${EVALS_GROK_MODEL:-}" ]]; then
    arm_args+=(--model "$EVALS_GROK_MODEL")
  fi
  ;;
*)
  echo "evals: no arm $arm (EVALS_ARM is setup, bare or grok)" >&2
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

# The memory hooks are off in every session this script starts: an eval session would
# otherwise be asked, at its stop, to write what it learned into the team's shared memory.
export HIPPIUS_MEM_HOOKS_BYPASS=1

# One headless Claude session in the crate at $1, with $2.. as extra arguments and the
# prompt on stdin.
session() {
  local dir="$1"
  shift
  (cd "$dir" && limit "$SESSION_LIMIT_SECS" "$claude_bin" -p "$@" "${common_args[@]}")
}

# The task session of this run's arm in the crate at $1, given the prompt file $2. Prints the
# session's JSON result, which has the same spend fields from both tools. Grok takes the
# prompt as a file, so $2 is a copy outside evals/tasks/: the path is on the command line,
# and the task's oracle lies beside the original.
task_session() {
  local dir="$1" prompt="$2"
  if [[ "$arm" == grok ]]; then
    (cd "$dir" && limit "$SESSION_LIMIT_SECS" "$grok_bin" --prompt-file "$prompt" \
      "${arm_args[@]}" </dev/null)
  else
    session "$dir" --output-format json ${arm_args[@]+"${arm_args[@]}"} <"$prompt"
  fi
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

# The oracle file $1 run in the crate at $3 as the integration test $2: `passed/total`,
# `build` when the oracle does not compile against what the session wrote (it missed the
# entry points the prompt names), `?` when the run gave no result (a hung test), or `-`
# when there is no such file. The log is $3.$2.log.
# Call it after every other score of that session: it adds tests/$2.rs to the crate, which
# the crate's own test score, the lint counts and the reviewer must not see.
oracle_score() {
  local oracle="$1" name="$2" dir="$3" log="$3.$2.log"
  if [[ ! -f "$oracle" ]]; then
    echo -
    return
  fi
  mkdir -p "$dir/tests"
  cp "$oracle" "$dir/tests/$name.rs"
  score_cargo "$dir" test --test "$name" >"$log" 2>&1 || true
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

# Field $2 of the session result file $1, or ? when the session left none.
session_field() {
  jq -r --arg field "$2" '.[$field] // "?"' "$1" 2>/dev/null || echo '?'
}

# The follow-up of the task directory $1 in the crate at $2: a second session is asked for
# the change in followup.md, and followup-oracle.rs scores the result. Prints four fields,
# "oracle lines turns cost", or four dashes for a task without a follow-up.
#
# These score the first session's code, by what a later change to it takes, not the second
# session. So the second session is the same in every arm, and it is the bare one: it has
# no hooks, reviewer or rules of its own, so its turns and cost follow the code it was
# given. Running it in the run's own arm was the alternative; the arm's own overhead (the
# setup arm's sessions cost about six times the bare arm's on 2026-11-17) would then sit
# on top of the number.
# `lines` is the Rust it added and removed, `+a/-r`, tests included: a removed line is
# first-session code that did not survive the change.
followup_scores() {
  local task="$1" dir="$2" base lines
  if [[ ! -f "$task/followup.md" ]]; then
    echo '- - - -'
    return
  fi
  # The second session must not find the first oracle in the crate: it would read the
  # hidden tests of the code it is about to change.
  rm -f "$dir/tests/eval_oracle.rs"
  rmdir "$dir/tests" 2>/dev/null || true
  git -C "$dir" add -A
  git -C "$dir" -c user.name=evals -c user.email=evals@localhost commit -q --allow-empty \
    -m first
  base="$(git -C "$dir" rev-parse HEAD)"
  session "$dir" --output-format json "${BARE_ARGS[@]}" <"$task/followup.md" \
    >"$dir.followup.json" 2>"$dir.followup.err" || true
  if ! session_wrote_code "$dir" "$base"; then
    echo 'no-change - - -'
    return
  fi
  # Intent to add, so that a file the session created counts in the diff.
  git -C "$dir" add -A -N
  lines="$(git -C "$dir" diff --numstat "$base" -- '*.rs' |
    awk '{ added += $1; removed += $2 } END { printf "+%d/-%d", added, removed }')"
  echo "$(oracle_score "$task/followup-oracle.rs" eval_followup "$dir") $lines" \
    "$(session_field "$dir.followup.json" num_turns)" \
    "$(session_field "$dir.followup.json" total_cost_usd)"
}

# Runs one task and appends its row. A session that wrote no Rust gets a row of dashes:
# scoring the untouched seed crate would report a clean result for no work.
run_task() {
  local name="$1" dir="$out/$1" task="$EVALS_DIR/tasks/$1" seed blocker major minor
  local tests diagnostics house oracle followup lines followup_turns followup_cost
  seed="$(seed_crate "$dir")"
  cp "$task/prompt.md" "$dir.prompt.md"
  task_session "$dir" "$dir.prompt.md" >"$dir.agent.json" 2>"$dir.agent.err" || true
  if ! session_wrote_code "$dir" "$seed"; then
    printf '%s\tno-change\t-\t-\t-\t-\t-\t-\t-\t-\t-\t-\t-\t-\t-\n' "$name" >>"$results"
    return
  fi

  session "$dir" --agent rust-style-reviewer >"$dir.review.md" 2>"$dir.review.err" <<EOF || true
Review every change in this crate since commit $seed, committed or not: \`git diff $seed\`
plus the untracked files. End your report with exactly one line of this form, with zeros
when there are none:
findings: blocker=<n> major=<n> minor=<n>
EOF
  read -r blocker major minor <<<"$(review_counts "$dir.review.md")"
  # In this order: the oracle is copied in only after these three have read the crate, and
  # the follow-up changes the crate only after everything else has scored it.
  tests="$(test_score "$dir")"
  diagnostics="$(diagnostics_count "$dir")"
  house="$(house_count "$dir")"
  oracle="$(oracle_score "$task/oracle.rs" eval_oracle "$dir")"
  read -r followup lines followup_turns followup_cost <<<"$(followup_scores "$task" "$dir")"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$tests" \
    "$oracle" "$diagnostics" "$house" "$blocker" "$major" "$minor" \
    "$(session_model "$dir.agent.json")" "$(session_field "$dir.agent.json" num_turns)" \
    "$(session_field "$dir.agent.json" total_cost_usd)" \
    "$followup" "$lines" "$followup_turns" "$followup_cost" >>"$results"
}

# HEAD of the deployed checkout and of this one. In a synced folder the files can be ahead
# of HEAD (agents/SETUP.md, Version control), so a commit names what git knows, no more.
deployed="$(git -C "$HOME/.claude/skills" rev-parse --short HEAD 2>/dev/null || echo unknown)"
checkers="$(git -C "$EVALS_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
header="# arm $arm, deployed $deployed, checkers $checkers,"
header+=" model ${EVALS_MODEL:-default}, effort $effort, $("$claude_bin" --version)"
if [[ "$arm" == grok ]]; then
  header+=", grok model ${EVALS_GROK_MODEL:-default}, $("$grok_bin" --version)"
fi
{
  echo "$header"
  printf 'task\ttests\toracle\tdiagnostics\thouse\tblocker\tmajor\tminor\tmodel\tturns\tcost_usd'
  printf '\tfollowup\tfollowup_lines\tfollowup_turns\tfollowup_cost_usd\n'
} >"$results"
for task in "${tasks[@]}"; do
  echo "running $task" >&2
  run_task "$task"
done
column -t -s $'\t' "$results"
echo "results: $results"
