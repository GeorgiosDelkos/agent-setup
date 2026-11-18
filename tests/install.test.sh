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

# A machine set up when the shared copy had three groups with one matcher, with a command
# added to one of them, or to all three, which is what that merge wrote at the next install
# (issue #39): after the shared copy folds the groups into one, each shared command and the
# added one are there once.
old_shared="{\"hooks\": {\"Stop\": [$(group a), $(group b), $(group c)]}}"
folded="$(jq -c '.hooks.Stop = [{matcher: "", hooks: [.hooks.Stop[].hooks[]]}]' \
  <<<"$old_shared")"
for groups in '[0]' '[1]' '[2]' '[0, 1, 2]'; do
  # From an empty file and no record, so no earlier case leaves anything in this one.
  trash "$HOME/.local/state/agent-setup"
  printf '{}\n' >"$file"
  merge_json "$old_shared" "$file" >/dev/null
  jq -c --argjson groups "$groups" 'reduce $groups[] as $i (.;
    .hooks.Stop[$i].hooks += [{type: "command", command: "mine"}])' "$file" >"$file.tmp"
  mv "$file.tmp" "$file"
  merge_json "$folded" "$file" >/dev/null
  check "groups folded, command added to old groups $groups: every command once" \
    '[["a","b","c","mine"]]' "$(jq -c '[.hooks.Stop[] | [.hooks[].command]]' "$file")"
done

# A machine that changed a field of a shared hook (its timeout) holds that hook, not a new
# one: the shared entry comes back, once. Compared as whole objects, both entries stayed
# (issue #41).
timed='{"hooks": {"Stop": [{"matcher": "", "hooks": [
  {"type": "command", "command": "a", "timeout": 600}, {"type": "command", "command": "b"}]}]}}'
# fresh SHARED: an empty file and no record, then SHARED installed.
fresh() {
  trash "$HOME/.local/state/agent-setup"
  printf '{}\n' >"$file"
  merge_json "$1" "$file" >/dev/null
}
# locally JQ_FILTER: the machine's own change to the installed file.
locally() {
  jq -c "$1" "$file" >"$file.tmp"
  mv "$file.tmp" "$file"
}
# The Stop groups as [matcher, command...] lists.
stop_groups() {
  jq -c '[.hooks.Stop[] | [.matcher] + [.hooks[].command]]' "$file"
}
fresh "$timed"
locally '.hooks.Stop[0].hooks[0].timeout = 900'
merge_json "$timed" "$file" >/dev/null
check "a changed timeout on a shared hook: one entry, the shared value" \
  '[["a",600],["b",null]]' "$(jq -c '[.hooks.Stop[].hooks[] | [.command, .timeout]]' "$file")"

# The same when the shared copy then drops that hook: the machine's changed entry is the
# dropped hook, not a hook of its own, and goes.
merge_json "$timed" "$file" >/dev/null
locally '.hooks.Stop[0].hooks[0].timeout = 900'
merge_json "$(jq -c '.hooks.Stop[0].hooks |= map(select(.command != "a"))' <<<"$timed")" \
  "$file" >/dev/null
check "a hook the shared copy dropped, changed on the machine, goes" '[["","b"]]' \
  "$(stop_groups)"

# A command the machine added twice, with two timeouts, is one hook: it is kept once.
fresh "$timed"
locally '.hooks.Stop[0].hooks += [{type: "command", command: "mine", timeout: 1},
  {type: "command", command: "mine", timeout: 2}]'
merge_json "$timed" "$file" >/dev/null
check "a command added twice with different timeouts is kept once" '[["","a","b","mine"]]' \
  "$(stop_groups)"

# A tool that rewrites the groups without the `matcher` key leaves the same groups: a
# missing matcher is the empty one. Kept beside the shared group, every command was there
# twice (issue #41). A command that tool added stays, once.
fresh "$timed"
locally '.hooks.Stop |= map(del(.matcher))
  | .hooks.Stop[0].hooks += [{type: "command", command: "mine"}]'
merge_json "$timed" "$file" >/dev/null
check "groups rewritten without a matcher key: one group, every command once" \
  '[["","a","b","mine"]]' "$(stop_groups)"

# The other way round: the shared copy and the record have no matcher key, the machine's
# file has the empty one. The recorded hooks are found under the same key, so only the
# machine's command is new.
keyless="$(jq -c '.hooks.Stop |= map(del(.matcher))' <<<"$timed")"
fresh "$keyless"
locally '.hooks.Stop[0].matcher = "" | .hooks.Stop[0].hooks += [{type: "command", command: "mine"}]'
merge_json "$keyless" "$file" >/dev/null
check "a shared group without a matcher key takes the machine's empty-matcher group" \
  '[[null,"a","b","mine"]]' "$(stop_groups)"
# The shared copy then gains the key and drops a hook. The record is still keyless, and its
# hooks must be found under the same key: read by the raw matcher, the dropped hook would
# look like the machine's own and stay.
merge_json "$(jq -c '.hooks.Stop[0].hooks |= map(select(.command != "a"))' <<<"$timed")" \
  "$file" >/dev/null
check "a keyless record is read under the empty matcher: its dropped hook goes" \
  '[["","b","mine"]]' "$(stop_groups)"

# The shared copy changes a group's matcher while the machine had changed a field in that
# group. The old group is the recorded one, so it goes; kept whole, its hooks stayed
# registered beside the renamed group. A command the machine added there stays, alone.
renamed="$(jq -c '.hooks.Stop[0].matcher = "x"' <<<"$timed")"
fresh "$timed"
locally '.hooks.Stop[0].hooks[0].timeout = 900'
merge_json "$renamed" "$file" >/dev/null
check "a group the shared copy renamed, changed on the machine, goes" '[["x","a","b"]]' \
  "$(stop_groups)"
