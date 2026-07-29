// Every skin, built for every view state (ticket 07).
//
// The hole this fills: Skins.Build is a switch over four layouts, each assembling
// a tree of controls from a WidgetView. A throw in any of them — a null reset
// string, a percentage that makes a dash array degenerate, a pace marker on a
// view that has no seven-day data — compiles fine and is caught only by eye.
//
// The assertions are deliberately structural rather than pixel-exact. What the
// widget looks like was established by measuring the real window in ticket 05;
// what this guards is that it still builds, and still says the numbers.

using System;
using System.Linq;
using Avalonia.Controls;
using Avalonia.Headless.XUnit;
using Avalonia.VisualTree;
using Xunit;

namespace Oriel.UiTests
{
    public class SkinTests
    {
        private const long Now = 1_700_000_000;

        private static WidgetConfig Cfg(string skin = "twin", string accent = "pastel")
            => new WidgetConfig { Skin = skin, Accent = accent }.Validated();

        // Named Rec, not Record: xUnit's Record.Exception is used here too.
        private static UsageRecord Rec(double five, double seven, long fiveReset, long sevenReset, long writtenAt)
            => new()
            {
                FiveHour = new Window5 { UsedPercentage = five, ResetsAt = fiveReset },
                SevenDay = new Window5 { UsedPercentage = seven, ResetsAt = sevenReset },
                WrittenAt = writtenAt,
            };

        /// The view states the widget can be in. Selected by name rather than passed
        /// as theory data: a WidgetView is not xUnit-serializable, and handing one to
        /// [Theory] silently yields a row with no arguments at all.
        private static WidgetView ViewNamed(string state)
        {
            var cfg = Cfg();
            return state switch
            {
                // written seconds ago, both windows well inside their period
                "fresh" => WidgetView.Build(Rec(42, 30, Now + 3600, Now + 200000, Now - 5), cfg, Now),
                // the tee stopped writing, so the percentages are frozen
                "stale" => WidgetView.Build(Rec(42, 30, Now + 3600, Now + 200000, Now - 86400), cfg, Now),
                // now has passed a reset instant
                "due" => WidgetView.Build(Rec(42, 30, Now - 10, Now - 10, Now - 5), cfg, Now),
                // seven-day usage running ahead of the clock
                "over-pace" => WidgetView.Build(Rec(10, 95, Now + 3600, Now + 600000, Now - 5), cfg, Now),
                // 0 and 100 each take a special branch in the ring geometry
                "empty-rings" => WidgetView.Build(Rec(0, 0, Now + 3600, Now + 200000, Now - 5), cfg, Now),
                "full-rings" => WidgetView.Build(Rec(100, 100, Now + 3600, Now + 200000, Now - 5), cfg, Now),
                "no-data" => WidgetView.Build(null, cfg, Now),
                _ => throw new ArgumentOutOfRangeException(nameof(state), state, "unknown view state"),
            };
        }

        public static TheoryData<string> AllSkins()
        {
            var d = new TheoryData<string>();
            foreach (var s in WidgetConfig.ValidSkins) d.Add(s);
            return d;
        }

        [AvaloniaTheory]
        [InlineData("fresh")]
        [InlineData("stale")]
        [InlineData("due")]
        [InlineData("over-pace")]
        [InlineData("empty-rings")]
        [InlineData("full-rings")]
        [InlineData("no-data")]
        public void Every_skin_builds_for_every_view_state(string state)
        {
            var view = ViewNamed(state);

            foreach (var skin in WidgetConfig.ValidSkins)
            {
                var thrown = Record.Exception(() => Skins.Build(skin, view));
                Assert.True(thrown == null, $"skin '{skin}' threw for the {state} view: {thrown}");
                Assert.NotNull(Skins.Build(skin, view));
            }
        }

        // The two halves of the skin declaration (polish ticket 01). The ids and their
        // menu labels are declared in Preferences; the builders have to live next to the
        // Avalonia code, so this is what stops them drifting. Both directions matter: a
        // declared skin with no builder renders as twin rings while the menu ticks its own
        // name, and a builder no id can reach is dead code nobody can select.
        [AvaloniaFact]
        public void Every_declared_skin_has_a_builder_and_every_builder_is_reachable()
        {
            var declared = WidgetConfig.ValidSkins.OrderBy(s => s, StringComparer.Ordinal).ToArray();
            var built = Skins.BuiltIds.OrderBy(s => s, StringComparer.Ordinal).ToArray();

            Assert.Equal(declared, built);
        }

