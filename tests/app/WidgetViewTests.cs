// The view-model builder — where the pieces above combine into what the widget renders
// (ported from the retired Pester View tests, extended with the staleness rule:
// only the PERCENTAGES drain, the countdown keeps running).

using Xunit;

namespace Oriel.Tests
{
    public class WidgetViewTests
    {
        private const long Now = 1700000000;
        private static readonly WidgetConfig Cfg = new WidgetConfig().Validated();

        private static UsageRecord Record(
            double fivePct = 63, double sevenPct = 15,
            long fiveReset = Now + 8017, long sevenReset = Now + (3 * 86400),
            long writtenAt = Now)
            => new UsageRecord
            {
                FiveHour = new Window5 { UsedPercentage = fivePct, ResetsAt = fiveReset },
                SevenDay = new Window5 { UsedPercentage = sevenPct, ResetsAt = sevenReset },
                WrittenAt = writtenAt,
            };

        [Fact]
        public void A_null_record_is_the_explicit_empty_state_with_no_fabricated_zeros()
        {
            var v = WidgetView.Build(null, Cfg, Now);

            Assert.False(v.HasData);
            Assert.False(v.IsStale);
            Assert.Null(v.Five);
            Assert.Null(v.Seven);
        }

        [Fact]
        public void Projects_both_windows_with_colour_and_reset_text_when_fresh()
        {
            var v = WidgetView.Build(Record(), Cfg, Now);

            Assert.True(v.HasData);
            Assert.False(v.IsStale);
            Assert.Equal(63, v.Five.Pct);
            Assert.Equal("#f9e2af", v.Five.ColorHex);      // amber band, pastel accent
            Assert.Equal("2h13m", v.Five.ResetText);
            Assert.Equal(15, v.Seven.Pct);
            Assert.Equal("#a6e3a1", v.Seven.ColorHex);     // green band
        }

        [Fact]
        public void Honours_the_configured_accent()
        {
            var vivid = new WidgetConfig { Accent = "vivid" }.Validated();
            var v = WidgetView.Build(Record(fivePct: 20, sevenPct: 20), vivid, Now);

            Assert.Equal("#34d399", v.Five.ColorHex);
            Assert.Equal("#34d399", v.Seven.ColorHex);
        }

        [Fact]
        public void Both_colours_drain_to_grey_when_the_record_is_stale()
        {
            var v = WidgetView.Build(Record(fivePct: 88, sevenPct: 60, writtenAt: Now - 600), Cfg, Now);

            Assert.True(v.IsStale);
            Assert.Equal("#585b70", v.Five.ColorHex);
            Assert.Equal("#585b70", v.Seven.ColorHex);
        }

        // The point of deriving reset text from absolute resets_at (ADR 0004): a dead tee
        // greys the numbers it can no longer vouch for, but the countdown is still true,
        // so it keeps ticking rather than freezing at whatever it last said.
        [Fact]
        public void Staleness_drains_the_percentages_but_the_countdown_keeps_running()
        {
            var rec = Record(fiveReset: Now + 8017, sevenReset: Now + (3 * 86400), writtenAt: Now - 600);

            var v = WidgetView.Build(rec, Cfg, Now);
            var later = WidgetView.Build(rec, Cfg, Now + 60);

            Assert.True(v.IsStale);
            Assert.Equal("2h13m", v.Five.ResetText);
            Assert.Equal("2h12m", later.Five.ResetText);            // still advancing
            Assert.Equal(v.Five.Pct, later.Five.Pct);               // the number itself is frozen
        }

        [Fact]
        public void Percentages_survive_staleness_unchanged_only_their_colour_changes()
        {
            var fresh = WidgetView.Build(Record(fivePct: 88, sevenPct: 60), Cfg, Now);
            var stale = WidgetView.Build(Record(fivePct: 88, sevenPct: 60, writtenAt: Now - 600), Cfg, Now);

            Assert.Equal(fresh.Five.Pct, stale.Five.Pct);
            Assert.Equal(fresh.Seven.Pct, stale.Seven.Pct);
            Assert.NotEqual(fresh.Five.ColorHex, stale.Five.ColorHex);
        }

        [Fact]
        public void Uses_the_staleness_threshold_it_is_given()
        {
            var rec = Record(writtenAt: Now - 300);

            Assert.True(WidgetView.Build(rec, Cfg, Now).IsStale);                  // default 180s
            Assert.False(WidgetView.Build(rec, Cfg, Now, thresholdSeconds: 600).IsStale);
        }

