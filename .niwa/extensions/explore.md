# Tsukumogami Project Extension: explore

## Label Vocabulary

| Label | Meaning |
|-------|---------|
| `needs-triage` | Issue needs classification before exploration |
| `needs-design` | Issue needs technical design work |
| `needs-prd` | Issue needs requirements definition |
| `needs-spike` | Issue needs feasibility investigation |
| `needs-decision` | Issue needs architectural choice |

## Content Governance

- **Private repos:** May reference competitors, internal discussions, and exploratory ideas
- **Public repos:** Must not reference private issues or internal-only resources

## Artifact Naming

Use kebab-case topics for all wip/ artifacts:
- `wip/explore_<topic>_scope.md`
- `wip/explore_<topic>_findings.md`
- `wip/research/explore_<topic>_r<N>_lead-<name>.md`