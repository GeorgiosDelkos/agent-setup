#!/usr/bin/env bash
# Tests for evals/run.sh with a stub claude (CLAUDE_BIN) and real cargo. One run over
# several tasks; the stub picks what the "session" does from the crate's name, so each
# task below stands for one case.
set -euo pipefail

RUN="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/run.sh"
WORK="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/evals-test.XXXXXX")" && pwd -P)"
trap 'trash "$WORK"' EXIT
pass=0
fail=0

check() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' "$name" "$expected" "$actual"
  fi
}

# The stub is the reviewer with --agent, the follow-up session when the crate's last commit
# is the harness's `first`, and the task session otherwise. The crate the task session
# writes is clean under the house lints and has one house-check finding (a TODO without an
# owner); the cases change one thing each.
cat >"$WORK/claude" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
crate="$(basename "$PWD")"
good_lib() {
  cat >src/lib.rs <<'RS'
//! Stub crate.

// TODO: finish this
/// Returns two.
#[must_use]
pub fn two() -> u32 {
    2
}
RS
}
a_test() {
  cat >>src/lib.rs <<'RS'

#[cfg(test)]
mod tests {
    use super::two;

    #[test]
    fn two_is_two() {
        assert_eq!(two(), 2);
    }
}
RS
}
# A reference solution as the session's work (STUB_SOLUTION=correct), or one with the defect
# a session is likely to write (broken): an interner that copies the string to look it up,
# a log that leaves a torn tail in the file.
solution() {
  local fixture="${crate//-/_}"
  cp "$FIXTURES/$fixture.rs" src/lib.rs
  if [[ "$crate" == actor-counter ]]; then
    printf '\n[dependencies.tokio]\nversion = "1"\nfeatures = ["rt", "sync"]\n' >>Cargo.toml
  fi
  case "$STUB_SOLUTION:$crate" in
  broken:interner)
    perl -pi -e 's/symbols\.get\(string\)/symbols.get(&Box::<str>::from(string))/' src/lib.rs
    ;;
  broken:wal) perl -ni -e 'print unless /file\.set_len\(/' src/lib.rs ;;
  esac
}
if [[ "$*" == *--version* ]]; then
  echo "stub 0.0.0"
  exit 0
fi
if [[ "$*" == *--agent* ]]; then
  role=review
elif [[ "$(git log -1 --format=%s)" == first ]]; then
  role=followup
else
  role=task
fi
printf '%s\t%s\t%s\n' "$crate" "$role" "$*" >>"$STUB_ARGS"
if [[ "$role" == review ]]; then
  case "$crate" in
  array-vec) echo "Two findings, both minor. blocker=0 major=0 minor=2 or so." ;;
  cli-wc)
    echo "For example:"
    echo "findings: blocker=0 major=0 minor=0"
    echo "findings: blocker=2 major=1 minor=0"
    ;;
  *) printf 'src/lib.rs:3 major DOC-10\n\nfindings: blocker=1 major=2 minor=0\n' ;;
  esac
elif [[ "$role" == followup ]]; then
  # The three tasks with a follow-up. What the session can see of the crate's tests is
  # kept, to show the first oracle is gone by now. A varint crate without the task's
  # functions (the bare run below) gets no change.
  find . -path ./target -prune -o -name '*.rs' -print >"$STUB_ARGS.$crate.files"
  case "$crate" in
  varint)
    if grep -q 'pub fn encode' src/lib.rs; then
      cp "$FIXTURES/varint_signed.rs" src/lib.rs
    fi
    ;;
  kv-parse) cp "$FIXTURES/kv_parse_quoted.rs" src/lib.rs ;;
  cli-wc) cp "$FIXTURES/wcount_flags.rs" src/main.rs ;;
  esac
  echo '{"num_turns": 2, "total_cost_usd": 0.25, "modelUsage": {"stub-model": {}}}'
elif [[ -n "${STUB_SOLUTION:-}" ]]; then
  solution
  echo '{"num_turns": 3, "total_cost_usd": 0.5, "modelUsage": {"stub-model": {}}}'
