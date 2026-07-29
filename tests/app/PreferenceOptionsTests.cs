// The interchangeable preferences — skin, size, accent — and the type that makes each
// of them one declaration instead of three (polish ticket 01).
//
// The bug this guards is not duplication, it is what duplication was hiding: the render
// path used to index a dictionary keyed by id with no guard, so a valid id the map did
// not have threw while rendering, in front of the user, for what looked like a one-line
// addition. Every lookup here has to fall back instead.

using System.Linq;
using Xunit;

namespace Oriel.Tests
{
    public class PreferenceOptionsTests
    {
        private static readonly PreferenceOptions<int> Three = new(
            new PreferenceOption<int>("one", "One", 1),
            new PreferenceOption<int>("two", "Two", 2),
            new PreferenceOption<int>("three", "Three", 3));

        [Fact]
        public void The_first_option_is_the_default()
        {
            Assert.Equal("one", Three.DefaultId);
            Assert.Equal(1, Three.ValueOf(Three.DefaultId));
        }

        [Fact]
        public void Ids_come_out_in_declaration_order()
            => Assert.Equal(new[] { "one", "two", "three" }, Three.Ids);

        [Fact]
        public void Labels_stay_attached_to_their_ids()
            => Assert.Equal(new[] { "One", "Two", "Three" }, Three.Select(o => o.Label));

        [Fact]
        public void Pick_keeps_a_recognised_id_and_defaults_anything_else()
        {
            Assert.Equal("two", Three.Pick("two"));
            Assert.Equal("one", Three.Pick("four"));
            Assert.Equal("one", Three.Pick(null));
            Assert.Equal("one", Three.Pick(""));
        }

        // The whole point of the ticket: the render path cannot throw on an id the set
        // does not know, however it got there.
        [Fact]
        public void ValueOf_falls_back_rather_than_throwing_on_an_unknown_id()
        {
            Assert.Equal(3, Three.ValueOf("three"));
            Assert.Equal(1, Three.ValueOf("nope"));
            Assert.Equal(1, Three.ValueOf(null));
        }

        [Fact]
        public void A_declaration_with_no_options_is_rejected_at_the_source()
            => Assert.ThrowsAny<System.ArgumentException>(() => new PreferenceOptions<int>());

        // Two options sharing an id would make the ticked menu entry ambiguous and the
        // render-path lookup silently pick one of them.
        [Fact]
        public void A_duplicate_id_is_rejected_at_the_source()
            => Assert.ThrowsAny<System.ArgumentException>(() => new PreferenceOptions<int>(
                new PreferenceOption<int>("dup", "First", 1),
                new PreferenceOption<int>("dup", "Second", 2)));
    }

    /// The render-path half of the two preferences whose value cannot be declared beside
    /// their id — the skin builders and the blur backdrops. Both are Avalonia, so the maps
    /// themselves are exercised in the UI tests; what is checked here is the shape they
    /// share, which is the thing that must not throw.
    public class RenderMapTests
    {
        private static readonly RenderMap<string> Map = new(
            fallback: "default-thing", ("a", "thing-a"), ("b", "thing-b"));

        [Fact]
        public void Finds_what_was_registered() => Assert.Equal("thing-a", Map.For("a"));

        [Fact]
        public void Reports_the_ids_it_can_render()
            => Assert.Equal(new[] { "a", "b" }, Map.Ids.OrderBy(i => i, System.StringComparer.Ordinal));

        // The whole reason the type exists: this call is on the render path, in front of
        // the user, and an unknown id must not take the window down.
        [Fact]
        public void Falls_back_rather_than_throwing_on_an_id_it_does_not_have()
        {
            Assert.Equal("default-thing", Map.For("c"));
            Assert.Equal("default-thing", Map.For(null));
            Assert.Equal("default-thing", Map.For(""));
        }

        // The fallback is passed in rather than looked up by default id, so it holds even
        // when the default id itself has no entry — the case a lookup-based fallback would
        // throw on.
        [Fact]
        public void Falls_back_even_when_the_map_is_empty()
            => Assert.Equal("default-thing", new RenderMap<string>("default-thing").For("a"));
    }

    /// The three real sets, and the property that used to hold only by coincidence:
    /// every id validation will yield has an entry the render path can use.
    public class WidgetPreferencesTests
    {
        [Fact]
        public void The_valid_ids_are_the_declared_ids()
        {
            Assert.Equal(WidgetConfig.ValidSkins, Preferences.Skins.Ids);
            Assert.Equal(WidgetConfig.ValidSizes, Preferences.Sizes.Ids);
            Assert.Equal(WidgetConfig.ValidAccents, Preferences.Accents.Ids);
        }

        [Fact]
        public void The_default_of_each_set_is_the_config_default()
        {
            var c = new WidgetConfig().Validated();

            Assert.Equal(c.Skin, Preferences.Skins.DefaultId);
            Assert.Equal(c.Size, Preferences.Sizes.DefaultId);
            Assert.Equal(c.Accent, Preferences.Accents.DefaultId);
        }

        [Fact]
        public void Every_option_has_a_label_for_the_menu()
        {
            foreach (var set in new PreferenceOptions[] { Preferences.Skins, Preferences.Sizes, Preferences.Accents })
                foreach (var option in set)
                    Assert.False(string.IsNullOrWhiteSpace(option.Label), $"'{option.Id}' has no label");
        }

        // The size scale is the lookup that would actually have thrown: the window
        // indexed a scale dictionary with the validated size id and nothing tied the two
        // together.
        [Fact]
        public void Every_valid_size_has_a_layout_scale()
        {
            foreach (var id in WidgetConfig.ValidSizes)
                Assert.True(Preferences.Sizes.ValueOf(id) > 0, $"size '{id}' has no scale");
        }

        [Fact]
        public void The_size_scales_are_the_locked_spec_values()
        {
            Assert.Equal(0.85, Preferences.Sizes.ValueOf("small"));
            Assert.Equal(1.0, Preferences.Sizes.ValueOf("medium"));
            Assert.Equal(1.25, Preferences.Sizes.ValueOf("large"));
        }

        [Fact]
        public void An_unknown_size_scales_by_the_default_rather_than_throwing()
            => Assert.Equal(Preferences.Sizes.ValueOf("small"), Preferences.Sizes.ValueOf("enormous"));

        [Fact]
        public void Every_valid_accent_has_a_full_severity_palette()
        {
            foreach (var id in WidgetConfig.ValidAccents)
            {
                var palette = Preferences.Accents.ValueOf(id);
                foreach (var band in new[] { "green", "amber", "red" })
                    Assert.False(string.IsNullOrWhiteSpace(palette.For(band)), $"accent '{id}' has no {band}");
            }
        }
    }
}
