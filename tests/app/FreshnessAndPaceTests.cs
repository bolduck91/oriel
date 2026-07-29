// Staleness threshold and the pace maths (port of the Test-UsageStale,
// Get-ElapsedFraction and Test-OverPace blocks).

using Xunit;

namespace Oriel.Tests
{
    public class FreshnessTests
    {
        [Fact]
        public void Is_fresh_within_the_threshold()
            => Assert.False(Freshness.IsStale(1300, 1200, 180));

        [Fact]
        public void Is_stale_once_older_than_the_threshold()
            => Assert.True(Freshness.IsStale(1400, 1200, 180));

        // The boundary itself: the rule is strictly greater-than, so a record exactly
        // at the threshold is still fresh and one second later is not.
        [Fact]
        public void A_record_exactly_at_the_threshold_is_still_fresh()
        {
            Assert.False(Freshness.IsStale(1000 + 180, 1000, 180));
            Assert.True(Freshness.IsStale(1000 + 181, 1000, 180));
        }

        [Fact]
        public void A_two_minute_reading_pause_stays_fresh_at_the_default_threshold()
            => Assert.False(Freshness.IsStale(1000 + 120, 1000));

        [Fact]
        public void The_default_threshold_is_three_minutes()
            => Assert.Equal(180, Freshness.DefaultThresholdSeconds);

        [Fact]
        public void A_clock_skewed_future_record_is_not_stale()
            => Assert.False(Freshness.IsStale(1000, 1200));
    }

    public class PaceTests
    {
        [Fact]
        public void Elapsed_is_half_at_the_window_midpoint()
            => Assert.Equal(0.5, Pace.ElapsedFraction(1000, 1000 + 9000, 18000), 6);

        [Fact]
        public void Elapsed_clamps_to_one_when_the_window_is_due_or_past()
        {
            Assert.Equal(1.0, Pace.ElapsedFraction(1000, 1000, 18000), 6);
            Assert.Equal(1.0, Pace.ElapsedFraction(5000, 1000, 18000), 6);   // long past
        }

        [Fact]
        public void Elapsed_clamps_to_zero_for_a_just_reset_window()
        {
            // resets_at further out than a whole window: the window only just began
            Assert.Equal(0.0, Pace.ElapsedFraction(1000, 1000 + 20000, 18000), 6);
            Assert.Equal(0.0, Pace.ElapsedFraction(1000, 1000 + 18000, 18000), 6);
        }

        [Fact]
        public void A_nonsensical_window_length_yields_zero_rather_than_dividing_by_zero()
        {
            Assert.Equal(0.0, Pace.ElapsedFraction(1000, 2000, 0), 6);
            Assert.Equal(0.0, Pace.ElapsedFraction(1000, 2000, -1), 6);
        }

        [Fact]
        public void Window_lengths_match_the_two_rate_limit_windows()
        {
            Assert.Equal(5 * 3600, Pace.FiveHourSeconds);
            Assert.Equal(7 * 86400, Pace.SevenDaySeconds);
        }

        [Fact]
        public void Over_pace_when_used_runs_ahead_of_elapsed()
            => Assert.True(Pace.IsOverPace(40, 0.2));

        [Fact]
        public void On_pace_when_used_tracks_or_trails_elapsed()
        {
            Assert.False(Pace.IsOverPace(15, 0.2));
            Assert.False(Pace.IsOverPace(20, 0.2));   // exactly on pace
        }

        // The epsilon exists so floating-point dust on an exactly-on-pace datum cannot
        // light the burn marker. Just inside it stays quiet; just outside it fires.
        [Fact]
        public void Epsilon_keeps_a_hair_over_quiet_but_lets_a_real_lead_through()
        {
            Assert.False(Pace.IsOverPace(20.05, 0.2));   // +0.0005 — inside epsilon
            Assert.True(Pace.IsOverPace(20.5, 0.2));     // +0.005  — outside epsilon
        }

        [Fact]
        public void Nothing_used_is_never_over_pace()
            => Assert.False(Pace.IsOverPace(0, 0.0));
    }
}
