#!/usr/bin/env bash
# Link this machine's Claude Code and Grok configuration to this shared AgentSetup folder.
#
# Idempotent: links that are already correct are left alone; anything else at a target
# path is moved to ~/.agent-setup-backup/<timestamp>/ before it is replaced. settings.json is
# merged rather than linked because Claude Code rewrites it in place, which would replace a
# symlink with a plain file. ~/.cargo/config.toml gets a marked copy of cargo/config.toml
# (setup_cargo).
set -euo pipefail

SETUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="$HOME/.agent-setup-backup/$(date +%Y%m%d-%H%M%S)"

# Move an existing path out of the way, keeping its location relative to $HOME.
backup() {
  local path="$1" relative
  relative="${path#"$HOME"/}"
  mkdir -p "$BACKUP_DIR/$(dirname "$relative")"
  mv "$path" "$BACKUP_DIR/$relative"
  echo "  backed up $path"
}

# Make $2 a symlink to $1, backing up whatever was there.
link() {
  local source="$1" target="$2"
  if [[ -L "$target" && "$(readlink "$target")" == "$source" ]]; then
    echo "ok      $target"
    return 0
  fi

  if [[ -e "$target" || -L "$target" ]]; then
    backup "$target"
  fi

  mkdir -p "$(dirname "$target")"
  ln -s "$source" "$target"
  echo "linked  $target -> $source"
}

# The merge for merge_json, with three inputs: $l the local file, $s the shared copy, $p the
# shared copy as of the last merge (null before the first). Objects merge key by key, the
# shared value winning. A key the shared copy had last time and has dropped since is deleted,
# so a setting or hook event removed from the shared file leaves every machine. The exception
# is a key whose value on the machine is a string, number or boolean that differs from the
# shared value at that merge: the shared file dropping `model` means "each machine picks",
# and deleting the machine's pick would undo it. So dropping a key removes only values no
# machine changed; to force a value everywhere, set it in the shared copy. The machine's
# value decides: when it is an object, an array or null, the key goes whole, changed or not.
# Telling the machine's part of an object or array from the shared part would need the array
# rules below, for a case not seen yet. An array is the shared one plus the local entries
# that neither the shared copy has nor it had last time: those are another tool's (a hook
# another tool registered under PreToolUse), while an entry the shared copy dropped goes. A
# hook group (an object with `hooks`) whose matcher a shared group has is merged into that
# group instead, hook by hook the same way: Claude's /hooks adds a command inside the
# existing group, and keeping the whole local group beside the shared one would run the
# shared hooks twice. The matcher is the group's key, so the shared copy has one group per
# matcher in each event: with two, a command added locally to either is appended to both
# (with three `Stop` groups it was written into all three, issue #39). The hook tests fail
# on a second group with a matcher. A command the local groups hold more than once is
# added once: a machine that merge already reached has it in every old group. A hook
# with a `command` is the same hook when the command is, whatever else it carries: a
# machine that changed the `timeout` of a shared hook holds that hook, not a new one, and
# gets the shared entry back (the shared value wins, as for any key the shared copy sets;
# before, both entries stayed in the group, issue #41). No machine is known to need a field
# of its own on a shared hook; one that does can set it again in install.local.sh, which
# runs after this merge. Hooks without a command (prompt, http and agent types) are still
# compared whole: the shared copy has none. A group without a `matcher` key counts as the
# group with the empty matcher, so a tool that rewrites the groups without the key does not
# leave them beside the shared ones. A local group whose matcher the shared copy no longer
# has keeps only the hooks the record did not hold under that matcher, and goes when none
# is left: kept whole, a machine that had changed one field in it went on running the hooks
# of a group the shared copy had renamed or dropped. Without $p,
# arrays are taken from the shared copy whole, as before this record existed, because no
# local entry can be told apart yet. Keys keep the local file's order, then the shared
# copy's new keys: sorting them would differ from the order Claude Code writes, and every
# install would report a change.
# shellcheck disable=SC2016 # jq variables, not shell ones
MERGE_JQ='
def id($x): if ($x | type) == "object" and ($x | has("command"))
  then {command: $x.command} else $x end;
