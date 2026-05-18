# tsuku/telemetry

Cloudflare Worker that receives and aggregates telemetry events from the tsuku CLI, exposing aggregated statistics via a public API.

## Quick Reference

```bash
# Install dependencies
npm install

# Local development (runs at http://localhost:8787)
npx wrangler dev

# Deploy to Cloudflare Workers
npx wrangler deploy

# Type checking
npx tsc
```

## Directory Structure

```
telemetry/
├── src/
│   └── index.ts           # Cloudflare Worker entrypoint
├── wrangler.toml          # Cloudflare Workers configuration
├── package.json
├── tsconfig.json
├── docs/
│   └── DESIGN.md          # Architecture and implementation details
└── README.md
```

## API Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/event` | POST | Receives telemetry events from tsuku CLI |
| `/stats` | GET | Returns aggregated statistics |
| `/stats/recipe/:name` | GET | Recipe-specific statistics |
| `/health` | GET | Health check endpoint |

## Event Schema

All events require `recipe` and `action` fields. Optional: `version`, `os`, `arch`, `tsuku_version`.

Actions: "install", "update", "remove"

## Development Notes

- Events stored in Cloudflare Analytics Engine (tsuku_telemetry dataset)
- No authentication on write endpoint (public telemetry collection)
- CORS enabled for stats endpoints
- Auto-deploys from main branch via GitHub Actions (requires CLOUDFLARE_API_TOKEN secret)
- Reference docs/DESIGN.md for implementation details

## Related Components

- CLI (root) - Sends telemetry events
- website/ - Stats dashboard consumer