# The drop shadow is its own window

**Extends [ADR 0006](0006-visual-identity.md)** (visual identity) and
[ADR 0008](0008-avalonia-rendering-stack.md) (rendering stack). It also records one
skin change made during the Avalonia parity pass.

The locked visual spec gives the pill a large soft drop shadow —
`box-shadow: 0 20px 54px -20px #000d`. The first build dropped it entirely, and its
absence is much of why the pill read as pasted onto the desktop rather than floating
above it. It is now rendered by a **second, transparent, click-through top-level
window** pinned directly beneath the pill (`src/app/Shadow.cs`).

## Why it cannot live in the widget window

The obvious implementation — leave a margin around the card and give the card a
`BoxShadow` — does not work, for the same class of reason that killed rounded acrylic
under WPF ([ADR 0008](0008-avalonia-rendering-stack.md)).

**The WinUI composition backdrop is clipped to the window's rect, not to what the
window draws.** The blur visual is sized to the window and clipped by the rounded
rectangle geometry built from `WinUICompositionBackdropCornerRadius`. So the margin
does not stay transparent: it fills with a second, larger, 26px-rounded pane of
blurred glass around the pill.

This was measured, not assumed. Over a hard navy/white colour seam, a build with a
`Thickness(12, 4, 12, 34)` margin showed the halo plainly — a rounded rectangle of
smeared seam extending well past the card on every side. The card must fill its
window exactly.

## Considered options

- **`Border.BoxShadow` on the card, with a window margin.** Rejected: produces the
  blur halo above. This is not tunable — any margin at all is backdrop.
- **Avalonia's native composition drop shadow.** `Avalonia.Win32` does carry one
  (`CreateDropShadow`, `SetWindowManagerAddShadowHint`, `EnableBoxShadow` are all in
  the assembly), but it is reachable only through `IWindowImpl`, which is **not an
  exported type** in Avalonia 11.2. Rejected as unreachable without reflection into
  internals.
- **An inner shadow on the card.** Rejected: that is a different effect. The spec asks
  for the pill to cast onto the desktop, not to be lit from inside.
- **Ship without the shadow.** The status quo, and the reason the pill reads flat.
  Rejected — it is a locked-spec element.

## How it works, and the two traps in it

- **The shape paints no background.** An outer box shadow is not drawn inside its own
  border box (the CSS rule Avalonia follows), so a background-less `Border` yields the
  shadow alone. This is load-bearing, not tidiness: the shadow window sits *directly
  behind the glass*, and the pill's acrylic samples what is behind it. A solid caster
  would be sampled and the glass would go dead black.
- **Z-order has to be re-asserted, not set once.** Both windows are topmost, so their
  relative order is whatever was shown or activated last — clicking the pill alone
  would shuffle the shadow in front of it. `SetWindowPos(shadow, insertAfter: pill)`
  runs on every sync.
- **The shadow is click-through** (`WS_EX_TRANSPARENT | WS_EX_NOACTIVATE |
  `WS_EX_TOOLWINDOW`), applied when the window opens, so every click, drag and hover
  lands on the pill and the shadow never appears in Alt-Tab.
- **It scales with the size preference.** The pill is scaled by a `LayoutTransform`;
  the shadow is a separate window, so its offset, blur, spread and bleed are scaled by
  hand to match. Without that, a "large" pill sits on a small pill's shadow.

## Consequences

The widget now owns **two** top-level windows. Anything that enumerates the app's
windows must expect both — they are told apart by title (`Oriel` versus
`Oriel (shadow)`). The shadow is closed with the pill; without that, Quit would
leave it floating on the desktop with nothing to cast it.

A pill straddling two monitors of **different DPI** will misalign its shadow slightly,
because the bleed is converted to physical pixels using the pill's scaling. Accepted
as not worth chasing for a widget this size.

## The concentric gauge loses its elapsed ring

The original skins-and-reset-display work
called the concentric gauge "the natural home for elapsed ring + pace". The parity pass
reverses that half of it: **the elapsed ring is drawn on twin rings only.**

The reason is crowding, not fidelity — and the distinction matters, because the "the
locked spec draws only two arcs" argument would condemn twin rings' elapsed ring just
as readily. The concentric skin stacks its rings concentrically, so a third one lands
in the middle, where the 5-hour percentage lives; at 32px it hugged the digits and read
as a third data arc competing with the two real ones instead of receding like a clock.
Twin rings sets its elapsed ring around a 64px ring with nothing in the way, so it
keeps it.

The pace marker is unaffected and still appears on every skin that hosts it.
