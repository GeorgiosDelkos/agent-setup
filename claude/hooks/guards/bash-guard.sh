#!/usr/bin/env bash
# PreToolUse (Bash / run_terminal_command): block recursive deletes (use `trash`, which can be
# undone), git commands that throw away uncommitted or stashed work, pushes that update main
# or master (use a feature branch and a PR), force pushes, admin merges that skip a PR's
# checks, and `cargo mutants` runs that let a runaway mutant exhaust memory. Reads Claude's
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
# to a shell (`bash -c`, `eval`, `ssh`, a heredoc into a shell, a pipe into a shell that reads
# its script from stdin) is kept whole: there the quoted text is what runs. Backslash line
# continuations are joined first.
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
    # A shell, by name or path, with its options. -o and -O (alone or ending a cluster, as in
    # `-euo pipefail`) and --rcfile / --init-file take the next word as their value; read as
    # a script operand, that word made `bash -euo pipefail -c ...` look like no hand-off.
    my $value = qr/-[A-Za-z]*[oO]\s+\S+|--(?:rcfile|init-file)\s+\S+/;
    my $options = qr/(?:\s+(?:$value|-[\w-]*))*/;
    my $shell = qr/(?:[\w.~-]*\/)*(?:ba|z|da)?sh$options/;
    my $start = qr/(?:^|[;&|(]\s*|\s)/;
    my $runs = qr/(?:^|[;&|(]\s*)(?:eval|ssh)\s/;
    # A pipe into a shell hands the piped text over only when the shell reads its script from
    # stdin: -s is among its options, or no script operand follows them (the command ends, an
    # operator, a redirect or a comment comes next, or the operand is \/dev\/stdin).
    # `... | bash hook.sh` runs the file and gets the pipe as data, so its quoted arguments
    # stay data. `||` is not a pipe.
    my $dash_s = qr/\s+-[A-Za-z]*s[A-Za-z]*(?:\s|\z)/;
    my $no_script = qr/\s*(?:\z|[;&|)}\n\x60]|\d*[<>]|#)|\s+\/dev\/stdin\b/;
    my $piped = qr/(?<!\|)\|\s*(?:$shell$dash_s|$shell(?:$no_script))/;
    if (/$start(?:$shell\s+-\w*c\b|$shell\s*<<)|$runs|$piped/) {
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

# git's global options that take their value as a separate word (`git -C dir`), from the
# usage of git 2.56 plus --attr-source and --super-prefix, which it also accepts. Any other
# word before the subcommand that starts with `-` stands alone (-P, --no-pager, --opt=value).
git_value_options=(-C -c --git-dir --work-tree --namespace --config-env --attr-source
  --super-prefix)

# The simple commands in $1, one per line: split at ; & && || | backticks and newlines, with
# subshell parens dropped. Quote marks become spaces: code_text keeps a shell hand-off
# (`bash -c "..."`, ssh) whole, and a closing quote right after `--hard` or `main` would hide
# the word from the checks. Known limit: a quoted option value with a space inside a
# hand-off (`bash -c 'git -c "a=b c" push'`) splits into words. perl, not sed: BSD sed writes
# `\n` in a replacement as a plain `n`.
simple_commands() {
  perl -pe 's/(&&|\|\||[;&|()`])/\n/g; s/["\x27]/ /g' <<<"$1"
}

# Why the first simple command in $1 that throws away uncommitted work does so, or nothing.
# trash cannot bring any of it back: `git clean -f` deletes untracked files, `git reset
# --hard` and a checkout or restore of the whole tree overwrite every uncommitted change. A
# single path (`git checkout -- src/x.rs`) and `git restore --staged` pass. `git stash drop`
# and `git stash clear` delete the changes a stash holds, which is where this guard's own
# messages send uncommitted work.
#
# `git branch -D` is deliberately not here: the branch's commits stay reachable through the
# reflog, and review-pr.md (Worktrees) uses it to remove a merged PR's branch.
discards_work() {
  # git as a word anywhere in the simple command, with the same boundary as the gh check
  # below, so a prefix (VAR=value, `env`, `sudo`, `command`, a full path, `then`) does not
  # hide it; then any global options (git_value_options with their value, or one word
  # starting with `-`). The costs: an unquoted `echo git reset --hard` is blocked, and so is
  # `find . -exec git checkout -- {} ;`, whose `.` reads as the whole tree (it does discard
  # those files, under the wrong message).
  local value_options="${git_value_options[*]}"
  local option="[[:space:]]+(${value_options// /|})[[:space:]]+[^[:space:]]+"
  local git="(^|[^[:alnum:]_.-])git(${option}|[[:space:]]+-[^[:space:]]+)*[[:space:]]+"
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
    if [[ "$segment" =~ ${git}stash[[:space:]]+(drop|clear)([[:space:]]|$) ]]; then
      echo "git stash drop and git stash clear delete stashed changes: apply the stash" \
        "(git stash pop), or leave it and tell the user"
      return
    fi
  done < <(simple_commands "$1")
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

# For one simple command run in directory $1, given as the remaining words: when it runs
# `git push`, print the index of `push` among those words and the directory git runs in;
# otherwise print nothing. Every word that is git, or a path ending in /git, is tried, as in
# discards_work, so a prefix (VAR=value, `env`, `sudo -u git`, `then`) does not hide it.
# Each -C applies relative to the one before, as git does. The cost: an unquoted
# `echo git push origin main` is blocked.
git_push_at() {
  local base="$1" words g i dir value_options=" ${git_value_options[*]} "
  shift
  words=("$@")
  for ((g = 0; g < ${#words[@]}; g++)); do
    if ! [[ "${words[g]}" =~ ^(.*/)?git$ ]]; then
      continue
    fi
    dir="$base"
    for ((i = g + 1; i < ${#words[@]}; i++)); do
      if [[ "${words[i]}" == -C ]]; then
        dir="$(resolve_dir "$dir" "${words[i + 1]:-}")"
        i=$((i + 1))
      elif [[ "$value_options" == *" ${words[i]} "* ]]; then
        i=$((i + 1))
      elif [[ "${words[i]}" != -* ]]; then
        break
      fi
    done
    if [[ "${words[i]:-}" == push ]]; then
      printf '%s %s\n' "$i" "$dir"
      return
    fi
  done
}

# $1 with each command substitution replaced by the word SUBST and its redirections removed,
# so the words of one `git push` stay in one simple command. simple_commands splits at the
# parentheses of `$(...)`, at backticks and at the `&` of `2>&1`: that hid a force option
# written after `"$(git branch --show-current)"`, and turned `git push origin 2>&1` on main
# into a push of a branch named `2>`. push_effects walks this text as well as the plain one,
# which still shows a push inside a substitution.
flattened() {
  perl -0777 -pe 's/\$\([^()]*\)|`[^`]*`/SUBST/g;
    s/\s\d*(?:>>?|<+)&?\d*-?(?:\s*[^\s;&|()<>]+)?//g' <<<"$1"
}

# What the `git push` invocations in $1 do, one line each. A branch they update: each
# refspec's destination, or the current branch for `HEAD`, for a substitution (SUBST, most
# often the current branch's name) and for a push without a refspec (it pushes the current
# branch under push.default simple or upstream). `*` for --all, --branches, --mirror. And
# `~force` for a forced push, which no branch name can be (git forbids `~` in a ref name):
# -f alone or in a cluster of short options (-uf), --force, --force-with-lease in any
# spelling git accepts (a value, an abbreviation), or a refspec that starts with `+`.
# The command is walked one simple command at a time so that `cd repo && git push` looks up
# the branch of `repo`, not of the session's directory.
push_effects() {
  local segment tokens dir="$cwd" i token positional refspec push_dir
  simple_commands "$1" | while IFS= read -r segment; do
    read -ra tokens <<<"$segment"
    if [[ ${#tokens[@]} -eq 0 ]]; then
      continue
    fi
    if [[ "${tokens[0]}" == cd || "${tokens[0]}" == pushd ]]; then
      dir="$(resolve_dir "$dir" "${tokens[1]:-~}")"
      continue
    fi
    read -r i push_dir <<<"$(git_push_at "$dir" "${tokens[@]}")"
    if [[ -z "$i" ]]; then
      continue
    fi
    positional=()
    for ((i = i + 1; i < ${#tokens[@]}; i++)); do
      token="${tokens[i]}"
      case "$token" in
      --all | --branches | --mirror) echo '*' ;;
      -o | --push-option | --repo | --receive-pack | --exec) i=$((i + 1)) ;;
      --force | --force-w*) echo '~force' ;;
      --*) ;;
      -*f*) echo '~force' ;;
      -*) ;;
      *) positional+=("$token") ;;
      esac
    done
    if [[ ${#positional[@]} -le 1 ]]; then
      current_branch "$push_dir"
      continue
    fi
    for refspec in "${positional[@]:1}"; do
      if [[ "$refspec" == +* ]]; then
        echo '~force'
      fi
      refspec="${refspec#+}"
      refspec="${refspec##*:}"
      refspec="${refspec#refs/heads/}"
      if [[ "$refspec" == HEAD || "$refspec" == SUBST ]]; then
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
effects="$(
  push_effects "$code"
  push_effects "$(flattened "$code")"
)"
if grep -qxE 'main|master|\*' <<<"$effects"; then
  block "push to a feature branch and open a PR, never directly to main/master"
fi
# The permission deny list has `git push --force*` and `git push *--force*`, but they match
# only a command that starts with `git push` and spells the option out: `git push -f`, a
# `+refspec`, and `git -C dir push --force` got past them.
if grep -qx '~force' <<<"$effects"; then
  block "a force push replaces commits on the remote branch: add a commit on top and push" \
    "it, or leave the force push to the user"
fi

# Why the first `cargo mutants` in $1 can let a runaway mutant exhaust memory, or nothing.
# A mutant can make a loop unbounded, and only the auto test timeout ends it: an explicit
# timeout or a skipped baseline (300 s) gives it longer to grow, and each job above 2 adds a
# process that can grow (rust-style TST-20). Words after ` -- ` go to the test runner, so
# they are not mutants' options. CARGO_MUTANTS_JOBS is checked in every simple command,
# because `export` sets it in one command for a later one.
unbounded_mutants() {
  local mutants='(^|[^[:alnum:]_.-])cargo(-mutants)?([[:space:]]+\+[^[:space:]]+)?'
  mutants+='[[:space:]]+mutants([[:space:]]|$)'
  local timeout='[[:space:]](-t|--timeout)([[:space:]]|=|[0-9]|$)'
  local skip='[[:space:]]--baseline([[:space:]]+|=)skip([[:space:]]|$)'
  local jobs='[[:space:]](-j|--jobs)(=|[[:space:]]*)([0-9]+)'
  local env_jobs='(^|[[:space:]])CARGO_MUTANTS_JOBS=([0-9]+)'
  local fix="run cargo mutants with -j 2 or fewer and no --timeout, -t or --baseline=skip"
  local segment
  while IFS= read -r segment; do
    if [[ "$segment" =~ $env_jobs ]] && ((10#${BASH_REMATCH[2]} > 2)); then
      echo "CARGO_MUTANTS_JOBS above 2 runs that many test processes at once: $fix"
      return
    fi
    if ! [[ "$segment" =~ $mutants ]]; then
      continue
    fi
    segment="${segment%%[[:space:]]--[[:space:]]*}"
    if [[ "$segment" =~ $timeout || "$segment" =~ $skip ]]; then
      echo "a set test timeout lets a runaway mutant allocate for that long: $fix"
      return
    fi
    if [[ "$segment" =~ $jobs ]] && ((10#${BASH_REMATCH[3]} > 2)); then
      echo "each cargo mutants job is a test process a runaway mutant can grow in: $fix"
      return
    fi
  done < <(simple_commands "$1")
}

reason="$(unbounded_mutants "$code")"
if [[ -n "$reason" ]]; then
  block "$reason"
fi

# `gh` as a word anywhere, as for rm above, not only at a command start: a prefix (`env`,
# `sudo`, `command`, VAR=value, a full path, `then`) would otherwise hide the merge. The cost:
# an unquoted `echo gh pr merge 7 --admin` is blocked too. `--admin` must be in the same
# simple command, and gh's own `-R`/`--repo` may come before `pr`.
admin_merge='(^|[^[:alnum:]_.-])gh([[:space:]]+(-R|--repo)([[:space:]]+|=)[^[:space:]]+)?'
admin_merge+='[[:space:]]+pr[[:space:]]+merge[[:space:]][^;&|]*--admin'
if grep -qE "$admin_merge" <<<"$code"; then
  block "gh pr merge --admin skips the PR's required reviews and checks: leave the merge" \
    "to the user"
fi
