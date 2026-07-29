# Running Oriel

An always-on-top Windows widget showing your Claude Code 5-hour and 7-day
rate-limit usage, fed entirely by the data Claude Code already pushes to your
statusline — **it never calls Anthropic's API and never touches a credential** (see
ADR 0002 / the ToS-clean guarantee).

The one network call anywhere in Oriel is the startup version check against its own
release host: it sends nothing about you, downloads nothing, replaces nothing, and is
switchable from the right-click menu (ADR 0012). The tee itself remains under a hard
never-reach-the-network guardrail.

Most people should install Oriel with the downloadable installer or the one-line
terminal install — see the README. What follows is the *from-source* route, which is
what you want if you are working on Oriel itself.

## One-time setup

1. **Run the installer entry point** — the same code both front ends drive. It reads
   what your Claude Code settings declare, decides which of the three populations you
   are in (**triage**), patches or writes a statusline accordingly, and then verifies
   that data actually started flowing before reporting success:

   ```powershell
   pwsh -NoProfile -File src/install/Install-Oriel.ps1 -Action install
   ```

   - `-Action triage` reports what it *would* do and shows the exact **managed block**,
     without writing anything.
   - `-Action uninstall` removes the block; add `-KeepStarter` to hold on to a
     statusline Oriel wrote for you.
   - Everything it reads is an input — `-HomeDir`, `-SettingsPath`, `-TeePath`,
     `-Interpreters` — which is why the whole feature is testable without a machine to
     install onto.

   If you have **no statusline**, it writes you one (model, effort, context use, and
   both rate-limit windows) and declares it. If you have a **supported statusline** —
   PowerShell that keeps the pushed JSON in a variable — it inserts the block after
   that assignment and changes nothing else. If it cannot serve you it **refuses**,
   leaves your disk exactly as it found it, and prints text you can paste into Claude
   Code to convert your statusline (ADR 0011).

   Re-run it if you move this repo: the injected block dot-sources the tee by absolute
   path.

2. **Build the widget** (one command, from the repo root):

   ```powershell
   pwsh -NoProfile -File build.ps1
   ```

   This publishes `dist/Oriel.exe` — a single self-contained file.
   Add `-Run` to launch it as soon as it builds.

3. **Launch it.** Double-click `dist\Oriel.exe`. No console window
   appears, and no runtime needs installing.

### What each side needs

