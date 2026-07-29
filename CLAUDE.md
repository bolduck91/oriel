## Agent skills

### Issue tracker

Issues and specs live as markdown files under `.scratch/<feature>/` in the **private working repository** (local markdown, no remote tracker). They are deliberately not published: the public repo is clean-room and carries code, `docs/` and `CONTEXT.md` only (ADR 0012). If `.scratch/` is absent, you are in the public repo — do not create one. See `docs/agents/issue-tracker.md`.

### Triage labels

The five canonical triage roles, each label string equal to its name (`needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`). See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: one `CONTEXT.md` + `docs/adr/` at the repo root. See `docs/agents/domain.md`.
