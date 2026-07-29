// Ring rendering + the four selectable skins (ADR 0003: one data model, N skins),
// ported from the retired PowerShell widget's Rings.ps1 and Skins.ps1.
//
// Reset reading is uniform across skins: 5h countdown, 7d adaptive. Additive
// elements sit where they fit and are omitted where they'd clutter:
//   - dual reset (resets-in + resets-at) : tooltip on every reset text
//   - elapsed ring (time through window)  : twin rings only
//   - 7-day pace marker (over-pace)       : a small red triangle next to 7d

using System;
using System.Collections.Generic;
using System.Globalization;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Shapes;
using Avalonia.Layout;
using Avalonia.Media;

namespace Oriel
{
    public static class Ui
    {
        // ADR 0006: a single readable light grey for all labels and reset times.
        public const string SecondaryHex = "#CFD3E2";
        public const string TrackHex = "#2BFFFFFF";       // ring track: white ~17%
        public const string TrackInnerHex = "#22FFFFFF";  // concentric inner track
        public const string SeparatorHex = "#585B70";
        public const string ElapsedHex = "#8A8FA6";       // reads as the clock, not usage

        public const string FontMono = "Cascadia Code,Consolas,Courier New";
        public const string FontSans = "Segoe UI Variable Text,Segoe UI";

        public static IBrush Brush(string hex) => new SolidColorBrush(Color.Parse(hex));

        public static TextBlock Label(string text) => new()
        {
            Text = text.ToUpperInvariant(),
            Foreground = Brush(SecondaryHex),
            FontFamily = new FontFamily(FontSans),
            FontSize = 11,
            VerticalAlignment = VerticalAlignment.Center,
        };

        /// Monospaced numerics: fixed-width digits keep the live countdown from
        /// jittering second to second.
        public static TextBlock Mono(string text, string hex = SecondaryHex, double size = 13, bool bold = false) => new()
        {
            Text = text,
            Foreground = Brush(hex),
            FontFamily = new FontFamily(FontMono),
            FontSize = size,
            FontWeight = bold ? FontWeight.Bold : FontWeight.Normal,
            VerticalAlignment = VerticalAlignment.Center,
        };

        public static StackPanel HStack(double gap) => new()
        {
            Orientation = Orientation.Horizontal,
            Spacing = gap,
            VerticalAlignment = VerticalAlignment.Center,
        };

        public static StackPanel VStack(double gap) => new()
        {
            Orientation = Orientation.Vertical,
            Spacing = gap,
            VerticalAlignment = VerticalAlignment.Center,
        };

        public static string Pct(double p) => Math.Round(p).ToString("0", CultureInfo.InvariantCulture) + "%";
    }

    public static class Rings
    {
        private static Ellipse Circle(double diameter, string hex, double stroke) => new()
        {
            Width = diameter,
            Height = diameter,
            Stroke = Ui.Brush(hex),
            StrokeThickness = stroke,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
        };

        /// One progress ring: a circle stroked with a single long dash whose length
        /// is the used fraction of the circumference, rotated to start at 12 o'clock.
        public static Control Ring(double pct, double size, double stroke, string colorHex, string trackHex = Ui.TrackHex)
        {
            var panel = new Panel { Width = size, Height = size };

            var r = (size - stroke) / 2.0;
            var diam = 2.0 * r;
            var circ = 2.0 * Math.PI * r;

            panel.Children.Add(Circle(diam, trackHex, stroke));

            var frac = Math.Clamp(pct / 100.0, 0.0, 1.0);
            if (frac >= 0.999)
            {
                // Full ring as a plain stroked circle — a full-length dash would
                // leave a visible round-cap seam.
                panel.Children.Add(Circle(diam, colorHex, stroke));
            }
            else if (frac > 0)
            {
                var prog = Circle(diam, colorHex, stroke);
                prog.StrokeLineCap = PenLineCap.Round;
                // dash units are multiples of stroke thickness
                prog.StrokeDashArray = new Avalonia.Collections.AvaloniaList<double>
                {
                    circ * frac / stroke,
                    circ / stroke + 1,
                };
                prog.RenderTransformOrigin = RelativePoint.Center;
                prog.RenderTransform = new RotateTransform(-90);
                panel.Children.Add(prog);
            }
            return panel;
        }

        /// Thin "elapsed through the window" ring — the am-I-burning-faster-than-the-
        /// clock read. Muted neutral so it reads as the clock, not as usage.
        public static Control ElapsedRing(double elapsedFraction, double size, double stroke = 3)
            => Ring(elapsedFraction * 100.0, size, stroke, Ui.ElapsedHex, "#16FFFFFF");

