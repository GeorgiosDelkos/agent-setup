#!/usr/bin/env bash
# PostToolUse (Skill | Read | read_file | Bash): record what this agent loaded, which opens
# style-gate.sh. Claude loads skills through the Skill tool; Grok loads them by reading the
# skill's SKILL.md, and a Claude agent may read it directly too. All three count, and so does
# a whole-file `cat` (or `bat`) of the file through the shell: agents do that, and a gate
# that ignored it cost them a blocked edit. A partial read does not count: `head`, `sed -n`,
# `cat | head`, or a Read/read_file with a limit or an offset past line 1. Grok's read_file
# ignores offset and limit for a file named SKILL.md and returns it whole when it fits in
# one read, so that call still counts. Topic files are ordinary markdown, and they are only
# ever read, never loaded as skills.
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
read_hook_input
need_tools fail-open jq

# Skill files read whole by the shell command $1, one path per line: every house skill
# path that is an argument of a `cat`/`bat` simple command, unless the output is cut short.
shell_reads() {
  local skill_path
  skill_path='[^[:space:]"'"'"';&|]*skills/'
  skill_path+='(rust-style/(SKILL|topics/[a-z-]+)'
  skill_path+="|(${HOUSE_LANG_SKILLS// /|})/SKILL)\\.md"
  if grep -qE '\|[[:space:]]*(head|tail|sed|awk|grep)\b' <<<"$1"; then
    return 0
  fi
  # One simple command per line (perl: BSD sed writes `\n` in a replacement as `n`).
  perl -pe 's/(&&|\|\||[;|()])/\n/g' <<<"$1" |
    { grep -E '^[[:space:]]*(cat|bat)[[:space:]]' || true; } |
    { grep -oE "$skill_path" || true; }
}

record() {
  local path="$1" name
  case "$path" in
  */skills/rust-style/SKILL.md)
    touch "$(agent_file style-loaded)"
    ;;
  */skills/*/SKILL.md)
    name="$(basename "$(dirname "$path")")"
    if is_house_lang "$name"; then
      touch "$(agent_file "skill-$name")"
    fi
    ;;
  esac
  local topic_re='/skills/rust-style/topics/([a-z-]+)\.md$'
  if [[ "$path" =~ $topic_re ]]; then
    touch "$(agent_file "topic-${BASH_REMATCH[1]}")"
  fi
}

# True when this Read/read_file asked for less than the whole file. A numeric limit,
# or an offset past line 1, is a slice. Grok's read_file drops both for a file named
# SKILL.md and returns that file whole, so the same input still put the skill in context.
# A topic file is not in that set: the rest of it stayed unread, and must not open the gate.
read_is_sliced() {
  local path="$1" tool answer
  tool="$(hook_field '.tool_name // .toolName')"
  if [[ "$tool" == "read_file" && "$path" == */skills/*/SKILL.md ]]; then
    return 1
  fi
  answer="$(jq -r 'if ((.tool_input.limit | type) == "number")
      or ((.tool_input.offset | type) == "number" and .tool_input.offset > 1)
    then "yes" else "no" end' <<<"$HOOK_INPUT")"
  [[ "$answer" == "yes" ]]
}

skill_name="$(hook_field '.tool_input.skill')"
case "$skill_name" in
rust-style) touch "$(agent_file style-loaded)" ;;
*)
  if is_house_lang "$skill_name"; then
    touch "$(agent_file "skill-$skill_name")"
  fi
  ;;
esac
read_path="$(tool_path)"
if ! read_is_sliced "$read_path"; then
  record "$read_path"
fi
while IFS= read -r path; do
  if [[ -n "$path" ]]; then
    record "$path"
  fi
done < <(shell_reads "$(hook_field '.tool_input.command')")
