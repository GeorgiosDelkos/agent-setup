# AgentSetup

Shared Claude Code and Grok configuration: global rules, skills, agents, hooks, and
settings. One folder, a clone of this repo on each machine, so every machine uses the same
setup.

On a new machine:

```sh
gh repo clone GeorgiosDelkos/agent-setup <folder>
bash <folder>/install.sh
```

To update a machine after a merge: `git -C <folder> pull --ff-only`, then `install.sh` again.

Full layout, prerequisites, and verification: `agents/SETUP.md`.
