# Widget window behavior

The always-on-top widget behaves as follows (all persisted to config):

- **Always-on-top over normal windows**, but it **yields to exclusive-fullscreen**
  apps (games, full-screen video). Reclaiming topmost over exclusive fullscreen is
  fragile on Windows and the user isn't checking quota mid-game.
- **Left-click-drag to move**, anywhere on the pill; **position is remembered**
  across restarts, including which **monitor**. If that monitor is gone at launch,
  clamp back to the primary so it can never open off-screen.
- **Interactive, not click-through** — the pill captures clicks on itself (needed
  for drag + the right-click menu). It's small enough to rarely cover anything. A
  lock/click-through toggle can join the menu later.
- **Size** is a user setting — **small / medium / large** (default **small**) — that
  scales the whole widget as a unit, for accessibility.
- **Opacity** is a user setting; **default 100%** (the user chose legibility over
  ambient translucency). **Hover-to-opaque** is retained: at rest the widget sits at
  the set opacity and snaps fully opaque on mouse-over — inert at 100%, but active
  the moment opacity is dialed down.

## Consequences

- Config must persist: skin, size, opacity, window position + monitor. This is the
  same config introduced by [ADR 0003](0003-selectable-skins.md); the right-click
  menu is its UI.
- Choosing 100% default opacity is a reversal of an earlier "65% is perfect" call,
  made after seeing the widget wash out over **white** windows — see
  [ADR 0006](0006-visual-identity.md) for how tint carries cross-surface legibility.