        /// Concentric dual gauge (skin J): outer arc = 5h, inner arc = 7d, and nothing
        /// else — the centre belongs to the 5h percentage.
        ///
        /// It briefly carried a third, innermost elapsed ring. Dropped on crowding
        /// grounds, not on spec grounds: at 32px it hugged the centred numeral and read
        /// as a third data arc competing with the two real ones instead of receding like
        /// a clock. This skin stacks its rings concentrically, so a third one lands in
        /// the middle where the number lives; twin rings sets its elapsed ring around a
        /// 64px ring with nothing in the way, so it keeps it (ADR 0009).
        public static Control Concentric(double fivePct, double sevenPct, string fiveHex, string sevenHex,
                                         double size = 78)
        {
            var panel = new Panel { Width = size, Height = size };
            panel.Children.Add(Ring(fivePct, size, 7, fiveHex));

            var inner = Ring(sevenPct, size - 22, 5, sevenHex, Ui.TrackInnerHex);
            ((Control)inner).HorizontalAlignment = HorizontalAlignment.Center;
            ((Control)inner).VerticalAlignment = VerticalAlignment.Center;
            panel.Children.Add(inner);

            return panel;
        }

        public static Control RingWithNumber(double pct, double size, double stroke, string colorHex,
                                             double numSize = 15, double elapsedFraction = -1)
        {
            var panel = new Panel();
            if (elapsedFraction >= 0)
            {
                var el = ElapsedRing(elapsedFraction, size - 12, 3);
                ((Control)el).HorizontalAlignment = HorizontalAlignment.Center;
                ((Control)el).VerticalAlignment = VerticalAlignment.Center;
                panel.Children.Add(el);
            }
            panel.Children.Add(Ring(pct, size, stroke, colorHex));
            var num = Ui.Mono(Ui.Pct(pct), colorHex, numSize, bold: true);
            num.HorizontalAlignment = HorizontalAlignment.Center;
            num.VerticalAlignment = VerticalAlignment.Center;
            panel.Children.Add(num);
            return panel;
        }
    }

    public static class Skins
    {
        private static Control PaceMarker(WindowView seven)
        {
            if (!seven.OverPace) return null;
            var m = Ui.Mono("▲", "#f38ba8", 9);
            ToolTip.SetTip(m, "Over pace: 7-day usage is running ahead of the clock");
            return m;
        }

        private static void AddSevenReset(Panel panel, WidgetView v, bool withPace = true)
        {
            if (withPace)
            {
                var pace = PaceMarker(v.Seven);
                if (pace != null) panel.Children.Add(pace);
            }
            var r7 = Ui.Mono(v.Seven.ResetText, Ui.SecondaryHex, 11);
            ToolTip.SetTip(r7, "resets at " + v.Seven.ResetClockText);
            panel.Children.Add(r7);
        }

        private static Control EmptyState()
        {
            var t = Ui.Mono("waiting for a Claude Code session", Ui.SecondaryHex, 12);
            t.HorizontalAlignment = HorizontalAlignment.Center;
            return t;
        }

        // ---- Skin D: twin rings --------------------------------------------
        private static Control Twin(WidgetView v)
        {
            var root = Ui.HStack(16);
            root.Children.Add(Rings.RingWithNumber(v.Five.Pct, 64, 7, v.Five.ColorHex, 15, v.Five.ElapsedFraction));

            var col = Ui.VStack(8);
            var line1 = Ui.VStack(2);
            line1.Children.Add(Ui.Label("5h"));
            var r5 = Ui.Mono("resets in " + v.Five.ResetText, Ui.SecondaryHex, 13);
            ToolTip.SetTip(r5, "resets at " + v.Five.ResetClockText);
            line1.Children.Add(r5);
            col.Children.Add(line1);

            // the 7d row is secondary — the visual spec dims it so 5h stays the hero
            var line2 = Ui.HStack(8);
            line2.Opacity = 0.9;
            line2.Children.Add(Rings.Ring(v.Seven.Pct, 30, 4, v.Seven.ColorHex));
            line2.Children.Add(Ui.Label("7d " + Ui.Pct(v.Seven.Pct)));
            AddSevenReset(line2, v);
            col.Children.Add(line2);

            root.Children.Add(col);
            return root;
        }

