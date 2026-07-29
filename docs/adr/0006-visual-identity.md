# Visual identity: flat frosted dark-glass

The widget is a **frosted dark-glass squircle** (corner radius ~26px), arrived at
against user references. The rules that carry the look:

- **Flat interior, no bevel.** No inset highlights, no top-to-bottom sheen gradient
  — those read as a fake 3D lip and were explicitly rejected. The body is an even
  dark translucent ground.
- **A real border**: a 1px **gradient hairline** that follows the corners, slightly
  brighter at the top. Defined enough to frame the card (not the barely-there line
  it started as), but still a hairline — not a bevel.
- **Backdrop blur** behind the glass (the feature the user most liked). Default: on,
  at the strongest the compositor will grant. (Written here as "blur 30" until
  [ADR 0010](0010-blur-is-a-two-step-preference.md) — the platform takes a transparency
  *level*, not a radius, so there was never a 30 to honour. It is now a two-step
  preference defaulting to `full`.)
- **Tint** — the darkness of the glass's own ground — is the **cross-surface
  legibility lever**, default **75%**. Dark glass looks great over a dark terminal
  but washes out over a **white** window; a darker tint keeps it a legible dark card
  on any surface while still blurring. This is why the default opacity is 100%
  ([ADR 0005](0005-window-behavior.md)): translucency (low opacity) and
  white-surface legibility pull against each other, and legibility won.
- **No halo.** A glowing broken-arc ring from a reference was prototyped and
  **dropped** — it only framed the round skin and otherwise read as a stray circle.

## Colour

- **Severity colour** (green < 50% / amber < 80% / red ≥ 80%, **pastel**) is carried
  on the **% number and its ring** — used %, so red = high usage, matching the
  statusline.
- **Secondary text** (window labels, reset times) is unified to a **single readable
  light grey** — the earlier tiered greys left everything but the countdown washed
  out.
- **Stale** drains the severity colour from the percentages only (see
  [ADR 0004](0004-freshness-model.md)); everything else is unaffected.
