#!/usr/bin/env bash
# Link this machine's Claude Code and Grok configuration to this shared AgentSetup folder.
#
# Idempotent: links that are already correct are left alone; anything else at a target
# path is moved to ~/.agent-setup-backup/<timestamp>/ before it is replaced. settings.json is
# merged rather than linked because Claude Code rewrites it in place, which would replace a
# symlink with a plain file.
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

# Merge the shared JSON text $1 into the file $2. Shared keys win key by key; local-only keys
# (and the whole file, on a fresh machine) are kept. Arrays such as hook lists are taken from
# the shared copy. The previous file goes to the backup dir, at its path relative to $HOME.
merge_json() {
  local shared="$1" local_file="$2" merged relative
  if [[ ! -f "$local_file" ]]; then
    mkdir -p "$(dirname "$local_file")"
    printf '%s\n' "$shared" >"$local_file"
    echo "copied  $local_file"
    return 0
  fi

  merged="$(jq -s '.[0] * .[1]' "$local_file" <(printf '%s\n' "$shared"))"
  if [[ "$merged" == "$(jq . "$local_file")" ]]; then
    echo "ok      $local_file"
    return 0
  fi

  relative="${local_file#"$HOME"/}"
  mkdir -p "$BACKUP_DIR/$(dirname "$relative")"
  cp "$local_file" "$BACKUP_DIR/$relative"
  printf '%s\n' "$merged" >"$local_file"
  echo "merged  $local_file (previous copy in $BACKUP_DIR)"
}

# Register the team-memory MCP server with Claude Code and Grok when the binary and its
# config exist. The config holds bucket credentials and keys, so it is never synced through
# this folder; it is copied to each machine by hand (see agents/SETUP.md). Existing
# registrations are left untouched.
register_Sync_mem() {
  local bin="$HOME/.cargo/bin/team-memory"
  local config="$HOME/.config/team-memory/team-memory.toml"
  local grok_servers
  if [[ ! -x "$bin" || ! -f "$config" ]]; then
    echo "skip    team-memory (needs $bin and $config; see agents/SETUP.md)"
    return 0
  fi

  if ! command -v claude >/dev/null; then
    echo "skip    team-memory for Claude (claude CLI not found)"
  elif claude mcp get team-memory >/dev/null 2>&1; then
    echo "ok      team-memory (Claude)"
  else
    claude mcp add --scope user team-memory -e "TEAM_MEMORY_CONFIG=$config" -- "$bin"
    echo "added   team-memory (Claude)"
  fi

  if ! command -v grok >/dev/null; then
    echo "skip    team-memory for Grok (grok CLI not found)"
    return 0
  fi

  # Read the whole list before matching. Piping into `grep -q` closes the pipe at the first
  # match; grok then panics on the broken pipe and pipefail reports the match as a failure.
  grok_servers="$(grok mcp list 2>/dev/null || true)"
  if grep -qE '^[[:space:]]*team-memory:' <<<"$grok_servers"; then
    echo "ok      team-memory (Grok)"
  else
    grok mcp add --scope user team-memory -e "TEAM_MEMORY_CONFIG=$config" -- "$bin"
    echo "added   team-memory (Grok)"
  fi
}

# Register Grok and Claude Code as ACP agents in JetBrains Air. The Claude adapter is pinned
# and installed globally. The grok, node, and script paths are absolute because Air, started
# from the Dock, may not see the shell's PATH (~/.grok/bin, nvm). Merged like settings.json: shared agents win, agents
# added locally in Air stay.
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

