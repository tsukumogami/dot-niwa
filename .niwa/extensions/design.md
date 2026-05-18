# Tsukumogami Project Extension: design

## Label Lifecycle

| Transition | From | To | When |
|------------|------|-----|------|
| Triage -> Design | `needs-triage` | `needs-design` | Triage identifies design need |
| Design accepted | `needs-design` | (removed) | Design doc reaches Accepted status |
| Design spawns plan | (none) | `tracks-design` | Child design created from parent issue |
| Plan created | `tracks-design` | `tracks-plan` | Plan created from design doc |

## Mermaid Status Classes

| Label | Mermaid Class |
|-------|--------------|
| `needs-design` | `needsDesign` |
| `needs-prd` | `needsPrd` |
| `needs-spike` | `needsSpike` |
| `needs-decision` | `needsDecision` |
| `tracks-design` | `tracksDesign` |
| `tracks-plan` | `tracksPlan` |

## Content Governance

- **Private repos:** May include internal stakeholder notes, competitive references
- **Public repos:** Must not reference private issues or internal resources