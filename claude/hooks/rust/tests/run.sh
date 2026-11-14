#!/usr/bin/env bash
# Tests for the Rust hooks in the directory above this one:
#   1. house-check.pl over tests/fixtures: every .rs / Cargo.toml there has a sibling
#      .expected file holding the exact output (empty for a clean file).
#   2. baseline-lints.pl over the real lint template.
#   3. Every hook fed with Claude and Grok JSON inputs, against throwaway crates and git
#      repos, with TMPDIR pointed at a scratch state dir. check-on-stop.sh runs real cargo
#      clippy on those crates (about a minute in total).
set -euo pipefail

HOOKS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES="$HOOKS/tests/fixtures"
# The checkout's own skill tree, not the installed one under $HOME: a change to a template
# is tested in the same commit that makes it.
TEMPLATES="$(cd "$HOOKS/../../skills/rust-style/templates" && pwd)"
TEMPLATE="$TEMPLATES/Cargo.lints.toml"
WORK="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/rust-hooks-test.XXXXXX")" && pwd -P)"
trap 'trash "$WORK"' EXIT
pass=0
fail=0

check() {
  local name="$1" ok="$2" detail="${3:-}"
  if [[ "$ok" == "yes" ]]; then
    pass=$((pass + 1))
    return
  fi
  fail=$((fail + 1))
  printf 'FAIL: %s\n' "$name"
  if [[ -n "$detail" ]]; then
    printf '%s\n' "$detail" | sed 's/^/    /'
  fi
}

# ---- 1. house-check fixtures -------------------------------------------------------------

while IFS= read -r file; do
  rel="${file#"$FIXTURES"/}"
  if [[ ! -f "$file.expected" ]]; then
    check "house-check $rel: missing $rel.expected" no
    continue
  fi
  expected="$(cat "$file.expected")"
  code=0
  actual="$(cd "$FIXTURES" && perl "$HOOKS/house-check.pl" "$rel")" || code=$?
  want_code=0
  if [[ -n "$expected" ]]; then
    want_code=1
  fi
  ok=no
  if [[ "$actual" == "$expected" && "$code" -eq "$want_code" ]]; then
    ok=yes
  fi
  check "house-check $rel (exit $code, want $want_code)" "$ok" \
    "$(diff <(printf '%s\n' "$expected") <(printf '%s\n' "$actual") || true)"
done < <(find "$FIXTURES" \( -name '*.rs' -o -name Cargo.toml \) | sort)

mkdir -p "$WORK/target"
cp "$FIXTURES/bin-crate/src/lay_super_bad.rs" "$WORK/target/"
code=0
perl "$HOOKS/house-check.pl" "$WORK/target/lay_super_bad.rs" >/dev/null || code=$?
check "house-check skips target/" "$([[ $code -eq 0 ]] && echo yes)"
code=0
perl "$HOOKS/house-check.pl" 2>/dev/null || code=$?
check "house-check without arguments exits 2" "$([[ $code -eq 2 ]] && echo yes)"

# ---- 2. baseline-lints ---------------------------------------------------------------------

flags="$(perl "$HOOKS/baseline-lints.pl" "$TEMPLATE" | paste -sd ' ' -)"
check "baseline: rustc group first" "$([[ "$flags" == "-W rust_2018_idioms "* ]] && echo yes)" \
  "$flags"
check "baseline: pedantic before its allow" \
  "$([[ "$flags" == *"-W clippy::pedantic "*"-A clippy::module_name_repetitions"* ]] && echo yes)"
check "baseline: deny level kept" \
  "$([[ "$flags" == *"-D clippy::undocumented_unsafe_blocks"* ]] && echo yes)"
check "baseline: rustc lint without prefix" \
  "$([[ "$flags" == *"-D unsafe_op_in_unsafe_fn"* ]] && echo yes)"
check "baseline: skips rustdoc and check-cfg" \
  "$([[ "$flags" != *intra_doc* && "$flags" != *unexpected_cfgs* ]] && echo yes)"

# ---- 3. hooks --------------------------------------------------------------------------------

STATE_TMP="$WORK/state"
mkdir -p "$STATE_TMP"
# A fake HOME with stub skill files: the gate only requires topic files that exist.
# cargo and rustup keep their real homes; the hooks read only the fake skill tree.
CARGO_HOME="${CARGO_HOME:-$HOME/.cargo}"
RUSTUP_HOME="${RUSTUP_HOME:-$HOME/.rustup}"
FAKE_HOME="$WORK/home"
SKILL="$FAKE_HOME/.claude/skills/rust-style"
mkdir -p "$SKILL/topics"
for topic in unsafe concurrency async library-api testing repo low-level; do
  touch "$SKILL/topics/$topic.md"
  # The gate skips a topic file that is not installed, so a renamed one would go unread.
  check "topic $topic.md exists in the checkout" \
    "$([[ -f "$TEMPLATES/../topics/$topic.md" ]] && echo yes)"
done
ln -s "$TEMPLATES" "$SKILL/templates"

# Runs hook $1 with JSON $2 (and PATH $3 when given). Sets $code, $out (stderr) and
# $stdout. A JSON deny on stdout (style-gate.sh) counts as a block: code 2, and $out carries
# the deny reason followed by stderr.
run_hook() {
  local path="${3:-$PATH}" stderr_file="$WORK/stderr"
  code=0
  stdout="$(PATH="$path" HOME="$FAKE_HOME" CARGO_HOME="$CARGO_HOME" RUSTUP_HOME="$RUSTUP_HOME" \
    TMPDIR="$STATE_TMP" "$HOOKS/$1" <<<"$2" 2>"$stderr_file")" || code=$?
  out="$(cat "$stderr_file")"
  if [[ "$stdout" == *'"permissionDecision"'* ]] &&
    [[ "$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$stdout")" == deny ]]; then
    code=2
    out="$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$stdout")"$'\n'"$out"
  fi
}

# expect NAME CODE HOOK JSON [NEEDLE]: exit code is CODE and stderr contains NEEDLE.
expect() {
  local name="$1" want="$2" needle="${5:-}"
  run_hook "$3" "$4"
  local ok=no
  if [[ "$code" -eq "$want" && "$out" == *"$needle"* ]]; then
    ok=yes
  fi
  check "$name" "$ok" "exit $code, want $want; stderr: $out"
}

# Claude Edit: session path new_string [agent_id].
edit() {
  jq -nc --arg s "$1" --arg p "$2" --arg t "$3" --arg a "${4:-}" \
    '{session_id: $s, tool_name: "Edit", tool_input: {file_path: $p, new_string: $t}}
     + (if $a == "" then {} else {agent_id: $a} end)'
}
skill() {
  jq -nc --arg s "$1" '{session_id: $s, tool_name: "Skill", tool_input: {skill: "rust-style"}}'
}
load_skill() {
  jq -nc --arg s "$1" --arg n "$2" \
    '{session_id: $s, tool_name: "Skill", tool_input: {skill: $n}}'
}
read_file() {
  jq -nc --arg s "$1" --arg p "$2" \
    '{session_id: $s, tool_name: "Read", tool_input: {file_path: $p}}'
}
grok_edit() {
  jq -nc --arg s "$1" --arg p "$2" --arg t "$3" \
    '{session_id: $s, tool_name: "search_replace",
      tool_input: {target_file: $p, old_string: "x", new_string: $t}}'
}
grok_read() {
  jq -nc --arg s "$1" --arg p "$2" \
    '{session_id: $s, tool_name: "read_file", tool_input: {target_file: $p}}'
}
stop() {
  local extra="${2:-}"
  if [[ -z "$extra" ]]; then
    extra="{}"
  fi
  jq -nc --arg s "$1" --argjson extra "$extra" '{session_id: $s, hook_event_name: "Stop"} + $extra'
}
# The session's first prompt in repo $2: records its baseline (session-baseline.sh).
prompt() {
  run_hook session-baseline.sh "$(jq -nc --arg s "$1" --arg c "$2" \
    '{session_id: $s, hook_event_name: "UserPromptSubmit", cwd: $c, prompt: "go"}')"
}

new_crate() {
  mkdir -p "$1/src"
  printf '[package]\nname = "c"\nversion = "0.1.0"\nedition = "2024"\n%s' "${2:-}" \
    >"$1/Cargo.toml"
  printf '//! Crate.\n' >"$1/src/lib.rs"
}
LIB="$WORK/lib"
new_crate "$LIB" $'publish = ["crates-io"]\n'
new_crate "$WORK/internal"
new_crate "$WORK/private" $'publish = false\n'
mkdir -p "$WORK/notrust/.github/workflows" "$LIB/.github/workflows"

# Core gate and topic gates, Claude field names.
expect "core: first .rs edit blocked" 2 style-gate.sh "$(edit g1 "$LIB/src/x.rs" 'fn a() {}')" \
  "$SKILL/SKILL.md"
expect "core: non-Rust file passes" 0 style-gate.sh "$(edit g1 "$WORK/README.md" 'unsafe')"
run_hook style-loaded.sh "$(skill g1)"
expect "core: passes after Skill load" 0 style-gate.sh "$(edit g1 "$LIB/src/x.rs" 'fn a() {}')"
expect "unsafe: blocked" 2 style-gate.sh "$(edit g1 "$LIB/src/x.rs" 'unsafe { f() }')" \
  "$SKILL/topics/unsafe.md"
expect "unsafe: raw pointer blocked" 2 style-gate.sh "$(edit g1 "$LIB/src/x.rs" 'p: *mut u8')" \
  "topics/unsafe.md"
expect "unsafe: comment only passes" 0 style-gate.sh \
  "$(edit g1 "$LIB/src/x.rs" $'// unsafe is not used here\nfn a() {}')"
run_hook style-loaded.sh "$(read_file g1 "$SKILL/topics/unsafe.md")"
expect "unsafe: passes after topic read" 0 style-gate.sh \
  "$(edit g1 "$LIB/src/x.rs" 'unsafe { f() }')"
expect "concurrency: atomic blocked" 2 style-gate.sh \
  "$(edit g1 "$LIB/src/x.rs" 'static N: AtomicUsize = AtomicUsize::new(0);')" \
  "topics/concurrency.md"
# One input per channel pattern, so dropping any one of them fails a test.
for channel in 'use std::sync::{mpsc, Arc};' 'let (tx, rx) = sync_channel(64);' \
  'crossbeam_channel::bounded(8)' 'crossbeam::channel::bounded(8)' 'flume::bounded(8)' \
  'async_channel::bounded(8)' 'kanal::bounded(8)'; do
  expect "concurrency: channel blocked: $channel" 2 style-gate.sh \
    "$(edit g1 "$LIB/src/x.rs" "$channel")" "topics/concurrency.md"
done
expect "concurrency: cmp::Ordering passes" 0 style-gate.sh \
  "$(edit g1 "$LIB/src/x.rs" 'x.cmp(&y) == Ordering::Less')"
expect "testing: tests/ path blocked" 2 style-gate.sh "$(edit g1 "$LIB/tests/t.rs" 'fn a() {}')" \
  "topics/testing.md"
expect "testing: #[test] blocked" 2 style-gate.sh \
  "$(edit g1 "$LIB/src/x.rs" $'#[test]\nfn a() {}')" \
  "topics/testing.md"
expect "library-api: pub fn in lib blocked" 2 style-gate.sh \
  "$(edit g1 "$LIB/src/x.rs" 'pub fn a() {}')" "topics/library-api.md"
expect "library-api: pub(crate) passes" 0 style-gate.sh \
  "$(edit g1 "$LIB/src/x.rs" 'pub(crate) fn a() {}')"
expect "library-api: src/main.rs passes" 0 style-gate.sh \
  "$(edit g1 "$LIB/src/main.rs" 'pub fn a() {}')"
expect "library-api: publish = false passes" 0 style-gate.sh \
  "$(edit g1 "$WORK/private/src/lib.rs" 'pub struct A;')"
expect "library-api: no publish key (internal crate) passes" 0 style-gate.sh \
  "$(edit g1 "$WORK/internal/src/lib.rs" 'pub struct A;')"
PUBWS="$WORK/pubws"
mkdir -p "$PUBWS/m/src"
printf '[workspace]\nmembers = ["m"]\n\n[workspace.package]\npublish = ["crates-io"]\n' \
  >"$PUBWS/Cargo.toml"
printf '[package]\nname = "m"\nversion = "0.1.0"\npublish.workspace = true\n' >"$PUBWS/m/Cargo.toml"
printf '//! Crate.\n' >"$PUBWS/m/src/lib.rs"
expect "library-api: publish inherited from the workspace blocked" 2 style-gate.sh \
  "$(edit g1 "$PUBWS/m/src/lib.rs" 'pub struct A;')" "topics/library-api.md"
expect "async: MultiEdit edits[] scanned" 2 style-gate.sh \
  "$(jq -nc --arg p "$LIB/src/x.rs" '{session_id: "g1", tool_name: "MultiEdit",
      tool_input: {file_path: $p, edits: [{new_string: "fn a() {}"}, {new_string: "x.await"}]}}')" \
  "topics/async.md"
expect "async: Write content scanned" 2 style-gate.sh \
  "$(jq -nc --arg p "$LIB/src/y.rs" '{session_id: "g1", tool_name: "Write",
      tool_input: {file_path: $p, content: "async fn a() {}"}}')" "topics/async.md"
expect "subagent: does not inherit parent's load" 2 style-gate.sh \
  "$(edit g1 "$LIB/src/x.rs" 'fn a() {}' sub1)" "SKILL.md"

trash "$SKILL/topics/concurrency.md"
expect "topic not installed: not required" 0 style-gate.sh \
  "$(edit g1 "$LIB/src/x.rs" 'static N: AtomicUsize = AtomicUsize::new(0);')"
touch "$SKILL/topics/concurrency.md"

# Grok field names: search_replace/read_file with target_file, Cursor preset path/contents.
expect "grok: core blocked" 2 style-gate.sh "$(grok_edit g2 "$LIB/src/x.rs" 'fn a() {}')" "SKILL.md"
run_hook style-loaded.sh "$(grok_read g2 "$SKILL/SKILL.md")"
expect "grok: passes after read_file SKILL.md" 0 style-gate.sh \
  "$(grok_edit g2 "$LIB/src/x.rs" 'fn a() {}')"
expect "grok: async blocked" 2 style-gate.sh "$(grok_edit g2 "$LIB/src/x.rs" 'x.await')" \
  "topics/async.md"
run_hook style-loaded.sh "$(grok_read g2 "$SKILL/topics/async.md")"
expect "grok: async passes after topic read" 0 style-gate.sh \
  "$(grok_edit g2 "$LIB/src/x.rs" 'x.await')"
expect "grok: path/contents scanned" 2 style-gate.sh \
  "$(jq -nc --arg p "$LIB/src/x.rs" '{session_id: "g2", tool_name: "write",
      tool_input: {path: $p, contents: "unsafe impl Send for A {}"}}')" "topics/unsafe.md"

# $1 session, $2 path, $3 tool (read_file or Read), $4 offset, $5 limit.
# An empty offset or limit is omitted. Grok's read_file names the file target_file.
sliced_read() {
  jq -nc --arg s "$1" --arg p "$2" --arg tool "$3" \
    --arg offset "${4:-}" --arg limit "${5:-}" '
    {session_id: $s, tool_name: $tool, tool_input:
      ((if $tool == "read_file" then {target_file: $p} else {file_path: $p} end)
      + (if $offset == "" then {} else {offset: ($offset | tonumber)} end)
      + (if $limit == "" then {} else {limit: ($limit | tonumber)} end))}
  '
}
# Grok returns SKILL.md whole even when offset and limit are set. A topic slice
# leaves the rest unread, so it must not open that topic.
run_hook style-loaded.sh "$(sliced_read g8 "$SKILL/SKILL.md" read_file 1 5)"
expect "grok: sliced SKILL.md still loads the skill" 0 style-gate.sh \
  "$(grok_edit g8 "$LIB/src/x.rs" 'fn a() {}')"
