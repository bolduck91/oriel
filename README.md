# Oriel

An always-on-top desktop widget for Windows showing your Claude Code subscription
rate-limit usage — both windows, live — so the numbers stay visible when the terminal
is behind everything else.

Named for the window that projects from a wall so one can watch from inside it. The
thing it measures is also a pair of windows.

## Why this one

Comparable tools read the OAuth token Claude Code stores on your disk and poll
Anthropic's API with it. **Oriel reads only what Claude Code already pushes to your
statusline, and touches no credentials.**

That was a compliance decision long before it was a competitive one. Anthropic's
Consumer Terms, § 3, prohibit accessing the Services "through automated or non-human
means, whether through a bot, script, or otherwise" except via an Anthropic API Key —
and an OAuth token minted for Claude Code is not an API Key. Oriel makes no such call.
It reads a file Claude Code hands to your own statusline script, on your own machine.

## What Oriel reads, and what it never reads

| Reads | Never reads |
|---|---|
| The JSON Claude Code pushes to your statusline on each render — model, context use, and the two rate-limit windows | `~/.claude/.credentials.json`, or any OAuth token, API key or credential |
| Its own state file at `~/.claude/oriel/current.json` | Your conversations, prompts, files or project contents |
| Its own preferences at `~/.claude/oriel/config.json` | Anthropic's API — Oriel makes no request to it, ever |

The one network call Oriel makes is a version check against its own GitHub releases at
startup. It sends nothing about you, downloads nothing, replaces nothing, and you can
switch it off from the widget's right-click menu.

## Install

### Download

Get `OrielSetup.exe` from the [latest release](https://github.com/bolduck91/oriel/releases/latest)
and double-click it. It installs for your user only and never asks for administrator
rights.

> **Windows will show a blue "Windows protected your PC" screen.**
>
> Oriel is not code-signed yet, and that screen is what Windows shows every unsigned
> program. To get past it: click **More info**, then **Run anyway**. Two clicks.
>
> This is documented here rather than glossed over because that screen reads as
> "malware" to most people, and it is the single most likely reason someone gives up.
> Signing is a cost-and-eligibility problem, not a technical one, and it is on the list.

### Terminal

```powershell
irm https://raw.githubusercontent.com/bolduck91/oriel/main/installer/install.ps1 | iex
```

Same installer, same result, consent taken in the console instead of a window. If you
would rather read it before running it — and you should — open that URL first; it is a
plain script written to be read.

## What the installer does to your statusline

Oriel needs the JSON Claude Code pushes to your statusline, and the only way to be
handed it is from inside a statusline script. So the installer reads what you already
have and picks one of three behaviours (**triage**):

| What you have | What Oriel does |
|---|---|
| No statusline | Writes you one — model, effort, context use, both rate-limit windows — declares it, and uses it. It is an ordinary script you then own and can edit. |
| A statusline it can serve | Inserts a small marked block after the line that parses the JSON. **Nothing else in your file changes, byte for byte** — your colours, layout, line endings and habits all survive. |
| Anything else | **Refuses**, changes nothing at all, and hands you text to paste into Claude Code that converts your statusline. Run it again afterwards. |

A statusline Oriel can serve is one written in PowerShell that keeps the pushed JSON in
a variable. Standard input can only be read once, so Oriel cannot fetch the JSON itself
— it can only borrow a variable that already holds it. A bash, Node or Python
statusline cannot be served at all.

Both install paths **verify before claiming success**: they trigger a render and wait
to see the state file appear. If it does not, you get a diagnosis rather than a
checkmark — because the inserted block is deliberately fail-silent, and without that
check a wrong guess would leave you with a widget showing dashes forever and no idea
why.

Installing twice replaces the block rather than stacking another one.

## Using it

- **Drag** anywhere on the pill to move it; the position is remembered.
- **Right-click** for skins (twin rings, sidecar ring, inline arcs, concentric gauge),
  size, opacity, tint, blur, accent, start-with-Windows, reset notifications, the
  update check, and quit.
- Green below 50%, amber below 80%, red at 80% and above. A small red ▲ by the 7-day
  figure means you are burning ahead of the clock.
- If nothing feeds it for a few minutes the percentages drain to grey while the
  countdown keeps ticking — the countdown is derived from an absolute reset time and is
  never stale.

Rate-limit data exists only on Pro/Max accounts, and only from the first API response
of a session. Until then the widget says so rather than showing fabricated zeros.

## Uninstall

Add/Remove Programs, like any other program. It removes exactly the block it added and
nothing else — months of your own later edits to your statusline are not thrown away.
If Oriel wrote your statusline, it asks whether you want to keep it; kept, it is left
working with the block gone, and discarded, your Claude Code settings go back to how
they were.

## Building from source

```powershell
pwsh -NoProfile -File build.ps1                            # dist\Oriel.exe
pwsh -NoProfile -File src\install\Install-Oriel.ps1        # tee + statusline
pwsh -NoProfile -File tests\Run-AllTests.ps1
```

Needs the [.NET 8 SDK](https://dotnet.microsoft.com/download/dotnet/8.0) to build;
nothing at all to run. See [docs/running-the-widget.md](docs/running-the-widget.md) for
the full development story and [docs/releasing.md](docs/releasing.md) for how a release
is cut.

## How it is put together

| Path | Role |
|---|---|
| `src/app/` | The widget (C#, Avalonia). `Core.cs` is the pure logic and has no Avalonia reference at all. |
| `src/tee/` | The **tee**: the side effect your statusline performs on each render, normalising the record and writing it atomically. It never reaches the network — that is a hard guardrail. |
| `src/install/` | The installer. `Statusline.ps1` is the judgement (triage, anchoring, insertion and its exact inverse) and writes nothing; `Install-Oriel.ps1` is the only thing that touches your disk. |
| `installer/` | The two front ends over that entry point: the Inno Setup wizard and the one-line install. |
| `docs/adr/` | Why things are the way they are. Start at 0011 (why injection and never wrapping) and 0012 (how it is distributed). |

Design decisions live in [`CONTEXT.md`](CONTEXT.md) and [`docs/adr/`](docs/adr/).

## Licence

MIT — see [LICENSE](LICENSE).