def holds($a; $x): any($a[]; id(.) == id($x));
def new_in($a; $s; $p): [$a[] | select(. as $x | (holds($s; $x) or holds($p; $x)) | not)];
def once($a): reduce $a[] as $x ([]; if holds(.; $x) then . else . + [$x] end);
def matcher($g): $g.matcher // "";
def group($x): ($x | type) == "object" and ($x | has("hooks"));
def merge($l; $s; $p):
  if ($s | type) == "object" and ($l | type) == "object" then
    reduce (($l | keys_unsorted)
      + [($s | keys_unsorted)[] | select(. as $k | $l | has($k) | not)])[] as $k ({};
      if $s | has($k) then
        .[$k] = merge($l[$k]; $s[$k]; (if ($p | type) == "object" then $p[$k] else null end))
      elif ($p | type) == "object" and ($p | has($k)) then
        if ($l[$k] | type | IN("object", "array", "null") | not) and $l[$k] != $p[$k]
        then .[$k] = $l[$k] else . end
      else .[$k] = $l[$k]
      end)
  elif ($s | type) == "array" and ($l | type) == "array" and ($p | type) == "array" then
    new_in($l; $s; $p) as $extra
    | [$s[] | . as $g
        | if group($g) then
            [$extra[] | select(group(.) and matcher(.) == matcher($g)) | .hooks[]] as $more
            | [$p[] | select(group(.) and matcher(.) == matcher($g)) | .hooks[]] as $old
            | .hooks += once(new_in($more; $g.hooks; $old))
          else . end]
      + [$extra[] | . as $x
          | select((group($x) and any($s[]; group(.) and matcher(.) == matcher($x))) | not)
          | if group($x) then
              [$p[] | select(group(.) and matcher(.) == matcher($x)) | .hooks[]] as $old
              | .hooks = once(new_in($x.hooks; []; $old))
              | select(.hooks | length > 0)
            else . end]
  else $s
  end;
merge($l; $s; $p)'

# Merge the shared JSON text $1 into the file $2 (MERGE_JQ says how; local-only keys, and
# the whole file on a fresh machine, are kept). The shared copy is recorded under
# ~/.local/state/agent-setup/ for the next merge, only after the file is written: recorded
# first, a crash in between would make the next merge treat a dropped key as local. It is
# written through a rename, and a record that is not valid JSON counts as none. The previous
# file goes to the backup dir, at its path relative to $HOME.
merge_json() {
  local shared="$1" local_file="$2" merged relative last previous
  relative="${local_file#"$HOME"/}"
  last="$HOME/.local/state/agent-setup/$relative"
  mkdir -p "$(dirname "$last")"
  if [[ ! -f "$local_file" ]]; then
    mkdir -p "$(dirname "$local_file")"
    printf '%s\n' "$shared" >"$local_file"
    record_shared "$shared" "$last"
    echo "copied  $local_file"
    return 0
  fi

  previous="$(jq -c . "$last" 2>/dev/null || true)"
  if [[ -z "$previous" || "$previous" == *$'\n'* ]]; then
    previous=null
  fi
  merged="$(jq -n --slurpfile l "$local_file" --argjson s "$shared" --argjson p "$previous" \
    '$l[0] as $l | '"$MERGE_JQ")"
  if [[ "$merged" == "$(jq . "$local_file")" ]]; then
    record_shared "$shared" "$last"
    echo "ok      $local_file"
    return 0
  fi

  mkdir -p "$BACKUP_DIR/$(dirname "$relative")"
  cp "$local_file" "$BACKUP_DIR/$relative"
  printf '%s\n' "$merged" >"$local_file"
  record_shared "$shared" "$last"
  echo "merged  $local_file (previous copy in $BACKUP_DIR)"
}