run_hook style-loaded.sh "$(sliced_read g8 "$SKILL/topics/async.md" read_file 1 5)"
expect "grok: sliced topic read does not count" 2 style-gate.sh \
  "$(grok_edit g8 "$LIB/src/x.rs" 'x.await')" "topics/async.md"
run_hook style-loaded.sh "$(sliced_read g8 "$SKILL/topics/async.md" read_file 2)"
expect "grok: topic offset past line 1 does not count" 2 style-gate.sh \
  "$(grok_edit g8 "$LIB/src/x.rs" 'x.await')" "topics/async.md"
run_hook style-loaded.sh "$(sliced_read g8 "$SKILL/topics/async.md" read_file 1)"
expect "grok: topic offset 1 with no limit counts" 0 style-gate.sh \
  "$(grok_edit g8 "$LIB/src/x.rs" 'x.await')"
# Claude's Read honors offset and limit on every file, including SKILL.md.
run_hook style-loaded.sh "$(sliced_read g9 "$SKILL/SKILL.md" Read "" 20)"
expect "claude: sliced SKILL.md does not load the skill" 2 style-gate.sh \
  "$(edit g9 "$LIB/src/x.rs" 'fn a() {}')" "SKILL.md"
run_hook style-loaded.sh "$(read_file g9 "$SKILL/SKILL.md")"
run_hook style-loaded.sh "$(sliced_read g9 "$SKILL/topics/testing.md" Read 1 5)"
expect "claude: sliced topic read does not count" 2 style-gate.sh \
  "$(edit g9 "$LIB/tests/t.rs" 'fn a() {}')" "topics/testing.md"

# Whole-file shell reads count as loading; partial ones do not.
bash_cmd() {
  jq -nc --arg s "$1" --arg c "$2" '{session_id: $s, tool_name: "Bash", tool_input: {command: $c}}'
}
run_hook style-loaded.sh "$(bash_cmd g6 "cat $SKILL/SKILL.md")"
expect "bash: cat of SKILL.md loads the skill" 0 style-gate.sh \
  "$(edit g6 "$LIB/src/x.rs" 'fn a() {}')"
run_hook style-loaded.sh "$(bash_cmd g6 "head -20 $SKILL/topics/unsafe.md")"
run_hook style-loaded.sh "$(bash_cmd g6 "cat $SKILL/topics/unsafe.md | head -5")"
expect "bash: partial reads of a topic do not count" 2 style-gate.sh \
  "$(edit g6 "$LIB/src/x.rs" 'unsafe { f() }')" "topics/unsafe.md"
run_hook style-loaded.sh \
  "$(bash_cmd g6 "cd /tmp && cat $SKILL/topics/unsafe.md $SKILL/topics/async.md")"
expect "bash: one cat of two topics counts both" 0 style-gate.sh \
  "$(edit g6 "$LIB/src/x.rs" $'unsafe { f() }\nx.await')"

# Low-level profile: any .rs edit in a crate with `low-level = true` needs the topic.
LOW="$WORK/low"
new_crate "$LOW" $'\n[package.metadata.house-check]\nlow-level = true\n'
touch "$SKILL/topics/low-level.md"
run_hook style-loaded.sh "$(skill g7)"
expect "low-level: plain edit in a flagged crate blocked" 2 style-gate.sh \
  "$(edit g7 "$LOW/src/lib.rs" 'fn a() {}')" "topics/low-level.md"
expect "low-level: crate without the switch passes" 0 style-gate.sh \
  "$(edit g7 "$LIB/src/x.rs" 'fn a() {}')"
run_hook style-loaded.sh "$(read_file g7 "$SKILL/topics/low-level.md")"
expect "low-level: passes after topic read" 0 style-gate.sh \
  "$(edit g7 "$LOW/src/lib.rs" 'fn a() {}')"

# Repo topic: manifest, lint, toolchain, and workflow files in a Rust repo.
expect "repo: Cargo.toml needs core and repo" 2 style-gate.sh \
  "$(edit g3 "$LIB/Cargo.toml" '[lints]')" "SKILL.md"
check "repo: message names repo.md too" "$([[ "$out" == *topics/repo.md* ]] && echo yes)" "$out"
run_hook style-loaded.sh "$(skill g3)"
expect "repo: deny.toml blocked" 2 style-gate.sh "$(edit g3 "$LIB/deny.toml" 'x')" "topics/repo.md"
expect "repo: workflow in Rust repo blocked" 2 style-gate.sh \
  "$(edit g3 "$LIB/.github/workflows/ci.yml" 'on: push')" "topics/repo.md"
expect "repo: workflow outside Rust passes" 0 style-gate.sh \
  "$(edit g3 "$WORK/notrust/.github/workflows/ci.yml" 'on: push')"
run_hook style-loaded.sh "$(read_file g3 "$SKILL/topics/repo.md")"
expect "repo: passes after topic read" 0 style-gate.sh "$(edit g3 "$LIB/Cargo.toml" '[lints]')"

# Language skills. A missing install is not required: the block has no escape.
expect "lang: python passes when its skill is absent" 0 style-gate.sh \
  "$(edit g10 "$WORK/app.py" 'x = 1')"
LANG_SKILLS="$FAKE_HOME/.claude/skills"
for name in python-style ts-style bash-style gh-actions-style; do
  mkdir -p "$LANG_SKILLS/$name"
  printf '# %s\n' "$name" >"$LANG_SKILLS/$name/SKILL.md"
done
expect "lang: python blocked until loaded" 2 style-gate.sh \
  "$(edit g10 "$WORK/app.py" 'x = 1')" "python-style/SKILL.md"
run_hook style-loaded.sh "$(load_skill g10 python-style)"
expect "lang: python passes after Skill load" 0 style-gate.sh \
  "$(edit g10 "$WORK/app.py" 'x = 1')"
expect "lang: typescript blocked" 2 style-gate.sh \
  "$(edit g11 "$WORK/app.ts" 'const x = 1')" "ts-style/SKILL.md"
run_hook style-loaded.sh "$(grok_read g11 "$LANG_SKILLS/ts-style/SKILL.md")"
expect "lang: typescript passes after read_file" 0 style-gate.sh \
  "$(grok_edit g11 "$WORK/app.ts" 'const x = 1')"
expect "lang: shell blocked" 2 style-gate.sh \
  "$(edit g12 "$WORK/run.sh" 'echo hi')" "bash-style/SKILL.md"
run_hook style-loaded.sh "$(bash_cmd g12 "cat $LANG_SKILLS/bash-style/SKILL.md")"
expect "lang: shell passes after cat" 0 style-gate.sh \
  "$(edit g12 "$WORK/run.sh" 'echo hi')"
run_hook style-loaded.sh "$(bash_cmd g20 "head -5 $LANG_SKILLS/bash-style/SKILL.md")"
expect "lang: a partial read does not load the skill" 2 style-gate.sh \
  "$(edit g20 "$WORK/partial.sh" 'echo hi')" "bash-style/SKILL.md"
expect "lang: workflow outside a Rust repo blocked" 2 style-gate.sh \
  "$(edit g13 "$WORK/notrust/.github/workflows/ci.yml" 'on: push')" \
  "gh-actions-style"
expect "lang: dependabot blocked" 2 style-gate.sh \
  "$(edit g13 "$WORK/notrust/.github/dependabot.yml" 'version: 2')" \
  "gh-actions-style"
run_hook style-loaded.sh \
  "$(sliced_read g14 "$LANG_SKILLS/python-style/SKILL.md" read_file 1 5)"
expect "lang: grok sliced SKILL.md still loads" 0 style-gate.sh \
  "$(grok_edit g14 "$WORK/other.py" 'y = 1')"
run_hook style-loaded.sh \
  "$(sliced_read g15 "$LANG_SKILLS/ts-style/SKILL.md" Read "" 5)"
expect "lang: claude sliced SKILL.md does not load" 2 style-gate.sh \
  "$(edit g15 "$WORK/app.tsx" 'const x = 1')" "ts-style/SKILL.md"
mkdir -p "$WORK/proj/node_modules/pkg"
expect "lang: node_modules is not gated" 0 style-gate.sh \
  "$(edit g16 "$WORK/proj/node_modules/pkg/x.py" 'x = 1')"
expect "lang: a Rust workflow lists every skill" 2 style-gate.sh \
  "$(edit g17 "$LIB/.github/workflows/ci.yml" 'on: push')" "gh-actions-style"
check "lang: a Rust workflow also names repo.md" \
  "$([[ "$out" == *topics/repo.md* ]] && echo yes)" "$out"
check "lang: a Rust workflow also names rust-style" \
  "$([[ "$out" == *rust-style/SKILL.md* ]] && echo yes)" "$out"
run_hook style-loaded.sh "$(load_skill g18 python-style)"
expect "lang: a subagent does not inherit the load" 2 style-gate.sh \
  "$(edit g18 "$WORK/app.py" 'x = 1' subpy)" "python-style/SKILL.md"
printf 'x = 1\n' >"$WORK/app.py"
run_hook fmt-on-edit.sh "$(edit g19 "$WORK/app.py" 'x = 2')"
edited_list="$STATE_TMP/claude-rust-hooks/g19.main.edited"
check "fmt: records an existing python file" \
  "$(grep -q 'app\.py$' "$edited_list" && echo yes)" \
  "$(cat "$edited_list" 2>/dev/null || true)"
printf 'x = 1\n' >"$WORK/proj/node_modules/pkg/x.py"
before="$(cat "$edited_list")"
run_hook fmt-on-edit.sh "$(edit g19 "$WORK/proj/node_modules/pkg/x.py" 'x = 2')"
check "fmt: does not record node_modules" \
  "$([[ "$(cat "$edited_list")" == "$before" ]] && echo yes)" \
  "$(cat "$edited_list")"

# A relative Grok target_file resolves against the hook input's cwd.
grok_rel() {
  jq -nc --arg c "$1" --arg p "$2" --arg t "$3" '{session_id: "g4", cwd: $c,
    tool_name: "search_replace", tool_input: {target_file: $p, new_string: $t}}'
}
expect "relative path: library-api gate" 2 style-gate.sh \
  "$(grok_rel "$LIB" src/x.rs 'pub fn a() {}')" "topics/library-api.md"
expect "relative path: repo gate" 2 style-gate.sh "$(grok_rel "$LIB" Cargo.toml x)" "topics/repo.md"

# The deny is JSON on stdout for both tools, its reason names every file to load, and the
# stderr summary is one self-sufficient line.
run_hook style-gate.sh "$(edit g5 "$LIB/src/x.rs" $'unsafe { f() }\nx.await')"
deny_reason="$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$stdout")"
check "deny: JSON permissionDecision deny on stdout, exit 0" \
  "$([[ "$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$stdout")" == deny ]] && echo yes)" \
  "$stdout"
check "deny: reason names every file to load" "$([[ "$deny_reason" == *"$SKILL/SKILL.md"* &&
  "$deny_reason" == *"$SKILL/topics/unsafe.md"* &&
  "$deny_reason" == *"$SKILL/topics/async.md"* ]] && echo yes)" "$deny_reason"
summary="$(cat "$WORK/stderr")"
check "deny: stderr is one line naming every file" "$([[ "$(wc -l <<<"$summary")" -eq 1 &&
"$summary" == *"$SKILL/SKILL.md"* && "$summary" == *"topics/unsafe.md"* &&
"$summary" == *"topics/async.md"* ]] && echo yes)" "$summary"

# Grok's hashline_edit: input shape undocumented, so every new-text string field is scanned
# (the shape below is an assumption).
expect "hashline_edit: new text scanned" 2 style-gate.sh \
  "$(jq -nc --arg p "$LIB/src/x.rs" '{session_id: "g2", tool_name: "hashline_edit",
      tool_input: {target_file: $p,
        edits: [{anchor: "1#ab", content: "unsafe impl Send for A {}"}]}}')" \
  "topics/unsafe.md"

# fmt-on-edit records Cargo.toml (physical path) without formatting it.
run_hook fmt-on-edit.sh "$(edit f1 "$LIB/Cargo.toml" 'x')"
check "fmt-on-edit: records Cargo.toml" \
  "$(grep -qxF "$LIB/Cargo.toml" "$STATE_TMP/claude-rust-hooks/f1.main.edited" && echo yes)"

# fmt-on-edit formats only the edited file (not child modules), honors rustfmt.toml, and
# leaves a file with a syntax error as written.
FMT="$WORK/fmt"
new_crate "$FMT"
printf 'max_width = 40\n' >"$FMT/rustfmt.toml"
printf 'mod m;\nfn main() { let x = vec![1111111, 2222222, 3333333, 444444]; }\n' \
  >"$FMT/src/main.rs"
printf 'fn   ugly( ) {}\n' >"$FMT/src/m.rs"
expect "fmt: formats the edited file" 0 fmt-on-edit.sh "$(edit f2 "$FMT/src/main.rs" 'x')"
check "fmt: rustfmt.toml max_width honored" \
  "$([[ "$(sed -n 3p "$FMT/src/main.rs")" == '    let x = vec![' ]] && echo yes)" \
  "$(cat "$FMT/src/main.rs")"
check "fmt: child module untouched" \
  "$([[ "$(cat "$FMT/src/m.rs")" == 'fn   ugly( ) {}' ]] && echo yes)" "$(cat "$FMT/src/m.rs")"
printf 'fn broken( {\n' >"$FMT/src/bad.rs"
expect "fmt: syntax error fed back" 2 fmt-on-edit.sh "$(edit f2 "$FMT/src/bad.rs" 'x')" \
  "rustfmt failed"
check "fmt: broken file left as written" \
  "$([[ "$(cat "$FMT/src/bad.rs")" == 'fn broken( {' ]] && echo yes)"

