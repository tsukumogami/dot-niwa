# Tsuku Project

Tsuku is a self-contained package manager for developer tools. It installs tools to `~/.tsuku/` without requiring sudo or system dependencies.

## Philosophy

- **Self-contained**: Users only need tsuku to install anything
- **No system dependencies**: Tools are downloaded as pre-built binaries or built in isolation
- **Reproducible**: Recipes define exact installation steps
- **Version-aware**: Multiple versions can coexist, managed via symlinks

## Public Repositories

The generated `workspace-context.md` at the instance root lists what this instance
actually cloned; this table says what each public repo is for.

| Repository | Description |
|------------|-------------|
| `tsuku` | Monorepo: CLI, recipes, website, telemetry |
| `koto` | Workflow orchestration engine for AI coding agents |
| `niwa` | Workspace manager CLI |
| `shirabe` | Workflow skills plugin |
| `dot-niwa` | Workspace configuration for the tsukumogami org |
| `.github` | Org community health files |

niwa installs repo-level context for `tsuku` and `koto` only, from the
`[claude.content.repos.*]` entries in `dot-niwa`'s `.niwa/workspace.toml`
(`tsuku` also gets context for its `recipes/`, `website/`, and `telemetry/`
subdirectories). Any other repo's `CLAUDE.md`, if it has one, is committed in
that repo.

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

Avoid overused AI writing patterns. `/shirabe:writing-style` carries the full guidance and can revise a draft against it.

**Quick reference - avoid these words:**
- "tier/tiered" (use: level, category, phase)
- "robust" (use: reliable, solid)
- "leverage" (use: use, apply)
- "comprehensive/holistic" (use: complete, full)
- "facilitate" (use: enable, allow)

Write directly without preamble ("It's worth noting that..."). Vary sentence length. Use contractions.

## Communication Style

Answer in plain-language narrative, not structured report. Lead with
what happened or what the answer is; two or three paragraphs of normal
sentences beat any wall of bullets with bold labels. Prefer concrete
facts ("the daemon strips the flag before the worker sees it") over
abstractions ("the platform posture invalidates the approach"). Never
use internal artifact codes (R7, D3, R-SEC-1) in conversation — say
what the thing is; codes live inside documents. Don't offer menus of
options with trade-off tables unless asked for a decision — give one
recommendation and the reason. Headers, tables, and bullets in chat
are for genuinely tabular data only; when in doubt, use prose. If the
answer fits in two paragraphs, two paragraphs is the answer.

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

## Testing

- Unit tests: `go test ./...` in tsuku/
- CI runs on every PR via GitHub Actions

## Temporary Artifacts (wip/)

The `wip/` (Work In Progress) directory holds temporary artifacts during multi-step skill workflows. It is a coordinator-handoff staging area: agents drop intermediate artifacts there during multi-step workflows, and the workflow's cleanup phase deletes them before the PR can merge.

### The wip-hygiene rule

Files under `wip/` are non-durable. They MUST NOT be referenced from any committed final artifact — not from frontmatter (e.g. `upstream:`), not from prose, not from code comments — and they MUST be removed from the branch before a PR can merge. **This rule applies workspace-wide, to every repo regardless of visibility (public or private).**

Why both halves matter:

- Cleanup deletes the physical files. Any committed reference to a `wip/...` path becomes a dangling pointer the instant cleanup runs, breaking the audit trail for the artifact a future reader is trying to follow.
- "Clean up wip/" is two operations, not one: (1) delete the files, (2) grep committed prose, frontmatter, and code for `wip/` and remove every reference. Both must happen before the cleanup commit lands.

The rule is workspace-wide because `wip/` is a workflow primitive, not a CI artifact. Private repos run the same workflows as public ones; orphan references break audit trails in both, and the staging-then-delete contract is identical regardless of visibility.

### Enforcement

The `shirabe:design` and `shirabe:plan` skills enforce this rule via their Phase 0 validation step (cross-repo path resolution, `wip/...` reject in `upstream:` frontmatter, references-section scan).

CI enforcement is per-repo and covers only the first half of the rule. Where a repo has the check, it fails a pull request whose `wip/` directory survives; the exact trigger and whether draft PRs are exempt vary, so read the repo's own workflows rather than assuming. Many repos have no check at all.

No repo greps committed prose for `wip/` references. The second half of the rule — removing every reference before the cleanup commit lands — rests entirely on the skill-level check and reviewer discipline, in every repo, including the ones whose CI catches a surviving directory.

The rule itself is the same everywhere; only the enforcement differs.

### Storage and resumability

**Do NOT .gitignore wip/.** These files are committed to feature branches during workflows and cleaned before merge. PRs use squash-merge, so wip/ artifacts never appear in the main branch history. Gitignoring wip/ breaks workflow resumability since agents need to `git add` state files during multi-issue implementations.
