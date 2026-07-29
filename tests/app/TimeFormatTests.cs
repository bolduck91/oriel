// Duration / countdown / adaptive reset text — ported from the retired Pester suite's
// Format-Duration, Get-ResetCountdownText and Get-ResetAdaptiveText blocks.
//
// Every case is expressed against explicit `now` and `resetsAt` values, so nothing here
// depends on the wall clock. The cases that render an absolute weekday+clock name the
// wall-clock instant and let `LocalTime.Unix` derive the epoch, so the expected string
// can be a literal that holds in any timezone — see the comment on that helper.

using System;
using Xunit;

namespace Oriel.Tests
{
    public class TimeFormatTests
    {
        [Theory]
        [InlineData((2 * 3600) + (13 * 60) + 37, "2h13m")]   // above an hour: h + zero-padded m
        [InlineData((3 * 3600) + (2 * 60), "3h02m")]         // minutes zero-pad in the hour form
        [InlineData((5 * 60) + 4, "5m04s")]                  // below an hour: m + zero-padded s
        [InlineData(0, "0m00s")]
        [InlineData(59, "0m59s")]
        public void Duration_formats_by_magnitude(long seconds, string expected)
            => Assert.Equal(expected, TimeFormat.Duration(seconds));

        [Fact]
        public void Duration_flips_form_exactly_at_one_hour()
        {
            Assert.Equal("59m59s", TimeFormat.Duration(3599));
            Assert.Equal("1h00m", TimeFormat.Duration(3600));
        }

        [Fact]
        public void Duration_floors_a_negative_span_to_zero()
            => Assert.Equal("0m00s", TimeFormat.Duration(-5));

        // ---- 5-hour window: countdown ----------------------------------------

        [Fact]
        public void Countdown_ticks_down_while_time_remains()
            => Assert.Equal("2h13m", TimeFormat.Countdown(1000, 1000 + 8017));

        [Fact]
        public void Countdown_is_due_at_the_reset_instant()
            => Assert.Equal("due", TimeFormat.Countdown(1000, 1000));

        [Fact]
        public void Countdown_is_due_past_the_reset_instant_never_a_negative_timer()
            => Assert.Equal("due", TimeFormat.Countdown(2000, 1000));

        [Fact]
        public void Countdown_still_counts_one_second_before_reset()
            => Assert.Equal("0m01s", TimeFormat.Countdown(1000, 1001));

        // ---- 7-day window: adaptive ------------------------------------------

        [Fact]
        public void Adaptive_counts_down_with_an_in_prefix_within_a_day()
            => Assert.Equal("in 6h00m", TimeFormat.Adaptive(1000, 1000 + (6 * 3600)));

        [Fact]
        public void Adaptive_is_due_once_reached()
        {
            Assert.Equal("due", TimeFormat.Adaptive(1000, 1000));
            Assert.Equal("due", TimeFormat.Adaptive(1000, 900));
        }

        [Fact]
        public void Adaptive_shows_an_absolute_weekday_clock_beyond_a_day()
        {
            var resetsAt = LocalTime.Unix(2023, 11, 15, 14, 30);   // a Wednesday
            Assert.Equal("Wed 14:30", TimeFormat.Adaptive(resetsAt - (2 * 86400), resetsAt));
        }

        // The boundary the ticket calls out: the flip from countdown to weekday+clock.
        // 86400 exactly is still a countdown; one second more is absolute.
        [Fact]
        public void Adaptive_flips_from_countdown_to_absolute_just_past_24h()
        {
            var resetsAt = LocalTime.Unix(2023, 11, 15, 14, 30);

            Assert.Equal("in 24h00m", TimeFormat.Adaptive(resetsAt - 86400, resetsAt));
            Assert.Equal("Wed 14:30", TimeFormat.Adaptive(resetsAt - 86401, resetsAt));
        }

        // ---- absolute renderings used by the dual-reset tooltip ---------------

        [Fact]
        public void Clock_renders_the_reset_as_a_zero_padded_24h_time()
        {
            Assert.Equal("14:30", TimeFormat.Clock(LocalTime.Unix(2023, 11, 15, 14, 30)));
            Assert.Equal("09:05", TimeFormat.Clock(LocalTime.Unix(2023, 11, 15, 9, 5)));
            Assert.Equal("00:00", TimeFormat.Clock(LocalTime.Unix(2023, 11, 15, 0, 0)));
        }

        [Theory]
        [InlineData(2023, 11, 12, "Sun 08:00")]
        [InlineData(2023, 11, 15, "Wed 08:00")]
        [InlineData(2023, 11, 17, "Fri 08:00")]
        [InlineData(2023, 11, 18, "Sat 08:00")]
        public void WeekdayClock_prefixes_the_abbreviated_local_weekday(int y, int m, int d, string expected)
            => Assert.Equal(expected, TimeFormat.WeekdayClock(LocalTime.Unix(y, m, d, 8, 0)));
    }
}
