// The update check (oriel-distribution ticket 10).
//
// The whole decision — is this newer, and should anything be said — is pure, and the
// fetcher is injected, so none of these tests touch the network. What is asserted is
// what the user would notice: a notice appears, or nothing does.

using System;
using Oriel;
using Xunit;

namespace Oriel.Tests
{
    public class UpdateCheckTests
    {
        private static string Release(string tag, string url = "https://example.invalid/r/1")
            => $"{{\"tag_name\":\"{tag}\",\"html_url\":\"{url}\"}}";

        [Theory]
        [InlineData("1.0.0", "1.0.1")]
        [InlineData("1.0.0", "v1.1.0")]
        [InlineData("1.0.0", "2.0.0")]
        [InlineData("v1.9.9", "1.10.0")]   // not a string comparison
        public void A_newer_release_produces_a_notice(string current, string latest)
        {
            var notice = UpdateCheck.Evaluate(current, () => Release(latest));
            Assert.NotNull(notice);
            Assert.Equal(latest, notice.Version);
            Assert.Equal("https://example.invalid/r/1", notice.Url);
        }

        [Theory]
        [InlineData("1.0.0", "1.0.0")]
        [InlineData("1.0.0", "v1.0.0")]
        [InlineData("1.2.0", "1.1.9")]
        // Running ahead of the last release is a developer on a local build; telling
        // them to "upgrade" downwards would be worse than saying nothing.
        [InlineData("2.0.0", "1.9.9")]
        public void An_equal_or_older_release_produces_nothing(string current, string latest)
            => Assert.Null(UpdateCheck.Evaluate(current, () => Release(latest)));

        [Fact]
        public void A_failed_check_is_invisible()
        {
            // No network is the ordinary case on some machines, not an error case.
            Assert.Null(UpdateCheck.Evaluate("1.0.0", () => throw new InvalidOperationException("no network")));
        }

        [Theory]
        [InlineData("")]
        [InlineData("   ")]
        [InlineData("not json at all")]
        [InlineData("[1,2,3]")]
        [InlineData("{}")]
        [InlineData("{\"tag_name\":null}")]
        [InlineData("{\"tag_name\":\"nightly\"}")]   // unreadable as a version
        public void A_response_it_cannot_read_produces_nothing(string body)
            => Assert.Null(UpdateCheck.Evaluate("1.0.0", () => body));

        [Fact]
        public void A_null_response_produces_nothing()
            => Assert.Null(UpdateCheck.Evaluate("1.0.0", () => null));

        [Fact]
        public void A_release_without_a_link_falls_back_to_the_releases_page()
        {
            var notice = UpdateCheck.Evaluate("1.0.0", () => "{\"tag_name\":\"1.1.0\"}");
            Assert.NotNull(notice);
            Assert.Equal(UpdateCheck.ReleasesPage, notice.Url);
        }

        [Fact]
        public void A_pre_release_suffix_is_not_read_as_a_version_component()
        {
            // 1.1.0-beta.2 is still 1.1.0 for the purpose of "is there something newer".
            Assert.True(UpdateCheck.IsNewer("1.0.0", "v1.1.0-beta.2"));
            Assert.False(UpdateCheck.IsNewer("1.1.0", "v1.1.0-beta.2"));
        }

        [Fact]
        public void An_unreadable_current_version_produces_nothing()
        {
            // Better silent than announcing an upgrade against a version we cannot read.
            Assert.False(UpdateCheck.IsNewer("who knows", "2.0.0"));
            Assert.Null(UpdateCheck.Evaluate(null, () => Release("9.9.9")));
        }

        [Fact]
        public void It_asks_for_the_release_tag_and_nothing_else()
        {
            // The check reports and links; it must never be a download. If a fetch is
            // ever allowed to hand back a payload, this is where it would show up.
            var calls = 0;
            var notice = UpdateCheck.Evaluate("1.0.0", () => { calls++; return Release("1.1.0"); });
            Assert.Equal(1, calls);
            Assert.NotNull(notice);
            // A notice carries a version and a link. Nothing else — there is nothing
            // else for it to carry.
            Assert.Equal("1.1.0", notice.Version);
            Assert.StartsWith("https://", notice.Url);
        }

        [Fact]
        public void A_missing_fetcher_produces_nothing_rather_than_throwing()
            => Assert.Null(UpdateCheck.Evaluate("1.0.0", null));
    }

    public class UpdateCheckPreferenceTests
    {
        [Fact]
        public void The_check_is_on_by_default_and_survives_a_round_trip()
        {
            var path = System.IO.Path.Combine(System.IO.Path.GetTempPath(), Guid.NewGuid().ToString("N"), "config.json");
            try
            {
                Assert.True(new WidgetConfig().Validated().CheckForUpdates);

                var cfg = new WidgetConfig().Validated();
                cfg.CheckForUpdates = false;
                cfg.Write(path);
                Assert.False(WidgetConfig.Read(path).CheckForUpdates);
            }
            finally
            {
                try { System.IO.Directory.Delete(System.IO.Path.GetDirectoryName(path), true); } catch { }
            }
        }

        [Fact]
        public void A_config_written_before_the_check_existed_loads_as_on()
        {
            // The announced behaviour is that it is on; a file predating the setting
            // must not silently opt the user out of what the installer told them.
            var dir = System.IO.Path.Combine(System.IO.Path.GetTempPath(), Guid.NewGuid().ToString("N"));
            System.IO.Directory.CreateDirectory(dir);
            var path = System.IO.Path.Combine(dir, "config.json");
            try
            {
                System.IO.File.WriteAllText(path, "{\"skin\":\"inline\",\"tint\":90}");
                var cfg = WidgetConfig.Read(path);
                Assert.True(cfg.CheckForUpdates);
                Assert.Equal("inline", cfg.Skin);
            }
            finally
            {
                try { System.IO.Directory.Delete(dir, true); } catch { }
            }
        }
    }
}