else
  case "$crate" in
  rate-limiter) ;;
  lru-cache) touch Cargo.lock ;;
  # Three tasks whose session writes a solution. Every other session here writes a crate
  # without its task's entry points, so its oracle does not compile, as the varint session
  # does in the bare arm.
  varint)
    if [[ "$*" == *--safe-mode* ]]; then
      good_lib
    else
      cp "$FIXTURES/varint.rs" src/lib.rs
    fi
    ;;
  kv-parse) cp "$FIXTURES/kv_parse.rs" src/lib.rs ;;
  cli-wc)
    good_lib
    a_test
    cp "$FIXTURES/wcount_counts_chars.rs" src/main.rs
    printf '\n[[bin]]\nname = "wcount"\npath = "src/main.rs"\n' >>Cargo.toml
    ;;
  wal)
    good_lib
    a_test
    git add -A
    git -c user.name=t -c user.email=t@t commit -qm work
    ;;
  interner)
    good_lib
    # An undocumented function (a warn lint, reported for the library and for its test
    # harness) and a dbg! (a deny lint, which makes cargo clippy exit non-zero).
    printf '\n#[must_use]\npub fn three() -> u32 {\n    dbg!(3)\n}\n' >>src/lib.rs
    a_test
    ;;
  *)
    good_lib
    a_test
    ;;
  esac
  echo '{"num_turns": 3, "total_cost_usd": 0.5, "modelUsage": {"stub-model": {}}}'
fi
EOF
chmod +x "$WORK/claude"
# The stub Grok: a task session only. It writes the kv-parse solution.
cat >"$WORK/grok" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == *--version* ]]; then
  echo "grok-stub 9.9"
  exit 0
fi
printf '%s\tgrok\t%s\n' "$(basename "$PWD")" "$*" >>"$STUB_ARGS"
cp "$FIXTURES/kv_parse.rs" src/lib.rs
echo '{"num_turns": 4, "total_cost_usd": 0.75, "modelUsage": {"grok-stub-model": {}}}'
EOF
chmod +x "$WORK/grok"
# A space in the path: the file list given to house-check.pl must survive it.
export CLAUDE_BIN="$WORK/claude" EVALS_OUT="$WORK/out dir"
# For the stub: the reference solutions, and a file that collects the arguments of each call.
FIXTURES="$(cd "$(dirname "${BASH_SOURCE[0]}")/fixtures" && pwd)"
export FIXTURES STUB_ARGS="$WORK/stub-args"

bash "$RUN" ring-buffer rate-limiter lru-cache wal varint kv-parse interner array-vec cli-wc \
  >/dev/null 2>"$WORK/run.err" || {
  echo "FAIL: the run exited non-zero"
  cat "$WORK/run.err"
  exit 1
}
results="$(find "$EVALS_OUT" -name results.tsv)"

# The row of task $1, fields joined by a space.
row() {
  awk -F '\t' -v task="$1" '$1 == task { $1 = $1; print }' "$results"
}

check "header names the arm, both commits and the claude version" 1 "$(head -n 1 "$results" |
  grep -c '^# arm setup, deployed .*, checkers .*, model default, effort high, stub 0.0.0$')"
check "every row has fifteen fields" "" \
  "$(awk -F '\t' 'NR > 1 && NF != 15 { print NR ": " $0 }' "$results")"
check "scored: tests, oracle, no diagnostics, one house finding, review, turns, cost" \
  "ring-buffer pass build 0 1 1 2 0 stub-model 3 0.5 - - - -" "$(row ring-buffer)"
check "a session that wrote nothing: dashes, not a clean score" \
  "rate-limiter no-change - - - - - - - - - - - - -" "$(row rate-limiter)"
check "a session that left only Cargo.lock: dashes" \
  "lru-cache no-change - - - - - - - - - - - - -" "$(row lru-cache)"
check "a session that committed its work is scored, and has no follow-up to run" \
  "wal pass build 0 1 1 2 0 stub-model 3 0.5 - - - -" "$(row wal)"
# The oracle column, and with it each oracle against a reference solution.
check "a correct solution without tests of its own: none, and the whole oracle passes" \
  "varint none 7/7" "$(row varint | cut -d ' ' -f 1-3)"
check "the kv-parse oracle passes against a correct solution" \
  "kv-parse none 8/8" "$(row kv-parse | cut -d ' ' -f 1-3)"
check "a defect fails its oracle test only, and the oracle is no part of the crate's score" \
  "cli-wc pass 7/8" "$(row cli-wc | cut -d ' ' -f 1-3)"
