// The locked visual spec's large soft drop shadow (`box-shadow: 0 20px 54px -20px
// #000d`), rendered as a companion window pinned directly beneath the pill.
//
// Why a whole extra window for a shadow (ticket 05):
//
//   The WinUI composition backdrop is clipped to the widget WINDOW's rect, not to
//   whatever the window happens to draw. So the card has to fill its window exactly.
//   Leaving a margin for a BoxShadow does not leave transparent space — it leaves a
//   second, larger, 26px-rounded pane of blurred glass around the pill. That was
//   measured, not assumed: the halo is plainly visible over a hard colour seam.
//
//   Drawing the shadow inside the card instead would make it an inner shadow, which
//   is a different effect entirely.
//
// So the shadow gets its own window: transparent, click-through, never activated,
// tracking the pill's position, size and opacity, and held immediately below it in
// the z-order.
//
// The shape deliberately has NO background. An outer box shadow is not painted
// inside its own border box (the CSS rule Avalonia follows), so a background-less
// Border yields the shadow alone. That matters more here than it looks: this window
// sits directly behind the glass, and the acrylic samples what is behind it — paint
// a solid caster and the pill's blur would sample black and the glass would die.

using System;
using System.Runtime.InteropServices;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Media;

namespace Oriel
{
    internal sealed class ShadowWindow : Window
    {
        /// Room around the card for the shadow to fall into, at 100%. The spec's shadow
        /// is offset 20 down, blur 54, spread -20 — so it reaches roughly 27px below the
        /// card and 7px to each side, and nothing above. These are those numbers with
        /// slack; the window is transparent everywhere the shadow is not, so slack costs
        /// nothing. Scaled with the size preference, like everything else on the pill.
        public static readonly Thickness Bleed = new(24, 8, 24, 48);

        // The locked spec: box-shadow: 0 20px 54px -20px #000d (#000d is #RGBA, so
        // alpha d -> 0xDD). Offset, blur and spread scale with the pill, or a "large"
        // widget would sit on a shadow sized for a small one.
        private const double SpecOffsetY = 20, SpecBlur = 54, SpecSpread = -20;
        private const string SpecColour = "#DD000000";

        private readonly Border _shape;
        private bool _clickThroughApplied;

        public ShadowWindow()
        {
            SystemDecorations = SystemDecorations.None;
            Background = Brushes.Transparent;
            // Per-pixel alpha only. Explicitly NOT acrylic — this window contributes a
            // shadow, not a second pane of glass.
            TransparencyLevelHint = new[] { WindowTransparencyLevel.Transparent };
            SizeToContent = SizeToContent.Manual;
            CanResize = false;
            ShowInTaskbar = false;
            ShowActivated = false;
            Topmost = true;
            Title = "Oriel (shadow)";

            _shape = new Border
            {
                Background = null,          // shadow only — see the header note
                HorizontalAlignment = Avalonia.Layout.HorizontalAlignment.Left,
                VerticalAlignment = Avalonia.Layout.VerticalAlignment.Top,
            };
            Content = new Panel { Background = Brushes.Transparent, Children = { _shape } };

            // Before anything can be clicked, not on the first SyncTo — otherwise the
            // shadow swallows a click that lands in the gap after Show().
            Opened += (_, _) => ApplyClickThrough();
        }

        private static BoxShadows SpecShadowAt(double scale) => BoxShadows.Parse(
            FormattableString.Invariant(
                $"0 {SpecOffsetY * scale} {SpecBlur * scale} {SpecSpread * scale} {SpecColour}"));

        /// Match the pill: same footprint, same corner radius, same opacity, and
        /// immediately below it in the z-order. Cheap enough to call on every move.
        ///
        /// `sizeScale` is the size preference (0.85 / 1.0 / 1.25). The pill is scaled by
        /// a LayoutTransform, so the shadow has to be scaled by hand to match.
        public void SyncTo(Window pill, double cornerRadius, double sizeScale)
        {
            var w = pill.ClientSize.Width;
            var h = pill.ClientSize.Height;
            if (w <= 0 || h <= 0) return;

            var bleed = new Thickness(Bleed.Left * sizeScale, Bleed.Top * sizeScale,
                                      Bleed.Right * sizeScale, Bleed.Bottom * sizeScale);

            _shape.Margin = bleed;
            _shape.Width = w;
            _shape.Height = h;
            _shape.CornerRadius = new CornerRadius(cornerRadius);
            _shape.BoxShadow = SpecShadowAt(sizeScale);

            Width = w + bleed.Left + bleed.Right;
            Height = h + bleed.Top + bleed.Bottom;

            // Position is in physical pixels; the bleed is in DIPs. Both windows are
            // whole-screen neighbours in practice, so the pill's scaling is the right
            // one to convert with — a pill straddling two monitors of different DPI
            // would misalign the shadow slightly, which is not worth chasing here.
            var dpi = pill.RenderScaling;
            Position = new PixelPoint(
                pill.Position.X - (int)Math.Round(bleed.Left * dpi),
                pill.Position.Y - (int)Math.Round(bleed.Top * dpi));

            Opacity = pill.Opacity;

            ApplyClickThrough();
            PinBehind(pill);
        }

        // ---- Win32 plumbing ------------------------------------------------
        //
        // Two things Avalonia has no portable API for: making a window ignore the
        // mouse entirely, and parking one window immediately below another.

        private const int GwlExStyle = -20;
        private const int WsExTransparent = 0x00000020;
        private const int WsExNoActivate = 0x08000000;
        private const int WsExToolWindow = 0x00000080;

        private const uint SwpNoSize = 0x0001;
        private const uint SwpNoMove = 0x0002;
        private const uint SwpNoActivate = 0x0010;

        [DllImport("user32.dll", SetLastError = true)]
        private static extern int GetWindowLong(IntPtr hWnd, int nIndex);

        [DllImport("user32.dll", SetLastError = true)]
        private static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);

        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter,
                                                int x, int y, int cx, int cy, uint flags);

        private IntPtr Handle => TryGetPlatformHandle()?.Handle ?? IntPtr.Zero;

        /// Clicks, drags and hovers must all land on the pill, never on its shadow.
        /// Also keeps the shadow out of Alt-Tab.
        ///
        /// Failures here are swallowed on purpose: the shadow is decoration, and a
        /// widget that still works with a slightly wrong-behaving shadow beats one that
        /// refuses to start because a window style would not take.
        private void ApplyClickThrough()
        {
            if (_clickThroughApplied) return;
            var h = Handle;
            if (h == IntPtr.Zero) return;
            var ex = GetWindowLong(h, GwlExStyle);
            SetWindowLong(h, GwlExStyle, ex | WsExTransparent | WsExNoActivate | WsExToolWindow);
            _clickThroughApplied = true;
        }

        /// Both windows are topmost, so their relative order is whatever was shown or
        /// activated last — clicking the pill would otherwise be enough to shuffle
        /// them. Re-asserting the order on every sync keeps the shadow behind.
        private void PinBehind(Window pill)
        {
            var mine = Handle;
            var theirs = pill.TryGetPlatformHandle()?.Handle ?? IntPtr.Zero;
            if (mine == IntPtr.Zero || theirs == IntPtr.Zero) return;
            SetWindowPos(mine, theirs, 0, 0, 0, 0, SwpNoMove | SwpNoSize | SwpNoActivate);
        }
    }
}
