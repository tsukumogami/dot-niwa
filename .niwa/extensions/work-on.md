# Tsukumogami Project Extension: work-on

## Label Vocabulary

### Blocking Labels (stop execution if present)

| Label | Routing Message |
|-------|----------------|
| `needs-triage` | "This issue needs triage. Run `/tsukumogami:triage <issue-number>` first." |
| `needs-design` | "This issue needs a design. Run `/shirabe:explore <issue-number>` to investigate." |
| `needs-prd` | "This issue needs requirements. Run `/shirabe:explore <issue-number>` to investigate." |
| `needs-spike` | "This issue needs a spike. Run `/shirabe:explore <issue-number>` to investigate." |
| `needs-decision` | "This issue needs a decision. Run `/shirabe:explore <issue-number>` to investigate." |

### Tracking Labels (stop, redirect to child artifact)

| Label | Routing Message |
|-------|----------------|
| `tracks-design` | "This issue tracks a child design. Work on the child design instead." |
| `tracks-plan` | "This issue tracks a child plan. Work on the child plan's issues instead." |

## Triage Workflow

If the issue has `needs-triage`, invoke the triage skill: `/tsukumogami:triage <issue-number>`

## Language Skill

Invoke the appropriate language skill based on issue content:
- Go code: `/tsukumogami:go-development`
- Bash/shell scripts: `/tsukumogami:bash-development`
- Rust code: `/tsukumogami:rust-development`
- TypeScript/Node.js: `/tsukumogami:nodejs`
- HTML/CSS/frontend: `/tsukumogami:web-development`

## PR Creation Skill

Invoke `/tsukumogami:pr-creation` for pull request requirements.