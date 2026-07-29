# Build the widget with PowerShell + WPF

> **Superseded for the rendering half by
> [ADR 0008](0008-avalonia-rendering-stack.md).** WPF has no `Compositor` on its
> `HwndTarget`, so it can only ask DWM for a backdrop and inherits DWM's corner enum —
> which has no radius parameter. That made the locked 26px-radius pill with real blur
> ([ADR 0006](0006-visual-identity.md)) structurally unreachable, and the widget's
> rendering moved to Avalonia. **The tee below is still PowerShell and still current**;
> only the window is affected.

The widget must float always-on-top on Windows 11 and look discreet. We chose
**PowerShell hosting a WPF window** over Electron, Tauri, Rainmeter, Python, and
AutoHotkey.

Why: **zero new runtime** (WPF ships with .NET on Windows 11 — no node_modules,
Rust toolchain, or build step), and it keeps the **whole project in one language**
— the statusline that produces the data is already PowerShell, so the tee-writer
and the reader share a stack. WPF natively covers the hard requirements:
`TopMost` for always-on-top, borderless + `AllowsTransparency` for a discreet
floating pill, opacity/rounded corners via XAML, drag-to-move in a few lines.

## Considered Options

- **Tauri / Electron** — nicer styling, but a heavy toolchain/binary for a tiny
  always-on-top pill.
- **Rainmeter** — purpose-built for file-driven desktop widgets, but a heavier
  install, a skinning DSL, and weaker topmost behaviour over fullscreen apps.
- **Python / AutoHotkey** — each drags in a runtime not already required.

## Consequences

A PowerShell process hosting a persistent WPF window is slightly unusual: it must
be launched windowless (e.g. `pwsh -WindowStyle Hidden` or a small shim), and XAML
has no hot-reload during development. Neither blocks a personal widget.
