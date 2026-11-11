#!/usr/bin/env bash
# Tests for install.sh's merge_json, in a throwaway HOME: shared keys win, local-only keys
# and another tool's array entries stay, and what the shared copy drops leaves the machine.
set -euo pipefail

INSTALL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/install.sh"
WORK="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/install-test.XXXXXX")" && pwd -P)"
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

export HOME="$WORK/home"
mkdir -p "$HOME"
# shellcheck source=install.sh
source "$INSTALL"
file="$HOME/.claude/settings.json"

# A fresh machine gets the shared copy.
merge_json '{"a": 1, "hooks": {"Stop": ["s1"]}}' "$file" >/dev/null
check "fresh: copied" '{"a":1,"hooks":{"Stop":["s1"]}}' "$(jq -c . "$file")"

# Local keys and another tool's hook entries stay; a shared value wins.
jq -c '.a = 9 | .local = true | .hooks.Stop += ["other"] | .hooks.SessionStart = ["rex"]' \
  "$file" >"$file.tmp" && mv "$file.tmp" "$file"
merge_json '{"a": 1, "hooks": {"Stop": ["s1"]}}' "$file" >/dev/null
check "local kept, shared wins" \
  '{"a":1,"hooks":{"SessionStart":["rex"],"Stop":["s1","other"]},"local":true}' \
  "$(jq -c -S . "$file")"

# What the shared copy drops leaves the machine: a key, a hook event, an array entry.
merge_json '{"b": 2, "hooks": {"Stop": ["s2"]}}' "$file" >/dev/null
check "dropped key and entry removed" \
  '{"b":2,"hooks":{"SessionStart":["rex"],"Stop":["s2","other"]},"local":true}' \
  "$(jq -c -S . "$file")"
merge_json '{"b": 2, "hooks": {}}' "$file" >/dev/null
check "dropped event removed" '{"b":2,"hooks":{"SessionStart":["rex"]},"local":true}' \
  "$(jq -c -S . "$file")"

# A second run with nothing new changes nothing.
before="$(cat "$file")"
out="$(merge_json '{"b": 2, "hooks": {}}' "$file")"
check "idempotent: file" "$before" "$(cat "$file")"
check "idempotent: says ok" "ok      $file" "$out"

# A command added inside a shared hook group (Claude's /hooks does that) joins that group,
# not a second copy of it; when the shared group changes, the added command stays with it.
group() { jq -nc --arg c "$1" '{matcher: "", hooks: [{type: "command", command: $c}]}'; }
shared="{\"hooks\": {\"Stop\": [$(group a)]}}"
merge_json "$shared" "$file" >/dev/null
jq -c '.hooks.Stop[0].hooks += [{type: "command", command: "mine"}]' "$file" >"$file.tmp"
mv "$file.tmp" "$file"
merge_json "$shared" "$file" >/dev/null
check "hook group: added command merged, shared hook once" '["a","mine"]' \
  "$(jq -c '[.hooks.Stop[].hooks[].command]' "$file")"
merge_json "{\"hooks\": {\"Stop\": [$(group b)]}}" "$file" >/dev/null
check "hook group: shared hook replaced, added command kept" '["b","mine"]' \
  "$(jq -c '[.hooks.Stop[].hooks[].command]' "$file")"

# Keys keep the local file's order, so a file Claude Code wrote in its own order is unchanged.
printf '{"zeta": 1, "model": "x"}\n' >"$file"
check "key order: unchanged file says ok" "ok      $file" "$(merge_json '{"model": "x"}' "$file")"

# A damaged record (a crash mid-write) counts as no record instead of stopping the install.
record="$HOME/.local/state/agent-setup/.claude/settings.json"
for damage in '{"trunc' ''; do
  printf '%s' "$damage" >"$record"
  code=0
  merge_json '{"model": "x"}' "$file" >/dev/null 2>&1 || code=$?
  check "damaged record '$damage': merge still runs" 0 "$code"
  check "damaged record '$damage': record rewritten" '{"model":"x"}' "$(jq -c . "$record")"
done

# Before any record of the shared copy (a machine set up earlier), arrays come from the
# shared copy whole and no key is removed, as before the record existed.
trash "$HOME/.local/state/agent-setup"
printf '{"old": 1, "hooks": {"Stop": ["stale", "s1"]}}\n' >"$file"
merge_json '{"hooks": {"Stop": ["s1"]}}' "$file" >/dev/null
check "no record: shared arrays, no removal" '{"hooks":{"Stop":["s1"]},"old":1}' \
  "$(jq -c -S . "$file")"

printf '%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
