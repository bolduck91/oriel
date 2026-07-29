# Issue tracker: Local Markdown, in the private workspace

Issues and specs (you may know a spec as a PRD) live as markdown files in `.scratch/`
**in the private working repository**. There is no remote tracker.

> **If you are reading this in the public repository, `.scratch/` is not here and will
> not be.** Publishing is clean-room (ADR 0012): code, `docs/` and `CONTEXT.md` cross
> over; tickets, research and prototypes stay behind. Everything below describes the
> private workspace. Do not create a `.scratch/` in a clone of the public repo and do
> not go looking for one — if you need the reasoning behind a decision, it is in
> `docs/adr/`, which is the part that was published deliberately.
>
> Moving the tracker to GitHub issues is separate housekeeping and has not happened. If
> and when it does, this document and `CLAUDE.md` are what must change with it — they
> are read at the start of every agent session, so a stale answer here quietly causes
> work to be done the old way.

## Conventions

- One feature per directory: `.scratch/<feature-slug>/`
- The spec is `.scratch/<feature-slug>/spec.md`
- Implementation issues are one file per ticket at `.scratch/<feature-slug>/issues/<NN>-<slug>.md`, numbered from `01` — never a single combined tickets file
- **Status and labels are two different things, on two different lines.**
  - `Status:` is where the work stands: `open` or `resolved` (older files say `done`, which means the same).
  - `Labels:` carries the triage roles — `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix` (see `triage-labels.md`). Several may apply; comma-separate them.

  A label is not a status. `ready-for-agent` says *who should pick this up*, not *whether it is finished*; `wontfix` says a decision was taken, and the ticket is still `resolved`. Putting a label in the `Status:` line loses one of the two facts.
- Comments and conversation history append to the bottom of the file under a `## Comments` heading

## When a skill says "publish to the issue tracker"

Create a new file under `.scratch/<feature-slug>/` (creating the directory if needed).

## When a skill says "fetch the relevant ticket"

Read the file at the referenced path. The user will normally pass the path or the issue number directly.

## Wayfinding operations

Used by `/wayfinder`. The **map** is a file with one **child** file per ticket.

- **Map**: `.scratch/<effort>/map.md` — the Notes / Decisions-so-far / Fog body.
- **Child ticket**: `.scratch/<effort>/issues/NN-<slug>.md`, numbered from `01`, with the question in the body. A `Type:` line records the ticket type (`research`/`prototype`/`grilling`/`task`); a `Status:` line records `claimed`/`resolved`.
- **Blocking**: a `Blocked by: NN, NN` line near the top. A ticket is unblocked when every file it lists is `resolved`.
- **Frontier**: scan `.scratch/<effort>/issues/` for files that are open, unblocked, and unclaimed; first by number wins.
- **Claim**: set `Status: claimed` and save before any work.
- **Resolve**: append the answer under an `## Answer` heading, set `Status: resolved`, then append a context pointer (gist + link) to the map's Decisions-so-far in `map.md`.
