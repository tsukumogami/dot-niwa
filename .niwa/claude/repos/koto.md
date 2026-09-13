# koto (workspace context)

Workspace context for koto, installed as `CLAUDE.local.md` and read alongside the
repo's own `CLAUDE.md`. That file is authoritative for repository structure, build,
test and lint, and `koto --help` lists the current subcommands. Nothing here restates
either: koto's `CLAUDE.md` changes in the same commit as the code it describes, and a
copy kept here would not.

## Default Scope: Tactical

This repo is for tactical planning. When running /shirabe:explore or /shirabe:plan here:
- Designs focus on "how to build it" (implementation)
- Issues are atomic, implementable work items
- Reference upstream strategic designs if applicable
- Link to specific commits/PRs that implement each issue

Override with `--strategic` when doing product-focused work (e.g., major architecture RFC).

## Environment

API keys and secrets are stored in `.local.env` at the repo root. Source this file when you need credentials (e.g., `GH_TOKEN`):

```bash
source .local.env
```

niwa generates that file when it applies the workspace configuration, and the repo's own `.gitignore` keeps it out of git.
