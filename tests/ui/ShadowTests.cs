// The shadow companion window's geometry (ticket 07).
//
// ShadowWindow exists because the spec's drop shadow cannot live inside the pill's
// own window — see Shadow.cs. That makes its correctness entirely a matter of
// staying glued to the pill: same footprint plus bleed, offset up and left by the
// bleed, same opacity, all scaled by the size preference.
//
// The Win32 half (click-through, z-order pinning) is not covered here. It has no
// window handle under the headless platform, and both methods already return early
// when the handle is zero — so what is left to check is the arithmetic, which is
// the part that silently drifts.

using Avalonia;
using Avalonia.Controls;
using Avalonia.Headless.XUnit;
using Xunit;

namespace Oriel.UiTests
{
    public class ShadowTests
    {
        private const double PillW = 240, PillH = 60;

        private static Window Pill(double w = PillW, double h = PillH, int x = 500, int y = 300, double opacity = 1.0)
        {
            var pill = new Window
            {
                SystemDecorations = SystemDecorations.None,
                Width = w,
                Height = h,
                Opacity = opacity,
                Position = new PixelPoint(x, y),
            };
            pill.Show();
            return pill;
        }

        [AvaloniaFact]
        public void The_shadow_window_is_the_pill_plus_its_bleed()
        {
            var pill = Pill();
            var shadow = new ShadowWindow();

            shadow.SyncTo(pill, cornerRadius: 26, sizeScale: 1.0);

            var b = ShadowWindow.Bleed;
            Assert.Equal(pill.ClientSize.Width + b.Left + b.Right, shadow.Width, 3);
            Assert.Equal(pill.ClientSize.Height + b.Top + b.Bottom, shadow.Height, 3);
        }

        [AvaloniaFact]
        public void The_shadow_sits_up_and_left_of_the_pill_by_the_bleed()
        {
            var pill = Pill(x: 500, y: 300);
            var shadow = new ShadowWindow();

            shadow.SyncTo(pill, cornerRadius: 26, sizeScale: 1.0);

            var dpi = pill.RenderScaling;
            Assert.Equal(500 - (int)System.Math.Round(ShadowWindow.Bleed.Left * dpi), shadow.Position.X);
            Assert.Equal(300 - (int)System.Math.Round(ShadowWindow.Bleed.Top * dpi), shadow.Position.Y);
        }

        [AvaloniaFact]
        public void The_bleed_scales_with_the_size_preference()
        {
            // A "large" widget must not sit on a shadow sized for a small one.
            var pill = Pill();
            var small = new ShadowWindow();
            var large = new ShadowWindow();

            small.SyncTo(pill, 26 * 0.85, 0.85);
            large.SyncTo(pill, 26 * 1.25, 1.25);

            Assert.True(large.Width > small.Width);
            Assert.True(large.Height > small.Height);
        }

        [AvaloniaFact]
        public void The_shadow_matches_the_pills_opacity()
        {
            var pill = Pill(opacity: 0.4);
            var shadow = new ShadowWindow();

            shadow.SyncTo(pill, 26, 1.0);

            Assert.Equal(0.4, shadow.Opacity, 3);
        }

        [AvaloniaFact]
        public void Re_syncing_re_fits_the_same_shadow_rather_than_keeping_the_old_size()
        {
            // The shadow is re-fitted after every render, because the pill resizes with
            // its contents — a countdown crossing the hour loses a digit.
            //
            // The size change is driven through the size preference rather than by
            // resizing the pill: the headless platform does not reflect a mutated Width
            // into ClientSize without a layout pass, so a resize-based test would assert
            // on a stale value and pass for the wrong reason. What matters here is that
            // a second SyncTo on the SAME shadow re-fits it instead of leaving the first
            // geometry in place.
            var pill = Pill();
            var shadow = new ShadowWindow();

            shadow.SyncTo(pill, 26 * 0.85, 0.85);
            var small = shadow.Width;
            shadow.SyncTo(pill, 26 * 1.25, 1.25);

            Assert.True(shadow.Width > small,
                $"re-sync left the shadow at {small} instead of growing it");
        }

        [AvaloniaFact]
        public void A_pill_with_no_size_yet_is_ignored_rather_than_collapsing_the_shadow()
        {
            // SyncTo runs before the first layout pass too, when ClientSize is still
            // zero. Sizing to that would produce a negative window dimension.
            var pill = new Window { SystemDecorations = SystemDecorations.None };
            var shadow = new ShadowWindow();

            var ex = Record.Exception(() => shadow.SyncTo(pill, 26, 1.0));

            Assert.Null(ex);
        }
    }
}

