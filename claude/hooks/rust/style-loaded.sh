#!/usr/bin/env bash
# PostToolUse (Skill | Read | read_file | Bash): record what this agent loaded, which opens
# style-gate.sh. Claude loads skills through the Skill tool; Grok loads them by reading the
# skill's SKILL.md, and a Claude agent may read it directly too. All three count, and so does
# a whole-file `cat` (or `bat`) of the file through the shell: agents do that, and a gate
# that ignored it cost them a blocked edit. A partial read (`head`, `sed -n`, `cat | head`)
# does not count. Topic files (rust-style/topics/<name>.md) are only ever read, never loaded
# as skills.
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
read_hook_input
need_tools fail-open jq

# Skill files read whole by the shell command $1, one path per line: every rust-style path
# that is an argument of a `cat`/`bat` simple command, unless the output is cut short.
shell_reads() {
  local skill_path='[^[:space:]"'"'"';&|]*skills/rust-style/(SKILL|topics/[a-z-]+)\.md'
  if grep -qE '\|[[:space:]]*(head|tail|sed|awk|grep)\b' <<<"$1"; then
    return 0
  fi
  # One simple command per line (perl: BSD sed writes `\n` in a replacement as `n`).
  perl -pe 's/(&&|\|\||[;|()])/\n/g' <<<"$1" |
    { grep -E '^[[:space:]]*(cat|bat)[[:space:]]' || true; } |
    { grep -oE "$skill_path" || true; }
}

record() {
  local path="$1"
  if [[ "$path" == */skills/rust-style/SKILL.md ]]; then
    touch "$(agent_file style-loaded)"
  fi
  local topic_re='/skills/rust-style/topics/([a-z-]+)\.md$'
  if [[ "$path" =~ $topic_re ]]; then
    touch "$(agent_file "topic-${BASH_REMATCH[1]}")"
  fi
}

if [[ "$(hook_field '.tool_input.skill')" == "rust-style" ]]; then
  touch "$(agent_file style-loaded)"
fi
record "$(tool_path)"
while IFS= read -r path; do
  if [[ -n "$path" ]]; then
    record "$path"
  fi
done < <(shell_reads "$(hook_field '.tool_input.command')")
