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
TEMPLATE="$HOME/.claude/skills/rust-style/templates/Cargo.lints.toml"
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
done
ln -s "$HOME/.claude/skills/rust-style/templates" "$SKILL/templates"

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
# Waits for the next second. The hooks tell the session's commits from earlier ones by
# reflog time, in whole seconds, and count a tie as the session's; a test that commits and
# then starts a session (or reviews) in the same second would see that tie.
next_second() {
  local now
  now="$(date +%s)"
  while (($(date +%s) == now)); do
    sleep 0.1
  done
}
# The session's first prompt in repo $2: records its baseline (session-baseline.sh).
prompt() {
  next_second
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

# Review gate: changed set since the session's baseline plus every agent's recorded paths,
# session-caused repos only, threshold, snapshot at the reviewer's SubagentStop, Claude and
# Grok stop fields.
lines() { for ((i = $2; i < $2 + $3; i++)); do printf 'pub fn f%d() {}\n' "$i"; done >>"$1"; }
commit_all() {
  git -C "$1" add -A
  git -C "$1" -c user.name=t -c user.email=t@t commit -qm "${2:-snapshot}"
}
# commit_all an hour ago: work from before the session, which the hooks tell from the
# session's own by its reflog time.
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
# Others' work arriving in repo $1 as branch $2: what commands $3... do in a separate clone
# (cwd the clone), committed there and pushed back, as a teammate's push or a GitHub merge
# arrives.
arrive() {
  local repo="$1" branch="$2" clone="$1-elsewhere"
  shift 2
  git clone -q "$repo" "$clone"
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
REPO="$WORK/repo"
new_repo "$REPO"
prompt r1 "$REPO"
lines "$REPO/src/lib.rs" 5 3
run_hook fmt-on-edit.sh "$(edit r1 "$REPO/src/lib.rs" 'x')"
expect "review: small diff passes" 0 review-gate.sh "$(rstop r1 "$REPO")"
lines "$REPO/src/lib.rs" 8 20
expect "review: large diff blocked" 2 review-gate.sh "$(rstop r1 "$REPO")" \
  "since this session started"
check "review: message lists the file" "$([[ "$out" == *"$REPO/src/lib.rs"* ]] && echo yes)" "$out"
expect "review: a later turn with no new Rust change passes" 0 review-gate.sh "$(rstop r1 "$REPO")"
# Forgets the last block of session $1, so the same state is judged again.
unblock() { : >"$STATE_TMP/claude-rust-hooks/$1.main.review-blocked"; }
expect "review: stop_hook_active passes" 0 review-gate.sh \
  "$(rstop r1 "$REPO" '{"stop_hook_active": true}')"
expect "review: grok stopHookActive passes" 0 review-gate.sh \
  "$(rstop r1 "$REPO" '{"stopHookActive": true}')"
expect "review: grok shutdown passes" 0 review-gate.sh \
  "$(rstop r1 "$REPO" '{"reason": "shutdown"}')"
unblock r1
expect "review: grok end_turn checked" 2 review-gate.sh \
  "$(rstop r1 "$REPO" '{"reason": "end_turn"}')"
expect "review: Claude subagent skipped" 0 review-gate.sh "$(rstop r1 "$REPO" '{"agent_id": "a1"}')"
expect "review: grok subagent skipped" 0 review-gate.sh \
  "$(rstop r1 "$REPO" '{"subagentType": "x"}')"
run_hook review-done.sh "$(subagent_stop r1 "$REPO" '{"agent_id": "a2", "agent_type": "Explore"}')"
unblock r1
expect "review: other agent type does not count" 2 review-gate.sh "$(rstop r1 "$REPO")"
run_hook review-done.sh \
  "$(subagent_stop r1 "$REPO" '{"agent_id": "a3", "agent_type": "rust-style-reviewer"}')"
expect "review: passes after reviewer (Claude agent_type)" 0 review-gate.sh "$(rstop r1 "$REPO")"
lines "$REPO/src/lib.rs" 28 3
expect "review: 3-line fix after review passes" 0 review-gate.sh "$(rstop r1 "$REPO")"
lines "$REPO/src/lib.rs" 31 25
expect "review: 25 lines after review block" 2 review-gate.sh "$(rstop r1 "$REPO")" \
  "since the last review"
run_hook review-done.sh \
  "$(subagent_stop grok-child "$REPO" '{"subagentType": "rust-style-reviewer"}')"
expect "review: grok reviewer in its own session counts for the repo" 0 review-gate.sh \
  "$(rstop r1 "$REPO")"
lines "$REPO/src/later.rs" 0 25
expect "review: unrecorded (Bash) untracked file counts" 2 review-gate.sh "$(rstop r1 "$REPO")" \
  "src/later.rs"

REPO2="$WORK/repo2"
new_repo "$REPO2"
prompt r5 "$REPO2"
lines "$REPO2/src/lib.rs" 5 25
expect "review: unrecorded (Bash) edit to a tracked file counts" 2 review-gate.sh \
  "$(rstop r5 "$REPO2")" "$REPO2/src/lib.rs"

# B1: committing before the stop hides nothing.
REPO3="$WORK/repo3"
new_repo "$REPO3"
prompt r6 "$REPO3"
lines "$REPO3/src/lib.rs" 5 25
commit_all "$REPO3" "agent commit"
expect "review: committed changes still count" 2 review-gate.sh "$(rstop r6 "$REPO3")" \
  "$REPO3/src/lib.rs"

# B1: after a rebase the baseline is no longer an ancestor of HEAD; measure from the
# merge-base with the default branch (25 lines), neither from HEAD (0) nor from the stale
# baseline (45).
REPO4="$WORK/repo4"
new_repo "$REPO4"
git -C "$REPO4" checkout -q -b feature
lines "$REPO4/src/lib.rs" 5 20
commit_all "$REPO4" "feature work"
prompt r7 "$REPO4"
git -C "$REPO4" reset -q --hard main
lines "$REPO4/src/lib.rs" 100 25
commit_all "$REPO4" "rewritten"
run_hook fmt-on-edit.sh "$(edit r7 "$REPO4/src/lib.rs" 'x')"
expect "review: rebased baseline falls back to the merge-base (25 lines)" 2 review-gate.sh \
  "$(rstop r7 "$REPO4")" "changed 25 lines"
REPO4B="$WORK/repo4b"
new_repo "$REPO4B"
git -C "$REPO4B" checkout -q -b feature
lines "$REPO4B/src/lib.rs" 5 40
commit_all "$REPO4B" "feature work"
prompt r8 "$REPO4B"
git -C "$REPO4B" reset -q --hard main
lines "$REPO4B/src/lib.rs" 100 5
commit_all "$REPO4B" "rewritten small"
run_hook fmt-on-edit.sh "$(edit r8 "$REPO4B/src/lib.rs" 'x')"
expect "review: stale baseline not used after a rebase (5 lines)" 0 review-gate.sh \
  "$(rstop r8 "$REPO4B")"

# Commits that only arrive are not the session's: a fast-forward to work merged elsewhere,
# or a checkout of main after the session's pull request merged. Its own commits still
# count, through the merge, and a merge it finishes by hand counts only the hand-written
# part.
ARR_FF="$WORK/arr-ff"
new_repo "$ARR_FF"
git -C "$ARR_FF" checkout -q -b upstream
lines "$ARR_FF/src/lib.rs" 5 40
old_commit "$ARR_FF" "merged elsewhere"
git -C "$ARR_FF" checkout -q main
prompt r9 "$ARR_FF"
git -C "$ARR_FF" merge -q --ff-only upstream
expect "review: a fast-forward to others' work passes" 0 review-gate.sh "$(rstop r9 "$ARR_FF")"
lines "$ARR_FF/src/own.rs" 0 25
commit_all "$ARR_FF" "own work"
expect "review: own commit after a fast-forward counts (25 lines)" 2 review-gate.sh \
  "$(rstop r9 "$ARR_FF")" "changed 25 lines"

ARR_PR="$WORK/arr-pr"
new_repo "$ARR_PR"
git -C "$ARR_PR" checkout -q -b feature
prompt r10 "$ARR_PR"
lines "$ARR_PR/src/lib.rs" 5 3
commit_all "$ARR_PR" "own fix"
# Elsewhere: 40 lines of others' work on main, then the feature branch merged into it, as
# GitHub merges a pull request.
merge_feature() {
  git checkout -q main
  lines src/other.rs 0 40
  commit_all . "others' work"
  git -c user.name=t -c user.email=t@t merge -q --no-ff origin/feature -m "Merge pull request"
}
arrive "$ARR_PR" main merge_feature
git -C "$ARR_PR" checkout -q main
expect "review: checkout of main after the merge passes (3 own lines)" 0 review-gate.sh \
  "$(rstop r10 "$ARR_PR")"
lines "$ARR_PR/src/lib.rs" 8 20
expect "review: own commit inside the merge still counts (23 lines)" 2 review-gate.sh \
  "$(rstop r10 "$ARR_PR")" "changed 23 lines"

ARR_HAND="$WORK/arr-hand"
new_repo "$ARR_HAND"
git -C "$ARR_HAND" checkout -q -b other
perl -pi -e 's/f0\(/other0(/' "$ARR_HAND/src/lib.rs"
lines "$ARR_HAND/src/big.rs" 0 40
old_commit "$ARR_HAND" "other side"
git -C "$ARR_HAND" checkout -q main
perl -pi -e 's/f0\(/main0(/' "$ARR_HAND/src/lib.rs"
old_commit "$ARR_HAND" "main side"
prompt r11 "$ARR_HAND"
git -C "$ARR_HAND" merge -q other >/dev/null 2>&1 || true
git -C "$ARR_HAND" checkout -q --ours src/lib.rs
git -C "$ARR_HAND" add -A
git -C "$ARR_HAND" -c user.name=t -c user.email=t@t commit -q --no-edit
expect "review: a merge finished by hand counts the resolution only" 0 review-gate.sh \
  "$(rstop r11 "$ARR_HAND")"

# After a review, work that arrives in a reviewed file moves its snapshot diff but is not
# the session's: a small fix on top passes.
ARR_REV="$WORK/arr-rev"
new_repo "$ARR_REV"
prompt r12 "$ARR_REV"
lines "$ARR_REV/src/lib.rs" 5 25
commit_all "$ARR_REV" "own work"
next_second
run_hook review-done.sh \
  "$(subagent_stop r12 "$ARR_REV" '{"agent_id": "rv", "agent_type": "rust-style-reviewer"}')"
arrive "$ARR_REV" upstream lines src/lib.rs 30 40
git -C "$ARR_REV" merge -q --ff-only upstream
lines "$ARR_REV/src/lib.rs" 70 3
expect "review: arrivals after a review do not count against it (3 lines)" 0 review-gate.sh \
  "$(rstop r12 "$ARR_REV")"
lines "$ARR_REV/src/lib.rs" 73 25
expect "review: own work after the review still counts (28 lines)" 2 review-gate.sh \
  "$(rstop r12 "$ARR_REV")" "changed 28 lines"

# Undercounting is the failure that matters: the session's commits stay counted when git
# expires old reflog entries, when a later change deletes or edits the file a session
# commit created, when the work was committed in a linked worktree (a subagent's) and
# merged in, and when gc prunes the cached base.
ARR_KEEP="$WORK/arr-keep"
new_repo "$ARR_KEEP"
prompt r13 "$ARR_KEEP"
lines "$ARR_KEEP/src/own.rs" 0 30
commit_all "$ARR_KEEP" "own file"
git -C "$ARR_KEEP" reflog expire --expire=30.minutes.ago --all
expect "review: own commit counts after old reflog entries expire (30 lines)" 2 \
  review-gate.sh "$(rstop r13 "$ARR_KEEP")" "changed 30 lines"
arrive "$ARR_KEEP" edited perl -pi -e 's/f0\(/edited0(/' src/own.rs
git -C "$ARR_KEEP" merge -q --ff-only edited
unblock r13
expect "review: own file edited by others still counts (30 lines)" 2 review-gate.sh \
  "$(rstop r13 "$ARR_KEEP")" "changed 30 lines"
git -C "$ARR_KEEP" gc -q --prune=now
unblock r13
expect "review: a base pruned by gc is rebuilt (30 lines)" 2 review-gate.sh \
  "$(rstop r13 "$ARR_KEEP")" "changed 30 lines"

ARR_WT="$WORK/arr-wt"
new_repo "$ARR_WT"
prompt r14 "$ARR_WT"
git -C "$ARR_WT" worktree add -q -b sub "$WORK/arr-wt-sub" main
lines "$WORK/arr-wt-sub/src/sub.rs" 0 25
commit_all "$WORK/arr-wt-sub" "subagent work"
git -C "$ARR_WT" worktree remove "$WORK/arr-wt-sub"
git -C "$ARR_WT" merge -q --ff-only sub
expect "review: work committed in a worktree and merged in counts (25 lines)" 2 \
  review-gate.sh "$(rstop r14 "$ARR_WT")" "changed 25 lines"
# M2: a Q&A session in a dirty repo changed nothing and passes both stop hooks.
REPO5="$WORK/repo5"
new_repo "$REPO5"
lines "$REPO5/src/lib.rs" 5 30
printf '// TODO: dirty before the session\n' >>"$REPO5/src/lib.rs"
prompt q1 "$REPO5"
expect "review: Q&A session in a dirty repo passes" 0 review-gate.sh "$(rstop q1 "$REPO5")"
expect "check: Q&A session in a dirty repo passes" 0 check-on-stop.sh "$(rstop q1 "$REPO5")"
expect "review: Q&A session without a prompt hook passes too" 0 review-gate.sh \
  "$(rstop q2 "$REPO5")"

# M3: an old review's snapshot does not count other people's later commits.
REPO6="$WORK/repo6"
new_repo "$REPO6"
prompt o1 "$REPO6"
lines "$REPO6/src/lib.rs" 5 3
run_hook fmt-on-edit.sh "$(edit o1 "$REPO6/src/lib.rs" 'x')"
run_hook review-done.sh \
  "$(subagent_stop o1 "$REPO6" '{"agent_id": "a4", "agent_type": "rust-style-reviewer"}')"
commit_all "$REPO6" "o1 work"
lines "$REPO6/src/lib.rs" 8 30
commit_all "$REPO6" "someone else"
prompt o2 "$REPO6"
lines "$REPO6/src/lib.rs" 38 3
run_hook fmt-on-edit.sh "$(edit o2 "$REPO6/src/lib.rs" 'x')"
expect "review: old snapshot ignores other people's commits" 0 review-gate.sh \
  "$(rstop o2 "$REPO6")"

mkdir -p "$WORK/plain"
lines "$WORK/plain/small.rs" 0 10
run_hook fmt-on-edit.sh "$(edit r3 "$WORK/plain/small.rs" 'x' sub1)"
expect "review: small non-git file passes" 0 review-gate.sh "$(stop r3)"
lines "$WORK/plain/x.rs" 0 25
run_hook fmt-on-edit.sh "$(edit r3 "$WORK/plain/x.rs" 'x' sub2)"
expect "review: a running subagent's edits wait" 0 review-gate.sh "$(stop r3)"
sub2_done="$(subagent_stop r3 "$WORK" '{"agent_id": "sub2", "agent_type": "general-purpose"}')"
run_hook review-done.sh "$sub2_done"
expect "review: subagent's non-git edits count once it stops" 2 review-gate.sh "$(stop r3)" \
  "plain/x.rs"
lines "$WORK/plain/resumed.rs" 0 25
run_hook fmt-on-edit.sh "$(edit r3 "$WORK/plain/resumed.rs" 'x' sub2)"
expect "review: edits after a resume wait for the next stop" 0 review-gate.sh "$(stop r3)"
run_hook review-done.sh "$sub2_done"
expect "review: edits after a resume count at the next stop" 2 review-gate.sh "$(stop r3)" \
  "plain/resumed.rs"
# A subagent's work counts only once review-done.sh has recorded its stop, so it must run
# for every subagent, not only the reviewer.
SETTINGS="$HOOKS/../../settings.json"
check "settings: review-done.sh runs for every subagent" "$(jq -e '[.hooks.SubagentStop[]
  | select(any(.hooks[]; .command | test("review-done")))
  | .matcher] == [""]' "$SETTINGS" >/dev/null && echo yes)"
# A garbled stop count reads as not stopped yet, not as an error.
printf 'x\n' >"$STATE_TMP/claude-rust-hooks/r3.sub2.finished"
lines "$WORK/plain/garbled.rs" 0 25
run_hook fmt-on-edit.sh "$(edit r3 "$WORK/plain/garbled.rs" 'x' sub2)"
expect "review: a garbled stop count waits" 0 review-gate.sh "$(stop r3)"
check "review: a garbled stop count is not an error" "$([[ -z "$out" ]] && echo yes)" "$out"
expect "review: session without edits passes" 0 review-gate.sh "$(rstop r4 "$WORK/notrust")"

# A git repo inside a non-git directory that also holds a recorded file: each file is
# counted once, under the repo, and a recorded file deleted since is not listed.
NEST="$WORK/nest"
mkdir -p "$NEST"
new_repo "$NEST/inner"
lines "$NEST/stray.rs" 0 2
run_hook fmt-on-edit.sh "$(edit n1 "$NEST/stray.rs" 'x')"
lines "$NEST/inner/src/lib.rs" 5 25
run_hook fmt-on-edit.sh "$(edit n1 "$NEST/inner/src/lib.rs" 'x')"
lines "$NEST/gone.rs" 0 30
run_hook fmt-on-edit.sh "$(edit n1 "$NEST/gone.rs" 'x')"
trash "$NEST/gone.rs"
expect "review: nested repo counted once" 2 review-gate.sh "$(stop n1)" "changed 27 lines"
check "review: nested file listed once, deleted file not listed" \
  "$([[ "$(grep -c 'inner/src/lib.rs' <<<"$out")" -eq 1 && "$out" != *gone.rs* ]] && echo yes)" \
  "$out"

# Claude's session scratchpad is exempt: no style gate, nothing recorded, no review.
SCRATCH="$WORK/tmp/claude-501/proj/sess/scratchpad/crate"
new_repo "$SCRATCH"
prompt s1 "$SCRATCH"
expect "scratch: style gate skips the scratchpad" 0 style-gate.sh \
  "$(edit s1 "$SCRATCH/src/lib.rs" 'unsafe { f() }')"
lines "$SCRATCH/src/lib.rs" 5 30
run_hook fmt-on-edit.sh "$(edit s1 "$SCRATCH/src/lib.rs" 'x')"
check "scratch: edit not recorded" \
  "$([[ ! -s "$STATE_TMP/claude-rust-hooks/s1.main.edited" ]] && echo yes)"
expect "scratch: review gate ignores scratch changes" 0 review-gate.sh "$(rstop s1 "$SCRATCH")"
expect "scratch: stop check ignores scratch changes" 0 check-on-stop.sh "$(rstop s1 "$SCRATCH")"

# Performance: 1500 changed files, one git call per root rather than per file.
BIG="$WORK/big"
new_repo "$BIG"
prompt p1 "$BIG"
for ((n = 0; n < 1500; n++)); do printf 'pub fn g() {}\n' >"$BIG/src/f$n.rs"; done
started="$(date +%s)"
expect "review: 1500 changed files" 2 review-gate.sh "$(rstop p1 "$BIG")" "1500 lines"
elapsed=$(($(date +%s) - started))
check "review: 1500 files in under 20 s (took ${elapsed}s)" "$([[ $elapsed -lt 20 ]] && echo yes)"

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
guard "push maintenance passes" 0 "git push origin maintenance"
git -C "$GREPO" checkout -q -b feature
guard "push on a feature branch passes" 0 "git push -u origin"
guard "push HEAD on a feature branch passes" 0 "git push origin HEAD"
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

printf '%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