fresh "$timed"
locally '.hooks.Stop[0].hooks[0].timeout = 900
  | .hooks.Stop[0].hooks += [{type: "command", command: "mine"}]'
merge_json "$renamed" "$file" >/dev/null
check "the machine's own command stays under the old matcher" '[["x","a","b"],["","mine"]]' \
  "$(stop_groups)"

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

# When the shared copy drops a key, a plain value the machine changed since the last merge
# stays (the machine's own model), an unchanged one goes, and a dropped object goes whole
# even with a local change inside.
merge_json '{"model": "shared", "theme": "dark", "env": {"A": "1"}}' "$file" >/dev/null
jq -c '.model = "mine" | .env.A = "local"' "$file" >"$file.tmp" && mv "$file.tmp" "$file"
merge_json '{}' "$file" >/dev/null
check "dropped key: changed value kept, unchanged and object removed" \
  '{"model":"mine","zeta":1}' "$(jq -c -S . "$file")"
merge_json '{}' "$file" >/dev/null
check "dropped key: kept value survives the next install" \
  '{"model":"mine","zeta":1}' "$(jq -c -S . "$file")"

# The same inside an object the shared copy keeps, where most settings live (permissions,
# env): the changed value stays and the unchanged one goes. The machine's value decides: a
# key it set to an array or to null goes.
merge_json '{"env": {"A": "1", "B": "1"}, "list": "x", "gone": "x"}' "$file" >/dev/null
jq -c '.env.A = "local" | .list = ["mine"] | .gone = null' "$file" >"$file.tmp"
mv "$file.tmp" "$file"
merge_json '{"env": {}}' "$file" >/dev/null
check "dropped nested key: changed kept, unchanged removed; array and null removed" \
  '{"env":{"A":"local"},"model":"mine","zeta":1}' "$(jq -c -S . "$file")"

# Before any record of the shared copy (a machine set up earlier), arrays come from the
# shared copy whole and no key is removed, as before the record existed.
trash "$HOME/.local/state/agent-setup"
printf '{"old": 1, "hooks": {"Stop": ["stale", "s1"]}}\n' >"$file"
merge_json '{"hooks": {"Stop": ["s1"]}}' "$file" >/dev/null
check "no record: shared arrays, no removal" '{"hooks":{"Stop":["s1"]},"old":1}' \
  "$(jq -c -S . "$file")"

# The review profile's `~/` paths are expanded to this HOME, since the review runs with its
# own empty HOME; a second run finds the copy current and changes nothing.
profile="$HOME/.grok-review/sandbox.toml"
setup_grok_review >/dev/null
# The same test grok-review.sh applies before a review.
check "review profile: no ~ path left" 0 \
  "$(grep -v '^[[:space:]]*#' "$profile" | grep -c "[\"']~" || true)"
check "review profile: comments unchanged" same \
  "$(diff <(grep '^#' "$SETUP_DIR/grok/review-sandbox.toml") <(grep '^#' "$profile") >/dev/null &&
    echo same)"
check "review profile: ~/.grok denied by absolute path" 1 \
  "$(grep -cxF "  \"$HOME/.grok\"," "$profile" || true)"
check "review profile: mode 600" 600 "$(stat -f %Lp "$profile")"
check "review profile: second run is current" "ok      $profile" \
  "$(setup_grok_review | grep -F "$profile")"
check "review profile: no scratch copy left" no "$([[ -e "$profile.new" ]] && echo yes || echo no)"

# Grok's own config can keep Grok on always-approve; install.sh says so and writes nothing.
mkdir -p "$HOME/.grok"
check "grok mode: no config file, no warning" "" "$(check_grok_mode)"
printf '[ui]\npermission_mode = "auto"\n# permission_mode = "always-approve"\n' \
  >"$HOME/.grok/config.toml"
check "grok mode: auto, with the old line commented out: no warning" "" "$(check_grok_mode)"
printf '[ui]\n  permission_mode="always-approve"\n' >"$HOME/.grok/config.toml"
before="$(cat "$HOME/.grok/config.toml")"
check "grok mode: always-approve is reported" 1 \
  "$(check_grok_mode | grep -c "^warning: $HOME/.grok/config.toml sets permission_mode")"
check "grok mode: the config file is left as it was" "$before" \
  "$(cat "$HOME/.grok/config.toml")"

# The shared sandbox block. Worktrees, the Grok review and a headless session cannot run
# inside the sandbox (agents/SETUP.md, Sandbox), so the retry outside it must stay allowed.
shared="$(dirname "$INSTALL")/claude/settings.json"
check "sandbox: on, and a blocked command may still be retried outside it" "true true" \
  "$(jq -r '.sandbox | "\(.enabled) \(.allowUnsandboxedCommands != false)"' "$shared")"
# A machine's own folders and sockets are local entries, which the merge must keep.
merge_json "$(cat "$shared")" "$file" >/dev/null
jq '.sandbox.filesystem.allowWrite += ["~/work"]
  | .sandbox.network.allowUnixSockets = ["~/run/tool.sock"]' "$file" >"$file.new"
mv "$file.new" "$file"
merge_json "$(cat "$shared")" "$file" >/dev/null
check "sandbox: a machine's own folder and socket survive the next install" \
  '["~/work",["~/run/tool.sock"]]' \
  "$(jq -c '[(.sandbox.filesystem.allowWrite[] | select(. == "~/work")),
    .sandbox.network.allowUnixSockets]' "$file")"

printf '%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
