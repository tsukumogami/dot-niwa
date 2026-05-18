# Tsukumogami Project Extension: prd

## Label Lifecycle

| Transition | From | To | When |
|------------|------|-----|------|
| Triage -> PRD | `needs-triage` | `needs-prd` | Triage identifies requirements need |
| PRD accepted | `needs-prd` | (removed) | PRD reaches Accepted status |
| PRD spawns plan | (none) | `tracks-plan` | Plan created from PRD |

## Mermaid Status Classes

| Label | Mermaid Class |
|-------|--------------|
| `needs-prd` | `needsPrd` |
| `tracks-plan` | `tracksPlan` |

## Content Governance

- **Private repos:** May include business rationale, stakeholder discussions
- **Public repos:** Must not reference private issues or internal resources