        [Fact]
        public void Flags_seven_day_over_pace_when_used_runs_ahead_of_elapsed()
        {
            // 3 of 7 days elapsed (~43%), 60% used => burning too fast
            var v = WidgetView.Build(Record(sevenPct: 60, sevenReset: Now + (4 * 86400)), Cfg, Now);
            Assert.True(v.Seven.OverPace);
        }

        [Fact]
        public void Does_not_flag_over_pace_when_used_trails_elapsed()
        {
            var v = WidgetView.Build(Record(sevenPct: 20, sevenReset: Now + (4 * 86400)), Cfg, Now);
            Assert.False(v.Seven.OverPace);
        }

        [Fact]
        public void Never_flags_over_pace_while_stale()
        {
            var v = WidgetView.Build(Record(sevenPct: 90, sevenReset: Now + (6 * 86400), writtenAt: Now - 600), Cfg, Now);
            Assert.True(v.IsStale);
            Assert.False(v.Seven.OverPace);
        }

        [Fact]
        public void Does_not_flag_over_pace_for_a_datum_exactly_on_pace()
        {
            // 3.5 of 7 days elapsed, exactly 50% used — level, so the marker stays dark
            var v = WidgetView.Build(Record(sevenPct: 50, sevenReset: Now + (7 * 86400 / 2)), Cfg, Now);

            Assert.Equal(0.5, v.Seven.ElapsedFraction, 6);
            Assert.False(v.Seven.OverPace);
        }

        // The burn marker belongs to the 7-day window only — the 5-hour window is short
        // enough that being "ahead" of it is normal and would fire constantly.
        [Fact]
        public void The_five_hour_window_never_carries_a_pace_marker()
        {
            var v = WidgetView.Build(Record(fivePct: 99, fiveReset: Now + (5 * 3600)), Cfg, Now);
            Assert.False(v.Five.OverPace);
        }

        [Fact]
        public void Shows_the_five_hour_reset_as_due_while_still_showing_the_percentage()
        {
            var v = WidgetView.Build(Record(fivePct: 40, fiveReset: Now - 5), Cfg, Now);

            Assert.Equal("due", v.Five.ResetText);
            Assert.Equal(40, v.Five.Pct);
        }

        // IsDue is what the reset notifications key off, so it has to come from the
        // clock rather than from the rendered wording.
        [Fact]
        public void Marks_a_window_due_from_the_reset_instant_not_from_the_reset_text()
        {
            var live = WidgetView.Build(Record(fiveReset: Now + 1, sevenReset: Now + 86400), Cfg, Now);
            Assert.False(live.Five.IsDue);
            Assert.False(live.Seven.IsDue);

            var expired = WidgetView.Build(Record(fiveReset: Now, sevenReset: Now - 1), Cfg, Now);
            Assert.True(expired.Five.IsDue);
            Assert.True(expired.Seven.IsDue);
            Assert.Equal("due", expired.Five.ResetText);      // and the two still agree
            Assert.Equal("due", expired.Seven.ResetText);
        }

        [Fact]
        public void Carries_absolute_reset_strings_for_the_dual_reset_tooltip()
        {
            var fiveReset = LocalTime.Unix(2023, 11, 15, 14, 30);    // a Wednesday
            var sevenReset = LocalTime.Unix(2023, 11, 17, 9, 5);     // the Friday
            var now = fiveReset - 8017;

            var v = WidgetView.Build(Record(fiveReset: fiveReset, sevenReset: sevenReset, writtenAt: now), Cfg, now);

            Assert.Equal("14:30", v.Five.ResetClockText);
            Assert.Equal("Fri 09:05", v.Seven.ResetClockText);
        }

        [Fact]
        public void Elapsed_fractions_are_measured_against_each_windows_own_length()
        {
            // 5h window half gone; 7d window 3 of 7 days gone
            var v = WidgetView.Build(Record(fiveReset: Now + 9000, sevenReset: Now + (4 * 86400)), Cfg, Now);

            Assert.Equal(0.5, v.Five.ElapsedFraction, 6);
            Assert.Equal(3.0 / 7.0, v.Seven.ElapsedFraction, 6);
        }

        [Fact]
        public void A_just_reset_seven_day_window_reads_as_zero_elapsed_and_never_over_pace()
        {
            var v = WidgetView.Build(Record(sevenPct: 0, sevenReset: Now + (7 * 86400)), Cfg, Now);

            Assert.Equal(0.0, v.Seven.ElapsedFraction, 6);
            Assert.False(v.Seven.OverPace);
        }
    }
}