# Write the shared JSON text $1 to the record $2, through a rename.
record_shared() {
  printf '%s\n' "$1" >"$2.new"
  mv -f "$2.new" "$2"
}

# Register Grok and Claude Code as ACP agents in JetBrains Air. The Claude adapter is pinned
# and installed globally. The grok, node, and script paths are absolute because Air, started
# from the Dock, may not see the shell's PATH (~/.grok/bin, nvm). Merged like settings.json:
# shared agents win, agents added locally in Air stay.
setup_air() {
  local air_dir="$HOME/Library/Application Support/JetBrains/Air"
  local acp_version="0.94.0" pkg="@agentclientprotocol/claude-agent-acp"
  local installed grok node script shared
  if [[ ! -d "$air_dir" ]]; then
    echo "skip    Air ACP agents (JetBrains Air not installed)"
    return 0
  fi

  # Air puts this task list in the user turn of every code review. Without it, Air's generic
  # default outranks the review order in AGENTS.md.
  link "$SETUP_DIR/air/review-prompt.md" "$air_dir/review/review-prompt.md"

  # The editor theme with loud comments (AGENTS.md, Comments), selected in settings.json. The
  # folder is linked, not the file: if Air's theme editor saves by replacing the file, a file
  # link would break, while a folder link holds either way.
  link "$SETUP_DIR/air/themes" "$air_dir/themes"
  merge_json "$(cat "$SETUP_DIR/air/settings.json")" "$air_dir/settings.json"

  if ! command -v npm >/dev/null; then
    echo "skip    Air ACP agents (npm not found)"
    return 0
  fi

  # npm ls exits non-zero when the package is missing; jq then prints null.
  installed="$(npm ls -g --depth=0 --json "$pkg" || true)"
  installed="$(jq -r --arg pkg "$pkg" '.dependencies[$pkg].version' <<<"$installed")"
  if [[ "$installed" != "$acp_version" ]]; then
    npm install -g "$pkg@$acp_version" >/dev/null
    echo "added   $pkg@$acp_version"
  fi

  # Bare "grok" is the fallback so Air still works once grok is installed onto its PATH.
  grok="$(command -v grok || echo grok)"
  node="$(command -v node)"
  script="$(npm root -g)/$pkg/dist/index.js"
  shared="$(jq --arg grok "$grok" --arg node "$node" --arg script "$script" \
    '.agent_servers["Grok"].command = $grok
      | .agent_servers["Claude Code"].command = $node
      | .agent_servers["Claude Code"].args = [$script]' "$SETUP_DIR/air/acp.json")"
  merge_json "$shared" "$air_dir/acp.json"
}

