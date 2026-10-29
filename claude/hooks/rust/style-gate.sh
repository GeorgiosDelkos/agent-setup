#!/usr/bin/env bash
# PreToolUse (Edit|Write|MultiEdit|search_replace|write|hashline_edit): block an edit until
# this agent has the house style in context. Any .rs edit, or an edit to a Rust repo's
# manifest, lint, toolchain, or CI config, needs the core rust-style skill. On top of that,
# each topic file under rust-style/topics/ is required when the edit's new text or path
# touches its area. One message lists everything still missing, so the agent loads it all in
# one round.
#
# The block is a JSON deny on stdout (`hookSpecificOutput.permissionDecision`), the canonical
# form for both Claude Code and Grok: Grok turns only the first stderr line into the deny
# reason, which would drop the list of files to load. stderr gets a one-line summary.
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
read_hook_input
need_tools fail-open jq

# True when $1 is a manifest, lint, toolchain, or workflow file inside a Rust repo.
is_repo_config() {
  local path="$1"
  case "$(basename "$path")" in
  Cargo.toml) return 0 ;;
  deny.toml | clippy.toml | .clippy.toml | rust-toolchain.toml | rust-toolchain) ;;
  *.yml | *.yaml) [[ "$path" == */.github/workflows/* ]] || return 1 ;;
  *) return 1 ;;
  esac
  [[ -n "$(crate_dir_of "$(dirname "$path")")" ]]
}

# True when $1 is a library source file of a published crate: the crate has src/lib.rs, the
# file is under src/ but not a binary root, and the manifest opts in to publishing
# (house-metadata.pl published: a crate without a `publish` key counts as internal).
is_published_lib_src() {
  local path="$1" crate
  crate="$(crate_dir_of "$(dirname "$path")")"
  if [[ -z "$crate" || ! -f "$crate/src/lib.rs" ]]; then
    return 1
  fi
  case "${path#"$crate"/}" in
  src/main.rs | src/bin/*) return 1 ;;
  src/*) ;;
  *) return 1 ;;
  esac
  perl "$RUST_HOOKS_DIR/house-metadata.pl" published "$crate" 2>/dev/null
}

# The new text of the edit. Claude: new_string, content, edits[].new_string; Grok:
# new_string, content, contents (Cursor preset). Grok's hashline_edit has no documented
# input shape, so for it every string field except the old text and the path is scanned.
new_text() {
  jq -r '(.tool_name // "") as $tool | .tool_input
    | if $tool == "hashline_edit" then
        [paths(strings) as $p
          | select($p[-1] | tostring | IN("old_string", "file_path", "target_file", "path") | not)
          | getpath($p)]
      else [.new_string?, .content?, .contents?, (.edits[]?.new_string)] | map(strings)
      end
    | join("\n")' <<<"$HOOK_INPUT"
}

# Topics the new Rust text and its path trigger, one name per line. Line comments are
# dropped first so prose about `unsafe` or `async` does not trigger a topic.
rust_topics() {
  local path="$1" code
  code="$(new_text | sed -E 's#//.*$##')"

  local unsafe='\bunsafe\b|extern "C"|repr\(C\)|MaybeUninit|UnsafeCell|\*const\b|\*mut\b'
  # Only the atomic orderings: cmp::Ordering::Less is not concurrency.
  local concurrency='\bAtomic[A-Z][A-Za-z0-9]*|Ordering::(Relaxed|Acquire|Release|AcqRel|SeqCst)'
  concurrency+='|\bMutex\b|\bRwLock\b|\bCondvar\b|thread::spawn|\bloom::'
  local async='\basync\b|\.await\b|impl Future|\bPoll<|\bWaker\b|\btokio::'
  local testing='#\[([a-z_]+::)?test\]|#\[cfg\(test\)\]|proptest!|loom::model'
  local pub_item='^[[:space:]]*pub[[:space:]]+((const|unsafe|async|extern[[:space:]]+"[^"]*")'
  pub_item+='[[:space:]]+)*(fn|struct|enum|trait|type|mod|use|const|static|union|macro)\b'
  pub_item+='|#\[macro_export\]'

  grep -qE "$unsafe" <<<"$code" && echo unsafe
  grep -qE "$concurrency" <<<"$code" && echo concurrency
  grep -qE "$async" <<<"$code" && echo async
  if [[ "$path" == */tests/* || "$path" == */benches/* ]] || grep -qE "$testing" <<<"$code"; then
    echo testing
  fi
  if grep -qE "$pub_item" <<<"$code" && is_published_lib_src "$path"; then
    echo library-api
  fi
  local crate
  crate="$(crate_dir_of "$(dirname "$path")")"
  if [[ -n "$crate" ]] && house_switch low-level "$crate"; then
    echo low-level
  fi
  return 0
}

path="$(tool_path)"
if is_scratch_path "$path"; then
  exit 0
fi
if [[ "$path" == *.rs ]]; then
  topics="$(rust_topics "$path")"
elif is_repo_config "$path"; then
  topics="repo"
else
  exit 0
fi

missing=""
summary=""
if [[ ! -f "$(agent_file style-loaded)" ]]; then
  missing+="  the rust-style skill (Claude: Skill tool; Grok: read_file"
  missing+=" $RUST_STYLE_DIR/SKILL.md)"$'\n'
  summary+=" $RUST_STYLE_DIR/SKILL.md (Claude: Skill rust-style)"
fi
# A PreToolUse block has no block-once escape, so a topic file that is not installed must
# not be required: the agent could never read it and every edit would stay blocked.
for topic in $topics; do
  topic_file="$RUST_STYLE_DIR/topics/$topic.md"
  if [[ -f "$topic_file" && ! -f "$(agent_file "topic-$topic")" ]]; then
    missing+="  Read $topic_file"$'\n'
    summary+=" $topic_file"
  fi
done

if [[ -z "$missing" ]]; then
  exit 0
fi
reason="BLOCKED: this edit to $path needs house-style context you have not loaded yet."
reason+=" Load each of these, then retry the edit:"$'\n'"$missing"
jq -n --arg reason "$reason" '{hookSpecificOutput: {hookEventName: "PreToolUse",
  permissionDecision: "deny", permissionDecisionReason: $reason}}'
echo "BLOCKED: load before editing $path:$summary" >&2
