// Config defaults, validation, persistence and off-screen repair (ADR 0007; ported
// from the retired Pester Config.Tests). Validation is the whole point: everything
// downstream reads config without re-checking it, so a hostile or half-written
// file must be impossible to observe.

using System.Collections.Generic;
using System.IO;
using Xunit;

namespace Oriel.Tests
{
    public class ConfigDefaultsTests
    {
        [Fact]
        public void Defaults_match_the_locked_visual_spec()
        {
            var c = new WidgetConfig().Validated();

            Assert.Equal("twin", c.Skin);
            Assert.Equal("small", c.Size);
            Assert.Equal(100, c.Opacity);
            Assert.Equal(75, c.Tint);
            Assert.Equal("full", c.Blur);
            Assert.Equal("pastel", c.Accent);
            Assert.False(c.StartWithWindows);
            Assert.False(c.ResetNotifications);
            Assert.Null(c.X);
            Assert.Null(c.Y);
        }

        [Fact]
        public void The_valid_sets_are_the_skins_sizes_accents_and_two_blur_steps()
        {
            Assert.Equal(new[] { "twin", "sidecar", "inline", "concentric" }, WidgetConfig.ValidSkins);
            Assert.Equal(new[] { "small", "medium", "large" }, WidgetConfig.ValidSizes);
            Assert.Equal(new[] { "pastel", "vivid", "muted" }, WidgetConfig.ValidAccents);
            Assert.Equal(new[] { "full", "off" }, WidgetConfig.ValidBlurs);
        }
    }

    public class ConfigValidationTests
    {
        [Fact]
        public void Keeps_a_recognised_value_and_defaults_the_rest()
        {
            var c = new WidgetConfig { Skin = "inline" }.Validated();

            Assert.Equal("inline", c.Skin);
            Assert.Equal("small", c.Size);
            Assert.Equal(75, c.Tint);
        }

        [Theory]
        [InlineData("twin")]
        [InlineData("sidecar")]
        [InlineData("inline")]
        [InlineData("concentric")]
        public void Every_valid_skin_survives_validation(string skin)
            => Assert.Equal(skin, new WidgetConfig { Skin = skin }.Validated().Skin);

        [Fact]
        public void Unknown_enum_values_fall_back_to_the_default()
        {
            var c = new WidgetConfig { Skin = "spinny", Size = "huge", Accent = "neon", Blur = "bokeh" }.Validated();

            Assert.Equal("twin", c.Skin);
            Assert.Equal("small", c.Size);
            Assert.Equal("pastel", c.Accent);
            Assert.Equal("full", c.Blur);
        }

        [Fact]
        public void Null_enum_values_fall_back_to_the_default()
        {
            var c = new WidgetConfig { Skin = null, Size = null, Accent = null, Blur = null }.Validated();

            Assert.Equal("twin", c.Skin);
            Assert.Equal("small", c.Size);
            Assert.Equal("pastel", c.Accent);
            Assert.Equal("full", c.Blur);
        }

        [Fact]
        public void Out_of_range_numbers_clamp_into_range()
        {
            var low = new WidgetConfig { Opacity = 5, Tint = 0 }.Validated();
            Assert.Equal(40, low.Opacity);
            Assert.Equal(50, low.Tint);

            var high = new WidgetConfig { Opacity = 400, Tint = 200 }.Validated();
            Assert.Equal(100, high.Opacity);
            Assert.Equal(97, high.Tint);
        }

        [Fact]
        public void In_range_numbers_pass_through_including_the_exact_bounds()
        {
            var c = new WidgetConfig { Opacity = 40, Tint = 97 }.Validated();

            Assert.Equal(40, c.Opacity);
            Assert.Equal(97, c.Tint);
        }

        [Fact]
        public void Preserves_a_saved_window_position_and_the_toggles()
        {
            var c = new WidgetConfig { X = 1200, Y = 40, StartWithWindows = true, ResetNotifications = true }.Validated();

            Assert.Equal(1200, c.X);
            Assert.Equal(40, c.Y);
            Assert.True(c.StartWithWindows);
            Assert.True(c.ResetNotifications);
        }

        [Fact]
        public void Validation_is_idempotent()
        {
            var once = new WidgetConfig { Skin = "spinny", Opacity = 5 }.Validated();
            var twice = once.Validated();

            Assert.Equal(once.Skin, twice.Skin);
            Assert.Equal(once.Opacity, twice.Opacity);
        }
    }

