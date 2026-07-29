# Oriel

An always-on-top desktop widget for Windows that shows the current Claude Code
subscription rate-limit consumption (percentage + reset time) so the numbers stay
visible when the terminal is hidden behind other windows.

## Language

**Oriel**:
The product: the **widget**, the **tee** that feeds it, and the installer that
joins the two. Named for the window that projects from a wall so one can watch
from inside it — the thing it measures is also a pair of windows (ADR 0014).
_Avoid_: Claude Usage Widget, the app, the tool

**Widget**:
The always-on-top Avalonia window that displays the rate-limit numbers.
Single-account, read-only.
_Avoid_: app, tray icon, overlay

**Skin**:
One of the interchangeable visual layouts the widget can render the same data in.
The user switches between skins at runtime; the choice is a persisted preference,
not a build-time fork. Four skins are in scope: **twin rings**, **sidecar ring**,
**inline arcs**, **concentric gauge**.
_Avoid_: theme, variant, mode, template

**Tee**:
The side-effect write the statusline script performs on each render — emitting the
normalized rate-limit record to the state file. A side effect of statusline
rendering, never its primary job.
_Avoid_: export, dump, log

**State file**:
The single JSON file at `~/.claude/oriel/current.json` holding the last-known
normalized record. Written atomically by the tee, read by the widget.
_Avoid_: cache, pipe, output file

**Supported statusline**:
A statusline Oriel can attach the **tee** to: one written in PowerShell that keeps
the JSON Claude Code pushes it in a variable the tee can reach. The shape matters
because the pushed JSON can only be read once — a statusline that consumes it
without keeping it leaves nothing to tee (ADR 0011).
_Avoid_: compatible statusline, valid statusline

**Starter statusline**:
The statusline Oriel writes for someone who has none, so that the **tee** has a
host. It is an ordinary **supported statusline** the user then owns and may edit —
not a managed file.
_Avoid_: default statusline, template, generated statusline

**Managed block**:
The marked region Oriel inserts into a statusline to invoke the **tee**. Delimited
so that installing twice replaces it rather than stacking, and uninstalling removes
exactly it and nothing else.
_Avoid_: snippet, patch, hook

**Triage**:
The installer's reading of what the user already has — no statusline, a
**supported statusline**, or one Oriel declines to touch — which decides whether it
writes a **starter statusline**, injects the **managed block**, or refuses.
_Avoid_: detection, scan, probe

**Normalized record**:
The small widget-owned JSON shape written to the state file: `five_hour`,
`seven_day` (each `used_percentage` + `resets_at`), and `written_at`. Deliberately
decoupled from the full statusline JSON schema Claude Code emits.
_Avoid_: payload, blob

**5-hour window** / **7-day window**:
The two Claude Code subscription rate-limit windows (`rate_limits.five_hour` and
`rate_limits.seven_day`). Each has a `used_percentage` (0–100) and a `resets_at`.
_Avoid_: session limit, weekly limit (use these exact terms)

**Tint**:
The darkness of the widget glass's own ground, independent of window opacity. It is
the **cross-surface legibility lever**: a darker tint keeps the dark-glass widget
readable even when it floats over a white window. Default 75%.
_Avoid_: background opacity, alpha

**Blur**:
Whether the widget glass blurs the windows behind it — **tint**'s neighbouring lever:
blur is what is behind the ground, tint is the ground laid over it. Two steps, `full`
(acrylic) and `off` (see-through but unblurred), because the platform takes a
transparency *level* rather than a radius and the one middle step available was
measured to be identical to `off` (ADR 0010). Default `full`.
_Avoid_: blur radius, frost, transparency

**Severity colour**:
The green / amber / red the widget applies by **used_percentage** band (green < 50,
amber < 80, red ≥ 80, pastel), carried on the percentage number and its ring. Red =
high usage, matching the statusline. Distinct from the neutral **Stale** grey.
_Avoid_: status colour, heat

**used_percentage**:
The 0–100 fraction of a window already consumed, as pushed by Claude Code. The
source is "used"; any "remaining" figure the widget shows is a presentation flip.

**resets_at**:
The instant a window's consumption resets. Unix epoch seconds in the state file.

**written_at**:
Unix-epoch timestamp the tee stamps on each write, used by the widget to detect
staleness (see **Stale**).

**Stale**:
The state of the widget when `written_at` is older than the freshness threshold —
i.e. no active session is feeding it, so the **used_percentage** is frozen. Shown
by the percentages draining to a neutral grey; the countdown is *not* stale (it
ticks off the absolute `resets_at`) and keeps its live look.
_Avoid_: frozen, expired, offline

**Due**:
The countdown state once `now` reaches a window's `resets_at`: the widget shows
`resets: due` rather than a negative timer or a fabricated 0%. The next tee write
repopulates the real numbers.