| | Requirement |
|---|---|
| **Building** | The [.NET 8 SDK](https://dotnet.microsoft.com/download/dotnet/8.0). Note that a `dotnet` already on your PATH is often a *runtime-only* install and cannot build; `build.ps1` checks for a real SDK, also looks in `%LOCALAPPDATA%\Microsoft\dotnet` and `%DOTNET_ROOT%`, and tells you which if none qualifies. |
| **Running** | Nothing. The executable carries its own runtime, so it can be copied to a machine with no .NET at all. |

Build output (`dist/`, `bin/`, `obj/`) is git-ignored — no compiled artefacts
land in the repo.

The widget appears once your active Claude Code session makes its first API call
(that's when `rate_limits` first appears in the statusline JSON). Until then it
shows a quiet "waiting for a Claude Code session" state — never fabricated zeros.

## Using it

- **Drag** anywhere on the pill to move it; the position is remembered.
- **Right-click** for the menu: switch **skin** (twin rings / sidecar ring /
  inline arcs / concentric gauge), **size** (S/M/L), **opacity**, **tint**,
  **blur** (full acrylic / off),
  **accent**, toggle **Start with Windows** (off by default) and **Reset
  notifications**, and **Quit**.
- **Hover** to snap to full opacity when you've dialed opacity down.
- Colours: green < 50%, amber < 80%, red ≥ 80% (used %, so red = heavy use). A
  small red ▲ by the 7-day figure means you're burning ahead of the clock.
- If no session feeds it for a few minutes the percentages **drain to grey**
  (stale) while the countdown keeps ticking — the countdown is never stale.

### Start with Windows

Off by default. Toggling it on adds a per-user `Run` registry entry (no admin, no
scheduled task) pointing at `dist\Oriel.exe` — the *published* path,
so it keeps working after every rebuild. Enabling it from a development build
under `src\app\bin\` registers the published executable instead, provided one has
been built; the git-ignored `bin\` path would stop working at the next clean
rebuild.

You can also drive it from a script, which is the way to repair an entry after
moving the repo:

```powershell
dist\Oriel.exe --startup status   # prints the registered path
dist\Oriel.exe --startup on
dist\Oriel.exe --startup off      # removes the entry entirely
```

Exit codes: `0` the command did what you asked (for `status`, startup is on),
`1` `status` and startup is off, `2` unknown verb, `3` the registry refused.

If a registration already exists but points somewhere else, the widget re-points
it at itself the next time it starts. It never *creates* one you didn't ask for.

Preferences and the state file live under `~/.claude/oriel/`
(`config.json` + `current.json`). Only one widget runs at a time
(single-instance).

## Files

| Path | Role |
|------|------|
| `build.ps1`, `src/build/*.ps1` | The one build command, and the SDK lookup behind it |
| `src/app/*.cs`, `*.csproj` | The widget itself (Avalonia, ADR 0008): `Program.cs` window + menu + lifecycle, `Skins.cs` rings and the four skins, `Core.cs` pure logic, `Shadow.cs` the drop-shadow companion window (ADR 0009) |
| `src/tee/*.ps1` | The tee, self-contained: normalize, atomic write (never-tee-nulls) |
| `src/install/*.ps1` | The installer: `Statusline.ps1` the pure judgement (triage, anchoring, insertion and its exact inverse), `Install-Oriel.ps1` the one thing that writes to a user's disk, `starter-statusline.ps1` the statusline written for someone who has none |
| `installer/` | The two front ends over that entry point: the Inno Setup wizard and the one-line terminal install (ADR 0012) |
| `tests/app/*.cs` | xUnit tests over the C# logic that drives the widget |
| `tests/*.Tests.ps1` | Pester unit tests for the tee and the SDK lookup |

Run all tests: `pwsh -NoProfile -File tests/Run-AllTests.ps1`.
Just the C# core (needs the .NET 8 SDK): `pwsh -NoProfile -File tests/Run-CoreTests.ps1`.

The whole suite passes **while the widget is running** — nothing in it competes with
the live app for the single-instance gate.

The repo holds one widget. The original PowerShell/WPF implementation was removed
once this one reached parity; ADR 0008 records why it could never render the spec,
and it is still in git history if you want to read it.

## Notes / limitations

- **The backdrop blur is real.** The pill is genuine acrylic — it samples and blurs
  the windows behind it, at the spec's 26px corner radius, which is the whole reason
  the widget moved to Avalonia (ADR 0008). Measured rather than eyeballed: a hard
  colour boundary passing behind the pill spreads from a 0px step to a ~70px ramp.
  On Windows 10, or anywhere the compositor declines — transparency effects switched
  off, battery saver, a remote desktop session — the request falls back through plain
  blur to see-through and then to none, and the widget degrades to the tinted
  dark-glass look. Tint, not blur, is the cross-surface legibility lever (ADR 0006), so
  it stays readable either way. Set `CLAUDE_WIDGET_DIAG=<path>` to have the widget
  record what the compositor actually granted, as against what it asked for — one
  block appended per appearance change, so switching blur or tint leaves a trail
  rather than only its last state.

- **Blur is a two-step setting, not a slider.** `Blur > Full (acrylic)` or
  `Blur > Off`, which asks for see-through-but-unblurred rather than going opaque. It is
  two steps because the platform takes a transparency *level* and not a radius, and
  because the one intermediate level available was measured to come back identical to
  off (ADR 0010). A `config.json` from before this change carries `blur` as a number;
  it loads as `full` and is rewritten as a step, leaving your other preferences alone.

  If you want to check the glass yourself, use a **large colour field** — a big flat
  block with a hard edge. Fine stripes blur into flat grey and look exactly like an
  opaque card, which produced two false "no blur" readings during development.
- **The widget owns two windows**, the pill and its drop shadow (`Oriel` and
  `Oriel (shadow)`). The shadow is click-through and never takes focus, so it
  cannot be clicked or Alt-Tabbed to; it exists as a separate window because the
  compositor clips the blur to the window rect, so the pill has to fill its own
  window exactly (ADR 0009).
- Topmost **yields to exclusive/borderless fullscreen** apps and reclaims when
  they exit (ADR 0005); reclaiming over exclusive fullscreen is inherently
  best-effort on Windows.