    public class ConfigPersistenceTests
    {
        [Fact]
        public void A_missing_file_yields_validated_defaults()
        {
            using var f = new TempFile();   // a path, deliberately with no file at it

            var c = WidgetConfig.Read(f.Path);

            Assert.Equal("twin", c.Skin);
            Assert.Equal("full", c.Blur);
        }

        [Fact]
        public void Persists_and_reloads_a_change()
        {
            using var f = new TempFile();

            new WidgetConfig { Skin = "concentric", Size = "large", Accent = "vivid", Blur = "off", X = 800, Y = 120 }
                .Write(f.Path);
            var back = WidgetConfig.Read(f.Path);

            Assert.Equal("concentric", back.Skin);
            Assert.Equal("off", back.Blur);
            Assert.Equal("large", back.Size);
            Assert.Equal("vivid", back.Accent);
            Assert.Equal(800, back.X);
            Assert.Equal(120, back.Y);
        }

        // The atomic write is temp-then-replace, so a leftover .tmp would mean the
        // replace half never happened — the same contract as src/tee/AtomicWrite.ps1.
        [Fact]
        public void Writing_leaves_no_temp_file_behind()
        {
            using var f = new TempFile();

            new WidgetConfig().Write(f.Path);

            Assert.True(File.Exists(f.Path));
            Assert.False(File.Exists(f.Path + ".tmp"));
        }

        // The failure path, which is the one that actually leaked (ticket 09). The
        // move is what removes the temp, so a write that gets that far and no
        // further strands it — and because a failed save is swallowed to keep the
        // widget up, nothing would ever report it.
        [Fact]
        public void A_failed_write_leaves_no_temp_file_behind()
        {
            using var f = new TempFile("{}");

            // Hold the destination open with no sharing so the replace is denied.
            using (var held = new FileStream(f.Path, FileMode.Open, FileAccess.ReadWrite, FileShare.None))
            {
                new WidgetConfig { Skin = "inline" }.Write(f.Path);
            }

            Assert.False(File.Exists(f.Path + ".tmp"));
        }

        // Saving preferences must never take the widget down, however badly the
        // write goes — the reason the catch is there in the first place.
        [Fact]
        public void A_failed_write_does_not_throw()
        {
            using var f = new TempFile("{}");

            using var held = new FileStream(f.Path, FileMode.Open, FileAccess.ReadWrite, FileShare.None);

            var ex = Record.Exception(() => new WidgetConfig { Skin = "inline" }.Write(f.Path));

            Assert.Null(ex);
        }

        [Theory]
        [InlineData("{ not valid json")]
        [InlineData("")]
        [InlineData("null")]
        public void A_corrupt_file_yields_defaults_rather_than_throwing(string content)
        {
            using var f = new TempFile(content);

            var c = WidgetConfig.Read(f.Path);

            Assert.Equal("twin", c.Skin);
            Assert.Equal("pastel", c.Accent);
        }

        [Fact]
        public void A_file_with_hostile_values_is_read_back_validated()
        {
            using var f = new TempFile(
                @"{ ""skin"": ""spinny"", ""opacity"": -999, ""tint"": 9999, ""blur"": ""bokeh"", ""accent"": ""neon"" }");

            var c = WidgetConfig.Read(f.Path);

            Assert.Equal("twin", c.Skin);
            Assert.Equal(40, c.Opacity);
            Assert.Equal(97, c.Tint);
            Assert.Equal("full", c.Blur);
            Assert.Equal("pastel", c.Accent);
        }

        [Fact]
        public void A_partial_file_fills_the_missing_keys_from_defaults()
        {
            using var f = new TempFile(@"{ ""skin"": ""sidecar"" }");

            var c = WidgetConfig.Read(f.Path);

            Assert.Equal("sidecar", c.Skin);
            Assert.Equal("small", c.Size);
            Assert.Equal("full", c.Blur);
        }
    }

    /// `blur` was a number (0-60) that nothing consumed, until polish ticket 02 made it a
    /// named backdrop step (ADR 0010). Every config.json written before that carries the
    /// number, and the whole-file read is wrapped in a catch that turns ANY deserialization
    /// failure into "reset every preference to its default" — so a number arriving where a
    /// step is expected has to be tolerated rather than thrown.
    public class ConfigLegacyBlurTests
    {
        [Fact]
        public void A_config_from_before_the_change_keeps_every_other_preference()
        {
            using var f = new TempFile(
                @"{ ""skin"": ""concentric"", ""size"": ""large"", ""opacity"": 70, ""tint"": 90,
                     ""blur"": 30, ""accent"": ""vivid"", ""resetNotifications"": true, ""x"": 800, ""y"": 120 }");

            var c = WidgetConfig.Read(f.Path);

            // The legacy number never reached the screen, so it carries no intent to honour.
            Assert.Equal("full", c.Blur);
            // ...and nothing else may be lost on the way past it.
            Assert.Equal("concentric", c.Skin);
            Assert.Equal("large", c.Size);
            Assert.Equal(70, c.Opacity);
            Assert.Equal(90, c.Tint);
            Assert.Equal("vivid", c.Accent);
            Assert.True(c.ResetNotifications);
            Assert.Equal(800, c.X);
            Assert.Equal(120, c.Y);
        }