# By name: with only the count, a wrong expectation in the byte-count test would fail that
# same test against this fixture and go unnoticed.
check "the oracle test that fails against the fixture is the one for its defect" \
  "test bytes_are_counted_not_characters ... FAILED" \
  "$(grep -E '^test .* FAILED$' "$(dirname "$results")/cli-wc.eval_oracle.log")"
check "the oracle adds no diagnostics or house findings to the crate's counts" \
  "0 0" "$(row varint | cut -d ' ' -f 4,5)"
check "a deny lint and a warn lint: two diagnostics, each counted once, in one cell" \
  "interner pass build 2" "$(row interner | cut -d ' ' -f 1-4)"
check "a review without the findings line: unknown, not zero" "? ? ?" \
  "$(row array-vec | cut -d ' ' -f 6-8)"
check "the last findings line wins over an example before it" "2 1 0" \
  "$(row cli-wc | cut -d ' ' -f 6-8)"
check "the setup arm adds only the effort to the task session" \
  "-p --output-format json --effort high" \
  "$(awk -F '\t' '$1 == "varint" && $2 == "task" { print $3 }' "$STUB_ARGS")"

# The follow-up: a second session changes the scored crate, and its own oracle scores that.
# Each follow-up oracle runs against a reference solution here, as each first oracle does.
check "follow-up: its oracle, the Rust lines added and removed, the session's turns and cost" \
  "7/7 +26/-2 2 0.25" "$(row varint | cut -d ' ' -f 12-15)"
check "the kv-parse follow-up oracle passes against a correct solution" \
  "9/9" "$(row kv-parse | cut -d ' ' -f 12)"
check "the cli-wc follow-up oracle passes against a correct solution" \
  "7/7" "$(row cli-wc | cut -d ' ' -f 12)"
check "the follow-up leaves the first session's scores as they were" \
  "cli-wc pass 7/8" "$(row cli-wc | cut -d ' ' -f 1-3)"
check "the follow-up session is the bare one, in the setup arm too" \
  "-p --output-format json --safe-mode --permission-mode auto --effort high" \
  "$(awk -F '\t' '$1 == "varint" && $2 == "followup" { print $3 }' "$STUB_ARGS")"
check "the follow-up session finds no oracle in the crate" "" \
  "$(grep -h eval_ "$STUB_ARGS".*.files || true)"
check "the follow-up session sees the crate as the first session left it" \
  "./src/lib.rs ./src/main.rs" "$(sort "$STUB_ARGS.cli-wc.files" | tr '\n' ' ' | sed 's/ $//')"

# The bare arm: the task session alone runs in safe mode, and the reviewer still runs with
# the setup. Its varint session writes a crate without the task's entry points.
: >"$STUB_ARGS"
EVALS_ARM=bare EVALS_EFFORT=xhigh bash "$RUN" varint >/dev/null 2>"$WORK/run.err"
bare="$(find "$EVALS_OUT" -name results.tsv -newer "$results")"
check "bare arm: named in the header" 1 "$(head -n 1 "$bare" | grep -c '^# arm bare, ')"
check "bare arm: the task session runs in safe mode with a permission mode" 1 \
  "$(awk -F '\t' '$2 == "task"' "$STUB_ARGS" | grep -c -e '--safe-mode --permission-mode auto')"
check "bare arm: the reviewer does not" 0 \
  "$(awk -F '\t' '$2 == "review"' "$STUB_ARGS" | grep -c -e '--safe-mode' || true)"
check "a follow-up session that changed no Rust: no-change, not a score" \
  "no-change - - -" "$(awk -F '\t' '$1 == "varint" { print $12, $13, $14, $15 }' "$bare")"
# Left to the settings file, the two arms ran at different efforts (run.sh says how).
check "the task session and the reviewer are given the same effort" "" \
  "$(grep -v -e '--effort xhigh' "$STUB_ARGS" || true)"
check "the effort is named in the header" 1 "$(head -n 1 "$bare" | grep -c ', effort xhigh, ')"
check "an oracle that does not compile against the crate: build, not a count" "build" \
  "$(awk -F '\t' '$1 == "varint" { print $3 }' "$bare")"
code=0
EVALS_ARM=nonsense bash "$RUN" varint >/dev/null 2>&1 || code=$?
check "unknown arm: exit 2" 2 "$code"

