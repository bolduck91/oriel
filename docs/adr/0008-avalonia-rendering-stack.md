# Render the widget with Avalonia, not WPF

**Supersedes [ADR 0001](0001-powershell-wpf-stack.md)** for the rendering half only.
The statusline tee stays PowerShell (see [What this does not change](#what-this-does-not-change)).

The locked visual spec ([ADR 0006](0006-visual-identity.md)) is a **frosted pill at a
26px corner radius with real backdrop blur** — blur being "the feature the user most liked". The WPF build
could not render it, and could never have. It shipped a square, unblurred tint instead.
The widget's rendering half moves to **Avalonia** (WinUIComposition backend), which
renders the spec exactly.

## Why WPF could not do it — the mechanism

The conclusion rests on four facts, each established by a research note on rounded
acrylic under WPF (held in the private workspace), which cites Microsoft Learn and
eight OSS codebases read at source.

1. **A layered window has nothing to blur.** `AllowsTransparency = $true` makes WPF
   render the window as a per-pixel-alpha layered window: the app hands DWM finished
   pixels. Backdrop materials are *sampled from behind the window before the window is
   drawn*, so there is no composed layer underneath to sample. The accent policy's
   gradient **tint** still lands (it is a colour fill over the window rect); the blur
   pass has nothing to operate on. WPF's own `WindowBackdropManager.SetBackdrop`
   encodes this by early-returning on `window.AllowsTransparency`.
2. **`SetWindowRgn` cannot clip the acrylic.** The region clips the window's *own*
   content. The accent material is a DWM layer composed behind the window and addressed
   by the window **rect** — the region never enters that calculation. That is precisely
   what produced the square of backdrop leaking past our rounded corners. Sourcing
   caveat, as the research note states it: Microsoft publishes no prose on DWM's internal
   layer order for the accent policy, because `SetWindowCompositionAttribute` is
   undocumented. Treat "region and backdrop are different pipeline stages" as
   **well-supported inference, not a cited Microsoft statement** — it rests on the
   documented behaviour of `SetWindowRgn`, the documented sampling semantics of backdrop
   brushes, and consistent community reproduction. Fact 3 below does not depend on it.
3. **DWM's corner API has no radius.** `DWMWA_WINDOW_CORNER_PREFERENCE` takes a
   four-value enum (`DEFAULT / DONOTROUND / ROUND / ROUNDSMALL`); `ROUND` is the
   Windows 11 signature **8px**. So asking the window manager for a backdrop means
   accepting the window manager's corner radius. There is no supported radius parameter,
   and this is true of the documented `DWMWA_SYSTEMBACKDROP_TYPE` path too — the leak
   was never an artifact of using an undocumented API.
4. **Custom radius belongs to whoever owns the backdrop visual.** The one supported way
   to get an arbitrary radius is to own the material as a composition visual and clip it
   yourself (`CreateRoundedRectangleGeometry` → `CreateGeometricClipWithGeometry`).
   Avalonia's WinUIComposition backend does exactly that and exposes it as
   `Win32PlatformOptions.WinUICompositionBackdropCornerRadius`. **WPF has no `Compositor`
   on its `HwndTarget`**, so its own render surface can never carry a clipped backdrop.
   That single difference is the whole decision.

The survey agrees: every WPF app that attempted this surrendered its corners. Flow
Launcher — our closest analog — force-overwrites `Border.CornerRadius` to `0` whenever
blur is on, its maintainer having spent three years on the same question; PowerToys Run
and lepoco/wpfui take DWM's 8px. The apps with an arbitrary radius (Avalonia, WinUI 3's
`SystemBackdropElement`) all own their backdrop visual.

Verified on this machine before committing to the migration: the 26px radius **and** real
blur together, confirmed by a colour-field measurement. (That verification and the
measurement traps below postdate the research note; everything above is checkable against
it.)

## Considered Options

- **Stay on WPF, accept DWM's 8px** (`DWMWA_SYSTEMBACKDROP_TYPE` +
  `DWMWA_WINDOW_CORNER_PREFERENCE`, `AllowsTransparency = $false`). ~40 lines of
  P/Invoke, documented and supported, and it would have given us real blur for the first
  time. **Rejected because it trades the locked visual spec away** — 26px → 8px. It also
  carries two costs worth naming: it is **Windows 11 22621+ only**, with blur dropped
  entirely on Windows 10, and it invites the double-corner artifact (the app's own
  corners fighting DWM's) that Flow Launcher had to fix after taking this path and that
  CmdPal pre-empts with `DWMWCP_DONOTROUND`.
- **Stay on WPF, keep 26px with a flat tint and no blur.** The status quo, honestly
  labelled. Rejected: it drops the feature the user most liked.
- **Raw WinRT composition interop from PowerShell.** Proven *reachable* — empirically, on
  this machine, with `Add-Type` alone and no NuGet: a `DispatcherQueue` +
  `RoActivateInstance` activates a `Compositor`, `ICompositorDesktopInterop` QIs, and
  `CreateDesktopWindowTarget` succeeds against a live WPF HWND. The bootstrap is not the
  cost. The cost is everything after it: `CreateHostBackdropBrush` on `ICompositor3`, the
  clip on `ICompositor5`/`ICompositor6`, and a hand-rolled `IGraphicsEffect` graph
  (Win2D is explicitly unsupported in desktop apps). That is **~15 hand-declared WinRT
  COM vtables whose method order is undocumented** — estimated at **500–1000 lines of
  C#** in a here-string, against the ~90 lines of `Interop.ps1` we have now — where one
  wrong slot is silent stack corruption. Avalonia does not hand-write these; it generates them
  from a checked-in `winrt.idl`. Rejected as a far worse undocumented-ABI dependency than
  the one hack we already regret.
- **WinUI 3 / Windows App SDK `SystemBackdropElement`.** Also gives an arbitrary radius,
  but drags in the Windows App SDK runtime as a machine dependency. Avalonia needs no
  such runtime. Rejected as the more expensive route to the same pixel.
- **Capture the desktop and blur it ourselves.** The host backdrop brush cannot be read
  back by design, so this means screen capture at ~30fps with recursion artifacts and a
  battery cost wildly out of proportion to a widget this small. Rejected.

## Consequences

**The accepted cost is a compiled app and a build step.** That is a direct reversal of
ADR 0001's founding rationale — "zero new runtime", "whole project in one language", "no
build step" — and it buys the locked visual spec, which was otherwise unreachable. The
repo now holds two languages, and the widget must be built before it can be launched
(see `build.ps1`, and `docs/running-the-widget.md`).

**The `blur` setting becomes live.** Under WPF it was inert: `Config.ps1` persisted
`blur = 30` but nothing consumed it — the accent policy has no blur-radius field and
there was no WPF `BlurEffect` anywhere in `src/`. The research note's advice was to stop
presenting an inert control to the user; we honour that by making it real rather than by
removing it, which Avalonia owning the material now allows.

> **Landed later, and not as a radius.** The Avalonia build shipped with the setting still
> inert. [ADR 0010](0010-blur-is-a-two-step-preference.md) makes it live as a two-step
> preference: the platform takes a transparency *level*, not a number, so there was never a
> radius to expose. Owning the backdrop visual buys the custom **corner** radius, which is
> what this ADR's fact 4 is about — not a blur radius.

**The OS floor is Windows 11 22000.** Avalonia's acrylic sets
`DWMWA_USE_HOSTBACKDROPBRUSH`, the documented opt-in that lets a non-UWP window use host
backdrop brushes, and that attribute is Windows 11 build 22000+. No new machine runtime
is required beyond that — unlike the Windows App SDK route.

## What this does not change

The migration is deliberately confined to rendering:

- **The tee stays PowerShell and stays as it is.** It is the ToS-clean half — statusline
  data only, no network, no credentials — and that guarantee is untouched.
- **The `current.json` contract** ([ADR 0002](0002-file-based-tee-contract.md)) is
  unchanged, which is what keeps the two halves decoupled across the migration.
- **Behavioural ADRs 0003–0007** (skins, freshness, window behaviour, visual identity,
  lifecycle) all still hold; the parity pass ports them, it does not re-decide them.

## Measurement traps

Two false negatives during this work, recorded so they are not repeated when checking
whether blur is live:

- **Fine stripes average to flat grey under blur.** A test backdrop of thin
  high-contrast stripes is indistinguishable from an unblurred flat grey once blurred —
  the blur is working and the measurement cannot see it. Use large colour fields.
- **Sampling a pixel row that crosses the text measures glyph contrast, not the
  backdrop.** Sample a row through empty glass, well clear of any text or ring.
