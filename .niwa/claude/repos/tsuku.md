# tsuku (monorepo)

Public monorepo for the tsuku package manager. Contains the CLI, recipe registry, marketing website, and telemetry service.

## Repo Visibility: Public

This is a public repository. Content should be written for external consumption:
- **Design docs**: Focus on external audience clarity
- **Issues/PRs**: Polished language, avoid internal references
- **Code comments**: Clear for open-source contributors
- **Commits**: Follow conventional commits without internal context

## Default Scope: Tactical

This repo is for tactical planning. When running /tsukumogami:explore or /tsukumogami:plan here:
- Designs focus on "how to build it" (implementation)
- Issues are atomic, implementable work items
- Reference upstream strategic designs if applicable
- Link to specific commits/PRs that implement each issue

Override with `--strategic` when doing product-focused work (e.g., major architecture RFC).

## Monorepo Structure

```
tsuku/
├── cmd/tsuku/           # CLI entry point
├── internal/            # CLI internal packages
├── recipes/             # Recipe registry (was tsuku-registry)
├── website/             # Marketing site (was tsuku.dev)
├── telemetry/           # Telemetry worker (was tsuku-telemetry)
├── testdata/            # Test fixtures
└── .github/workflows/   # CI/CD pipelines
```

## Component Overview

| Component | Description | Tech Stack |
|-----------|-------------|------------|
| CLI (root) | Package manager binary | Go |
| recipes/ | TOML recipe definitions | TOML, validation CI |
| website/ | tsuku.dev marketing site | Static HTML, Cloudflare Pages |
| telemetry/ | Usage analytics worker | TypeScript, Cloudflare Workers |

## Quick Reference (CLI)

```bash
# Build
go build -o tsuku ./cmd/tsuku

# Test
go test ./...

# Install locally
go install ./cmd/tsuku

# Lint
go vet ./...
golangci-lint run --timeout=5m ./...
```

## Commands

| Command | Description |
|---------|-------------|
| `tsuku install <tool>` | Install a tool |
| `tsuku remove <tool>` | Remove a tool |
| `tsuku list` | List installed tools |
| `tsuku update <tool>` | Update tool to latest version |
| `tsuku recipes` | List available recipes |
| `tsuku search <query>` | Search for tools |
| `tsuku info <tool>` | Get information about a tool |
| `tsuku versions <tool>` | List available versions for a tool |
| `tsuku verify <tool>` | Verify tool installation |
| `tsuku outdated` | Check for outdated tools |
| `tsuku update-registry` | Refresh recipe cache |

## Development

### Docker Development (Recommended)

```bash
# Start interactive development container
./docker-dev.sh shell

# Inside container:
go build -o tsuku ./cmd/tsuku
./tsuku install serve
```

### Integration Tests

```bash
# Build tsuku first
go build -o tsuku ./cmd/tsuku

# Run integration test
./tsuku install gh
gh --version
```

## Release Process

Releases are automated via GitHub Actions using GoReleaser:

1. Push a version tag: `git tag -a v0.1.0 -m "Release v0.1.0"`
2. Push tag to remote: `git push origin v0.1.0`
3. GitHub Actions automatically builds binaries and creates release

Pre-releases: Tags with hyphens (e.g., `v1.0.0-rc.1`) are marked as pre-releases.

## Environment

API keys and secrets are stored in `.local.env` at the repo root. Source this file when you need credentials (e.g., `GH_TOKEN`):

```bash
source .local.env
```

This file is gitignored and installed by the workspace `install.sh` script.

## Key Points

- All Go code must pass `gofmt` formatting
- Linting uses `golangci-lint` (see `.golangci.yaml`)
- CI runs tests and linting on every PR
- Component-specific context is in subdirectory CLAUDE.local.md files

## QA Configuration

- **Build Command**: `make build-test` (produces `tsuku-test` binary with `.tsuku-test` home override)
- **Binary Name**: `tsuku-test` → install as `tsuku` in `$QA_HOME/bin/`
- **Issue Target**: `tsukumogami/tsuku`
- **Isolation Env**: `TSUKU_HOME`, `TSUKU_TELEMETRY=0`
- **Validation Command**: `tsuku doctor`

## Conventions

### Use `$TSUKU_HOME` in documentation

When referring to the tsuku installation directory in code comments or documentation, use `$TSUKU_HOME` rather than the literal `~/.tsuku`.

**Why:** While `~/.tsuku` is the default, users can customize the location via the `$TSUKU_HOME` environment variable. Using the variable name ensures documentation remains accurate for all users.

**Preferred:**
```go
// ToolsDir contains installed tools ($TSUKU_HOME/tools)
ToolsDir string
```

**Discouraged:**
```go
// ToolsDir contains installed tools (~/.tsuku/tools)
ToolsDir string
```

This applies to:
- Code comments
- Design documents
- README and other documentation
- Error messages that reference paths