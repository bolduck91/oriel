# The widget ships multiple selectable skins

Rather than picking one layout, the widget renders the same rate-limit data in one
of **four interchangeable skins** — *twin rings*, *sidecar ring*, *inline arcs*,
*concentric gauge* — and the user switches between them at runtime via a
**right-click context menu** (a check marks the active skin). The choice is
**persisted** so it survives a restart.

Why: during design (see the reset-time prototype) the user liked several layouts
and expected to prefer different ones at different times, so a single baked-in
layout would be the wrong call. Skins are a runtime preference, not a build-time
fork.

## Consequences

- The render layer must be **skin-agnostic**: one data model, N render templates
  selected by the persisted preference. Adding a skin = adding a template, not
  touching the data path.
- The **right-click menu is the widget's settings surface** — future options
  (opacity, lock-position, start-with-Windows, quit) live there too, so it is
  built once, now.
- A persisted **config** is now required (at minimum: selected skin; later: window
  position and other preferences).
- **Reset-time format is uniform across all skins**: 5h as a countdown, 7d
  adaptive (absolute weekday+time while > 24h away, countdown once within a day).
  It is not per-skin and not an independent user setting — every skin renders time
  the same way, so switching skin changes only the layout, not the reading.
- Scroll-to-cycle was considered as a quick-flip shortcut and **deferred** — menu
  only for now.
