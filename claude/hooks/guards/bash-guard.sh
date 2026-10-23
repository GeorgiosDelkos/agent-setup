#!/usr/bin/env bash
# PreToolUse (Bash / run_terminal_command): block recursive deletes (use `trash`, which can be
# undone) and pushes that update main or master (use a feature branch and a PR). Reads
# Claude's `tool_input.command`, which Grok also sends as a snake_case alias.
#
# A guardrail against an agent's mistakes, not a sandbox: a script file, an interpreter or
# `xargs` gets past any pattern match.
set -euo pipefail

input="$(cat)"
command="$(jq -r '.tool_input.command // empty' <<<"$input")"
cwd="$(jq -r '.cwd // empty' <<<"$input")"

block() {
  echo "BLOCKED: $*" >&2
  exit 2
}

# Recursive rm in any spelling (-r, -R, -rf, -fR, -v -r, --recursive) and find -delete. -f is
# beside the point: it only skips prompts for write-protected files, so `rm -r` deletes as
# much as `rm -rf`. `git rm` is exempt: it removes tracked files, which git can restore.
deletes_recursively() {
  local git_rm='git([[:space:]]+-C[[:space:]]+[^[:space:]]+)?[[:space:]]+rm([[:space:]]|$)'
  local start='(^|[^[:alnum:]_-])' args='([[:space:]]+[^;&|[:space:]]+)*'
  local rm_r="${start}rm${args}[[:space:]]+(-[[:alpha:]]*[rR]|--recursive)"
  local find_delete="${start}find[[:space:]][^;&|]*[[:space:]]-delete([[:space:]]|\$)"
  local cmd
  cmd="$(sed -E "s/${git_rm}/git-rm\\2/g" <<<"$1")"
  grep -qE "$rm_r" <<<"$cmd" || grep -qE "$find_delete" <<<"$cmd"
}

# Current branch of the repo at $1, or nothing (detached HEAD, not a repo).
current_branch() {
  git -C "${1:-.}" symbolic-ref --short -q HEAD 2>/dev/null || true
}

# Directory $2 resolved against directory $1, with a leading `~` expanded.
resolve_dir() {
  local base="$1" dir="$2"
  dir="${dir/#\~/$HOME}"
  if [[ "$dir" != /* && -n "$base" ]]; then
    dir="$base/$dir"
  fi
  printf '%s' "$dir"
}

# Branches the `git [-C dir] push` invocations in $1 update, one per line: each refspec's
# destination, the current branch for `HEAD` or a push without a refspec (it pushes the
# current branch under push.default simple or upstream), `*` for --all, --branches, --mirror.
# The command is walked one simple command at a time so that `cd repo && git push` looks up
# the branch of `repo`, not of the session's directory.
pushed_branches() {
  local push='^git([[:space:]]+-C[[:space:]]+[^[:space:]]+)?[[:space:]]+push([[:space:]]|$)'
  local segment tokens dir="$cwd" i token positional refspec
  # One simple command per line: split at ; && || | and newlines, drop subshell parens.
  # perl, not sed: BSD sed writes `\n` in a replacement as a plain `n`.
  perl -pe 's/(&&|\|\||[;|()])/\n/g' <<<"$1" | while IFS= read -r segment; do
    read -ra tokens <<<"$segment"
    if [[ ${#tokens[@]} -eq 0 ]]; then
      continue
    fi
    if [[ "${tokens[0]}" == cd || "${tokens[0]}" == pushd ]]; then
      dir="$(resolve_dir "$dir" "${tokens[1]:-~}")"
      continue
    fi
    if ! grep -qE "$push" <<<"${tokens[*]}"; then
      continue
    fi
    local push_dir="$dir"
    i=1
    if [[ "${tokens[1]}" == -C ]]; then
      push_dir="$(resolve_dir "$dir" "${tokens[2]}")"
      i=3
    fi
    positional=()
    for ((i = i + 1; i < ${#tokens[@]}; i++)); do
      token="${tokens[i]}"
      case "$token" in
      --all | --branches | --mirror) echo '*' ;;
      -o | --push-option | --repo | --receive-pack | --exec) i=$((i + 1)) ;;
      -*) ;;
      *) positional+=("$token") ;;
      esac
    done
    if [[ ${#positional[@]} -le 1 ]]; then
      current_branch "$push_dir"
      continue
    fi
    for refspec in "${positional[@]:1}"; do
      refspec="${refspec#+}"
      refspec="${refspec##*:}"
      refspec="${refspec#refs/heads/}"
      if [[ "$refspec" == HEAD ]]; then
        current_branch "$push_dir"
      else
        printf '%s\n' "$refspec"
      fi
    done
  done
}

if deletes_recursively "$command"; then
  block "use trash instead of a recursive rm or find -delete"
fi

# Captured first: `grep -q` on a pipe would close it early and pipefail would hide a match.
branches="$(pushed_branches "$command")"
if grep -qxE 'main|master|\*' <<<"$branches"; then
  block "push to a feature branch and open a PR, never directly to main/master"
fi

# example-console only (example-service PRs target main through its merge queue): a PR into main is
# only ever a promotion from dev (dev deploys to staging, main to production), so
# `gh pr create ... --base main` must also say `--head dev`.
base_main='gh[[:space:]]+pr[[:space:]]+create.*(--base|-B)[[:space:]=]+(main|master)([[:space:]]|$)'
head_dev='(--head|-H)[[:space:]=]+dev([[:space:]]|$)'
in_console=false
if [[ "$cwd" == *example-console* || "$command" == *example/console* ]]; then
  in_console=true
fi
if $in_console && grep -qE "$base_main" <<<"$command" && ! grep -qE "$head_dev" <<<"$command"; then
  block "open PRs against dev; main only takes promotions (--head dev --base main)"
fi