# This checkout is the deployed copy and should be origin/main (agents/SETUP.md, Version
# control): its working files are live in every session on this machine, so a change made
# here runs before any review or test. Read-only and offline: it compares against the last
# fetched origin/main, so a merge made since that fetch is not seen.
check_deployed() {
  local top branch status changed counts ahead behind
  # The layout from before 2026-11-18: no git command is safe to suggest there.
  if [[ -f "$SETUP_DIR/.git" ]] && grep -q 'agent-setup\.git' "$SETUP_DIR/.git"; then
    echo "warning: $SETUP_DIR still has the file-sync layout (its .git is a file that names" \
      "agent-setup.git): convert it once (SETUP.md, Version control)"
    return 0
  fi
  top="$(git -C "$SETUP_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
  if [[ -z "$top" || "$(cd "$top" && pwd -P)" != "$(cd "$SETUP_DIR" && pwd -P)" ]]; then
    echo "note: $SETUP_DIR is not a git clone, so it cannot be updated with git pull" \
      "(SETUP.md, Version control)"
    return 0
  fi
  # The branch and the changed files need no origin/main, so they come before that check.
  branch="$(git -C "$SETUP_DIR" symbolic-ref -q --short HEAD || echo "a detached HEAD")"
  if [[ "$branch" != main ]]; then
    echo "warning: $SETUP_DIR is on $branch, not main: git -C \"$SETUP_DIR\" switch main"
  fi
  # No git call below may end install.sh, which still has its tool check to print: an
  # unreadable index fails this one, a clone with no commit checked out the rev-list.
  if ! status="$(git -C "$SETUP_DIR" status --porcelain)"; then
    echo "warning: cannot read the state of $SETUP_DIR (git's message above)"
    return 0
  fi
  changed="$(grep -c . <<<"$status" || true)"
  if ((changed > 0)); then
    echo "warning: $SETUP_DIR has $changed changed or untracked path(s); they are live in" \
      "every session on this machine, unreviewed. Move them to a separate clone and open a" \
      "PR (SETUP.md, Version control)."
  fi

  if ! git -C "$SETUP_DIR" rev-parse -q --verify origin/main >/dev/null; then
    echo "note: $SETUP_DIR has no origin/main to compare with: it needs a remote named" \
      "origin that has main, fetched"
    return 0
  fi
  if ! counts="$(git -C "$SETUP_DIR" rev-list --left-right --count HEAD...origin/main)"; then
    echo "warning: cannot compare $SETUP_DIR with origin/main (git's message above)"
    return 0
  fi
  read -r ahead behind <<<"$counts"
  if ((ahead > 0)); then
    echo "warning: $SETUP_DIR has $ahead commit(s) that are not on origin/main; they are" \
      "live on this machine, unreviewed. Move them to a branch in a separate clone and" \
      "open a PR."
  fi
  if ((behind > 0)); then
    # The pull is named only where it works: on main, with no commit or change of its own.
    if [[ "$branch" == main ]] && ((ahead == 0 && changed == 0)); then
      echo "note: $SETUP_DIR is $behind commit(s) behind origin/main:" \
        "git -C \"$SETUP_DIR\" pull --ff-only, then run install.sh again"
    else
      echo "note: $SETUP_DIR is $behind commit(s) behind origin/main"
    fi
  fi
}