        // ...and the builders must be distinct, since a duplicated entry would satisfy
        // the set comparison above while quietly rendering two skins the same.
        [AvaloniaFact]
        public void Each_skin_renders_a_layout_of_its_own()
        {
            var view = WidgetView.Build(Rec(42, 30, Now + 3600, Now + 200000, Now - 5), Cfg(), Now);

            var shapes = WidgetConfig.ValidSkins
                .Select(skin => Describe(Skins.Build(skin, view)))
                .ToArray();

            Assert.Equal(shapes.Length, shapes.Distinct().Count());
        }

        /// A skin's control tree as a comparable string — the type of every control in
        /// visual order, plus the text. Enough to tell the four layouts apart without
        /// pinning any of them to a pixel.
        private static string Describe(Control root)
            => string.Join("|", root.GetSelfAndVisualDescendants()
                                    .Select(v => v.GetType().Name + ":" + (v as TextBlock)?.Text));

        [AvaloniaFact]
        public void An_unknown_skin_name_falls_back_rather_than_throwing()
        {
            // Config validation should stop this ever happening, but Build is the last
            // line and a corrupt file must not be able to leave the widget blank.
            var view = WidgetView.Build(Rec(42, 30, Now + 3600, Now + 200000, Now - 5), Cfg(), Now);

            var control = Skins.Build("no-such-skin", view);

            Assert.NotNull(control);
        }

        [AvaloniaFact]
        public void With_no_record_at_all_every_skin_shows_the_empty_state()
        {
            var view = WidgetView.Build(null, Cfg(), Now);
            Assert.False(view.HasData);

            foreach (var skin in WidgetConfig.ValidSkins)
            {
                var control = Skins.Build(skin, view);
                Assert.NotNull(control);
                Assert.Contains("waiting", AllText(control), StringComparison.OrdinalIgnoreCase);
            }
        }

        [AvaloniaTheory]
        [MemberData(nameof(AllSkins))]
        public void Every_skin_shows_both_percentages(string skin)
        {
            var view = WidgetView.Build(Rec(42, 30, Now + 3600, Now + 200000, Now - 5), Cfg(skin), Now);

            var text = AllText(Skins.Build(skin, view));

            Assert.Contains("42%", text);
            Assert.Contains("30%", text);
        }

        [AvaloniaFact]
        public void The_over_pace_marker_appears_only_when_over_pace()
        {
            // The marker is the one element that is conditional on the data rather
            // than on the skin, so it is the one most likely to be missed.
            var over = WidgetView.Build(Rec(10, 95, Now + 3600, Now + 600000, Now - 5), Cfg(), Now);
            // Under pace means used < elapsed. A reset far in the future means barely
            // any of the 7-day window has elapsed, so even 1% used would be *ahead* of
            // the clock — the under-pace case needs a window that is mostly spent.
            var under = WidgetView.Build(Rec(10, 1, Now + 3600, Now + 60000, Now - 5), Cfg(), Now);

            Assert.True(over.Seven.OverPace);
            Assert.False(under.Seven.OverPace);
            Assert.Contains("▲", AllText(Skins.Build("twin", over)));
            Assert.DoesNotContain("▲", AllText(Skins.Build("twin", under)));
        }

        [AvaloniaFact]
        public void Inline_stays_minimal_and_omits_the_pace_marker()
        {
            // A documented deliberate difference between skins, which means a future
            // refactor that "tidied" it away would be changing the design silently.
            var over = WidgetView.Build(Rec(10, 95, Now + 3600, Now + 600000, Now - 5), Cfg("inline"), Now);

            Assert.True(over.Seven.OverPace);
            Assert.DoesNotContain("▲", AllText(Skins.Build("inline", over)));
        }

        /// Flatten every TextBlock in the built tree. The skins are assembled by hand
        /// rather than templated, so the text is present without a layout pass.
        private static string AllText(Control root)
            => string.Join(" ", root.GetSelfAndVisualDescendants()
                                    .OfType<TextBlock>()
                                    .Select(t => t.Text)
                                    .Where(t => !string.IsNullOrEmpty(t)));
    }
}

