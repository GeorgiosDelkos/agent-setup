#!/usr/bin/env bash
# Tests for evals/run.sh with a stub claude (CLAUDE_BIN) and real cargo: a scored row, a
# session that changed nothing, a review without the findings line, and an unknown task.
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

# The stub is the task session without --agent and the reviewer with it. STUB_AGENT=idle
# makes the session change nothing; STUB_REVIEW=prose makes the review end without counts.
# The crate it writes has one house-check finding (a TODO without an owner) and at least one
# clippy finding under the house lints (an undocumented public function).
cat >"$WORK/claude" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == *--version* ]]; then
  echo "stub 0.0.0"
elif [[ "$*" == *--agent* ]]; then
  if [[ "${STUB_REVIEW:-}" == prose ]]; then
    echo "Two findings, both minor."
  else
    printf 'src/lib.rs:3 major DOC-10\n\nfindings: blocker=1 major=2 minor=0\n'
  fi
elif [[ "${STUB_AGENT:-}" != idle ]]; then
  printf '//! Stub crate.\n\n// TODO: finish this\npub fn two() -> u32 {\n    2\n}\n' >src/lib.rs
  echo '{"num_turns": 3, "total_cost_usd": 0.5}'
fi
EOF
chmod +x "$WORK/claude"
export CLAUDE_BIN="$WORK/claude" EVALS_OUT="$WORK/out"

# The data row of the newest results file, as fields joined by a space.
row() {
  local file
  file="$(find "$EVALS_OUT" -name results.tsv | sort | tail -n 1)"
  tail -n 1 "$file" | tr '\t' ' '
}

bash "$RUN" varint >/dev/null 2>&1
read -r task tests clippy house blocker major minor turns cost <<<"$(row)"
check "scored: task and tests" "varint pass" "$task $tests"
check "scored: clippy found the undocumented function" yes \
  "$([[ "$clippy" =~ ^[0-9]+$ && "$clippy" -gt 0 ]] && echo yes || echo "no ($clippy)")"
check "scored: one house-check finding" 1 "$house"
check "scored: review counts" "1 2 0" "$blocker $major $minor"
check "scored: turns and cost from the session" "3 0.5" "$turns $cost"
check "header names the claude version" 1 \
  "$(head -n 1 "$(find "$EVALS_OUT" -name results.tsv | sort | tail -n 1)" | grep -c 'stub 0.0.0')"

# Runs are named by the second, so the next one needs a new name.
sleep 1
STUB_AGENT=idle bash "$RUN" varint >/dev/null 2>&1
check "no change: a row of dashes, not a clean score" "varint no-change - - - - - - -" "$(row)"

sleep 1
STUB_REVIEW=prose bash "$RUN" varint >/dev/null 2>&1
read -r _ _ _ _ blocker major minor _ <<<"$(row)"
check "review without the findings line: unknown, not zero" "? ? ?" "$blocker $major $minor"

sleep 1
code=0
bash "$RUN" no-such-task >/dev/null 2>&1 || code=$?
check "unknown task: exit 2" 2 "$code"

printf '%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
