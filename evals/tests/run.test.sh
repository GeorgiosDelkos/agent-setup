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

# The stub is the task session without --agent and the reviewer with it. The crate it
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
if [[ "$*" != *--version* ]]; then
  printf '%s\t%s\n' "$crate" "$*" >>"$STUB_ARGS"
fi
if [[ "$*" == *--version* ]]; then
  echo "stub 0.0.0"
elif [[ "$*" == *--agent* ]]; then
  case "$crate" in
  array-vec) echo "Two findings, both minor. blocker=0 major=0 minor=2 or so." ;;
  cli-wc)
    echo "For example:"
    echo "findings: blocker=0 major=0 minor=0"
    echo "findings: blocker=2 major=1 minor=0"
    ;;
  *) printf 'src/lib.rs:3 major DOC-10\n\nfindings: blocker=1 major=2 minor=0\n' ;;
  esac
else
  case "$crate" in
  rate-limiter) ;;
  lru-cache) touch Cargo.lock ;;
  # The three tasks with an oracle. In the bare arm the varint session misses the entry
  # points its prompt names, so the oracle cannot compile.
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
check "every row has eleven fields" "" \
  "$(awk -F '\t' 'NR > 1 && NF != 11 { print NR ": " $0 }' "$results")"
check "scored: tests, no oracle, no diagnostics, one house finding, review, turns, cost" \
  "ring-buffer pass - 0 1 1 2 0 stub-model 3 0.5" "$(row ring-buffer)"
check "a session that wrote nothing: dashes, not a clean score" \
  "rate-limiter no-change - - - - - - - - -" "$(row rate-limiter)"
check "a session that left only Cargo.lock: dashes" \
  "lru-cache no-change - - - - - - - - -" "$(row lru-cache)"
check "a session that committed its work is scored" \
  "wal pass - 0 1 1 2 0 stub-model 3 0.5" "$(row wal)"
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
  "$(grep -E '^test .* FAILED$' "$(dirname "$results")/cli-wc.oracle.log")"
check "the oracle adds no diagnostics or house findings to the crate's counts" \
  "0 0" "$(row varint | cut -d ' ' -f 4,5)"
check "a deny lint and a warn lint: two diagnostics, each counted once, in one cell" \
  "interner pass - 2" "$(row interner | cut -d ' ' -f 1-4)"
check "a review without the findings line: unknown, not zero" "? ? ?" \
  "$(row array-vec | cut -d ' ' -f 6-8)"
check "the last findings line wins over an example before it" "2 1 0" \
  "$(row cli-wc | cut -d ' ' -f 6-8)"
check "the setup arm adds only the effort to the task session" \
  "--output-format json --effort high" \
  "$(awk -F '\t' '$1 == "varint" && $2 !~ /--agent/ { print $2 }' "$STUB_ARGS" |
    sed 's/^-p //')"

# The bare arm: the task session alone runs in safe mode, and the reviewer still runs with
# the setup. Its varint session writes a crate without the task's entry points.
: >"$STUB_ARGS"
EVALS_ARM=bare EVALS_EFFORT=xhigh bash "$RUN" varint >/dev/null 2>"$WORK/run.err"
bare="$(find "$EVALS_OUT" -name results.tsv -newer "$results")"
check "bare arm: named in the header" 1 "$(head -n 1 "$bare" | grep -c '^# arm bare, ')"
check "bare arm: the task session runs in safe mode with a permission mode" 1 \
  "$(grep -v -e '--agent' "$STUB_ARGS" | grep -c -e '--safe-mode --permission-mode auto')"
check "bare arm: the reviewer does not" 0 \
  "$(grep -e '--agent' "$STUB_ARGS" | grep -c -e '--safe-mode' || true)"
# Left to the settings file, the two arms ran at different efforts (run.sh says how).
check "the task session and the reviewer are given the same effort" "" \
  "$(grep -v -e '--effort xhigh' "$STUB_ARGS" || true)"
check "the effort is named in the header" 1 "$(head -n 1 "$bare" | grep -c ', effort xhigh, ')"
check "an oracle that does not compile against the crate: build, not a count" "build" \
  "$(awk -F '\t' '$1 == "varint" { print $3 }' "$bare")"
code=0
EVALS_ARM=nonsense bash "$RUN" varint >/dev/null 2>&1 || code=$?
check "unknown arm: exit 2" 2 "$code"

code=0
bash "$RUN" no-such-task >/dev/null 2>&1 || code=$?
check "unknown task: exit 2" 2 "$code"
check "unknown task or arm: no output directory beyond the two runs above" 2 \
  "$(find "$EVALS_OUT" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"

printf '%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
