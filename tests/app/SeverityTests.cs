// Severity bands and the three accent palettes (port of the Get-SeverityBand /
// Get-SeverityHex blocks). The ticket asks for the bands at their BOUNDARIES, not
// their middles — an off-by-one in `<` vs `<=` is invisible at 20% and 88%.

using Xunit;

namespace Oriel.Tests
{
    public class SeverityTests
    {
        [Theory]
        [InlineData(0, "green")]
        [InlineData(49.9, "green")]
        [InlineData(49.999, "green")]
        [InlineData(50, "amber")]      // lower edge of amber
        [InlineData(79.999, "amber")]
        [InlineData(80, "red")]        // lower edge of red
        [InlineData(100, "red")]
        [InlineData(140, "red")]       // over-quota readings still land in red
        public void Band_switches_at_50_and_80(double pct, string expected)
            => Assert.Equal(expected, Severity.Band(pct));

        [Theory]
        [InlineData("pastel", "#a6e3a1", "#f9e2af", "#f38ba8")]
        [InlineData("vivid", "#34d399", "#fbbf24", "#f87171")]
        [InlineData("muted", "#8fb89a", "#cbb98a", "#c99098")]
        public void Hex_returns_each_palette_by_band(string accent, string green, string amber, string red)
        {
            Assert.Equal(green, Severity.Hex(20, false, accent));
            Assert.Equal(amber, Severity.Hex(63, false, accent));
            Assert.Equal(red, Severity.Hex(88, false, accent));
        }

        // The band edges again, but through Hex — the colour is what the user sees, so
        // the expectations are literals rather than another call into production code.
        [Fact]
        public void Hex_switches_palette_entry_at_the_band_edges()
        {
            Assert.Equal("#a6e3a1", Severity.Hex(49.999, false, "pastel"));
            Assert.Equal("#f9e2af", Severity.Hex(50, false, "pastel"));
            Assert.Equal("#f9e2af", Severity.Hex(79.999, false, "pastel"));
            Assert.Equal("#f38ba8", Severity.Hex(80, false, "pastel"));
        }

        [Theory]
        [InlineData(20, "pastel")]
        [InlineData(63, "vivid")]
        [InlineData(88, "muted")]
        public void Hex_drains_to_the_neutral_grey_when_stale_whatever_the_band(double pct, string accent)
            => Assert.Equal("#585b70", Severity.Hex(pct, true, accent));

        [Theory]
        [InlineData(null)]
        [InlineData("neon")]
        [InlineData("")]
        public void Hex_falls_back_to_pastel_for_an_unknown_accent(string accent)
            => Assert.Equal("#a6e3a1", Severity.Hex(20, false, accent));
    }
}
