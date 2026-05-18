# Tsuku Project

Tsuku is a self-contained package manager for developer tools. It installs tools to `~/.tsuku/` without requiring sudo or system dependencies.

## Philosophy

- **Self-contained**: Users only need tsuku to install anything
- **No system dependencies**: Tools are downloaded as pre-built binaries or built in isolation
- **Reproducible**: Recipes define exact installation steps
- **Version-aware**: Multiple versions can coexist, managed via symlinks

## Workspace Structure

```
{workspace}/
├── CLAUDE.md                    # This file (org-wide context)
├── .claude/                     # Shared commands and skills
└── public/
    ├── CLAUDE.md                # Public visibility context
    ├── .github/                 # Org community health files
    ├── koto/                    # Workflow orchestration engine
    ├── niwa/                    # Workspace manager CLI
    ├── shirabe/                 # Workflow skills plugin
    └── tsuku/                   # Monorepo with component configs
```

## Repositories

| Repository | Description | Visibility |
|------------|-------------|------------|
| `tsuku` | Monorepo: CLI, recipes, website, telemetry | Public |
| `koto` | Workflow orchestration engine for AI coding agents | Public |
| `niwa` | Workspace manager CLI | Public |
| `shirabe` | Workflow skills plugin | Public |
| `.github` | Org community health files | Public |

## Monorepo Structure (tsuku)

The `tsuku` repository is a monorepo containing all public-facing components:

| Path | Component | Description |
|------|-----------|-------------|
| `/` (root) | CLI | Go package manager binary |
| `recipes/` | Registry | TOML recipe definitions |
| `website/` | Marketing | tsuku.dev static site |
| `telemetry/` | Analytics | Cloudflare Worker for usage stats |

## Architecture

### Core Concepts

- **Recipe**: TOML file defining how to install a tool (download URL, extraction, verification)
- **Action**: Composable installation step (download, extract, chmod, install_binaries, etc.)
- **Version Provider**: Resolves latest version from GitHub, PyPI, crates.io, npm, RubyGems, etc.

### Key Directories

```
~/.tsuku/
├── bin/           # Symlinks to installed binaries (add to PATH)
├── tools/         # Installed tools (name-version directories)
├── registry/      # Cached recipes from tsuku/recipes
└── state.json     # Installation state (versions, dependencies)
```

## Conventions

- Recipe names: kebab-case (e.g., `cargo-audit`, `aws-cli`)
- Go code: standard gofmt, no external linters beyond go vet
- No emojis in code or committed documentation
- Issues track all planned work with detailed descriptions
- Never add AI attribution or co-author lines to commits or PRs (no "Generated with Claude Code", no "Co-Authored-By: Claude")

## Writing Style

Avoid overused AI writing patterns. See `.claude/helpers/writing-style.md` for details.

**Quick reference - avoid these words:**
- "tier/tiered" (use: level, category, phase)
- "robust" (use: reliable, solid)
- "leverage" (use: use, apply)
- "comprehensive/holistic" (use: complete, full)
- "facilitate" (use: enable, allow)

Write directly without preamble ("It's worth noting that..."). Vary sentence length. Use contractions.

## File Operations

When creating or editing files, prefer dedicated tools over shell commands:

- **Creating files**: Use the Write tool, not `cat` with heredocs or `echo` with redirects
- **Editing files**: Use the Edit tool for targeted changes, Write for complete rewrites

Shell commands like `cat <<'EOF'` are acceptable when:
- Generating content within executed shell scripts
- Piping content to other commands (not writing files)

This improves user experience by providing better feedback and error handling.

## Key Technical Decisions

1. **Monorepo consolidation**: CLI, recipes, website, and telemetry unified in single repo
2. **Action-based installation**: Composable steps instead of monolithic installers
3. **Version providers**: Pluggable system for resolving versions from different sources
4. **Nix backend for complex deps**: Some tools use nix-portable for hermetic builds

## Development Workflow

Implementation happens in the `tsuku` monorepo:
- CLI changes: root Go code
- Recipe changes: `recipes/` directory
- Website changes: `website/` directory
- Telemetry changes: `telemetry/` directory

## Testing

- Unit tests: `go test ./...` in tsuku/
- CI runs on every PR via GitHub Actions

## Temporary Artifacts (wip/)

The `wip/` (Work In Progress) directory holds temporary artifacts during niwa workflow commands. It is a coordinator-handoff staging area: agents drop intermediate artifacts there during multi-step workflows, and the workflow's cleanup phase deletes them before the PR can merge.

### The wip-hygiene rule

Files under `wip/` are non-durable. They MUST NOT be referenced from any committed final artifact — not from frontmatter (e.g. `upstream:`), not from prose, not from code comments — and they MUST be removed from the branch before a PR can merge. **This rule applies workspace-wide, to every repo regardless of visibility (public or private).**

Why both halves matter:

- Cleanup deletes the physical files. Any committed reference to a `wip/...` path becomes a dangling pointer the instant cleanup runs, breaking the audit trail for the artifact a future reader is trying to follow.
- "Clean up wip/" is two operations, not one: (1) delete the files, (2) grep committed prose, frontmatter, and code for `wip/` and remove every reference. Both must happen before the cleanup commit lands.

The rule is workspace-wide because `wip/` is a workflow primitive, not a CI artifact. Private repos run the same workflows as public ones; orphan references break audit trails in both, and the staging-then-delete contract is identical regardless of visibility.

### Enforcement

The `shirabe:design` and `shirabe:plan` skills enforce this rule via their Phase 0 validation step (cross-repo path resolution, `wip/...` reject in `upstream:` frontmatter, references-section scan). Public-repo CI also runs a grep-based check on every PR. Private repos rely on the skill-level check plus reviewer discipline; the rule is identical.

### Storage and resumability

**Do NOT .gitignore wip/.** These files are committed to feature branches during workflows and cleaned before merge. PRs use squash-merge, so wip/ artifacts never appear in the main branch history. Gitignoring wip/ breaks workflow resumability since agents need to `git add` state files during multi-issue implementations.

### Private overlay note

The private workspace overlay (`tsukumogami/dot-niwa-overlay`) carries its own CLAUDE.md fragments for private-visibility repos. Those fragments must mirror this rule verbatim — the canonical wording lives here so the overlay can copy-and-keep-in-sync rather than re-derive the framing.
