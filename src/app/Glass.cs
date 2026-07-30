// The widget's glass: the backdrop the window asks the compositor for, the tint laid over
// it, and the hairline round its edge (ADR 0006, 0008, 0010).
//
// These were private statics on the window. They moved here so the **blur** steps could be
// tested at all: Program.cs is deliberately not linked into the UI test project — it owns
// Main, the Win32 window styles and the registry — so anything living in it can only be
// checked by launching the real widget and looking.

using System;
using System.Collections.Generic;
using Avalonia.Controls;
using Avalonia.Media;

namespace Oriel
{
    public static class Glass
    {
        /// The render-path half of the **blur** declaration (ticket 02), keyed by the same
        /// ids `Preferences.Blurs` declares. It lives here rather than there because
        /// `WindowTransparencyLevel` is an Avalonia type and Core.cs is deliberately
        /// without Avalonia; GlassTests asserts the two sets match in both directions.
        ///
        /// Each entry is a fallback chain, tried in order, because asking is not getting —
        /// the gap between the level requested and the level granted is what shipped a
        /// blur-less widget for weeks (ADR 0008). `Transparent` before `None` so a machine
        /// that cannot blur still shows the desktop through the tint rather than going black
        /// behind it; the tint alone carries legibility either way (ADR 0006).
        ///
        /// TWO steps, not three, and that was measured rather than chosen (ADR 0010): a
        /// middle "soft" step asking for plain `WindowTransparencyLevel.Blur` is granted
        /// `Transparent` — the same as off, and a level not even in the chain it asked for.
        /// Plain blur-behind is not reachable through this backend, so a soft step would be
        /// a menu entry that promises a look it cannot deliver.
        private static readonly WindowTransparencyLevel[] FullChain =
        {
            WindowTransparencyLevel.AcrylicBlur,   // blur-behind at a high radius
            WindowTransparencyLevel.Blur,          // in the chain in case a platform HAS it
            WindowTransparencyLevel.Transparent,
            WindowTransparencyLevel.None,
        };

        private static readonly RenderMap<WindowTransparencyLevel[]> Backdrops = new(
            fallback: FullChain,
            ("full", FullChain),
            ("off", new[]
            {
                WindowTransparencyLevel.Transparent,   // see through, unblurred
                WindowTransparencyLevel.None,
            }));

        /// The blur ids that can actually be rendered — the set the agreement test compares
        /// against the declared steps.
        public static IReadOnlyCollection<string> BackdropIds => Backdrops.Ids;

        /// What to hand the window's TransparencyLevelHint for a **blur** step. An id the
        /// map does not have falls back to the default step rather than throwing: this runs
        /// while opening and repainting the window (ticket 01).
        public static IReadOnlyList<WindowTransparencyLevel> Backdrop(string blur) => Backdrops.For(blur);

        /// **Tint** is the cross-surface legibility lever (ADR 0006): the #14141A ground
        /// laid over the blurred backdrop at `tint` opacity, keeping the card a legible dark
        /// chip even over a white window.
        public static IBrush Tint(int tintPercent)
        {
            var a = (byte)Math.Round(
                Math.Clamp(tintPercent, WidgetConfig.MinTint, WidgetConfig.MaxTint) / 100.0 * 255);
            return new SolidColorBrush(Color.FromArgb(a, 20, 20, 26));
        }

        /// The 1px hairline round the card — one flat white at 15%, the same the whole way
        /// round (ADR 0006). It was a top-left-bright gradient until the light direction read
        /// as the bevel that ADR rules out; a uniform line frames the card without implying
        /// a lit edge. This value is the dial: lower it and the card goes back to
        /// barely-there, raise it and the line starts to draw attention on its own.
        public static IBrush Hairline() => new SolidColorBrush(Color.Parse("#26FFFFFF"));
    }
}
