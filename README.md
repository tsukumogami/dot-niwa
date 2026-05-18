# tsukumogami workspace config

Declarative workspace configuration for the tsukumogami org, managed by
[niwa](https://github.com/tsukumogami/niwa).

## Setup

```bash
niwa init tsukumogami --from tsukumogami/dot-niwa
GITHUB_TOKEN=$(gh auth token) niwa create
```

## Structure

```
.niwa/workspace.toml Workspace declaration
claude/              CLAUDE.md content hierarchy
hooks/               Claude Code hook scripts (auto-discovered)
env/                 Environment files (auto-discovered)
extensions/          Shirabe extension files (distributed via [files])
```

## Updating

After modifying workspace.toml or any config files:

```bash
niwa apply
```