        // ---- Skin F: sidecar ring ------------------------------------------
        private static Control Sidecar(WidgetView v)
        {
            var root = Ui.HStack(14);
            root.Children.Add(Rings.RingWithNumber(v.Five.Pct, 56, 7, v.Five.ColorHex, 14));

            var col = Ui.VStack(6);
            var l1 = Ui.HStack(7);
            l1.Children.Add(Ui.Label("5h"));
            var r5 = Ui.Mono(v.Five.ResetText, Ui.SecondaryHex, 14);
            ToolTip.SetTip(r5, "resets at " + v.Five.ResetClockText);
            l1.Children.Add(r5);
            col.Children.Add(l1);

            var l2 = Ui.HStack(7);
            l2.Opacity = 0.85;
            l2.Children.Add(Ui.Label("7d"));
            l2.Children.Add(Ui.Mono(Ui.Pct(v.Seven.Pct), v.Seven.ColorHex, 13));
            AddSevenReset(l2, v);
            col.Children.Add(l2);

            root.Children.Add(col);
            return root;
        }

        // ---- Skin H: inline arcs -------------------------------------------
        private static Control Inline(WidgetView v)
        {
            var root = Ui.HStack(9);
            root.Children.Add(Rings.Ring(v.Five.Pct, 22, 3, v.Five.ColorHex));
            root.Children.Add(Ui.Mono(Ui.Pct(v.Five.Pct), v.Five.ColorHex, 15));
            root.Children.Add(Ui.Label("5h"));
            var r5 = Ui.Mono(v.Five.ResetText, Ui.SecondaryHex, 12);
            ToolTip.SetTip(r5, "resets at " + v.Five.ResetClockText);
            root.Children.Add(r5);

            root.Children.Add(Ui.Mono("│", Ui.SeparatorHex, 13));

            root.Children.Add(Rings.Ring(v.Seven.Pct, 18, 3, v.Seven.ColorHex));
            root.Children.Add(Ui.Mono(Ui.Pct(v.Seven.Pct), v.Seven.ColorHex, 13));
            root.Children.Add(Ui.Label("7d"));
            AddSevenReset(root, v, withPace: false);   // inline stays minimal
            return root;
        }

        // ---- Skin J: concentric gauge --------------------------------------
        private static Control ConcentricSkin(WidgetView v)
        {
            var root = Ui.HStack(15);
            var gauge = new Panel();
            gauge.Children.Add(Rings.Concentric(v.Five.Pct, v.Seven.Pct, v.Five.ColorHex, v.Seven.ColorHex));
            var num = Ui.Mono(Ui.Pct(v.Five.Pct), v.Five.ColorHex, 17, bold: true);
            num.HorizontalAlignment = HorizontalAlignment.Center;
            num.VerticalAlignment = VerticalAlignment.Center;
            gauge.Children.Add(num);
            root.Children.Add(gauge);

            var col = Ui.VStack(8);
            var l1 = Ui.HStack(7);
            l1.Children.Add(Ui.Mono("●", v.Five.ColorHex, 11));
            l1.Children.Add(Ui.Label("5h"));
            var r5 = Ui.Mono(v.Five.ResetText, Ui.SecondaryHex, 13);
            ToolTip.SetTip(r5, "resets at " + v.Five.ResetClockText);
            l1.Children.Add(r5);
            col.Children.Add(l1);

            var l2 = Ui.HStack(7);
            l2.Opacity = 0.85;
            l2.Children.Add(Ui.Mono("●", v.Seven.ColorHex, 11));
            l2.Children.Add(Ui.Label("7d " + Ui.Pct(v.Seven.Pct)));
            AddSevenReset(l2, v);
            col.Children.Add(l2);

            root.Children.Add(col);
            return root;
        }

        /// The render-path half of the **skin** declaration, keyed by the same ids
        /// Preferences.Skins declares (ticket 01). It lives here rather than there because
        /// building a skin needs Avalonia and Core.cs is deliberately without it; what
        /// keeps the two halves honest is SkinTests, which fails if either set holds an id
        /// the other does not.
        private static readonly RenderMap<Func<WidgetView, Control>> Builders = new(
            fallback: Twin,
            ("twin", Twin),
            ("sidecar", Sidecar),
            ("inline", Inline),
            ("concentric", ConcentricSkin));

        /// The ids that can actually be rendered — the set the agreement test compares
        /// against the declared **skins**.
        public static IReadOnlyCollection<string> BuiltIds => Builders.Ids;

        public static Control Build(string skinName, WidgetView view)
        {
            if (!view.HasData) return EmptyState();
            // Falls back rather than throwing: config validation should make an unknown id
            // impossible, but Build is the last line and a corrupt file must not be able
            // to leave the widget blank.
            return Builders.For(skinName)(view);
        }
    }
}