# The grok arm: Grok writes the code, with its prompt as a file; Claude still reviews.
: >"$STUB_ARGS"
EVALS_ARM=grok EVALS_GROK_MODEL=g1 GROK_BIN="$WORK/grok" bash "$RUN" kv-parse \
  >/dev/null 2>"$WORK/run.err"
grok="$(find "$EVALS_OUT" -name results.tsv -newer "$bare")"
check "grok arm: the header names the arm, Grok's model and its version" 1 \
  "$(head -n 1 "$grok" | grep -c '^# arm grok, .*, stub 0.0.0, grok model g1, grok-stub 9.9$')"
grok_prompt="$(dirname "$grok")/kv-parse.prompt.md"
grok_flags="--output-format json --permission-mode auto --effort high --model g1"
check "grok arm: Grok gets the prompt file, auto mode, the effort and its model" \
  "--prompt-file $grok_prompt $grok_flags" \
  "$(awk -F '\t' '$2 == "grok" { print $3 }' "$STUB_ARGS")"
check "grok arm: the prompt file is the task's prompt" "" \
  "$(diff "$grok_prompt" "$(dirname "$RUN")/tasks/kv-parse/prompt.md")"
check "grok arm: Claude runs no task session, and does review and follow up" \
  "followup review" \
  "$(awk -F '\t' '{ print $2 }' "$STUB_ARGS" | grep -v grok | sort | tr '\n' ' ' | sed 's/ $//')"
check "grok arm: the row is Grok's work, model, turns and cost" \
  "kv-parse none 8/8 stub-model 4 0.75" \
  "$(awk -F '\t' '$1 == "kv-parse" { print $1, $2, $3, $9, $10, $11 }' "$grok" |
    sed 's/grok-stub-model/stub-model/')"
code=0
EVALS_ARM=grok GROK_BIN="$WORK/no-grok" bash "$RUN" varint >/dev/null 2>&1 || code=$?
check "grok arm without the binary: exit 2" 2 "$code"

code=0
bash "$RUN" no-such-task >/dev/null 2>&1 || code=$?
check "unknown task: exit 2" 2 "$code"
check "unknown task, arm or binary: no output directory beyond the three runs above" 3 \
  "$(find "$EVALS_OUT" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"

# The other seven oracles, each against its reference solution. The actor-counter crate
# depends on Tokio, so this run needs crates.io or a Cargo cache that has it.
STUB_SOLUTION=correct bash "$RUN" actor-counter array-vec interner lru-cache rate-limiter \
  ring-buffer wal >/dev/null 2>"$WORK/run.err"
solved="$(find "$EVALS_OUT" -name results.tsv -newer "$grok")"
while read -r task total; do
  # Zero diagnostics and house findings too: the solutions are committed Rust.
  check "the $task oracle passes against a correct solution" "$task none $total/$total 0 0" \
    "$(awk -F '\t' -v task="$task" '$1 == task { print $1, $2, $3, $4, $5 }' "$solved")"
done <<'EOF'
actor-counter 5
array-vec 9
interner 7
lru-cache 8
rate-limiter 7
ring-buffer 8
wal 8
EOF

# The defect a session is most likely to write, in two of them. By name, as for cli-wc.
STUB_SOLUTION=broken bash "$RUN" interner wal >/dev/null 2>"$WORK/run.err"
broken="$(find "$EVALS_OUT" -name results.tsv -newer "$solved")"
check "an interner that allocates to look a string up fails one oracle test" "6/7" \
  "$(awk -F '\t' '$1 == "interner" { print $3 }' "$broken")"
check "which is the one that counts allocations" \
  "test looking_up_an_interned_string_does_not_allocate ... FAILED" \
  "$(grep -E '^test .* FAILED$' "$(dirname "$broken")/interner.eval_oracle.log")"
check "a log that keeps its torn tail fails one oracle test" "7/8" \
  "$(awk -F '\t' '$1 == "wal" { print $3 }' "$broken")"
check "which is the one that appends after the torn tail" \
  "test a_record_appended_after_a_torn_tail_is_kept ... FAILED" \
  "$(grep -E '^test .* FAILED$' "$(dirname "$broken")/wal.eval_oracle.log")"

printf '%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
