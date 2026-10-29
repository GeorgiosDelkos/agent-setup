#!/usr/bin/env bash
# PreToolUse (Bash / run_terminal_command): block recursive deletes (use `trash`, which can be
# undone), git commands that throw away uncommitted work, pushes that update main or master
# (use a feature branch and a PR), and admin merges that skip a PR's checks. Reads Claude's
# `tool_input.command`, which Grok also sends as a snake_case alias.
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

# The command with its data taken out, so the checks below match what runs, not what is
# written: heredoc bodies are dropped, and a quoted string holding a space or a shell operator
# (a commit message, a grep pattern) becomes Q. Other quotes only lose their quote marks, so
# `"main"` stays a refspec, and a double-quoted `$(...)` stays code. A command that hands text
# to a shell (`bash -c`, `eval`, `ssh`, a pipe or heredoc into a shell) is kept whole: there
# the quoted text is what runs. Backslash line continuations are joined first.
code_text() {
  perl -0777 -ne '
    sub data { my $text = shift; $text =~ /[\s;&|()<>]/ ? "Q" : $text }
    sub double { my $text = shift; $text =~ /\$\(|`/ ? $text : data($text) }
    s/\\\n/ /g;
    my $original = $_;
    s/<<-?[ \t]*([\x27"]?)(\w+)\1([^\n]*)\n.*?^\t*\2[ \t]*$/<<HEREDOC$3/gms;
    # One left-to-right pass, so the leftmost quote wins: an apostrophe inside "..." does not
    # pair with a later single quote, and an escaped quote outside quotes opens nothing.
    s/\\.|\x27([^\x27]*)\x27|"((?:[^"\\]|\\.)*)"/
      defined $1 ? data($1) : defined $2 ? double($2) : $&/gse;
    # Checked on the stripped text, so a message that mentions eval or bash -c is still data.
    my $shell = qr/(?:ba|z|da)?sh(?:\s+--?[\w-]+)*/;
    my $start = qr/(?:^|[;&|(]\s*|\s)/;
    my $runs = qr/(?:^|[;&|(]\s*)(?:eval|ssh)\s/;
    if (/$start(?:$shell\s+-\w*c\b|$shell\s*<<)|$runs|\|\s*$shell(?:\s|$)/) {
      print $original;
      exit;
    }
    print;' <<<"$1"
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

# Why the first simple command in $1 that throws away uncommitted work does so, or nothing.
# trash cannot bring any of it back: `git clean -f` deletes untracked files, `git reset
# --hard` and a checkout or restore of the whole tree overwrite every uncommitted change. A
# single path (`git checkout -- src/x.rs`) and `git restore --staged` pass.
discards_work() {
  # Leading VAR=value words, then git with any global options (-C dir, -c key=value, --long).
  local git='^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*git'
  git+='(([[:space:]]+-[Cc][[:space:]]+[^[:space:]]+)|([[:space:]]+--[a-z-]+(=[^[:space:]]*)?))*'
  git+='[[:space:]]+'
  local force='[[:space:]](-[[:alpha:]]*f[[:alpha:]]*|--force)([[:space:]]|$)'
  local dry_run='[[:space:]](-[[:alpha:]]*n[[:alpha:]]*|--dry-run)([[:space:]]|$)'
  local whole_tree='[[:space:]](\.|\./|:/|\*)([[:space:]]|$)'
  local staged_only='[[:space:]](--staged|-S)([[:space:]]|$)'
  local worktree='[[:space:]](--worktree|-W)([[:space:]]|$)'
  local discard='[[:space:]](-f|--force|--discard-changes)([[:space:]]|$)'
  local segment
  while IFS= read -r segment; do
    if [[ "$segment" =~ ${git}clean([[:space:]]|$) && "$segment" =~ $force &&
      ! "$segment" =~ $dry_run ]]; then
      echo "git clean -f deletes untracked files for good: list them with git clean -n," \
        "then trash the ones to delete"
      return
    fi
    if [[ "$segment" =~ ${git}reset([[:space:]].*)?[[:space:]]--hard([[:space:]]|$) ]]; then
      echo "git reset --hard overwrites uncommitted changes: use git reset --keep, which" \
        "refuses to, or ask the user"
      return
    fi
    if [[ "$segment" =~ ${git}(checkout|restore)[[:space:]] && "$segment" =~ $whole_tree ]] &&
      ! [[ "$segment" =~ $staged_only && ! "$segment" =~ $worktree ]]; then
      echo "a checkout or restore of the whole tree overwrites every uncommitted change:" \
        "git stash them first, or name the files"
      return
    fi
    if [[ "$segment" =~ ${git}(checkout|switch)[[:space:]] && "$segment" =~ $discard ]]; then
      echo "a forced checkout or switch throws away uncommitted changes: git stash them first"
      return
    fi
  done < <(perl -pe 's/(&&|\|\||[;|()])/\n/g' <<<"$1")
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

code="$(code_text "$command")"
if deletes_recursively "$code"; then
  block "use trash instead of a recursive rm or find -delete"
fi

reason="$(discards_work "$code")"
if [[ -n "$reason" ]]; then
  block "$reason"
fi

# Captured first: `grep -q` on a pipe would close it early and pipefail would hide a match.
branches="$(pushed_branches "$code")"
if grep -qxE 'main|master|\*' <<<"$branches"; then
  block "push to a feature branch and open a PR, never directly to main/master"
fi

admin_merge='(^|[;&|(][[:space:]]*)gh[[:space:]]+pr[[:space:]]+merge[[:space:]].*--admin'
if grep -qE "$admin_merge" <<<"$code"; then
  block "gh pr merge --admin skips the PR's required reviews and checks: leave the merge" \
    "to the user"
fi
