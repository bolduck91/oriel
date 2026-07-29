# Widget lifecycle

- **Config** lives in `~/.claude/oriel/config.json`, alongside the state file
  `current.json`. It persists skin, size, opacity, and window position + monitor,
  and is written whenever a setting changes via the right-click menu.
- **Single instance** — one widget process at a time, enforced by a named mutex; a
  second launch no-ops rather than stacking a duplicate pill.
- **Start with Windows** — a right-click-menu toggle, **default off**. The user opts
  in once; the app does not install a startup entry unprompted.
- **Hidden launch** — no console flash on start. ~~The PowerShell host starts
  windowless (`pwsh -WindowStyle Hidden` via a shortcut / small `.vbs` shim).~~
  Superseded by ADR 0008: the widget is a GUI-subsystem executable, so there is no
  console to hide and no shim to launch it through.
- **Quit** — from the right-click menu.

## Consequences

- The runtime user directory `~/.claude/oriel/` holds both the tee's
  `current.json` and this `config.json`; the repo holds only the code that reads and
  writes them.