# History lives in GitHub. The git directory stays outside this synced folder, because a .git
# directory synced between machines can be corrupted by concurrent writes. The folder's `.git`
# file points to ../../.local/share/agent-setup.git (relative, so it holds for any home
# directory with ~/Synced-Storage/AgentSetup); create that git directory where it is missing.
# The synced working files are left as they are: only the index is built from HEAD.
setup_git() {
  local git_dir="$HOME/.local/share/agent-setup.git"
  local remote="https://github.com/GeorgiosDelkos/agent-setup.git"
  if [[ "$SETUP_DIR" != "$HOME/Synced-Storage/AgentSetup" ]]; then
    echo "skip    git history (the .git file expects ~/Synced-Storage/AgentSetup)"
    return 0
  fi
  if ! command -v git >/dev/null; then
    echo "skip    git history (git not found)"
    return 0
  fi

  if [[ ! -d "$git_dir" ]]; then
    mkdir -p "$(dirname "$git_dir")"
    if ! git clone -q --bare "$remote" "$git_dir"; then
      echo "skip    git history (cannot clone $remote: check \`gh auth status\`)"
      return 0
    fi
  fi

  # Sync sync does not carry the .git file to other machines, so it is written here,
  # once the git directory it points to exists.
  if [[ ! -e "$SETUP_DIR/.git" ]]; then
    printf 'gitdir: ../../.local/share/agent-setup.git\n' >"$SETUP_DIR/.git"
    echo "wrote   $SETUP_DIR/.git"
  fi

  # The index is the last thing written below, so it marks a finished setup. A run that
  # stopped after the clone resumes from here.
  if [[ -f "$git_dir/index" ]]; then
    echo "ok      $git_dir"
    return 0
  fi
  git --git-dir="$git_dir" config core.bare false
  git --git-dir="$git_dir" config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
  if ! git -C "$SETUP_DIR" fetch -q origin; then
    echo "skip    git history (cannot fetch $remote: check \`gh auth status\`, then re-run)"
    return 0
  fi
  git -C "$SETUP_DIR" branch -q --set-upstream-to=origin/main main
  git -C "$SETUP_DIR" reset -q
  echo "cloned  $git_dir"
}

# The synced folder is the deployed copy and should match origin/main (agents/SETUP.md,
# Version control): an edit made in it is live on every machine before any review or test.
# Read-only and offline: it compares against the last fetched origin/main.
check_sync() {
  local branch changed behind
  if ! git -C "$SETUP_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    return 0
  fi
  branch="$(git -C "$SETUP_DIR" symbolic-ref -q --short HEAD || echo "a detached HEAD")"
  if [[ "$branch" != main ]]; then
    echo "warning: $SETUP_DIR is on $branch, not main: every machine runs that branch"
  fi
  changed="$(git -C "$SETUP_DIR" status --porcelain | wc -l | tr -d ' ')"
  if ((changed > 0)); then
    echo "warning: $SETUP_DIR has $changed changed files that are not in git; they are live" \
      "on every machine, unreviewed. Move them to a clone and open a PR (SETUP.md, Version" \
      "control)."
  fi
  behind="$(git -C "$SETUP_DIR" rev-list --count HEAD..origin/main 2>/dev/null || echo 0)"
  if ((behind > 0)); then
    echo "note: $SETUP_DIR is $behind commits behind origin/main: git pull --ff-only"
  fi
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

main() {
  echo "AgentSetup: $SETUP_DIR"

  link "$SETUP_DIR/agents" "$HOME/.config/agents"
  for dir in skills agents commands hooks; do
    link "$SETUP_DIR/claude/$dir" "$HOME/.claude/$dir"
  done
  link "$SETUP_DIR/claude/statusline.sh" "$HOME/.claude/statusline.sh"
  link "$SETUP_DIR/agents/AGENTS.md" "$HOME/.grok/rules/AGENTS.md"
  link "$SETUP_DIR/claude/agents/rust-style-reviewer.md" \
    "$HOME/.grok/agents/rust-style-reviewer.md"

  if [[ "$(cat "$HOME/.claude/CLAUDE.md" 2>/dev/null)" != "@~/.config/agents/AGENTS.md" ]]; then
    if [[ -e "$HOME/.claude/CLAUDE.md" ]]; then
      backup "$HOME/.claude/CLAUDE.md"
    fi
    printf '@~/.config/agents/AGENTS.md\n' >"$HOME/.claude/CLAUDE.md"
    echo "wrote   $HOME/.claude/CLAUDE.md"
  else
    echo "ok      $HOME/.claude/CLAUDE.md"
  fi

  merge_json "$(cat "$SETUP_DIR/claude/settings.json")" "$HOME/.claude/settings.json"
  register_Sync_mem
  setup_air
  setup_git
  check_sync
  # Sync drops the executable bit, so restore it on everything that is run directly.
  chmod +x "$SETUP_DIR/install.sh" "$SETUP_DIR"/claude/hooks/*/*.sh "$SETUP_DIR/claude/statusline.sh"
  check_tools
  echo "Done. Start new Claude Code and Grok sessions to pick up the changes."
}

main "$@"