# Grok's own config can keep it on always-approve whatever the shared settings say
# (agents/SETUP.md, Permissions): `permission_mode = "always-approve"` or the older
# `yolo = true`, both in the [ui] table. That file is the machine's and install.sh does not
# write it, so this only reports. Read by table, as setup_memory reads its own: the same
# key under another table is not Grok's mode. The dotted key `ui.permission_mode` and the
# inline table `ui = { ... }`, both written before any table, are the same setting.
check_grok_mode() {
  local config="$HOME/.grok/config.toml" setting
  if [[ ! -r "$config" || ! -f "$config" ]]; then
    return 0
  fi
  setting="$(awk '
    BEGIN {
      top = 1
      mode = "permission_mode[[:space:]]*=[[:space:]]*[\"\047]always-approve[\"\047]"
    }
    /^[[:space:]]*\[/ { top = 0; in_ui = /^[[:space:]]*\[ui\]/ }
    (in_ui && $0 ~ "^[[:space:]]*" mode) || (top && $0 ~ "^[[:space:]]*ui\\." mode) ||
      (top && $0 ~ "^[[:space:]]*ui[[:space:]]*=[[:space:]]*\\{.*" mode) {
      print "permission_mode = \"always-approve\""; exit
    }
    in_ui && /^[[:space:]]*yolo[[:space:]]*=[[:space:]]*true/ { print "yolo = true"; exit }
  ' "$config")"
  if [[ -n "$setting" ]]; then
    echo "warning: $config sets $setting, so Grok approves every tool call;" \
      "remove that line for Grok to follow the shared auto mode"
  fi
}

# The deployed copy holds the hooks, rules and scripts that every session runs outside the
# sandbox, and it lies inside a folder the sandbox may write to (agents/SETUP.md, Sandbox).
# This adds it to the machine's denied writes. The path is the machine's, so it cannot be
# in the shared copy; the merge keeps it as a local entry.
protect_setup_dir() {
  local file="$HOME/.claude/settings.json" dir
  dir="$(cd "$SETUP_DIR" && pwd -P)"
  if jq -e --arg dir "$dir" '.sandbox.filesystem.denyWrite // [] | index($dir)' "$file" \
    >/dev/null; then
    echo "ok      sandbox: no writes to $dir"
    return 0
  fi
  jq --arg dir "$dir" '.sandbox.filesystem.denyWrite += [$dir]' "$file" >"$file.new"
  mv "$file.new" "$file"
  echo "wrote   $file (sandbox: no writes to $dir)"
}

check_tools() {
  local tool missing=()
  # The Rust hooks need jq, git, perl, shasum, cargo, rustfmt and clippy; without one they
  # skip their checks (and say so).
  for tool in jq git perl shasum rustup cargo rustfmt shellcheck shfmt prek cargo-deny; do
    if ! command -v "$tool" >/dev/null; then
      missing+=("$tool")
    fi
  done
  if ! cargo clippy --version >/dev/null 2>&1; then
    missing+=("clippy (rustup component add clippy)")
  fi

  # Miri checks unsafe code in CI and locally.
  if ! rustup run nightly miri --version >/dev/null 2>&1; then
    missing+=("nightly-miri")
  fi

  if ((${#missing[@]} > 0)); then
    echo "missing tools: ${missing[*]} (see agents/SETUP.md, 'Install on a new machine')"
  fi
  # Optional: the format hook works with stable rustfmt alone.
  if ! rustup run nightly rustfmt --version >/dev/null 2>&1; then
    echo "optional: nightly rustfmt (rustup component add --toolchain nightly rustfmt)," \
      "only for repos whose rustfmt.toml uses unstable options"
  fi
}

# Copy the shared Cargo settings into ~/.cargo/config.toml, between marker lines, replacing an
# older copy. The file is not linked or merged: it also holds per-machine linkers and
# rustflags, and there is no TOML counterpart to jq here. Cargo's `include` was tried and
# dropped: a missing included file (a moved folder) makes every cargo command
# fail, and toolchain 1.88 ignores the key. A copy has neither problem; the cost is that an
# edit to cargo/config.toml reaches a machine only when install.sh runs there.
setup_cargo() {
  local local_file="$HOME/.cargo/config.toml" relative current kept new block
  local begin="# BEGIN agent-setup: from cargo/config.toml, rewritten by install.sh"
  local end="# END agent-setup"
  block="$begin"$'\n'"$(cat "$SETUP_DIR/cargo/config.toml")"$'\n'"$end"
  if [[ ! -f "$local_file" ]]; then
    mkdir -p "$(dirname "$local_file")"
    printf '%s\n' "$block" >"$local_file"
    echo "wrote   $local_file"
    return 0
  fi

  current="$(cat "$local_file")"
  kept="$(awk -v b="$begin" -v e="$end" \
    '$0 == b { skip = 1 } !skip { print } $0 == e { skip = 0 }' "$local_file")"
  # A second header for the same table would make the whole file invalid TOML.
  if grep -q '^[[:space:]]*\[profile\.dev\.package\."\*"\]' <<<"$kept"; then
    echo "skip    $local_file already sets [profile.dev.package.\"*\"]; merge" \
      "$SETUP_DIR/cargo/config.toml into it by hand"
    return 0
  fi
  new="$block"
  if [[ -n "$kept" ]]; then
    new="$kept"$'\n\n'"$block"
  fi
  if [[ "$new" == "$current" ]]; then
    echo "ok      $local_file"
    return 0
  fi

  # Copied, then written through: a symlinked config stays a symlink.
  relative="${local_file#"$HOME"/}"
  mkdir -p "$BACKUP_DIR/$(dirname "$relative")"
  cp "$local_file" "$BACKUP_DIR/$relative"
  printf '%s\n' "$new" >"$local_file"
  echo "updated $local_file (previous copy in $BACKUP_DIR)"
}

# The Grok review home (claude/scripts/grok-review.sh): GROK_HOME for review runs, with its
# own login so the main ~/.grok is out of reach, and the pr-review sandbox profile. The
# profile is copied, not linked: grok refuses a symlinked sandbox.toml. Its `~/` paths are
# expanded to this machine's HOME in the copy, because the review runs with an empty HOME
# that `~` would resolve to. A symlinked home is refused: chmod and the copy would follow
# it, into ~/.grok for example.
setup_grok_review() {
  local home="$HOME/.grok-review" source="$SETUP_DIR/grok/review-sandbox.toml"
  local target="$home/sandbox.toml"
  if [[ -L "$home" ]]; then
    echo "skip    $home is a symlink; make it a real directory to enable Grok reviews" >&2
    return 0
  fi
  mkdir -p "$home"
  chmod 700 "$home"
  # Write beside it, then rename over it, so a failed copy leaves the old profile.
  # A TOML basic ("...") or literal ('...') string; comments are left as they are.
  HOME_DIR="$HOME" perl -pe 'next if /^\s*#/; s{(["'\''])~/}{$1$ENV{HOME_DIR}/}g' "$source" \
    >"$target.new"
  if [[ -f "$target" && ! -L "$target" ]] && cmp -s "$target.new" "$target"; then
    rm -f "$target.new"
    echo "ok      $target"
  else
    chmod 600 "$target.new"
    if [[ -e "$target" || -L "$target" ]]; then
      backup "$target"
    fi
    mv -f "$target.new" "$target"
    echo "copied  $target"
  fi
  if [[ ! -f "$home/auth.json" || -L "$home/auth.json" || ! -s "$home/auth.json" ]]; then
    echo "note    Grok reviews need a login in the review home: GROK_HOME=$home grok login"
  fi
}

# Team memory is mandatory (AGENTS.md, Team memory), so check that both agents reach
# hippius-mem. Registration with the bearer token is `hippius-mem install`'s job; the token
# never enters this public repo. Claude reaches the shared loopback daemon over HTTP. Grok is
# moved onto the same daemon instead of starting its own stdio server, because a team note
# records that concurrent writer processes under one identity are not serialized on S3 and
# can permanently lose ops.
#
# Grok reads the token through `bearer_token_file`, so it never appears in argv, in Grok's
# config, or in a backup of it. `grok mcp add` has no flag for that key, so the server is added
# without auth and the key is written into its table here. Only the user-scope table is
# managed; a repo's own `.grok/config.toml` entry for hippius-mem overrides it there.
setup_memory() {
  local claude_json="$HOME/.claude.json" grok_config="$HOME/.grok/config.toml"
  local token_file="$HOME/.config/hippius-mem/mcp-token" url table relative
  if ! command -v hippius-mem >/dev/null; then
    echo "missing hippius-mem: team memory is mandatory; install it with" \
      "https://github.com/thenervelab/hippius-mem/blob/db9261b1/FOR-AGENTS.md"
    return 0
  fi
  url="$(jq -r '.mcpServers["hippius-mem"] | if .url then .url elif .command then "stdio"
    else empty end' "$claude_json" 2>/dev/null || true)"
  case "$url" in
  "")
    echo "missing hippius-mem in Claude: run \`hippius-mem install --agent claude\`, then" \
      "re-run install.sh"
    return 0
    ;;
  stdio)
    echo "ok      hippius-mem for Claude (stdio; no shared daemon to move Grok onto)"
    return 0
    ;;
  esac
  echo "ok      hippius-mem for Claude ($url)"

  if ! command -v grok >/dev/null; then
    return 0
  fi
  table="$(awk '/^\[/ { in_table = ($0 == "[mcp_servers.hippius-mem]") } in_table' \
    "$grok_config" 2>/dev/null || true)"
  if grep -qxF "url = \"$url\"" <<<"$table" &&
    grep -qxF "bearer_token_file = \"$token_file\"" <<<"$table"; then
    echo "ok      hippius-mem for Grok ($url)"
    return 0
  fi
  if [[ ! -s "$token_file" ]]; then
    echo "skip    hippius-mem for Grok: no daemon token in $token_file"
    return 0
  fi

  if [[ -f "$grok_config" ]]; then
    relative="${grok_config#"$HOME"/}"
    mkdir -p "$BACKUP_DIR/$(dirname "$relative")"
    cp "$grok_config" "$BACKUP_DIR/$relative"
  fi
  if [[ -n "$table" ]]; then
    grok mcp remove --scope user hippius-mem >/dev/null || true
  fi
  if ! grok mcp add --scope user --transport http hippius-mem "$url" >/dev/null; then
    echo "warning: \`grok mcp add\` failed; Grok is not on the hippius-mem daemon" \
      "(previous config in $BACKUP_DIR)"
    return 0
  fi
  awk -v key="bearer_token_file = \"$token_file\"" \
    '{ print } $0 == "[mcp_servers.hippius-mem]" { print key }' \
    "$grok_config" >"$grok_config.new"
  mv -f "$grok_config.new" "$grok_config"
  echo "updated hippius-mem for Grok: shared daemon $url (previous config in $BACKUP_DIR)"
}