# Missing tools: edit hooks fail open (exit 1, loud), stop hooks block once.
NOJQ="$WORK/nojq-bin"
mkdir -p "$NOJQ"
for dir in /usr/bin /bin; do
  for tool in "$dir"/*; do
    name="$(basename "$tool")"
    if [[ "$name" != jq && ! -e "$NOJQ/$name" ]]; then
      ln -s "$tool" "$NOJQ/$name"
    fi
  done
done
run_hook style-gate.sh "$(edit m1 "$LIB/src/x.rs" 'fn a() {}')" "$NOJQ"
check "missing jq: gate fails open with a message" \
  "$([[ $code -eq 1 && "$out" == *"missing tool(s): jq"* ]] && echo yes)" "exit $code: $out"
run_hook check-on-stop.sh "$(stop m1)" "$NOJQ"
check "missing jq: stop blocks once with the fix" \
  "$([[ $code -eq 2 && "$out" == *"missing tool(s): jq"* ]] && echo yes)" "exit $code: $out"
run_hook check-on-stop.sh "$(stop m1 '{"stop_hook_active": true}')" "$NOJQ"
check "missing jq: second stop passes" "$([[ $code -eq 1 ]] && echo yes)" "exit $code: $out"

# Shared git fixtures for the base, review-gate and stop-check tests.
lines() { for ((i = $2; i < $2 + $3; i++)); do printf 'pub fn f%d() {}\n' "$i"; done >>"$1"; }
commit_all() {
  git -C "$1" add -A
  git -C "$1" -c user.name=t -c user.email=t@t commit -qm "${2:-snapshot}"
}
# commit_all an hour ago: work from before the session.
old_commit() {
  local then="@$(($(date +%s) - 3600)) +0000"
  GIT_AUTHOR_DATE="$then" GIT_COMMITTER_DATE="$then" commit_all "$@"
}
new_repo() {
  mkdir -p "$1/src"
  lines "$1/src/lib.rs" 0 5
  git -C "$1" init -q -b main
  old_commit "$1" init
}
# Repo $1 with a bare origin at $1.git that its main tracks, so origin/main is the default
# branch, as in a real clone.
new_cloned_repo() {
  new_repo "$1"
  git init -q --bare -b main "$1.git"
  git -C "$1" remote add origin "$1.git"
  git -C "$1" push -q -u origin main
  git -C "$1" remote set-head origin main
}
# Others' work arriving on origin's branch $2 of repo $1: commands $3... run in a separate
# clone (cwd the clone), committed there and pushed, as a teammate's push or a GitHub merge
# arrives.
arrive() {
  local repo="$1" branch="$2" clone="$1-elsewhere"
  shift 2
  git clone -q "$repo.git" "$clone"
  (cd "$clone" && "$@")
  if [[ -n "$(git -C "$clone" status --porcelain)" ]]; then
    commit_all "$clone" "others' work"
  fi
  git -C "$clone" push -q origin "HEAD:refs/heads/$branch"
  trash "$clone"
}
# Stop in repo $2 for session $1, with optional extra JSON fields $3.
rstop() {
  local extra="${3:-}"
  if [[ -z "$extra" ]]; then
    extra="{}"
  fi
  stop "$1" "$(jq -nc --arg c "$2" --argjson extra "$extra" '{cwd: $c} + $extra')"
}
# A subagent finished: session $1, repo $2, agent fields $3.
subagent_stop() {
  jq -nc --arg s "$1" --arg c "$2" --argjson extra "$3" \
    '{session_id: $s, hook_event_name: "SubagentStop", cwd: $c} + $extra'
}

# The base (changes.sh diff_base): the branch's diff against the default branch, what the
# pull request and CI judge. base_lines SESSION REPO prints the .rs lines added plus removed
# since it, untracked files included, as the stop check counts them.
base_lines() {
  (
    TMPDIR="$STATE_TMP"
    HOME="$FAKE_HOME"
    # shellcheck source=/dev/null # the hooks under test, sourced to call diff_base directly
    source "$HOOKS/common.sh"
    # shellcheck disable=SC2034 # read by the sourced helpers
    HOOK_INPUT="$(jq -nc --arg s "$1" '{session_id: $s}')"
    # shellcheck source=/dev/null # as above
    source "$HOOKS/changes.sh"
    base="$(diff_base "$2")"
    {
      git -C "$2" diff --numstat "$base" -- '*.rs' | awk '{ print $1 + $2 }'
      git -C "$2" ls-files --others --exclude-standard -- '*.rs' |
        while IFS= read -r file; do wc -l <"$2/$file"; done
    } | awk '{ n += $1 } END { print n + 0 }'
  )
}
# expect_lines NAME WANT SESSION REPO
expect_lines() {
  local got
  got="$(base_lines "$3" "$4")"
  check "base: $1 ($got lines, want $2)" "$([[ "$got" == "$2" ]] && echo yes)"
}

LOCAL="$WORK/base-local"
new_repo "$LOCAL"
prompt b1 "$LOCAL"
expect_lines "work from before the session on a local main" 0 b1 "$LOCAL"
lines "$LOCAL/src/lib.rs" 5 25
commit_all "$LOCAL" "session work"
expect_lines "local main: commits before the stop still count" 25 b1 "$LOCAL"
lines "$LOCAL/src/new.rs" 0 4
expect_lines "local main: untracked files count" 29 b1 "$LOCAL"

FEAT="$WORK/base-feature"
new_cloned_repo "$FEAT"
git -C "$FEAT" checkout -q -b feature
lines "$FEAT/src/lib.rs" 5 10
commit_all "$FEAT" "earlier work on the branch"
prompt b2 "$FEAT"
lines "$FEAT/src/lib.rs" 15 15
commit_all "$FEAT" "session work"
expect_lines "feature branch: the whole branch diff counts" 25 b2 "$FEAT"
git -C "$FEAT" reset -q --hard main
lines "$FEAT/src/lib.rs" 100 7
commit_all "$FEAT" "rewritten"
expect_lines "feature branch: after a reset only the new branch counts" 7 b2 "$FEAT"

PULL="$WORK/base-pull"
new_cloned_repo "$PULL"
prompt b3 "$PULL"
arrive "$PULL" main lines src/lib.rs 5 40
git -C "$PULL" pull -q --ff-only
expect_lines "a pull of others' work counts nothing" 0 b3 "$PULL"
lines "$PULL/src/lib.rs" 45 5
expect_lines "uncommitted work on an up-to-date main counts" 5 b3 "$PULL"

MERGED="$WORK/base-merged"
new_cloned_repo "$MERGED"
prompt b4 "$MERGED"
git -C "$MERGED" checkout -q -b feature
lines "$MERGED/src/lib.rs" 5 30
commit_all "$MERGED" "own work"
git -C "$MERGED" push -q -u origin feature
# Elsewhere: others' work on main, then the feature branch merged into it, as GitHub merges
# a pull request.
merge_feature() {
  git fetch -q origin feature
  lines src/other.rs 0 40
  commit_all . "others' work"
  git -c user.name=t -c user.email=t@t merge -q --no-ff FETCH_HEAD -m "Merge pull request"
}
arrive "$MERGED" main merge_feature
git -C "$MERGED" checkout -q main
git -C "$MERGED" pull -q --ff-only
expect_lines "main after the session's PR merged counts nothing" 0 b4 "$MERGED"

# The review gate: `gh pr ready` and a non-draft `gh pr create` need a rust-style-reviewer
# run over the pull request's Rust.
pr_cmd() {
  jq -nc --arg s "$1" --arg c "$2" --arg cmd "$3" \
    '{session_id: $s, cwd: $c, tool_name: "Bash", tool_input: {command: $cmd}}'
}
GATE="$WORK/gate"
new_cloned_repo "$GATE"
prompt v1 "$GATE"
git -C "$GATE" checkout -q -b feature
lines "$GATE/src/lib.rs" 5 25
commit_all "$GATE" "feature"
expect "gate: other commands pass" 0 review-gate.sh "$(pr_cmd v1 "$GATE" 'git status')"
expect "gate: draft create passes" 0 review-gate.sh \
  "$(pr_cmd v1 "$GATE" 'gh pr create --draft --title x')"
expect "gate: ready blocked" 2 review-gate.sh "$(pr_cmd v1 "$GATE" 'gh pr ready')" \
  "changes 25 lines of Rust"
check "gate: message lists the file" "$([[ "$out" == *"src/lib.rs (25 lines)"* ]] && echo yes)" \
  "$out"
expect "gate: non-draft create blocked" 2 review-gate.sh \
  "$(pr_cmd v1 "$GATE" 'gh pr create --title x --body y')" "rust-style-reviewer"
expect "gate: cd into the repo first is followed" 2 review-gate.sh \
  "$(pr_cmd v1 "$WORK" "cd $GATE && gh pr ready")" "25 lines"
expect "gate: another repository (-R) passes" 0 review-gate.sh \
  "$(pr_cmd v1 "$GATE" 'gh pr ready 3 -R other/repo')"
expect "gate: ready --undo passes" 0 review-gate.sh "$(pr_cmd v1 "$GATE" 'gh pr ready --undo')"
expect "gate: outside git passes" 0 review-gate.sh "$(pr_cmd v1 "$WORK/notrust" 'gh pr ready')"
run_hook review-done.sh "$(subagent_stop v1 "$GATE" '{"agent_id": "e1", "agent_type": "Explore"}')"
expect "gate: another agent type is no review" 2 review-gate.sh \
  "$(pr_cmd v1 "$GATE" 'gh pr ready')"
run_hook review-done.sh \
  "$(subagent_stop v1 "$GATE" '{"agent_id": "r1", "agent_type": "rust-style-reviewer"}')"
expect "gate: passes after the reviewer" 0 review-gate.sh "$(pr_cmd v1 "$GATE" 'gh pr ready')"
lines "$GATE/src/lib.rs" 30 3
commit_all "$GATE" "review fix"
expect "gate: a small fix after the review passes" 0 review-gate.sh \
  "$(pr_cmd v1 "$GATE" 'gh pr ready')"
lines "$GATE/src/lib.rs" 33 25
commit_all "$GATE" "more work"
expect "gate: 28 lines since the review blocked" 2 review-gate.sh \
  "$(pr_cmd v1 "$GATE" 'gh pr ready')" "changes 28 lines"
run_hook review-done.sh \
  "$(subagent_stop grok-child "$GATE" '{"subagentType": "user:rust-style-reviewer"}')"
expect "gate: a Grok reviewer in its own session counts" 0 review-gate.sh \
  "$(pr_cmd v1 "$GATE" 'gh pr ready')"
lines "$GATE/src/lib.rs" 58 25
commit_all "$GATE" "more after the prefixed review"
expect "gate: Rust after that review is blocked again" 2 review-gate.sh \
  "$(pr_cmd v1 "$GATE" 'gh pr ready')"
run_hook review-done.sh \
  "$(subagent_stop grok-other "$GATE" '{"subagentType": "user:other-agent"}')"
expect "gate: a different Grok agent is not this reviewer" 2 review-gate.sh \
  "$(pr_cmd v1 "$GATE" 'gh pr ready')"
run_hook review-done.sh \
  "$(subagent_stop grok-bare "$GATE" '{"subagentType": "rust-style-reviewer"}')"
expect "gate: a bare Grok reviewer name counts" 0 review-gate.sh \
  "$(pr_cmd v1 "$GATE" 'gh pr ready')"
lines "$GATE/src/lib.rs" 83 25
commit_all "$GATE" "more after the bare review"
expect "gate: Rust after the bare review is blocked again" 2 review-gate.sh \
  "$(pr_cmd v1 "$GATE" 'gh pr ready')"
run_hook review-done.sh \
  "$(subagent_stop grok-plugin "$GATE" '{"subagentType": "plugin:rust-style-reviewer"}')"
expect "gate: a plugin-prefixed Grok reviewer counts" 0 review-gate.sh \
  "$(pr_cmd v1 "$GATE" 'gh pr ready')"
printf '# Notes\n%.0s' {1..30} >"$GATE/NOTES.md"
commit_all "$GATE" "docs"
expect "gate: non-Rust changes do not count" 0 review-gate.sh "$(pr_cmd v1 "$GATE" 'gh pr ready')"

# A review in a subagent's worktree covers the branch in every checkout of the repository.
git -C "$GATE" worktree add -q -b wt-branch "$WORK/gate-wt" main
lines "$WORK/gate-wt/src/wt.rs" 0 30
commit_all "$WORK/gate-wt" "worktree work"
run_hook review-done.sh \
  "$(subagent_stop v2 "$WORK/gate-wt" '{"agent_id": "r2", "agent_type": "rust-style-reviewer"}')"
git -C "$GATE" worktree remove "$WORK/gate-wt"
git -C "$GATE" checkout -q wt-branch
expect "gate: a review in a worktree counts for the main checkout" 0 review-gate.sh \
  "$(pr_cmd v2 "$GATE" 'gh pr ready')"

# --base: a stacked PR is measured against the branch it targets.
git -C "$GATE" checkout -q -b stacked
lines "$GATE/src/wt.rs" 30 5
commit_all "$GATE" "stacked"
lines "$GATE/src/other.rs" 0 30
expect "gate: --base measures from the base branch" 0 review-gate.sh \
  "$(pr_cmd v2 "$GATE" 'gh pr create --base wt-branch --title x')"
commit_all "$GATE" "unreviewed"
expect "gate: unreviewed work on the stacked branch blocked" 2 review-gate.sh \
  "$(pr_cmd v2 "$GATE" 'gh pr create --base wt-branch --title x')" "src/other.rs (30 lines)"

# --base is honoured even though `gh pr create` has no PR argument: measured from the default
# branch the PR would show the 30 unreviewed lines of its base as well.
GB="$WORK/gate-base"
new_cloned_repo "$GB"
git -C "$GB" checkout -q -b lower
lines "$GB/src/lower.rs" 0 30
commit_all "$GB" "lower PR, not reviewed here"
git -C "$GB" push -q -u origin lower
git -C "$GB" checkout -q -b upper
lines "$GB/src/upper.rs" 0 3
commit_all "$GB" "upper PR"
expect "gate: --base measured from that branch, not the default" 0 review-gate.sh \
  "$(pr_cmd v3 "$GB" 'gh pr create --base lower --fill')"
expect "gate: --base=branch too" 0 review-gate.sh \
  "$(pr_cmd v3 "$GB" 'gh pr create --base=lower --fill')"
expect "gate: without --base the default branch counts" 2 review-gate.sh \
  "$(pr_cmd v3 "$GB" 'gh pr create --fill')" "src/lower.rs (30 lines)"

# Quoted text and heredoc bodies are not commands; wrappers and skipped calls do not hide one.
expect "gate: gh pr ready in a commit message passes" 0 review-gate.sh \
  "$(pr_cmd v3 "$GB" "git commit -m 'note; gh pr ready after review'")"
expect "gate: gh pr ready in a heredoc body passes" 0 review-gate.sh \
  "$(pr_cmd v3 "$GB" $'gh pr comment 1 --body-file - <<\'X\'\ngh pr ready\nX')"
expect "gate: a quoted -d in the title is not --draft" 2 review-gate.sh \
  "$(pr_cmd v3 "$GB" "gh pr create --title 'Drop the -d flag' --body x")" "rust-style-reviewer"
expect "gate: a skipped call does not end the scan" 2 review-gate.sh \
  "$(pr_cmd v3 "$GB" 'gh pr create --draft --fill && gh pr create --fill')" "src/lower.rs"
expect "gate: an env prefix still runs gh" 2 review-gate.sh \
  "$(pr_cmd v3 "$GB" 'GH_TOKEN=x command gh pr create --fill')" "src/lower.rs"
mkdir -p "$WORK/dir with space"
expect "gate: a quoted cd target is followed" 2 review-gate.sh \
  "$(pr_cmd v3 "$WORK/dir with space" "cd \"$GB\" && gh pr create --fill")" "src/lower.rs"

# A renamed file is reviewed like any other: after the reviewer, only its content counts.
GR="$WORK/gate-rename"
new_cloned_repo "$GR"
lines "$GR/src/old.rs" 0 40
commit_all "$GR" "old file"
git -C "$GR" push -q origin main
git -C "$GR" checkout -q -b rename
git -C "$GR" mv src/old.rs src/new.rs
commit_all "$GR" "rename"
expect "gate: an unreviewed rename counts" 2 review-gate.sh "$(pr_cmd v4 "$GR" 'gh pr ready')"
run_hook review-done.sh \
  "$(subagent_stop v4 "$GR" '{"agent_id": "r4", "agent_type": "rust-style-reviewer"}')"
expect "gate: a reviewed rename passes" 0 review-gate.sh "$(pr_cmd v4 "$GR" 'gh pr ready')"

# An old snapshot cannot charge a PR for more lines than its own diff.
GS="$WORK/gate-stale"
new_cloned_repo "$GS"
git -C "$GS" checkout -q -b first
lines "$GS/src/x.rs" 0 25
commit_all "$GS" "first"
run_hook review-done.sh \
  "$(subagent_stop v5 "$GS" '{"agent_id": "r5", "agent_type": "rust-style-reviewer"}')"
git -C "$GS" checkout -q main
lines "$GS/src/x.rs" 0 60
commit_all "$GS" "others' work, merged"
git -C "$GS" push -q origin main
git -C "$GS" checkout -q -b second
lines "$GS/src/x.rs" 60 1
commit_all "$GS" "second"
expect "gate: a stale snapshot does not exceed the PR's own diff" 0 review-gate.sh \
  "$(pr_cmd v5 "$GS" 'gh pr ready')"

# Parallel worktrees: two branches change one file differently, each reviewed in turn. A
# review keeps a snapshot per version, so the second does not undo the first.
GP="$WORK/gate-parallel"
new_cloned_repo "$GP"
git -C "$GP" worktree add -q -b par-a "$WORK/gate-par-a" main
git -C "$GP" worktree add -q -b par-b "$WORK/gate-par-b" main
lines "$WORK/gate-par-a/src/lib.rs" 100 30
commit_all "$WORK/gate-par-a" "branch a"
run_hook review-done.sh \
  "$(subagent_stop p1 "$WORK/gate-par-a" '{"agent_id": "ra", "agent_type": "rust-style-reviewer"}')"
lines "$WORK/gate-par-b/src/lib.rs" 200 30
commit_all "$WORK/gate-par-b" "branch b"
run_hook review-done.sh \
  "$(subagent_stop p2 "$WORK/gate-par-b" '{"agent_id": "rb", "agent_type": "rust-style-reviewer"}')"
expect "gate: parallel branch a stays reviewed after b's review" 0 review-gate.sh \
  "$(pr_cmd p1 "$WORK/gate-par-a" 'gh pr create --fill')"
expect "gate: parallel branch b passes after its review" 0 review-gate.sh \
  "$(pr_cmd p2 "$WORK/gate-par-b" 'gh pr create --fill')"

# A reviewer run from a session rooted in the main checkout still covers a branch checked out
# in another worktree of the repository.
git -C "$GP" worktree add -q -b par-c "$WORK/gate-par-c" main
lines "$WORK/gate-par-c/src/c.rs" 0 30
commit_all "$WORK/gate-par-c" "branch c"
expect "gate: branch c unreviewed" 2 review-gate.sh \
  "$(pr_cmd p3 "$WORK/gate-par-c" 'gh pr create --fill')" "src/c.rs (30 lines)"
run_hook review-done.sh \
  "$(subagent_stop p3 "$GP" '{"agent_id": "rc", "agent_type": "rust-style-reviewer"}')"
expect "gate: a review from the main checkout covers another worktree" 0 review-gate.sh \
  "$(pr_cmd p3 "$WORK/gate-par-c" 'gh pr create --fill')"

# A worktree under the session scratchpad holds a real branch: the gate counts its diff, so
# the review must record it too.
GSP="$WORK/tmp/claude-501/proj/sess/scratchpad/gate-par-s"
mkdir -p "$(dirname "$GSP")"
git -C "$GP" worktree add -q -b par-s "$GSP" main
lines "$GSP/src/s.rs" 0 30
commit_all "$GSP" "branch s"
expect "gate: a scratchpad worktree's branch counts" 2 review-gate.sh \
  "$(pr_cmd p8 "$GSP" 'gh pr create --fill')" "src/s.rs (30 lines)"
run_hook review-done.sh \
  "$(subagent_stop p8 "$GP" '{"agent_id": "rs", "agent_type": "rust-style-reviewer"}')"
expect "gate: a review covers a worktree under the scratchpad" 0 review-gate.sh \
  "$(pr_cmd p8 "$GSP" 'gh pr create --fill')"

# A reviewed deletion passes: its snapshot is the empty file.
GD="$WORK/gate-delete"
new_cloned_repo "$GD"
lines "$GD/src/big.rs" 0 30
commit_all "$GD" "big"
git -C "$GD" push -q origin main
git -C "$GD" checkout -q -b drop
git -C "$GD" rm -q src/big.rs
commit_all "$GD" "drop big"
expect "gate: an unreviewed deletion counts" 2 review-gate.sh \
  "$(pr_cmd p4 "$GD" 'gh pr ready')" "src/big.rs (30 lines)"
run_hook review-done.sh \
  "$(subagent_stop p4 "$GD" '{"agent_id": "rd", "agent_type": "rust-style-reviewer"}')"
expect "gate: a reviewed deletion passes" 0 review-gate.sh "$(pr_cmd p4 "$GD" 'gh pr ready')"

# Two reviewers finishing at once leave whole snapshots and no temporary files.
REVIEW_STATE="$STATE_TMP/claude-rust-hooks/review-$(printf '%s' \
  "$(git -C "$GP" rev-parse --path-format=absolute --git-common-dir)" | shasum -a 256 |
  cut -c 1-32)"
lines "$WORK/gate-par-a/src/lib.rs" 300 30
commit_all "$WORK/gate-par-a" "branch a again"
reviewer='{"agent_id": "r5", "agent_type": "rust-style-reviewer"}'
review_a="$(subagent_stop p5 "$WORK/gate-par-a" "$reviewer")"
review_b="$(subagent_stop p6 "$GP" "$reviewer")"
for ((n = 0; n < 5; n++)); do
  run_hook review-done.sh "$review_a" &
  run_hook review-done.sh "$review_b" &
  wait
done
check "review: concurrent runs leave no temporary files" \
  "$([[ -z "$(find "$REVIEW_STATE" -name '.tmp-*')" ]] && echo yes)"
expect "gate: concurrent reviews still count" 0 review-gate.sh \
  "$(pr_cmd p5 "$WORK/gate-par-a" 'gh pr create --fill')"

# Several snapshots of one file, none of them its committed version: the closest counts.
GE="$WORK/gate-par-e"
git -C "$GP" worktree add -q -b par-e "$GE" main
lines "$GE/src/e.rs" 0 30
run_hook review-done.sh "$(subagent_stop p7 "$GE" "$reviewer")"
lines "$GE/src/e.rs" 30 30
run_hook review-done.sh "$(subagent_stop p7 "$GE" "$reviewer")"
: >"$GE/src/e.rs"
lines "$GE/src/e.rs" 0 30
lines "$GE/src/e.rs" 100 3
commit_all "$GE" "close to the first review"
expect "gate: the closest of several snapshots counts" 0 review-gate.sh \
  "$(pr_cmd p7 "$GE" 'gh pr create --fill')"

# Snapshots per path are bounded: the newest stay, the oldest go.
keep="$(sed -n 's/^REVIEW_KEEP=//p' "$HOOKS/changes.sh")"
lib_key="$(printf '%s' src/lib.rs | shasum -a 256 | cut -c 1-32)"
for ((n = 0; n < keep + 2; n++)); do
  printf 'pub fn round%d() {}\n' "$n" >>"$WORK/gate-par-a/src/lib.rs"
  run_hook review-done.sh "$review_a"
  if ((n == 0)); then
    first="$REVIEW_STATE/$lib_key.$(git hash-object "$WORK/gate-par-a/src/lib.rs")"
  fi
done
kept="$(find "$REVIEW_STATE" -name "$lib_key.*" | wc -l | tr -d ' ')"
check "review: at most $keep snapshots per path (kept $kept)" \
  "$([[ $kept -eq $keep ]] && echo yes)"
check "review: the oldest snapshot is pruned" "$([[ -n "$first" && ! -e "$first" ]] && echo yes)"
commit_all "$WORK/gate-par-a" "rounds"
expect "gate: the newest snapshot survives pruning" 0 review-gate.sh \
  "$(pr_cmd p5 "$WORK/gate-par-a" 'gh pr create --fill')"

# Many files: one pass over the snapshots, and a long listing still blocks (exit 2, not 141).
GM="$WORK/gate-many"
new_cloned_repo "$GM"
git -C "$GM" checkout -q -b many
long="$(printf 'very_long_module_name_%.0s' {1..8})"
for ((n = 0; n < 1200; n++)); do printf 'pub fn g() {}\n' >"$GM/src/${long}_$n.rs"; done
commit_all "$GM" "many files"
started="$(date +%s)"
expect "gate: 1200 unreviewed files block" 2 review-gate.sh "$(pr_cmd v6 "$GM" 'gh pr ready')" \
  "changes 1200 lines"
elapsed=$(($(date +%s) - started))
check "gate: 1200 files in under 20 s (took ${elapsed}s)" "$([[ $elapsed -lt 20 ]] && echo yes)"
# With every file reviewed the gate looks each one up in a single listing of the record.
run_hook review-done.sh "$(subagent_stop v6 "$GM" "$reviewer")"
started="$(date +%s)"
expect "gate: 1200 reviewed files pass" 0 review-gate.sh "$(pr_cmd v6 "$GM" 'gh pr ready')"
elapsed=$(($(date +%s) - started))
check "gate: 1200 reviewed files in under 20 s (took ${elapsed}s)" \
  "$([[ $elapsed -lt 20 ]] && echo yes)"

SETTINGS="$HOOKS/../../settings.json"
check "settings: the review gate runs on Bash, not on Stop" "$(jq -e '
  ([.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[].command
    | select(test("review-gate"))] | length == 1)
  and ([.hooks.Stop[].hooks[].command | select(test("review-gate"))] | length == 0)' \
  "$SETTINGS" >/dev/null && echo yes)"

# M2: a Q&A session in a dirty repo changed nothing and passes the stop check.
REPO5="$WORK/repo5"
new_repo "$REPO5"
lines "$REPO5/src/lib.rs" 5 30
printf '// TODO: dirty before the session\n' >>"$REPO5/src/lib.rs"
prompt q1 "$REPO5"
expect "check: Q&A session in a dirty repo passes" 0 check-on-stop.sh "$(rstop q1 "$REPO5")"

# Claude's session scratchpad is exempt (scratch_exempt) unless it holds a git branch: no
# style gate, nothing recorded, no stop check. Each case edits a crate there without loading
# the skill or running tests, so a checked one is blocked by both.
SCRATCHPAD="$WORK/tmp/claude-501/proj/sess/scratchpad"
# scratch_case SESSION DIR: style gate, recorded edit, and stop check for an edit in DIR.
# Sets $gate_code, $recorded (yes or empty) and $stop_code.
scratch_case() {
  prompt "$1" "$2"
  run_hook style-gate.sh "$(edit "$1" "$2/src/lib.rs" 'unsafe { f() }')"
  gate_code="$code"
  lines "$2/src/lib.rs" 5 30
  run_hook fmt-on-edit.sh "$(edit "$1" "$2/src/lib.rs" 'x')"
  recorded="$([[ -s "$STATE_TMP/claude-rust-hooks/$1.main.edited" ]] && echo yes || true)"
  run_hook check-on-stop.sh "$(rstop "$1" "$2")"
  stop_code="$code"
}
expect_exempt() {
  check "scratch: $1: style gate skips it" "$([[ $gate_code -eq 0 ]] && echo yes)"
  check "scratch: $1: edit not recorded" "$([[ -z "$recorded" ]] && echo yes)"
  check "scratch: $1: stop check ignores it" "$([[ $stop_code -eq 0 ]] && echo yes)" "$out"
}
expect_checked() {
  check "scratch: $1: style gate blocks" "$([[ $gate_code -eq 2 ]] && echo yes)"
  check "scratch: $1: edit recorded" "$([[ -n "$recorded" ]] && echo yes)"
  check "scratch: $1: stop check blocks" \
    "$([[ $stop_code -eq 2 && "$out" == *"No test run"* ]] && echo yes)" "$out"
}

mkdir -p "$SCRATCHPAD/plain/src"
lines "$SCRATCHPAD/plain/src/lib.rs" 0 5
scratch_case s1 "$SCRATCHPAD/plain"
expect_exempt "a plain directory"

# `cargo new` runs `git init`: a branch with no commit is still scratch.
mkdir -p "$SCRATCHPAD/unborn/src"
lines "$SCRATCHPAD/unborn/src/lib.rs" 0 5
git -C "$SCRATCHPAD/unborn" init -q -b main
scratch_case s4 "$SCRATCHPAD/unborn"
expect_exempt "a repo with no commit"

# A repo above the scratchpad does not make it a branch checkout.
OUTER="$WORK/outer"
new_repo "$OUTER"
mkdir -p "$OUTER/tmp/claude-501/proj/sess/scratchpad/x/src"
expect "scratch: a repo above the scratchpad keeps it exempt" 0 style-gate.sh \
  "$(edit s5 "$OUTER/tmp/claude-501/proj/sess/scratchpad/x/src/lib.rs" 'fn a() {}')"

# Worktrees of a repo outside the scratchpad, as the main session makes them.
SCRATCH_BASE="$WORK/scratch-base"
new_repo "$SCRATCH_BASE"
git -C "$SCRATCH_BASE" worktree add -q --detach "$SCRATCHPAD/old" main
scratch_case s2 "$SCRATCHPAD/old"
expect_exempt "a detached-HEAD worktree"

# A branch there may become a pull request (scratchpad/batch-e, 2026-10-30).
git -C "$SCRATCH_BASE" worktree add -q -b batch "$SCRATCHPAD/batch" main
scratch_case s3 "$SCRATCHPAD/batch"
expect_checked "a worktree on a branch"
run_hook style-gate.sh "$(edit s3 "$SCRATCHPAD/batch/src/new/mod.rs" 'fn a() {}')"
check "scratch: a new file in a branch worktree is gated" "$([[ $code -eq 2 ]] && echo yes)"

# check-on-stop: runs cargo clippy on throwaway crates.
# An opted-in crate (house rules on, with its own pedantic lint table) unless $3 is `plain`.
new_crate_repo() {
  local metadata=$'\n[package.metadata.house-check]\nbaseline = true\n'
  metadata+=$'\n[lints.clippy]\npedantic = { level = "warn", priority = -1 }\n'
  if [[ "${3:-}" == plain ]]; then
    metadata=""
  fi
  mkdir -p "$1/src"
  printf '[package]\nname = "c"\nversion = "0.1.0"\nedition = "2024"\n%s%s' "$metadata" \
    "${2:-}" >"$1/Cargo.toml"
  printf '//! Crate.\n\n/// Adds.\n#[must_use]\npub fn add(a: u8, b: u8) -> u8 {\n    a ^ b\n}\n' \
    >"$1/src/lib.rs"
  printf '//! Binary.\n\nfn main() {\n    let _ = c::add(1, 2);\n}\n' >"$1/src/main.rs"
  git -C "$1" init -q -b main
  printf 'target/\n' >"$1/.gitignore"
  commit_all "$1" init
}
# A pub fn with a pedantic lint (cast_possible_truncation) in its body.
narrow_fn() {
  printf '\n/// Narrows.\n#[must_use]\npub fn narrow(x: u64) -> u32 {\n    x as u32\n}\n'
}
cstop() {
  local extra="${3:-}"
  if [[ -z "$extra" ]]; then
    extra="{}"
  fi
  jq -nc --arg s "$1" --arg c "$2" --argjson extra "$extra" \
    '{session_id: $s, hook_event_name: "Stop", cwd: $c} + $extra'
}

# Session $1 ran its tests (tests-ran.sh), so the stop check judges the lints alone.
ran_tests() { run_hook tests-ran.sh "$(bash_cmd "$1" 'cargo nextest run')"; }

C1="$WORK/c1"
new_crate_repo "$C1"
prompt k1 "$C1"
expect "check: clean repo passes" 0 check-on-stop.sh "$(cstop k1 "$C1")"
printf '//! Crate.\n\n/// Identity.\n#[must_use]\npub fn add(a: u8) -> u8 {\n    dbg!(a)\n}\n' \
  >"$C1/src/lib.rs"
run_hook fmt-on-edit.sh "$(edit k1 "$C1/src/lib.rs" 'x')"
expect "check: lib edit breaking the bin reports E0061" 2 check-on-stop.sh "$(cstop k1 "$C1")" \
  "E0061"
check "check: compiler errors listed before warnings" "$(awk '/E0061/ { e = NR } /dbg!/ { w = NR }
  END { exit !(e && w && e < w) }' <<<"$out" && echo yes)" "$out"
expect "check: unchanged state does not block twice" 0 check-on-stop.sh "$(cstop k1 "$C1")"

C2="$WORK/c2"
new_crate_repo "$C2"
narrow_fn >>"$C2/src/lib.rs"
commit_all "$C2" legacy
prompt k2 "$C2"
printf '//! Binary.\n\nfn main() {\n' >"$C2/src/main.rs"
printf '    let v: Option<u8> = Some(c::add(1, 2));\n' >>"$C2/src/main.rs"
printf '    dbg!(v.unwrap());\n}\n' >>"$C2/src/main.rs"
run_hook fmt-on-edit.sh "$(edit k2 "$C2/src/main.rs" 'x')"
expect "check: bin linted despite a deny-level lint in the lib" 2 check-on-stop.sh \
  "$(cstop k2 "$C2")" "src/main.rs:5"
check "check: unchanged legacy lint in lib.rs not reported" \
  "$([[ "$out" != *"may truncate"* && "$out" == *"dbg!"* ]] && echo yes)" "$out"

git -C "$C2" checkout -q -- src/main.rs
prompt k3 "$C2"
printf '// Touched line.\n' >>"$C2/src/lib.rs"
run_hook fmt-on-edit.sh "$(edit k3 "$C2/src/lib.rs" 'x')"
ran_tests k3
expect "check: touching one line of a legacy file passes" 0 check-on-stop.sh "$(cstop k3 "$C2")"
printf '// TODO: new\n' >>"$C2/src/lib.rs"
expect "check: house-check finding on a changed line" 2 check-on-stop.sh "$(cstop k3 "$C2")" \
  "src/lib.rs:15: [DOC-TODO]"
perl -pi -e 's{^//! Crate.$}{//! Crate. TODO: second hunk} if $. == 1' "$C2/src/lib.rs"
expect "check: findings in two separate hunks" 2 check-on-stop.sh "$(cstop k3 "$C2")" \
  "src/lib.rs:1: [DOC-TODO]"
check "check: both hunks reported" "$([[ "$out" == *"lib.rs:15: [DOC-TODO]"* ]] && echo yes)" "$out"

C3="$WORK/c3"
new_crate_repo "$C3"
prompt k4 "$C3"
printf '//! Binary.\n\nfn main() {\n    dbg!(c::add(1, 2));\n}\n' >"$C3/src/main.rs"
narrow_fn >>"$C3/src/lib.rs"
expect "check: unrecorded (Bash) edit is checked" 2 check-on-stop.sh "$(cstop k4 "$C3")" "dbg!"
check "check: lints in two changed files of one repo both reported" \
  "$([[ "$out" == *"src/main.rs:4"* && "$out" == *"src/lib.rs:12"* ]] && echo yes)" "$out"

# B1 without a prompt hook (a Grok subagent session): the first edit records the baseline,
# so a commit before the stop still hides nothing.
C3C="$WORK/c3c"
new_crate_repo "$C3C"
printf '//! Binary.\n\nfn main() {\n    dbg!(c::add(1, 2));\n}\n' >"$C3C/src/main.rs"
run_hook fmt-on-edit.sh "$(edit k16 "$C3C/src/main.rs" 'x')"
commit_all "$C3C" "agent commit"
expect "check: baseline from the first edit survives a commit" 2 check-on-stop.sh \
  "$(cstop k16 "$C3C")" "dbg!"

# B1: committing before the stop does not hide the lint.
C3B="$WORK/c3b"
new_crate_repo "$C3B"
prompt k9 "$C3B"
printf '//! Binary.\n\nfn main() {\n    dbg!(c::add(1, 2));\n}\n' >"$C3B/src/main.rs"
commit_all "$C3B" "agent commit"
expect "check: committed change is still checked" 2 check-on-stop.sh "$(cstop k9 "$C3B")" "dbg!"

# The repo's own lint table is what the hook checks: a lint it enables is reported, one it
# allows is not, and the minimal set still applies beside it.
C4="$WORK/c4"
new_crate_repo "$C4" $'\n[lints.rust]\nunsafe_code = "forbid"\n'
prompt k5 "$C4"
narrow_fn >>"$C4/src/lib.rs"
expect "check: the repo's pedantic lint reported" 2 check-on-stop.sh "$(cstop k5 "$C4")" \
  "may truncate"
allows='\ncast_possible_truncation = "allow"\ndbg_macro = "allow"'
perl -pi -e "s/^(pedantic = .*)\$/\$1$allows/" "$C4/Cargo.toml"
printf '\n/// Logs.\npub fn log() {\n    dbg!(1);\n}\n' >>"$C4/src/lib.rs"
ran_tests k5
expect "check: repo lint settings win over the minimal set" 0 check-on-stop.sh \
  "$(cstop k5 "$C4")"

# No house template from the hook: an opted-in repo without its own lint table is told to
# commit one (the template is not injected behind its back).
C4B="$WORK/c4b"
new_crate_repo "$C4B" "" plain
printf '\n[package.metadata.house-check]\nbaseline = true\n' >>"$C4B/Cargo.toml"
prompt k19 "$C4B"
narrow_fn >>"$C4B/src/lib.rs"
expect "check: opted in without a lint table is reported" 2 check-on-stop.sh \
  "$(cstop k19 "$C4B")" "has no [workspace.lints]"
check "check: house template not injected" "$([[ "$out" != *"may truncate"* ]] && echo yes)" "$out"

C5="$WORK/c5"
mkdir -p "$C5/src"
printf '[package]\nname = "c"\nversion = "0.1.0"\nedition = "2024"\n' >"$C5/Cargo.toml"
printf '\n[package.metadata.house-check]\nbaseline = true\n\n[lints.clippy]\n' >>"$C5/Cargo.toml"
printf 'pedantic = { level = "warn", priority = -1 }\n' >>"$C5/Cargo.toml"
printf '//! Crate.\n\n// TODO: untracked marker\n' >"$C5/src/lib.rs"
run_hook fmt-on-edit.sh "$(edit k6 "$C5/src/lib.rs" 'x')"
expect "check: non-git recorded file checks all lines" 2 check-on-stop.sh "$(stop k6)" \
  "src/lib.rs:3: [DOC-TODO]"
printf '//! Crate.\n' >"$C5/src/lib.rs"
ran_tests k6
expect "check: fixed file passes" 0 check-on-stop.sh "$(stop k6)"
check "check: passing stop clears the edited list" \
  "$([[ ! -s "$STATE_TMP/claude-rust-hooks/k6.main.edited" ]] && echo yes)"

# M1: a subagent answers only for the paths it recorded.
C6="$WORK/c6"
new_crate_repo "$C6"
prompt k7 "$C6"
# The parent's file has a compile error and a lint; neither is the subagent's business.
printf '//! Binary.\n\nfn main() {\n    let _: u8 = "x";\n    dbg!(c::add(1, 2));\n}\n' \
  >"$C6/src/main.rs"
expect "check: subagent that recorded nothing is not checked" 0 check-on-stop.sh \
  "$(subagent_stop k7 "$C6" '{"agent_id": "reviewer1", "agent_type": "rust-style-reviewer"}')"
printf '\n/// Doubles.\n#[must_use]\npub fn double(a: u8) -> u8 {\n    dbg!(a) * 2\n}\n' \
  >>"$C6/src/lib.rs"
run_hook fmt-on-edit.sh "$(edit k7 "$C6/src/lib.rs" 'x' worker1)"
expect "check: subagent checked on its own file" 2 check-on-stop.sh \
  "$(subagent_stop k7 "$C6" '{"agent_id": "worker1", "agent_type": "general-purpose"}')" \
  "src/lib.rs"
check "check: subagent not told about the parent's file" \
  "$([[ "$out" != *"src/main.rs"* ]] && echo yes)" "$out"
expect "check: main agent sees the whole repo" 2 check-on-stop.sh "$(cstop k7 "$C6")" "src/main.rs"

# M8: a member's own [lints] table is honored (it allows print_stdout; the other member
# inherits nothing and gets the baseline).
WS="$WORK/ws"
mkdir -p "$WS/a/src" "$WS/b/src"
printf '[workspace]\nmembers = ["a", "b"]\nresolver = "3"\n\n[workspace.metadata.house-check]\n' \
  >"$WS/Cargo.toml"
printf 'baseline = true\n\n[workspace.lints.clippy]\nprint_stdout = "warn"\n' >>"$WS/Cargo.toml"
printf '[package]\nname = "a"\nversion = "0.1.0"\nedition = "2024"\n\n[lints.clippy]\n' \
  >"$WS/a/Cargo.toml"
printf 'print_stdout = "allow"\n' >>"$WS/a/Cargo.toml"
printf '[package]\nname = "b"\nversion = "0.1.0"\nedition = "2024"\n\n[lints]\nworkspace = true\n' \
  >"$WS/b/Cargo.toml"
printf 'target/\n' >"$WS/.gitignore"
git -C "$WS" init -q -b main
prompt k8 "$WS"
for member in a b; do
  printf '//! Crate.\n\n/// Says hi.\npub fn hi() {\n    println!("hi");\n}\n' \
    >"$WS/$member/src/lib.rs"
done
expect "check: member lints honored per package" 2 check-on-stop.sh "$(cstop k8 "$WS")" \
  "b/src/lib.rs:5"
check "check: member allowing print_stdout not flagged" \
  "$([[ "$out" != *"a/src/lib.rs:5"* ]] && echo yes)" "$out"

# M5: default features unless the repo opts in; build-script failures keep their cause.
C7="$WORK/c7"
new_crate_repo "$C7" $'\n[features]\nbroken = []\n'
printf '\n#[cfg(feature = "broken")]\ncompile_error!("broken feature");\n' >>"$C7/src/lib.rs"
prompt k10 "$C7"
printf '// touched\n' >>"$C7/src/lib.rs"
ran_tests k10
expect "check: default features only" 0 check-on-stop.sh "$(cstop k10 "$C7")"
perl -pi -e 's/^baseline = true$/baseline = true\nall-features = true/' "$C7/Cargo.toml"
expect "check: repo opts in to all features" 2 check-on-stop.sh "$(cstop k10 "$C7")" \
  "broken feature"
C8="$WORK/c8"
new_crate_repo "$C8"
prompt k11 "$C8"
printf 'fn main() {\n    panic!("boom in build");\n}\n' >"$C8/build.rs"
expect "check: build-script failure shows its cause" 2 check-on-stop.sh "$(cstop k11 "$C8")" \
  "boom in build"
check "check: build-script failure header kept" \
  "$([[ "$out" == *"failed to run custom build command"* ]] && echo yes)" "$out"

# M4: a broken manifest is reported, not swallowed.
C9="$WORK/c9"
new_crate_repo "$C9"
prompt k12 "$C9"
printf '[package\n' >>"$C9/Cargo.toml"
run_hook fmt-on-edit.sh "$(edit k12 "$C9/Cargo.toml" 'x')"
expect "check: broken manifest reported" 2 check-on-stop.sh "$(cstop k12 "$C9")" "Cargo.toml"

# M9: paths with spaces survive, both above the workspace and inside it (cargo reports
# workspace-relative paths, so only a space inside the workspace reached the old parser).
C10="$WORK/c 10"
new_crate_repo "$C10"
mkdir -p "$C10/src/sub dir"
printf '/// F.\npub fn f() {}\n' >"$C10/src/sub dir/x.rs"
printf '//! Binary.\n\n#[path = "sub dir/x.rs"]\nmod x;\n\nfn main() {\n    x::f();\n}\n' \
  >"$C10/src/main.rs"
commit_all "$C10" "sub dir"
prompt k13 "$C10"
printf '/// F.\npub fn f() {\n    dbg!(1);\n}\n' >"$C10/src/sub dir/x.rs"
expect "check: diagnostic in a path with spaces" 2 check-on-stop.sh "$(cstop k13 "$C10")" \
  "c 10/src/sub dir/x.rs:3"

# Minor: invalid UTF-8 does not crash the hook; a crashed checker is not a finding.
C11="$WORK/c11"
new_crate_repo "$C11"
prompt k14 "$C11"
# Invalid UTF-8 in a changed file: the bytes reach awk through `git diff -U0`. Not a module
# of the crate, so rustc never reads it; the hook's own text tools must not choke.
printf '// Orphan.\n' >"$C11/src/orphan.rs"
commit_all "$C11" orphan
printf '// \xff\xfe bytes\n// TODO: marker\n' >>"$C11/src/orphan.rs"
expect "check: invalid UTF-8 handled" 2 check-on-stop.sh "$(cstop k14 "$C11")" \
  "orphan.rs:3: [DOC-TODO]"
# An unreadable file at an opted-in crate's root (not a module, so clippy never reads it):
# house-check fails, the hook says so.
C12="$WORK/c12"
mkdir -p "$C12/src"
printf '[package]\nname = "c"\nversion = "0.1.0"\nedition = "2024"\n' >"$C12/Cargo.toml"
printf '\n[package.metadata.house-check]\nbaseline = true\n\n[lints.clippy]\n' >>"$C12/Cargo.toml"
printf 'pedantic = { level = "warn", priority = -1 }\n' >>"$C12/Cargo.toml"
printf '//! Crate.\n' >"$C12/src/lib.rs"
printf 'fn a() {}\n' >"$C12/locked.rs"
run_hook fmt-on-edit.sh "$(edit k15 "$C12/locked.rs" 'x')"
chmod 000 "$C12/locked.rs"
ran_tests k15
run_hook check-on-stop.sh "$(stop k15)"
chmod 644 "$C12/locked.rs"
check "check: internal failure exits 1, not 2" \
  "$([[ $code -ne 2 && "$out" == *"internal error"* ]] && echo yes)" "exit $code: $out"

# A repo that has not opted in: minimal lints only, no house-check, no column check.
C13="$WORK/c13"
new_crate_repo "$C13" "" plain
prompt k17 "$C13"
narrow_fn >>"$C13/src/lib.rs"
printf '// TODO: untracked marker\n' >>"$C13/src/lib.rs"
printf '//! Binary.\n\nfn main() {\n    dbg!(c::add(1, 2));\n}\n' >"$C13/src/main.rs"
expect "opt-out: leftover dbg! still reported" 2 check-on-stop.sh "$(cstop k17 "$C13")" "dbg!"
check "opt-out: no pedantic lint and no house-check finding" \
  "$([[ "$out" != *"may truncate"* && "$out" != *DOC-TODO* ]] && echo yes)" "$out"

# Scoping: clippy covers the changed member and its dependents, not unrelated members.
SC="$WORK/scope"
mkdir -p "$SC/a/src" "$SC/b/src" "$SC/c/src"
printf '[workspace]\nmembers = ["a", "b", "c"]\nresolver = "3"\n' >"$SC/Cargo.toml"
for member in a b c; do
  printf '[package]\nname = "%s"\nversion = "0.1.0"\nedition = "2024"\n' "$member" \
    >"$SC/$member/Cargo.toml"
done
printf '\n[dependencies]\na = { path = "../a" }\n' >>"$SC/c/Cargo.toml"
printf '//! A.\n\n/// One.\n#[must_use]\npub fn one() -> u8 {\n    1\n}\n' >"$SC/a/src/lib.rs"
# b is broken before the session; nothing the session does touches it.
printf '//! B.\n\n/// Broken.\npub fn broken() -> u8 {\n    "b"\n}\n' >"$SC/b/src/lib.rs"
printf '//! C.\n\n/// Uses a.\n#[must_use]\npub fn two() -> u8 {\n    a::one() + 1\n}\n' \
  >"$SC/c/src/lib.rs"
printf 'target/\n' >"$SC/.gitignore"
git -C "$SC" init -q -b main
commit_all "$SC" init
prompt k18 "$SC"
printf '//! A.\n\n/// One.\n#[must_use]\npub fn one(x: u8) -> u8 {\n    x\n}\n' >"$SC/a/src/lib.rs"
expect "scope: dependent of the changed member reports its break" 2 check-on-stop.sh \
  "$(cstop k18 "$SC")" "c/src/lib.rs"
check "scope: unrelated broken member not checked" \
  "$([[ "$out" != *"b/src/lib.rs"* ]] && echo yes)" "$out"

# Tests ran: a test command records the run for the session; other commands do not.
tests_stamp="$STATE_TMP/claude-rust-hooks/t1.tests-ran"
for cmd in 'cargo build' 'git status' 'echo cargo-test' 'cargo testx' 'cargo test --no-run' \
  'cargo nextest list'; do
  run_hook tests-ran.sh "$(bash_cmd t1 "$cmd")"
  check "tests-ran: '$cmd' is no test run" "$([[ ! -e "$tests_stamp" ]] && echo yes)"
done
for cmd in 'cargo test' 'cargo t -p c' 'RUST_LOG=debug cargo nextest run' \
  'cargo +nightly miri test' 'cargo mutants --in-diff x.diff' 'cd c && cargo test --doc' \
  'cargo -q test' 'cargo --locked nextest run' 'cargo hack test --each-feature' \
  'cargo llvm-cov nextest' 'cargo insta test'; do
  trash "$tests_stamp" 2>/dev/null || true
  run_hook tests-ran.sh "$(bash_cmd t1 "$cmd")"
  check "tests-ran: '$cmd' is a test run" "$([[ -e "$tests_stamp" ]] && echo yes)"
done

# The stop check asks once for a test run when Rust changed after the last one.
TR="$WORK/tests-ran"
new_crate_repo "$TR" "" plain
prompt t2 "$TR"
printf '\n/// Doubles.\n#[must_use]\npub fn double(a: u8) -> u8 {\n    a.wrapping_mul(2)\n}\n' \
  >>"$TR/src/lib.rs"
expect "untested: a Rust change without a test run asks once" 2 check-on-stop.sh \
  "$(cstop t2 "$TR")" "No test run since this Rust changed"
check "untested: the message names the file" "$([[ "$out" == *"$TR/src/lib.rs"* ]] && echo yes)" \
  "$out"
expect "untested: the next stop in the same state passes" 0 check-on-stop.sh "$(cstop t2 "$TR")"
printf '// later\n' >>"$TR/src/lib.rs"
ran_tests t2
expect "untested: a test run after the change passes" 0 check-on-stop.sh "$(cstop t2 "$TR")"
printf '\n[profile.dev]\nopt-level = 1\n' >>"$TR/Cargo.toml"
expect "untested: a manifest-only change does not ask" 0 check-on-stop.sh "$(cstop t2 "$TR")"
# A file git wrote (checking out a branch under review) is not an edit: no ask. Editing it
# afterwards is, and so is a commit of an untested edit.
git -C "$TR" add -A
git -C "$TR" -c user.name=t -c user.email=t@t commit -q -m tested
git -C "$TR" checkout -q -b review
printf '// from the branch under review\n' >>"$TR/src/lib.rs"
git -C "$TR" -c user.name=t -c user.email=t@t commit -q -am "someone else's change"
git -C "$TR" checkout -q -
ran_tests t2
sleep 1.1
git -C "$TR" checkout -q review
expect "untested: a file a checkout wrote does not ask" 0 check-on-stop.sh "$(cstop t2 "$TR")"
sleep 1.1
printf '// mine\n' >>"$TR/src/lib.rs"
expect "untested: editing it after the checkout asks" 2 check-on-stop.sh \
  "$(cstop t2 "$TR")" "No test run since this Rust changed"
printf '// mine, committed\n' >>"$TR/src/lib.rs"
git -C "$TR" -c user.name=t -c user.email=t@t commit -q -am mine
expect "untested: a committed untested edit still asks" 2 check-on-stop.sh \
  "$(cstop t2 "$TR")" "No test run since this Rust changed"
# Only files a move changed are git's. Each case in its own repo and session, so no earlier
# check of the same state lets it pass.
untested_after() {
  local session="$1" repo="$WORK/untested-$1" move="$2"
  new_crate_repo "$repo" "" plain
  if [[ "$move" == merge ]]; then
    # The branch to merge exists before the session's test run: switching to it and back
    # afterwards would rewrite src/lib.rs, which then really is git's (see the hook).
    git -C "$repo" checkout -q -b side
    printf 'other\n' >"$repo/other.txt"
    git -C "$repo" add other.txt
    git -C "$repo" -c user.name=t -c user.email=t@t commit -q -m other
    git -C "$repo" checkout -q main
  fi
  prompt "$session" "$repo"
  ran_tests "$session"
  sleep 1.1
  printf '// mine\n' >>"$repo/src/lib.rs"
  if [[ "$move" != dirty ]]; then
    git -C "$repo" -c user.name=t -c user.email=t@t commit -q -am mine
  fi
  sleep 1.1
  case "$move" in
  branch | dirty) git -C "$repo" checkout -q -b elsewhere ;;
  merge) git -C "$repo" -c user.name=t -c user.email=t@t merge -q --no-edit side ;;
  esac
  expect "untested: $3" 2 check-on-stop.sh "$(cstop "$session" "$repo")" \
    "No test run since this Rust changed"
}
untested_after t4 branch "a committed edit still asks after a new branch"
untested_after t5 merge "a committed edit still asks after a merge that does not touch it"
untested_after t6 dirty "an uncommitted edit carried across a checkout asks"
# An edit committed within a second of a checkout that wrote the file: its mtime is inside
# the slack, but HEAD no longer holds what the checkout left.
QUICK="$WORK/untested-quick"
new_crate_repo "$QUICK" "" plain
git -C "$QUICK" checkout -q -b review
printf '// theirs\n' >>"$QUICK/src/lib.rs"
git -C "$QUICK" -c user.name=t -c user.email=t@t commit -q -am theirs
git -C "$QUICK" checkout -q main
prompt t7 "$QUICK"
ran_tests t7
sleep 1.1
git -C "$QUICK" checkout -q review
printf '// mine, at once\n' >>"$QUICK/src/lib.rs"
git -C "$QUICK" -c user.name=t -c user.email=t@t commit -q -am mine
expect "untested: an edit committed in the checkout's second still asks" 2 check-on-stop.sh \
  "$(cstop t7 "$QUICK")" "No test run since this Rust changed"
# A second repo's baseline is written after the edit that first touches it; the session's
# start stamp, from its first prompt, still counts that edit.
TR2="$WORK/tests-ran-2"
new_crate_repo "$TR2" "" plain
prompt t3 "$TR"
printf '\n/// Halves.\n#[must_use]\npub fn half(a: u8) -> u8 {\n    a / 2\n}\n' >>"$TR2/src/lib.rs"
run_hook fmt-on-edit.sh "$(edit t3 "$TR2/src/lib.rs" 'x')"
expect "untested: the first edit in a second repo asks" 2 check-on-stop.sh \
  "$(cstop t3 "$TR2")" "No test run since this Rust changed"
check "settings: tests-ran also runs after a failing command" "$(jq -e '
  [.hooks.PostToolUseFailure[] | select(.matcher == "Bash") | .hooks[].command
    | select(test("tests-ran"))] | length == 1' "$HOOKS/../../settings.json" >/dev/null &&
  echo yes)"

# Language checks are their own stamps. A substring of the tool name is not a run.
py_stamp="$STATE_TMP/claude-rust-hooks/t1.checks-python-style"
ts_stamp="$STATE_TMP/claude-rust-hooks/t1.checks-ts-style"
run_hook tests-ran.sh "$(bash_cmd t1 'npx eslint .')"
check "tests-ran: eslint stamps the TypeScript check" \
  "$([[ -e "$ts_stamp" ]] && echo yes)"
run_hook tests-ran.sh "$(bash_cmd t1 'uv run ty check')"
check "tests-ran: ty check stamps the Python check" \
  "$([[ -e "$py_stamp" ]] && echo yes)"
trash "$py_stamp" 2>/dev/null || true
run_hook tests-ran.sh "$(bash_cmd t1 'echo city check')"
check "tests-ran: city check is not a Python check" \
  "$([[ ! -e "$py_stamp" ]] && echo yes)"
run_hook tests-ran.sh "$(bash_cmd t1 'pytest-cov')"
check "tests-ran: pytest-cov is not a Python check" \
  "$([[ ! -e "$py_stamp" ]] && echo yes)"
trash "$ts_stamp" 2>/dev/null || true
run_hook tests-ran.sh "$(bash_cmd t1 'cat tsconfig.json')"
check "tests-ran: tsconfig is not tsc" "$([[ ! -e "$ts_stamp" ]] && echo yes)"

# Formatters do not stamp. Runners do. make and just stamp every language skill.
bash_stamp="$STATE_TMP/claude-rust-hooks/t1.checks-bash-style"
act_stamp="$STATE_TMP/claude-rust-hooks/t1.checks-gh-actions-style"
clear_lang_stamps() {
  local stamp
  for stamp in "$py_stamp" "$ts_stamp" "$bash_stamp" "$act_stamp"; do
    trash "$stamp" 2>/dev/null || true
  done
}
clear_lang_stamps
run_hook tests-ran.sh "$(bash_cmd t1 'shfmt -w -i 2 run.sh')"
check "tests-ran: shfmt -w does not stamp bash" \
  "$([[ ! -e "$bash_stamp" ]] && echo yes)"
run_hook tests-ran.sh "$(bash_cmd t1 'shfmt -d -i 2 run.sh')"
check "tests-ran: shfmt -d stamps bash" "$([[ -e "$bash_stamp" ]] && echo yes)"
clear_lang_stamps
run_hook tests-ran.sh "$(bash_cmd t1 'ruff format src')"
check "tests-ran: ruff format does not stamp python" \
  "$([[ ! -e "$py_stamp" ]] && echo yes)"
run_hook tests-ran.sh "$(bash_cmd t1 'ruff check src')"
check "tests-ran: ruff check stamps python" "$([[ -e "$py_stamp" ]] && echo yes)"
clear_lang_stamps
run_hook tests-ran.sh "$(bash_cmd t1 'ruff format --check src')"
check "tests-ran: ruff format --check stamps python" \
  "$([[ -e "$py_stamp" ]] && echo yes)"
clear_lang_stamps
run_hook tests-ran.sh "$(bash_cmd t1 'ruff format src --check')"
check "tests-ran: ruff format src --check stamps python" \
  "$([[ -e "$py_stamp" ]] && echo yes)"
clear_lang_stamps
run_hook tests-ran.sh "$(bash_cmd t1 'ruff format --diff src')"
check "tests-ran: ruff format --diff stamps python" \
  "$([[ -e "$py_stamp" ]] && echo yes)"
clear_lang_stamps
run_hook tests-ran.sh "$(bash_cmd t1 'prettier --write .')"
check "tests-ran: prettier does not stamp TypeScript" \
  "$([[ ! -e "$ts_stamp" ]] && echo yes)"
run_hook tests-ran.sh "$(bash_cmd t1 'oxfmt')"
check "tests-ran: oxfmt does not stamp TypeScript" \
  "$([[ ! -e "$ts_stamp" ]] && echo yes)"
clear_lang_stamps
run_hook tests-ran.sh "$(bash_cmd t1 'cmake --build .')"
check "tests-ran: cmake is not make" \
  "$([[ ! -e "$py_stamp" && ! -e "$bash_stamp" ]] && echo yes)"
run_hook tests-ran.sh "$(bash_cmd t1 'make test')"
check "tests-ran: make test stamps every language" "$(
  [[ -e "$py_stamp" && -e "$ts_stamp" && -e "$bash_stamp" && -e "$act_stamp" ]] &&
    echo yes
)"
clear_lang_stamps
run_hook tests-ran.sh "$(bash_cmd t1 'bash check.sh')"
check "tests-ran: bash check.sh stamps bash only" \
  "$([[ -e "$bash_stamp" && ! -e "$py_stamp" ]] && echo yes)"
clear_lang_stamps
run_hook tests-ran.sh "$(bash_cmd t1 'npm test')"
check "tests-ran: npm test stamps TypeScript, not Python" \
  "$([[ -e "$ts_stamp" && ! -e "$py_stamp" ]] && echo yes)"
clear_lang_stamps
run_hook tests-ran.sh "$(bash_cmd t1 'tox')"
check "tests-ran: tox stamps python" "$([[ -e "$py_stamp" ]] && echo yes)"

# A Python repo asks once for a Python check. cargo does not satisfy it.
PY="$WORK/py-only"
mkdir -p "$PY"
printf 'x = 1\n' >"$PY/app.py"
git -C "$PY" init -q -b main
old_commit "$PY" init
prompt py1 "$PY"
printf 'x = 2\n' >"$PY/app.py"
expect "lang-stop: a Python change asks once" 2 check-on-stop.sh \
  "$(cstop py1 "$PY")" "No check since this Python changed"
check "lang-stop: the message names the file" \
  "$([[ "$out" == *"$PY/app.py"* ]] && echo yes)" "$out"
expect "lang-stop: the next stop in the same state passes" 0 check-on-stop.sh \
  "$(cstop py1 "$PY")"
printf 'x = 3\n' >"$PY/app.py"
run_hook tests-ran.sh "$(bash_cmd py1 'cargo test')"
expect "lang-stop: cargo test does not cover Python" 2 check-on-stop.sh \
  "$(cstop py1 "$PY")" "No check since this Python changed"
printf 'x = 4\n' >"$PY/app.py"
run_hook tests-ran.sh "$(bash_cmd py1 'uv run pytest -q')"
expect "lang-stop: pytest after the write passes" 0 check-on-stop.sh \
  "$(cstop py1 "$PY")"
printf 'echo hi\n' >"$PY/run.sh"
expect "lang-stop: a shell change asks" 2 check-on-stop.sh \
  "$(cstop py1 "$PY")" "No check since this shell changed"
printf 'echo bye\n' >>"$PY/run.sh"
run_hook tests-ran.sh "$(bash_cmd py1 'shellcheck run.sh && shfmt -d -i 2 run.sh')"
expect "lang-stop: shellcheck and shfmt cover the shell change" 0 check-on-stop.sh \
  "$(cstop py1 "$PY")"

# A subagent is asked only about the language file it recorded.
PY2="$WORK/py-sub"
mkdir -p "$PY2"
printf 'a = 1\n' >"$PY2/app.py"
printf 'b = 1\n' >"$PY2/other.py"
git -C "$PY2" init -q -b main
old_commit "$PY2" init
prompt py2 "$PY2"
printf 'b = 2\n' >"$PY2/other.py"
run_hook fmt-on-edit.sh "$(edit py2 "$PY2/other.py" 'b = 2')"
printf 'a = 2\n' >"$PY2/app.py"
run_hook fmt-on-edit.sh "$(edit py2 "$PY2/app.py" 'a = 2' pysub)"
expect "lang-stop: a subagent asks about its own file" 2 check-on-stop.sh \
  "$(subagent_stop py2 "$PY2" '{"agent_id": "pysub"}')" \
  "No check since this Python changed"
check "lang-stop: a subagent is not shown the parent's file" \
  "$([[ "$out" == *app.py* && "$out" != *other.py* ]] && echo yes)" "$out"

# Recording only a Python file must not run clippy on the crate it sits in.
PYC="$WORK/py-in-crate"
new_crate_repo "$PYC" "" plain
prompt pyc "$PYC"
printf 'x = 1\n' >"$PYC/app.py"
run_hook fmt-on-edit.sh "$(edit pyc "$PYC/app.py" 'x = 1' pyonly)"
printf 'not toml\n' >"$PYC/Cargo.toml"
expect "lang-stop: a python-only subagent does not run clippy" 2 check-on-stop.sh \
  "$(subagent_stop pyc "$PYC" '{"agent_id": "pyonly"}')" \
  "No check since this Python changed"
check "lang-stop: that stop has no cargo error" \
  "$([[ "$out" != *error:* ]] && echo yes)" "$out"

# TypeScript and workflow stops ask once, and a stamp after the write clears the ask.
TS="$WORK/ts-only"
mkdir -p "$TS"
printf 'export const n = 1\n' >"$TS/app.ts"
git -C "$TS" init -q -b main
old_commit "$TS" init
prompt ts1 "$TS"
printf 'export const n = 2\n' >"$TS/app.ts"
expect "lang-stop: a TypeScript change asks once" 2 check-on-stop.sh \
  "$(cstop ts1 "$TS")" "No check since this TypeScript changed"
printf 'export const n = 3\n' >"$TS/app.ts"
run_hook tests-ran.sh "$(bash_cmd ts1 'npx vitest run')"
expect "lang-stop: vitest after the write passes" 0 check-on-stop.sh \
  "$(cstop ts1 "$TS")"
WF="$WORK/wf-only"
mkdir -p "$WF/.github/workflows"
printf 'name: ci\n' >"$WF/.github/workflows/ci.yml"
git -C "$WF" init -q -b main
old_commit "$WF" init
prompt wf1 "$WF"
printf 'name: ci\non: push\n' >"$WF/.github/workflows/ci.yml"
expect "lang-stop: a workflow change asks once" 2 check-on-stop.sh \
  "$(cstop wf1 "$WF")" "No check since this workflow changed"
printf 'name: ci\non: pull_request\n' >"$WF/.github/workflows/ci.yml"
run_hook tests-ran.sh "$(bash_cmd wf1 'actionlint')"
expect "lang-stop: actionlint after the write passes" 0 check-on-stop.sh \
  "$(cstop wf1 "$WF")"

# Vendor trees are not a language change at stop time. The Python repo above already
# passed its check; these files must not open it again.
mkdir -p "$PY/node_modules/pkg" "$PY/.venv/lib"
printf 'x = 1\n' >"$PY/node_modules/pkg/x.py"
printf 'y = 1\n' >"$PY/.venv/lib/y.py"
expect "lang-stop: node_modules and .venv are not a Python change" 0 check-on-stop.sh \
  "$(cstop py1 "$PY")"

# A Python edit in a repo that also has Rust must not repeat the Rust finding.
MX="$WORK/mixed"
new_crate_repo "$MX" "" plain
prompt mx "$MX"
printf '\nfn main_extra() { dbg!(1); }\n' >>"$MX/src/main.rs"
expect "lang-stop: a Rust change in a mixed repo runs clippy" 2 check-on-stop.sh \
  "$(cstop mx "$MX")" "dbg!"
expect "lang-stop: that Rust state passes on the next stop" 0 check-on-stop.sh \
  "$(cstop mx "$MX")"
printf 'x = 1\n' >"$MX/app.py"
expect "lang-stop: a later Python edit does not repeat the Rust finding" 2 \
  check-on-stop.sh "$(cstop mx "$MX")" "No check since this Python changed"
check "lang-stop: the Python stop does not repeat Rust" \
  "$([[ "$out" != *dbg!* && "$out" != *"this Rust changed"* ]] && echo yes)" "$out"

# A language check must not drop a Rust file the subagent has not fixed.
KEEP="$WORK/keep-rust"
new_crate_repo "$KEEP" "" plain
prompt mxkeep "$KEEP"
printf '\nfn bad() {\n    let _: u8 = "x";\n}\n' >>"$KEEP/src/lib.rs"
run_hook fmt-on-edit.sh "$(edit mxkeep "$KEEP/src/lib.rs" 'x' worker)"
expect "lang-stop: a subagent Rust error blocks" 2 check-on-stop.sh \
  "$(subagent_stop mxkeep "$KEEP" '{"agent_id": "worker"}')" "mismatched types"
printf 'x = 1\n' >"$KEEP/app.py"
run_hook fmt-on-edit.sh "$(edit mxkeep "$KEEP/app.py" 'x = 1' worker)"
run_hook tests-ran.sh "$(bash_cmd mxkeep 'uv run pytest -q')"
expect "lang-stop: pytest leaves the Rust error for later" 0 check-on-stop.sh \
  "$(subagent_stop mxkeep "$KEEP" '{"agent_id": "worker"}')"
keep_edited="$STATE_TMP/claude-rust-hooks/mxkeep.worker.edited"
check "lang-stop: the unfixed Rust file stays recorded" \
  "$(grep -q 'src/lib.rs$' "$keep_edited" && echo yes)" \
  "$(cat "$keep_edited" 2>/dev/null || true)"
printf 'pub fn extra() {}\n' >"$KEEP/src/extra.rs"
run_hook fmt-on-edit.sh "$(edit mxkeep "$KEEP/src/extra.rs" 'x' worker)"
expect "lang-stop: a later file still shows the unfixed Rust error" 2 check-on-stop.sh \
  "$(subagent_stop mxkeep "$KEEP" '{"agent_id": "worker"}')" "mismatched types"

# cargo is required only for a Rust stop. jq, git, perl, and shasum stay required.
NOCARGO="$WORK/nocargo-bin"
mkdir -p "$NOCARGO"
IFS=':' read -ra nocargo_dirs <<<"$PATH"
for dir in "${nocargo_dirs[@]}"; do
  [[ -d "$dir" ]] || continue
  for tool in "$dir"/*; do
    [[ -x "$tool" && ! -d "$tool" ]] || continue
    name="$(basename "$tool")"
    case "$name" in
    cargo | cargo-*) continue ;;
    esac
    if [[ ! -e "$NOCARGO/$name" ]]; then
      ln -s "$tool" "$NOCARGO/$name"
    fi
  done
done
PYN="$WORK/py-nocargo"
mkdir -p "$PYN"
printf 'x = 1\n' >"$PYN/app.py"
git -C "$PYN" init -q -b main
old_commit "$PYN" init
prompt pyn "$PYN"
printf 'x = 2\n' >"$PYN/app.py"
run_hook check-on-stop.sh "$(cstop pyn "$PYN")" "$NOCARGO"
check "lang-stop: Python without cargo still asks" "$(
  [[ $code -eq 2 && "$out" == *"this Python changed"* && "$out" != *"missing tool"* ]] &&
    echo yes
)" "exit $code: $out"
RN="$WORK/rust-nocargo"
mkdir -p "$RN/src"
printf 'fn main() {}\n' >"$RN/src/main.rs"
git -C "$RN" init -q -b main
old_commit "$RN" init
prompt rn "$RN"
printf 'fn main() { let _ = 1; }\n' >"$RN/src/main.rs"
run_hook check-on-stop.sh "$(cstop rn "$RN")" "$NOCARGO"
check "lang-stop: Rust without cargo still names the missing tool" "$(
  [[ $code -eq 2 && "$out" == *"missing tool"* && "$out" == *cargo* ]] && echo yes
)" "exit $code: $out"
check "lang-stop: Rust without cargo does not ask for a cargo test run" "$(
  [[ "$out" != *"No test run since this Rust changed"* ]] && echo yes
)" "$out"
# The next turn's stop, with the same Rust, was told already: it passes and keeps the file.
run_hook check-on-stop.sh "$(cstop rn "$RN")" "$NOCARGO"
check "lang-stop: missing cargo blocks once per Rust state" "$([[ $code -eq 0 ]] && echo yes)" \
  "exit $code: $out"
printf 'fn main() { let _ = 2; }\n' >"$RN/src/main.rs"
run_hook check-on-stop.sh "$(cstop rn "$RN")" "$NOCARGO"
check "lang-stop: missing cargo blocks again once the Rust changes" "$(
  [[ $code -eq 2 && "$out" == *"missing tool"* ]] && echo yes
)" "exit $code: $out"
check "subagent stop: no empty state file for an agent with no edits" "$(
  run_hook check-on-stop.sh "$(jq -nc '{session_id: "noedit", hook_event_name: "SubagentStop",
    agent_id: "a1", cwd: "/"}')"
  compgen -G "$STATE_TMP/claude-rust-hooks/noedit.a1.edited" >/dev/null || echo yes
)"
MXN="$WORK/mixed-nocargo"
new_crate_repo "$MXN" "" plain
prompt mxn "$MXN"
printf '\nfn marker() {}\n' >>"$MXN/src/main.rs"
printf 'x = 1\n' >"$MXN/app.py"
run_hook check-on-stop.sh "$(cstop mxn "$MXN")" "$NOCARGO"
check "lang-stop: missing cargo still asks about Python" "$(
  [[ $code -eq 2 && "$out" == *"missing tool"* && "$out" == *"this Python changed"* ]] &&
    echo yes
)" "exit $code: $out"

# Grok's stop fields: camelCase stopHookActive, and the observe-only stop at session end.
GS="$WORK/grok-stop"
mkdir -p "$GS"
printf 'x = 1\n' >"$GS/app.py"
git -C "$GS" init -q -b main
old_commit "$GS" init
prompt gs "$GS"
printf 'x = 2\n' >"$GS/app.py"
run_hook check-on-stop.sh "$(cstop gs "$GS" '{"reason": "shutdown"}')" "$NOCARGO"
check "grok stop: the shutdown stop never blocks" "$([[ $code -eq 0 ]] && echo yes)" \
  "exit $code: $out"
run_hook check-on-stop.sh "$(cstop gs "$GS" '{"reason": "channel_closed"}')" "$NOCARGO"
check "grok stop: channel_closed never blocks" "$([[ $code -eq 0 ]] && echo yes)" \
  "exit $code: $out"
run_hook check-on-stop.sh "$(cstop gs "$GS" '{"stopHookActive": true}')" "$NOCARGO"
check "grok stop: stopHookActive passes" "$([[ $code -eq 0 ]] && echo yes)" "exit $code: $out"
printf 'x = 3\n' >"$GS/app.py"
run_hook check-on-stop.sh "$(cstop gs "$GS" '{"stopHookActive": false}')" "$NOCARGO"
check "grok stop: a real stop still asks after those" "$(
  [[ $code -eq 2 && "$out" == *"this Python changed"* ]] && echo yes
)" "exit $code: $out"

# Cursor names the edited file tool_input.path.
expect "cursor: tool_input.path is gated" 2 style-gate.sh "$(jq -nc --arg p "$LIB/src/c.rs" \
  '{session_id: "cur1", tool_name: "Edit", tool_input: {path: $p, new_string: "fn a() {}"}}')" \
  "$SKILL/SKILL.md"

# The early exits: a Skill call still records (its input names no path), and a test run
# whose output comes before its command still counts.
run_hook style-loaded.sh "$(skill early1)"
check "style-loaded: a Skill call passes the early exit" "$(
  [[ -f "$STATE_TMP/claude-rust-hooks/early1.main.style-loaded" ]] && echo yes
)"
run_hook tests-ran.sh '{"session_id": "early2", "tool_response": {"stdout": "ok"},
  "tool_name": "Bash", "tool_input": {"command": "cargo test"}}'
check "tests-ran: output before the command still counts" "$(
  [[ -f "$STATE_TMP/claude-rust-hooks/early2.tests-ran" ]] && echo yes
)"
run_hook tests-ran.sh '{"session_id": "early3", "tool_name": "Bash",
  "tool_input": {"command": "ls"}, "tool_response": {"stdout": "cargo test"}}'
check "tests-ran: output that names a test run is no test run" "$(
  [[ ! -e "$STATE_TMP/claude-rust-hooks/early3.tests-ran" ]] && echo yes
)"

# Daily prune of the hook state: old session files and old review snapshots go, recent
# ones stay, and a second prompt the same day does not scan again.
PS="$STATE_TMP/claude-rust-hooks"
mkdir -p "$PS/review-prunetest"
touch -t 202001010000 "$PS/prune-old.main.edited" "$PS/review-prunetest/old.abc"
touch "$PS/prune-new.main.edited" "$PS/review-prunetest/new.abc"
# A live session keeps its old files: started and baselines are written once.
touch -t 202001010000 "$PS/prune-live.started"
touch "$PS/prune-live.main.edited"
rm -f "$PS/pruned"
prompt prune1 "$WORK"
check "prune: old session file deleted" "$([[ ! -e "$PS/prune-old.main.edited" ]] && echo yes)"
check "prune: a live session's old file kept" "$([[ -e "$PS/prune-live.started" ]] && echo yes)"
check "prune: the prompting session is marked seen" "$([[ -e "$PS/prune1.seen" ]] && echo yes)"
check "prune: old snapshot deleted" "$([[ ! -e "$PS/review-prunetest/old.abc" ]] && echo yes)"
check "prune: recent files kept" "$([[ -e "$PS/prune-new.main.edited" &&
  -e "$PS/review-prunetest/new.abc" ]] && echo yes)"
touch -t 202001010000 "$PS/prune-old2.main.edited"
prompt prune2 "$WORK"
check "prune: at most once a day" "$([[ -e "$PS/prune-old2.main.edited" ]] && echo yes)"

# ---- 4. bash guard ---------------------------------------------------------------------------

GUARD="$HOOKS/../guards/bash-guard.sh"
GREPO="$WORK/guard-repo"
mkdir -p "$GREPO"
git -C "$GREPO" init -q -b main
git -C "$GREPO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
# guard NAME WANT COMMAND: the guard exits WANT for COMMAND run in GREPO.
guard() {
  local code=0
  jq -nc --arg c "$3" --arg d "$GREPO" '{tool_input: {command: $c}, cwd: $d}' |
    bash "$GUARD" >/dev/null 2>&1 || code=$?
  check "guard: $1 (exit $code, want $2)" "$([[ $code -eq $2 ]] && echo yes)"
}
# Built from parts so the strings never trip the guard of the shell running this file.
rm_r="rm -""r"
guard "rm -r blocked" 2 "$rm_r build"
guard "rm -v -r -f blocked" 2 "rm -v -""r -f build"
guard "rm --recursive blocked" 2 "rm --""recursive build"
guard "absolute rm path blocked" 2 "/bin/$rm_r""f build"
guard "find -delete blocked" 2 "find . -name '*.o' -""delete"
guard "plain rm passes" 0 "rm -f a.txt"
guard "git rm -r passes" 0 "git $rm_r --cached dir"
guard "word ending in rm passes" 0 "terraform -refresh=false"
guard "rm after ; checked" 2 "ls; $rm_r x"
guard "push on main without refspec blocked" 2 "git push"
guard "push -u origin on main blocked" 2 "git push -u origin"
guard "push origin HEAD on main blocked" 2 "git push origin HEAD"
guard "push explicit main blocked" 2 "git push origin main"
guard "push HEAD:main blocked" 2 "git push origin +HEAD:refs/heads/main"
guard "push --all blocked" 2 "git push --all origin"
guard "push after && blocked" 2 "git add . && git commit -m x && git push"
# Prefixes and global options do not hide a push to main.
guard "sudo push main blocked" 2 "sudo git push origin main"
guard "env push main blocked" 2 "env GIT_TRACE=1 git push origin main"
guard "full-path push main blocked" 2 "/usr/bin/git push origin main"
guard "push after then blocked" 2 "if true; then git push; fi"
guard "git -c k=v push blocked" 2 "git -c push.default=current push"
guard "git --no-pager push main blocked" 2 "git --no-pager push origin main"
guard "git --git-dir dir push main blocked" 2 "git --git-dir .git push origin main"
guard "bash -c push main blocked" 2 "bash -c \"git push origin main\""
guard "ssh push main blocked" 2 "ssh host 'cd repo && git push origin main'"
guard "git --attr-source tree push main blocked" 2 "git --attr-source HEAD push origin main"
guard "sudo -u git git push main blocked" 2 "sudo -u git git push origin main"
guard "push after a single & blocked" 2 "true &git push origin main"
guard "push in backticks blocked" 2 "echo \`git push origin main\`"
guard "sudo push feature passes" 0 "sudo git push origin feature"
guard "git -c k=v push feature passes" 0 "git -c a=b push origin feature"
guard "push maintenance passes" 0 "git push origin maintenance"
git -C "$GREPO" checkout -q -b feature
guard "push on a feature branch passes" 0 "git push -u origin"
guard "push HEAD on a feature branch passes" 0 "git push origin HEAD"
guard "sudo push on a feature branch passes" 0 "sudo git push -u origin"
guard "--no-pager push HEAD on a feature branch passes" 0 "git --no-pager push -u origin HEAD"
guard "bash -c push feature passes" 0 "bash -c \"git push origin feature\""
guard "push with 2>&1 on a feature branch passes" 0 "git push -u origin HEAD 2>&1"
guard "push feature:main from a feature branch blocked" 2 "git push origin feature:main"
git -C "$GREPO" checkout -q main
guard "cd into a repo on main, then push, blocked" 2 "cd $WORK && cd guard-repo && git push"
guard "(cd repo && git push) subshell blocked" 2 "ls && (cd $GREPO && git push -u origin)"
guard "cd elsewhere after the push is irrelevant" 2 "git push; cd /"
guard "cd to a non-repo, then push, passes" 0 "cd / && git push"
git -C "$GREPO" checkout -q feature
guard "cd to a feature branch repo, then push, passes" 0 "cd / && cd $GREPO && git push"
guard "git -C into a non-repo passes" 0 "git -C $LIB push"
git -C "$LIB" init -q -b main
guard "git -C resolves the other repo's branch" 2 "git -C $LIB push"
guard "a second relative -C resolves against the first" 2 "git -C $LIB -C . push"

# Quoted text and heredoc bodies are data; text handed to a shell is code.
guard "rm -r in a commit message passes" 0 "git commit -m \"stop using $rm_r in scripts\""
guard "rm -r in a single-quoted grep pattern passes" 0 "grep -n '$rm_r''f' ."
guard "rm -r in a heredoc body passes" 0 $'git commit -F - <<\'EOF\'\n'"$rm_r x"$'\nEOF'
guard "code after a heredoc still checked" 2 $'cat <<EOF >f\nx\nEOF\n'"$rm_r x"
guard "quoted path to rm -r still blocked" 2 "$rm_r \"my dir\""
guard "bash -c with rm -r blocked" 2 "bash -c \"$rm_r x\""
guard "pipe into sh with rm -r blocked" 2 "echo '$rm_r x' | sh"
guard "command substitution in quotes blocked" 2 "echo \"\$($rm_r x)\""
guard "push in a commit message passes" 0 "git commit -m 'then git push origin main'"
guard "quoted refspec main still blocked" 2 "git push origin \"main\""

# Commands that throw away uncommitted work: trash cannot bring it back.
guard "git clean -fdx blocked" 2 "git clean -fdx"
guard "git clean --force blocked" 2 "git -C $GREPO clean --force -d"
guard "git clean -n passes" 0 "git clean -n -d"
guard "git clean dry run with -f passes" 0 "git clean -fdn"
guard "git reset --hard blocked" 2 "git fetch && git reset --hard origin/main"
guard "git reset --soft passes" 0 "git reset --soft HEAD~1"
guard "checkout of the whole tree blocked" 2 "git checkout -- ."
guard "restore of the whole tree blocked" 2 "git restore :/"
guard "checkout of one file passes" 0 "git checkout -- src/x.rs"
guard "checkout of a branch passes" 0 "git checkout feature"
guard "restore --staged of the tree passes" 0 "git restore --staged ."
guard "restore --staged --worktree of the tree blocked" 2 "git restore --staged --worktree ."

# The leftmost quote wins: an apostrophe inside "..." does not hide the code after it.
guard "apostrophe in a message does not hide a recursive rm" 2 \
  "git commit -m \"it's fixed\" && $rm_r""f target && echo 'ok'"
guard "apostrophe in a message does not hide a push to main" 2 \
  "git commit -m \"don't block\" && git push origin main && echo 'pushed'"
guard "an escaped quote opens nothing" 2 "echo don\\'t && $rm_r""f target && echo 'ok'"
guard "apostrophe then a quoted rm mention passes" 0 \
  "git commit -m \"it's\" && grep 'x' f && git commit -m \"drop $rm_r""f usage\""
# Mentions of a shell hand-off in data are data too; a real hand-off is still checked whole.
guard "eval and rm -r in a message pass" 0 "git commit -m \"no eval, no $rm_r""f\""
guard "bash -c in a heredoc message passes" 0 \
  $'git commit -F - <<\'EOF\'\nStop using bash -c and '"$rm_r"$'f in scripts\nEOF'
guard "a path named eval passes" 0 "grep -rn \"$rm_r""f\" src/eval/"
guard "ssh with a remote rm -r blocked" 2 "ssh host '$rm_r""f /srv/app'"
guard "bash --norc -c blocked" 2 "bash --norc -c '$rm_r build'"
guard "a backslash continuation is one command" 2 $'git reset \\\n  --hard origin/feature'
# git global options and env prefixes do not hide a discard; forced checkouts are discards.
guard "git -c key=value reset --hard blocked" 2 "git -c core.quotepath=off reset --hard"
guard "git --no-pager reset --hard blocked" 2 "git --no-pager reset --hard HEAD"
guard "env prefix reset --hard blocked" 2 "GIT_TRACE=1 git reset --hard"
guard "env git reset --hard blocked" 2 "env GIT_TRACE=1 git reset --hard"
guard "sudo git clean -f blocked" 2 "sudo git clean -fd"
guard "command git checkout . blocked" 2 "command git checkout -- ."
guard "full-path git reset --hard blocked" 2 "/usr/bin/git reset --hard"
guard "git reset --hard after then blocked" 2 "if true; then git reset --hard; fi"
guard "git reset --hard in a loop body blocked" 2 "for r in a; do git -C \$r reset --hard; done"
guard "time git switch -f blocked" 2 "time git switch -f feature"
guard "quoted mention of reset --hard passes" 0 "git commit -m 'never git reset --hard'"
guard "bash -c git reset --hard blocked" 2 "bash -c \"git reset --hard\""
guard "ssh git clean -f blocked" 2 "ssh host 'cd repo && git clean -fd'"
guard "eval git checkout . blocked" 2 "eval \"git checkout .\""
guard "git -P reset --hard blocked" 2 "git -P reset --hard"
guard "git --git-dir dir reset --hard blocked" 2 "git --git-dir .git reset --hard"
guard "git --work-tree dir checkout . blocked" 2 "git --work-tree /x checkout ."
guard "git --namespace ns reset --hard blocked" 2 "git --namespace ns reset --hard"
guard "git --attr-source tree reset --hard blocked" 2 "git --attr-source HEAD reset --hard"
guard "reset --hard after a single & blocked" 2 "true &git reset --hard"
guard "a word ending in git passes" 0 "legit reset --hard"
guard "a dot before git is no boundary" 0 "cat .git reset --hard"
guard "a dash before git is no boundary" 0 "my-git reset --hard"
guard "checkout -f blocked" 2 "git checkout -f feature"
guard "switch --discard-changes blocked" 2 "git switch --discard-changes feature"
guard "switch to a branch passes" 0 "git switch -c feature"

guard "gh pr merge --admin blocked" 2 "gh pr merge 7 --squash --admin"
guard "env prefix gh pr merge --admin blocked" 2 "FOO=1 gh pr merge 7 --admin"
guard "two env prefixes gh pr merge --admin blocked" 2 \
  "A=1 B=x gh pr merge 7 --admin"
guard "env gh pr merge --admin blocked" 2 "env FOO=1 gh pr merge 7 --admin"
guard "sudo gh pr merge --admin blocked" 2 "sudo gh pr merge 7 --admin"
guard "full-path gh pr merge --admin blocked" 2 "/opt/homebrew/bin/gh pr merge 7 --admin"
guard "gh after then blocked" 2 "if true; then gh pr merge 7 --admin; fi"
guard "gh -R o/r pr merge --admin blocked" 2 "gh -R o/r pr merge 7 --admin"
guard "gh --repo=o/r pr merge --admin blocked" 2 "gh --repo=o/r pr merge 7 --admin"
# A removed ALLOW_ADMIN_MERGE exception matched anywhere in the line, so an allowed-looking
# first command unlocked an admin merge in a later one. This keeps that from coming back.
guard "admin merge chained after an allowed-looking merge blocked" 2 \
  "BYPASS=1 gh pr merge 1 && gh pr merge 9 --admin --repo o/r"
guard "gh pr merge passes" 0 "gh pr merge 7 --squash"
guard "env prefix gh pr merge passes" 0 "GH_DEBUG=1 gh pr merge 7 --squash"
guard "--admin in a later command passes" 0 "gh pr merge 7 --squash; echo --admin"
guard "quoted mention passes" 0 "git commit -m 'block gh pr merge 7 --admin'"
# cargo mutants: at most 2 jobs, and the auto test timeout (TST-20).
guard "mutants -j 4 blocked" 2 "cargo mutants --in-diff d -p s3-api -j 4"
guard "mutants -j4 blocked" 2 "cargo mutants -j4"
guard "mutants --jobs=3 blocked" 2 "cargo mutants --jobs=3"
guard "mutants --jobs 8 blocked" 2 "cargo mutants --jobs 8"
guard "mutants --timeout 300 blocked" 2 "cargo mutants --timeout 300"
guard "mutants --timeout=60 blocked" 2 "cargo mutants --timeout=60"
guard "mutants -t 60 blocked" 2 "cargo mutants -t 60"
guard "mutants -t60 blocked" 2 "cargo mutants -t60"
guard "mutants --baseline=skip blocked" 2 "cargo mutants --baseline=skip"
guard "mutants --baseline skip blocked" 2 "cargo mutants --baseline skip"
guard "toolchain mutants -j 4 blocked" 2 "cargo +nightly mutants -j 4"
guard "direct cargo-mutants -j 4 blocked" 2 "cargo-mutants mutants -j 4"
guard "mutants after cd && blocked" 2 "cd repo && cargo mutants -j 4 -o out > log 2>&1"
guard "CARGO_MUTANTS_JOBS=4 prefix blocked" 2 "CARGO_MUTANTS_JOBS=4 cargo mutants"
guard "exported CARGO_MUTANTS_JOBS=4 blocked" 2 "export CARGO_MUTANTS_JOBS=4; cargo mutants"
guard "mutants -j 2 passes" 0 "cargo mutants --in-diff d -p s3-api -j 2"
guard "mutants -j 1 passes" 0 "cargo mutants -j1"
guard "mutants default passes" 0 "cargo mutants --in-diff d"
guard "CARGO_MUTANTS_JOBS=2 passes" 0 "CARGO_MUTANTS_JOBS=2 cargo mutants"
guard "mutants --timeout-multiplier passes" 0 "cargo mutants --timeout-multiplier 2"
guard "mutants --minimum-test-timeout passes" 0 "cargo mutants --minimum-test-timeout 30"
guard "mutants --test-tool passes" 0 "cargo mutants --test-tool nextest"
guard "mutants --baseline=run passes" 0 "cargo mutants --baseline=run"
guard "test runner args after -- pass" 0 "cargo mutants -j 2 -- --test-threads 8 -t"
guard "cargo build -j 8 passes" 0 "cargo build -j 8"
guard "cargo install cargo-mutants -j 8 passes" 0 "cargo install cargo-mutants -j 8"
guard "quoted mutants mention passes" 0 "git commit -m 'never cargo mutants -j 4'"

# Force pushes, to any branch. The refspec is named, so the current branch does not matter.
guard "push -f blocked" 2 "git push -f origin feature"
guard "push --force blocked" 2 "git push --force origin feature"
guard "push --force-with-lease blocked" 2 "git push --force-with-lease origin feature"
guard "push --force-with-lease=ref blocked" 2 \
  "git push --force-with-lease=feature:abc origin feature"
guard "push -uf blocked" 2 "git push -uf origin feature"
guard "push +refspec blocked" 2 "git push origin +feature"
guard "push +src:dst blocked" 2 "git push origin +HEAD:feature"
guard "git -C dir push --force blocked" 2 "git -C $GREPO push --force origin feature"
guard "bash -c push -f blocked" 2 "bash -c \"git push -f origin feature\""
guard "push -f after && blocked" 2 "git commit -m x && git push -f origin feature"
guard "push -u passes" 0 "git push -u origin feature"
guard "push --follow-tags passes" 0 "git push --follow-tags origin feature"
guard "push --force-if-includes alone passes" 0 "git push --force-if-includes origin feature"
guard "push -o value with an f passes" 0 "git push -o notify=off origin feature"
guard "quoted force push mention passes" 0 "git commit -m 'never git push -f origin feature'"

# Stashed work, and the branch delete that is allowed on purpose.
guard "stash drop blocked" 2 "git stash drop"
guard "stash drop of one entry blocked" 2 "git -C $GREPO stash drop stash@{1}"
guard "stash clear blocked" 2 "git stash clear"
guard "stash passes" 0 "git stash"
guard "stash pop passes" 0 "git stash pop"
guard "stash list passes" 0 "git stash list"
guard "quoted stash drop mention passes" 0 "git commit -m 'never git stash drop'"
guard "branch -D passes" 0 "git branch -D feature"

# A pipe into a shell that runs a script file is data for that script, so quoted text in the
# command stays data; a pipe into a shell that reads its script from stdin is code.
guard "pipe into bash file: quoted rm -r passes" 0 "echo '{}' | bash hook.sh; grep '$rm_r x' log"
guard "pipe into bash file with a quoted arg passes" 0 "cat in | bash hook.sh '$rm_r x'"
guard "pipe into bash file: unquoted rm -r blocked" 2 "cat in | bash hook.sh && $rm_r x"
guard "pipe into bash blocked" 2 "echo '$rm_r x' | bash"
guard "pipe into bash, then more, blocked" 2 "echo '$rm_r x' | bash; ls"
guard "pipe into bash with a redirect blocked" 2 "echo '$rm_r x' | bash >/dev/null 2>&1"
guard "pipe into bash -s with args blocked" 2 "echo '$rm_r x' | bash -s arg"
guard "pipe into bash -es blocked" 2 "echo '$rm_r x' | bash -es -- arg"
guard "pipe into bash - blocked" 2 "echo '$rm_r x' | bash -"
guard "pipe into sh --posix blocked" 2 "echo '$rm_r x' | sh --posix"
guard "pipe into bash on the next line blocked" 2 "echo '$rm_r x' | bash"$'\n'"ls"
# Options that take a value are not a script operand; a path to the shell is still a shell.
guard "pipe into bash -euo pipefail blocked" 2 "echo '$rm_r x' | bash -euo pipefail"
guard "pipe into bash -o pipefail blocked" 2 "echo '$rm_r x' | bash -o pipefail"
guard "pipe into bash -o errexit -s blocked" 2 "echo '$rm_r x' | bash -o errexit -s"
guard "pipe into bash, then a comment, blocked" 2 "echo '$rm_r x' | bash # run it"
guard "pipe into bash /dev/stdin blocked" 2 "echo '$rm_r x' | bash /dev/stdin"
guard "pipe into /bin/bash blocked" 2 "echo '$rm_r x' | /bin/bash"
guard "bash -euo pipefail -c blocked" 2 "bash -euo pipefail -c '$rm_r x'"
guard "pipe into bash -x file passes" 0 "echo '$rm_r x' | bash -x hook.sh"
guard "pipe into bash -o pipefail file passes" 0 "echo '$rm_r x' | bash -o pipefail hook.sh"
guard "pipe into bash file -s passes" 0 "echo '$rm_r x' | bash hook.sh -s"
guard "|| before a shell is not a pipe" 0 "make || sh; echo '$rm_r x'"
guard "stash apply, then drop, blocked" 2 "git stash apply && git stash drop"

# A command substitution or a redirection among a push's words: simple_commands splits at
# both, so the push is also walked with them flattened. GREPO is on feature, LIB on main.
sub="\$(git branch --show-current)"
guard "force after a quoted substitution blocked" 2 "git push origin \"$sub\" --force-with-lease"
guard "force after a bare substitution blocked" 2 "git push -u origin $sub -f"
guard "force after backticks blocked" 2 "git push origin \`git branch --show-current\` -f"
guard "force after the refspec blocked" 2 "git push origin feature --force"
guard "push -f without a refspec blocked" 2 "git push -f"
guard "abbreviated --force-with-leas blocked" 2 "git push --force-with-leas origin feature"
guard "push of a substitution on a feature branch passes" 0 "git push -u origin \"$sub\""
guard "push of a substitution on main blocked" 2 "git -C $LIB push origin \"$sub\""
guard "push with 2>&1 on main blocked" 2 "git -C $LIB push origin 2>&1"
guard "push with 2>&1 | tail on main blocked" 2 "git -C $LIB push -u origin 2>&1 | tail -3"
guard "push of a named branch with redirects passes" 0 "git push origin feature >push.log 2>&1"
guard "a push inside a substitution is still seen" 2 "echo \"\$(git push origin main)\""

printf '%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
