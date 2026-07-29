// The glass: the backdrop each **blur** step asks the compositor for, and the tint laid
// over it (polish ticket 02, ADR 0010).
//
// What these cannot check is what the compositor grants — a headless platform has no
// backdrop to grant, and that gap is precisely the one ADR 0008 warns about. So the
// requested chain is checked here and the granted level was measured against the real
// window, recorded in the ticket.

using System.Linq;
using Avalonia.Controls;
using Avalonia.Headless.XUnit;
using Avalonia.Media;
using Xunit;

namespace Oriel.UiTests
{
    public class GlassTests
    {
        // The same both-directions agreement the skins get: the ids and labels are declared
        // in Preferences, the chains have to live beside Avalonia, and nothing but this test
        // ties them together.
        [AvaloniaFact]
        public void Every_declared_blur_step_has_a_backdrop_and_every_backdrop_is_reachable()
        {
            var declared = WidgetConfig.ValidBlurs.OrderBy(s => s, System.StringComparer.Ordinal).ToArray();
            var built = Glass.BackdropIds.OrderBy(s => s, System.StringComparer.Ordinal).ToArray();

            Assert.Equal(declared, built);
        }

        // Necessary, not sufficient, and the difference matters here more than anywhere:
        // asking differently is exactly what the removed "soft" step did while rendering
        // identically to off. What proves the two steps DIFFER is the granted-level table
        // in ADR 0010, measured against the real window. This only catches the cheaper
        // mistake — two steps that do not even ask for different things.
        [AvaloniaFact]
        public void The_two_steps_at_least_ask_for_different_things()
        {
            var chains = WidgetConfig.ValidBlurs
                .Select(id => string.Join(",", Glass.Backdrop(id)))
                .ToArray();

            Assert.Equal(chains.Length, chains.Distinct().Count());
        }

        [AvaloniaFact]
        public void Full_asks_for_acrylic_first()
            => Assert.Equal(WindowTransparencyLevel.AcrylicBlur, Glass.Backdrop("full").First());

        // "Off" has to mean unblurred, not opaque: the widget is a glass pill, and a step
        // that turned the backdrop black would read as a broken widget rather than a
        // setting.
        [AvaloniaFact]
        public void Off_asks_for_no_blur_at_all_but_stays_see_through()
        {
            var chain = Glass.Backdrop("off");

            Assert.DoesNotContain(WindowTransparencyLevel.AcrylicBlur, chain);
            Assert.DoesNotContain(WindowTransparencyLevel.Blur, chain);
            Assert.Equal(WindowTransparencyLevel.Transparent, chain.First());
        }

        // The step that was tried and removed (ADR 0010). A middle step asking for plain
        // Blur is granted Transparent on this backend — identical to off, and a level not
        // even in the chain it asked for. So no step may be declared whose FIRST choice is
        // plain Blur: it would promise a look the compositor will not deliver. Later in a
        // chain is fine, and deliberate — that is a fallback, not a promise.
        [AvaloniaFact]
        public void No_step_leads_with_a_blur_the_compositor_will_not_grant()
        {
            foreach (var id in WidgetConfig.ValidBlurs)
                Assert.NotEqual(WindowTransparencyLevel.Blur, Glass.Backdrop(id).First());
        }

        // Every chain ends somewhere the platform can definitely honour, because asking is
        // not getting (ADR 0008) — on a machine that cannot blur, the tint alone carries
        // legibility (ADR 0006).
        [AvaloniaFact]
        public void Every_chain_ends_in_a_level_any_platform_can_honour()
        {
            foreach (var id in WidgetConfig.ValidBlurs)
                Assert.Equal(WindowTransparencyLevel.None, Glass.Backdrop(id).Last());
        }

        [AvaloniaFact]
        public void An_unknown_step_falls_back_to_the_default_rather_than_throwing()
        {
            Assert.Equal(Glass.Backdrop(Preferences.Blurs.DefaultId), Glass.Backdrop("bokeh"));
            Assert.Equal(Glass.Backdrop(Preferences.Blurs.DefaultId), Glass.Backdrop(null));
        }

        [AvaloniaFact]
        public void The_tint_darkens_the_glass_without_ever_going_opaque_or_clear()
        {
            var lighter = (SolidColorBrush)Glass.Tint(60);
            var darker = (SolidColorBrush)Glass.Tint(90);

            Assert.True(darker.Color.A > lighter.Color.A);
            // clamped to the 50–97 band validation enforces, so a hand-edited file cannot
            // produce a fully clear or fully opaque card
            Assert.Equal(((SolidColorBrush)Glass.Tint(50)).Color.A, ((SolidColorBrush)Glass.Tint(0)).Color.A);
            Assert.Equal(((SolidColorBrush)Glass.Tint(97)).Color.A, ((SolidColorBrush)Glass.Tint(400)).Color.A);
            Assert.True(((SolidColorBrush)Glass.Tint(97)).Color.A < 255);
        }

        // The card is one flat ground over the backdrop, not a second material: the ADR 0010
        // trap is reaching for an acrylic brush here, which samples the wallpaper instead of
        // the windows behind and lays an opaque sheet over the real blur.
        [AvaloniaFact]
        public void The_tint_is_a_plain_brush_over_the_backdrop()
            => Assert.IsType<SolidColorBrush>(Glass.Tint(75));
    }
}
