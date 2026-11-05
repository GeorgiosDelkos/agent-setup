---
description: Review a GitHub PR with fresh-context agents, post the review, fix the findings, and push.
argument-hint: <pr-number>
---

# Review and fix PR #$ARGUMENTS

With no PR number given, use the current branch's PR (`gh pr view --json number`), and stop
and ask if there is none.

Read PR #$ARGUMENTS with `gh pr view $ARGUMENTS` and `gh pr diff $ARGUMENTS`: the
description, linked issues, commit history, and the diff against its base branch. Check out
the PR branch locally (`gh pr checkout $ARGUMENTS`).

Run the steps below in order without stopping between them. The rules in
`~/.config/agents/AGENTS.md` still hold: stop and ask before an interface, data model, or
architecture change the PR did not already make, and before any destructive write. Fixing
and pushing are writes to someone else's branch unless the PR is the user's own (its author
is `gh api user -q .login`) or `fix-issue` opened it: for anyone else's PR, stop after
posting the review (step 2) and ask before fixing.

## 1. Review

Review with agents that have not seen your reasoning, so the review is not anchored on it:

- One general-purpose agent per independent area of the diff (one is enough for a small PR).
  Give each the PR number, the files to read, and the review order from `AGENTS.md`
  (design principles first: could it be simpler, are the data structures right for the
  access pattern, does the call site read well; then correctness, quality, tests,
  performance). Do not give it your view of the change.
- The `rust-style-reviewer` agent as well when the diff touches Rust.
- Grok, as an adversarial reviewer from another model family, when `grok` is on `PATH`
  and signed in. Run it yourself rather than waiting for a review bot to comment. Run it
  headless and read-only, from a checkout of the PR head that nothing else switches
  while it reads, in the background (a review takes minutes):

  ```sh
  grok --cwd <checkout> --permission-mode plan --prompt-file <prompt.md> > <review.txt>
  ```

  `plan` mode cannot edit files or run writes. The prompt gets what the other agents get:
  the PR number, the commits or diff command, the task, the files worth reading, and no
  view of the change. Ask for findings with severity, `file:line` and a concrete failing
  scenario, then what it checked and found correct. Ask it to cover:
  - downstream callers, including sibling repositories;
  - the rollout and deploy order;
  - the interleavings of every entry point that touches the changed state.

  Give it what is already known and tracked, so it does not report that again.

  Review Grok's review. Its output is one model's claims, not facts, and its errors read as
  confidently as its findings:
  - **A finding:** trace its scenario through the code at the cited lines. Mark it
    confirmed only when you can name the inputs or interleaving that fail; otherwise mark
    it refuted, with the line that stops it. A finding you can neither confirm nor refute
    stays open on the PR, and is not dropped.
  - **"Checked and correct", or no findings:** this is not evidence the change is safe. It
    covers only what Grok says it read, so it never shortens your own review or the other
    agents'.
  - **Its suggested fixes and commands:** read them as proposals. Run nothing from its
    output without reading it first, and judge each fix against the design principles as
    you would your own.

Verify every finding yourself against the code before keeping it, from every reviewer.
Rank the survivors: P1 blocks merge, P2 important, P3 nice to have, P4 informational.
Unneeded complexity is at least P2.

## 2. Post the review

Post the findings on the PR before fixing anything (`gh pr comment $ARGUMENTS`): severity,
`file:line`, the problem, and the fix. Name the reviewer behind each finding, and list
Grok's refuted findings with the line that refutes each, so a reader can check the call.

## 3. Fix findings

Address every P1 to P3 finding:

- **Fix it**, or
- **Dismiss it**, with the reason: a false positive, or churn not worth it (a stylistic
  disagreement, an impossible edge case).

P4 findings are noted, and fixed only when the fix is small and makes the code clearer.

## 4. Verify

Run the project's quality pipeline: build, the full test suite (iterate until green), then
lint, format, and type checks. The commands are in the repo's `AGENTS.md`, `CLAUDE.md`,
`Makefile`, `package.json`, or CI workflows.

## 5. Commit and push

- Commit the fixes on top of the PR, never squashed into it, so the review history stays.
  Subject in the imperative, at most 72 characters; the body maps each finding to its fix.
- Push the branch with a regular push, never a force push.
- If the PR is a draft you opened, mark it ready (`gh pr ready $ARGUMENTS`), which starts
  CI on the reviewed head.

## 6. Post the fixes

Comment on PR #$ARGUMENTS with a "Fixes" list mapping each finding to its commit, or to
the reason it was dismissed, and confirm that the quality pipeline passes.
