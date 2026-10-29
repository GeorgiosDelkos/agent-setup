# AgentSetup

Shared Claude Code and Grok configuration: global rules, skills, agents, hooks, and
settings. One folder, kept in step across machines by a file-sync service, so every machine
uses the same setup.

On a new machine, once the folder is there (synced, or cloned from this repo):

```sh
bash <folder>/install.sh
```

Run it through `bash`: file sync can drop the executable bit, which `install.sh` restores.

Full layout, prerequisites, and verification: `agents/SETUP.md`.