main() {
  echo "AgentSetup: $SETUP_DIR"

  link "$SETUP_DIR/agents" "$HOME/.config/agents"
  for dir in skills agents commands hooks scripts; do
    link "$SETUP_DIR/claude/$dir" "$HOME/.claude/$dir"
  done
  link "$SETUP_DIR/claude/statusline.sh" "$HOME/.claude/statusline.sh"
  link "$SETUP_DIR/agents/AGENTS.md" "$HOME/.grok/rules/AGENTS.md"
  link "$SETUP_DIR/claude/agents/rust-style-reviewer.md" \
    "$HOME/.grok/agents/rust-style-reviewer.md"

  # The local layer (agents/SETUP.md, Local layer): rules that are not in the public repo.
  local claude_md="@~/.config/agents/AGENTS.md"
  if [[ -f "$SETUP_DIR/agents/AGENTS.local.md" ]]; then
    link "$SETUP_DIR/agents/AGENTS.local.md" "$HOME/.grok/rules/AGENTS.local.md"
    claude_md+=$'\n'"@~/.config/agents/AGENTS.local.md"
  elif [[ -L "$HOME/.grok/rules/AGENTS.local.md" ]]; then
    # The local file is gone; a link left behind would point at nothing.
    backup "$HOME/.grok/rules/AGENTS.local.md"
  fi
  if [[ "$(cat "$HOME/.claude/CLAUDE.md" 2>/dev/null)" != "$claude_md" ]]; then
    if [[ -e "$HOME/.claude/CLAUDE.md" ]]; then
      backup "$HOME/.claude/CLAUDE.md"
    fi
    printf '%s\n' "$claude_md" >"$HOME/.claude/CLAUDE.md"
    echo "wrote   $HOME/.claude/CLAUDE.md"
  else
    echo "ok      $HOME/.claude/CLAUDE.md"
  fi

  merge_json "$(cat "$SETUP_DIR/claude/settings.json")" "$HOME/.claude/settings.json"
  protect_setup_dir
  if [[ -f "$SETUP_DIR/install.local.sh" ]]; then
    bash "$SETUP_DIR/install.local.sh"
  fi
  setup_cargo
  setup_grok_review
  setup_memory
  setup_air
  check_deployed
  check_grok_mode
  check_tools
  echo "Done. Start new Claude Code and Grok sessions to pick up the changes."
}

# Run unless sourced: tests/install.test.sh sources this file to test its functions.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
