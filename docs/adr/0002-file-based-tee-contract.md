# Statusline tees to a file the widget polls

The statusline and the widget communicate through a **single JSON state file**
(`~/.claude/oriel/current.json`), not a named pipe or socket.

The deciding fact: the statusline script is **ephemeral** — Claude Code spawns it
fresh each render and it exits immediately, so it cannot hold a pipe/socket server
open between turns. A file naturally **persists the last-known value** after the
process exits, which is exactly what an always-on-top widget needs to keep showing
a number between turns, with no listener/reconnect logic in the widget.

The file holds a **normalized record the widget owns** (`five_hour`, `seven_day`
with `used_percentage` + `resets_at`, and a `written_at` stamp), not the raw
statusline JSON — this gives us a write-timestamp for staleness detection and
decouples the widget from Claude Code's full schema.

## Consequences

- The tee **writes atomically** (temp file + `Move-Item -Force`) so the widget
  never reads a torn file.
- The tee is **fail-silent** (wrapped in try/catch): it is a side effect of
  statusline rendering and must never break the statusline's actual output.

## Multiple concurrent sessions

Each open Claude Code session runs its own statusline and tees to the same
`current.json`. Because every session reports the **same single account's**
server-side numbers, they agree — so the rule is simply **last-write-wins**: the
most recent tee is the freshest copy of the same truth, and the atomic write keeps
concurrent writes from tearing.

The one guard: **never tee a nully record.** A just-started session has
`rate_limits` absent until its first API response; if it wrote anyway it would
clobber good numbers with nulls and blank the widget. So the tee **only writes when
the window data is present** — a starting-up session stays silent and leaves the
last-known-good value intact.
