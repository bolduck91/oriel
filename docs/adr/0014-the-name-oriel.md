# The name is Oriel, and Anthropic's mark stays in the description

The project is published as **Oriel — a usage widget for Claude Code**, not as
*Claude Usage Widget*.

**An oriel is a window that projects out from a wall so one can watch from inside
it.** The domain's own unit is a window — the **5-hour window**, the **7-day
window** — and the product is a small window floating in front of the others. The
name is the one place where the thing measured, the thing built, and the act of
watching are the same word.

## Two reasons the old name could not ship

**It is taken, twice.** `claude-usage-widget` is already the name of two GitHub
projects doing very nearly this: one a cross-platform widget plus CLI, the other a
Windows 11 taskbar widget. Publishing under it would have meant arriving third into
a name.

**It leads with someone else's trademark.** Describing compatibility by naming the
product one is compatible with is ordinary and widely tolerated; opening a product
name with another company's mark is the exposed end of that spectrum. Putting the
mark in the descriptor keeps the useful part — people find it by searching for Claude
Code — without the claim. This is consistent with how this project has already
resolved that kind of question (the go/no-go took the compliant path at real feature
cost), and here it costs only a naming exercise.

## What this frees up

The survey done while naming turned up the neighbours, and with them the sentence the
README needs. Comparable tools read the OAuth token Claude Code stores in
`~/.claude/.credentials.json` and poll `api.anthropic.com` with it. Anthropic
restricted OAuth tokens to its own products server-side in January 2026 and
documented in February 2026 that using them in third-party tools violates the
Consumer Terms. Oriel never touches credentials and never calls Anthropic: it reads
only what Claude Code already pushes to the statusline. **That is the differentiator,
and it was a consequence of a decision made before it was an advantage.**

Before that claim goes in the README it should be checked against Anthropic's own
legal and compliance page; the dates above come from secondary reporting.

## Consequences

- The name reaches all the way down: executable, state directory (`~/.claude/oriel/`)
  and **managed block** markers. Half-renaming would leave a directory named after a
  product that no longer exists, and a future reader unable to tell which name is
  authoritative.
- Because it reaches that far it breaks the one installation that already exists, so
  the installer migrates: it moves the old state directory and replaces the old
  markers on first run. The migration code is disposable, and it gets tested against a
  real prior install — the author's.