        [Theory]
        [InlineData("0")]        // the old lower bound
        [InlineData("30")]       // the old default
        [InlineData("60")]       // the old upper bound
        [InlineData("9999")]     // hand-edited nonsense
        [InlineData("-3")]
        [InlineData("22.5")]
        [InlineData("true")]     // any wrong-typed value, not only numbers
        [InlineData("null")]
        [InlineData("{ }")]
        [InlineData("[ 1, 2 ]")]
        public void Any_shape_of_legacy_blur_value_loads_as_the_default_step(string raw)
        {
            using var f = new TempFile(@"{ ""tint"": 90, ""blur"": " + raw + @", ""accent"": ""muted"" }");

            var c = WidgetConfig.Read(f.Path);

            Assert.Equal("full", c.Blur);
            // The keys on BOTH sides of it survived, so the reader consumed exactly the
            // one value rather than derailing the rest of the object.
            Assert.Equal(90, c.Tint);
            Assert.Equal("muted", c.Accent);
        }

        [Fact]
        public void The_key_is_written_back_as_a_step_rather_than_a_number()
        {
            using var f = new TempFile(@"{ ""blur"": 30 }");

            WidgetConfig.Read(f.Path).Write(f.Path);

            Assert.Contains(@"""blur"": ""full""", File.ReadAllText(f.Path));
        }
    }

    public class ConfigPositionRepairTests
    {
        private static readonly (int X, int Y, int W, int H) Primary = (0, 0, 1920, 1080);
        private static readonly (int X, int Y, int W, int H) Second = (1920, 0, 1920, 1080);

        [Fact]
        public void Leaves_an_on_screen_position_untouched()
        {
            var c = new WidgetConfig { X = 2000, Y = 100 };   // on the second monitor
            c.RepairPosition(new List<(int, int, int, int)> { Primary, Second });

            Assert.Equal(2000, c.X);
            Assert.Equal(100, c.Y);
        }

        [Fact]
        public void Clamps_an_off_screen_position_back_onto_the_primary()
        {
            var c = new WidgetConfig { X = 5000, Y = 3000 };  // second monitor unplugged
            c.RepairPosition(new List<(int, int, int, int)> { Primary });

            Assert.InRange(c.X.Value, Primary.X, Primary.X + Primary.W - 1);
            Assert.InRange(c.Y.Value, Primary.Y, Primary.Y + Primary.H - 1);
        }

        [Fact]
        public void Leaves_a_first_run_null_position_null_so_the_widget_can_place_itself()
        {
            var c = new WidgetConfig();
            c.RepairPosition(new List<(int, int, int, int)> { Primary });

            Assert.Null(c.X);
            Assert.Null(c.Y);
        }

        [Fact]
        public void Does_nothing_when_no_screens_are_reported()
        {
            var c = new WidgetConfig { X = 5000, Y = 3000 };
            c.RepairPosition(new List<(int, int, int, int)>());
            c.RepairPosition(null);

            Assert.Equal(5000, c.X);
        }

        // The caller has to know whether anything moved, so it can write the repaired
        // position back. Without that the config keeps the dead coordinates for ever:
        // the widget opens in the right place every time, while the file on disk still
        // claims it lives on a monitor that is no longer plugged in.
        [Fact]
        public void Reports_whether_it_actually_moved_the_widget()
        {
            var moved = new WidgetConfig { X = 5000, Y = 3000 };
            Assert.True(moved.RepairPosition(new List<(int, int, int, int)> { Primary }));

            var fine = new WidgetConfig { X = 100, Y = 100 };
            Assert.False(fine.RepairPosition(new List<(int, int, int, int)> { Primary }));

            var firstRun = new WidgetConfig();
            Assert.False(firstRun.RepairPosition(new List<(int, int, int, int)> { Primary }));

            var noScreens = new WidgetConfig { X = 5000, Y = 3000 };
            Assert.False(noScreens.RepairPosition(new List<(int, int, int, int)>()));
        }
    }
}
