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
  kv-parse) ;;
  lru-cache) touch Cargo.lock ;;
  wal)
    good_lib
    a_test
    git add -A
    git -c user.name=t -c user.email=t@t commit -qm work
    ;;
  varint) good_lib ;;
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
  echo '{"num_turns": 3, "total_cost_usd": 0.5}'
fi
EOF
chmod +x "$WORK/claude"
# A space in the path: the file list given to house-check.pl must survive it.
export CLAUDE_BIN="$WORK/claude" EVALS_OUT="$WORK/out dir"

bash "$RUN" ring-buffer kv-parse lru-cache wal varint interner array-vec cli-wc \
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

check "header names both commits and the claude version" 1 \
  "$(head -n 1 "$results" | grep -c '^# deployed .*, checkers .*, model default, stub 0.0.0$')"
check "every row has nine fields" "" \
  "$(awk -F '\t' 'NR > 1 && NF != 9 { print NR ": " $0 }' "$results")"
check "scored: tests, no diagnostics, one house finding, review counts, turns, cost" \
  "ring-buffer pass 0 1 1 2 0 3 0.5" "$(row ring-buffer)"
check "a session that wrote nothing: dashes, not a clean score" \
  "kv-parse no-change - - - - - - -" "$(row kv-parse)"
check "a session that left only Cargo.lock: dashes" \
  "lru-cache no-change - - - - - - -" "$(row lru-cache)"
check "a session that committed its work is scored" \
  "wal pass 0 1 1 2 0 3 0.5" "$(row wal)"
check "a crate without tests: none, not pass" "varint none" \
  "$(row varint | cut -d ' ' -f 1,2)"
check "a deny lint and a warn lint: two diagnostics, each counted once, in one cell" \
  "interner pass 2" "$(row interner | cut -d ' ' -f 1-3)"
check "a review without the findings line: unknown, not zero" "? ? ?" \
  "$(row array-vec | cut -d ' ' -f 5-7)"
check "the last findings line wins over an example before it" "2 1 0" \
  "$(row cli-wc | cut -d ' ' -f 5-7)"

code=0
bash "$RUN" no-such-task >/dev/null 2>&1 || code=$?
check "unknown task: exit 2" 2 "$code"
check "unknown task: no second output directory" 1 \
  "$(find "$EVALS_OUT" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"

printf '%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
