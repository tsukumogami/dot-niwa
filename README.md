# tsukumogami workspace config

Declarative workspace configuration for the tsukumogami org, managed by
[niwa](https://github.com/tsukumogami/niwa).

## Setup

```bash
niwa init tsukumogami --from tsukumogami/dot-niwa
niwa create
```

That is the whole setup. You need no credentials, no vault client, and no
account beyond whatever `git clone` already needs.

## Secrets

This workspace declares a handful of optional secrets. **None of them is
required.** Every repo clones, builds and tests without any of them set, and
`niwa create` succeeds on a host with no secret manager installed.

If a declared key has no value, niwa reports it once, leaves it out of the
generated environment files, and carries on. Each key's description in
`.niwa/workspace.toml` says what it buys and what happens without it.

The one worth setting is `GH_TOKEN`. Unauthenticated GitHub API calls are capped
at 60 requests an hour, which is usually enough to clone this org but will
rate-limit a busy session:

```bash
export GH_TOKEN=$(gh auth token)
```

Maintainers get the rest through their own arrangements; nothing about that is
needed to contribute.

## Structure

```
.niwa/workspace.toml Workspace declaration
claude/              CLAUDE.md content hierarchy
hooks/               Claude Code hook scripts (auto-discovered)
env/                 Environment files (auto-discovered)
extensions/          Shirabe extension files (distributed via [files])
```

### Repo-level context

A repo receives context when this config declares it: a `[claude.content.repos.*]`
entry in `.niwa/workspace.toml`, or — with no entry — a file at
`claude/repos/<repo>.md`, which niwa discovers on its own. An entry may draw its
text from here, from a private overlay, or from both, and only an entry can
declare subdirectory content.

Either way it arrives in the instance as that repo's `CLAUDE.local.md`. Edit the
source here; the generated file is rewritten on every `niwa apply`.

## Updating

After modifying workspace.toml or any config files:

```bash
niwa apply
```
