# tsuku/website

Official marketing website and install endpoint for tsuku package manager.

## What This Is

Static website deployed via Cloudflare Pages:
- Main site: https://tsuku.dev (landing page)
- Install endpoint: https://get.tsuku.dev (serves install.sh)
- Stats: https://tsuku.dev/stats/ (placeholder)
- Privacy: https://tsuku.dev/telemetry/ (placeholder)

## Quick Reference

```bash
# Local development (no build step)
python3 -m http.server 8000

# Or with Node.js
npx serve
```

## Key Files

| File | Purpose |
|------|---------|
| `index.html` | Landing page with installation command and feature overview |
| `assets/style.css` | Dark theme styles (minimal, self-contained) |
| `install.sh` | Installation script (synced from main tsuku repo) |
| `_redirects` | Cloudflare Pages path-based routing |
| `_headers` | Custom HTTP headers (Content-Type for install.sh, caching) |
| `stats/index.html` | Telemetry dashboard placeholder |
| `telemetry/index.html` | Privacy policy placeholder |

## Directory Structure

```
website/
├── index.html          # Main landing page
├── install.sh          # Installation script (from CLI)
├── assets/
│   └── style.css       # GitHub-like dark theme
├── stats/
│   └── index.html      # Dashboard placeholder
├── telemetry/
│   └── index.html      # Privacy policy placeholder
├── _redirects          # Cloudflare Pages routing config
└── _headers            # Custom HTTP headers
```

## Key Conventions

- **No build step**: Static files only. Test locally with `python3 -m http.server 8000`
- **CSS variables**: Theme colors defined in `:root` (dark theme)
- **install.sh sync**: Keep install.sh in sync with CLI root
- **Cloudflare Pages config**: Domain routing is handled by Cloudflare configuration
- **Cache headers**: install.sh has 5-minute cache; adjust in _headers if needed
- **Responsive design**: Mobile-first breakpoint at 600px