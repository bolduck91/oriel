# Blur is a two-step preference, not a radius

**Completes the "`blur` setting becomes live" consequence of
[ADR 0008](0008-avalonia-rendering-stack.md)**, which the migration promised and did not
land — the setting was read, validated and persisted, and then consumed by nothing.

`blur` was read from `config.json`, validated, clamped to 0–60, defaulted to 30, persisted
on every write — and consumed by nothing, with no menu entry either. The only way to set it
was to hand-edit the file, where it did nothing at all. It is now **live**: a named step
that changes the backdrop the window asks the compositor for, reachable from the right-click
menu next to tint.

**It is a step, not a number, because the platform takes a level and not a radius.**
`TransparencyLevelHint` accepts `WindowTransparencyLevel` values — `None`, `Transparent`,
`Blur`, `AcrylicBlur`, `Mica` — in fallback order. There is no radius parameter anywhere on
that path. ADR 0008 said "owning the backdrop is what makes a custom radius possible", and
that is true of the **corner** radius (`WinUICompositionBackdropCornerRadius`, a float we
do set); it was never true of the blur radius. A 0–60 setting could only ever have been
three or four bands wearing a number's clothes, so the number is gone rather than dressed up.

## Two steps, because the third was measured and did not exist

The first cut had three: `full` (acrylic), `soft` (plain blur-behind) and `off`. Verified
against the real window with `CLAUDE_WIDGET_DIAG`, as ADR 0008's own warning demands —
asking is not getting:

| step | requested | **granted** |
|---|---|---|
| full | `AcrylicBlur, Blur, Transparent, None` | **`AcrylicBlur`** |
| soft | `Blur, Transparent, None` | **`Transparent`** |
| off | `Transparent, None` | **`Transparent`** |

`soft` and `off` were the same widget. Narrowed further to rule out our own fallback
chain masking it: asking for `Blur, None` alone still came back **`Transparent`** — a level
that was not in the request at all. Plain blur-behind is not reachable through Avalonia's
WinUIComposition backend on Windows 11; the request is mapped onto transparency.

So the preference is `full` / `off`, both of which were measured to differ. `Blur` stays in
the middle of the `full` chain deliberately — as a *fallback* on some platform that has it,
which is not the same as a promise. `GlassTests` enforces the distinction: no step may
*lead* with plain `Blur`.

## Consequences

**`off` means unblurred, not opaque.** It asks for `Transparent`, so the desktop still shows
through the tint. `None` — where the window background goes black behind whatever is not
drawn — would read as a broken widget rather than as a setting, so it is only ever the last
entry in a chain.

**A config file from before this change still loads.** `blur` arrives as a number in every
`config.json` written until now, and `WidgetConfig.Read` wraps the whole deserialize in a
catch that falls back to defaults — so a number landing on a string property would have
quietly reset the user's skin, size, opacity, tint, accent **and window position** as well:
one inert key taking every live one down with it. `LegacyBlurConverter` consumes anything
that is not a string and leaves validation to supply the default. The old number is not
translated into a step, because it never reached the screen — there is no look the user
chose and no intent to preserve. Verified against the real live `config.json` on this
machine (`"blur": 30`, non-default skin/opacity/tint/position): the step came out `full`
and every other preference survived.

**The blur is the window's backdrop, not the card's.** Unchanged from ADR 0008, and worth
repeating here because it is the trap next to this code: the composition host backdrop
samples the live windows behind the widget, and the tint is a plain semi-transparent brush
painted over it. An `ExperimentalAcrylicBorder` on the card instead samples the desktop
*wallpaper*, which lays an opaque sheet over the real blur and kills the glass.
