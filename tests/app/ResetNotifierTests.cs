// Reset notifications: once per reset TRANSITION, never once per tick.
//
// This is the rule that is easy to get wrong and impossible to notice in a
// screenshot: the view sits on "due" from the moment a window expires until the tee
// writes a fresh one, which on a 1-second heartbeat is hundreds of ticks. Firing on
// the state rather than the edge would carpet the desktop in toasts.

using Xunit;

namespace Oriel.Tests
{
    public class ResetNotifierTests
    {
        private static WidgetView View(string fiveReset, string sevenReset, bool hasData = true) =>
            new()
            {
                HasData = hasData,
                // "due" is the rendering of an expired window; IsDue is the fact behind
                // it. Both are set here so these cases read as the widget shows them.
                Five = new WindowView { ResetText = fiveReset, IsDue = fiveReset == "due" },
                Seven = new WindowView { ResetText = sevenReset, IsDue = sevenReset == "due" },
            };

        [Fact]
        public void Fires_when_a_window_crosses_into_due()
        {
            var n = new ResetNotifier();
            Assert.Empty(n.Advance(View("12m30s", "Wed 16:00"), enabled: true));
            Assert.Equal(new[] { "5-hour limit reset" }, n.Advance(View("due", "Wed 16:00"), true));
        }

        [Fact]
        public void Stays_quiet_while_the_window_remains_due()
        {
            var n = new ResetNotifier();
            n.Advance(View("1m00s", "Wed 16:00"), true);
            Assert.Single(n.Advance(View("due", "Wed 16:00"), true));
            Assert.Empty(n.Advance(View("due", "Wed 16:00"), true));
            Assert.Empty(n.Advance(View("due", "Wed 16:00"), true));
        }

        [Fact]
        public void Fires_again_after_the_window_recovers_and_expires_once_more()
        {
            var n = new ResetNotifier();
            n.Advance(View("1m00s", "Wed 16:00"), true);
            Assert.Single(n.Advance(View("due", "Wed 16:00"), true));
            Assert.Empty(n.Advance(View("4h59m", "Wed 16:00"), true));    // tee wrote a fresh window
            Assert.Single(n.Advance(View("due", "Wed 16:00"), true));
        }

        [Fact]
        public void Reports_both_windows_when_they_expire_together()
        {
            var n = new ResetNotifier();
            n.Advance(View("1m00s", "in 2m00s"), true);
            Assert.Equal(
                new[] { "5-hour limit reset", "7-day limit reset" },
                n.Advance(View("due", "due"), true));
        }

        [Fact]
        public void Says_nothing_while_the_preference_is_off()
        {
            var n = new ResetNotifier();
            n.Advance(View("1m00s", "Wed 16:00"), enabled: false);
            Assert.Empty(n.Advance(View("due", "Wed 16:00"), enabled: false));
        }

        // Turning the preference on must not immediately fire for a window that was
        // already sitting on "due" — that is a state, not a transition the user caused.
        [Fact]
        public void Enabling_the_preference_does_not_replay_an_existing_due_state()
        {
            var n = new ResetNotifier();
            n.Advance(View("due", "due"), enabled: false);
            Assert.Empty(n.Advance(View("due", "due"), enabled: true));
        }

        // Before the tee has ever written, there are no windows to have reset. The
        // empty state must not be mistaken for one.
        [Fact]
        public void The_empty_state_neither_fires_nor_forgets_what_came_before()
        {
            var n = new ResetNotifier();
            n.Advance(View("1m00s", "Wed 16:00"), true);
            Assert.Empty(n.Advance(View(null, null, hasData: false), true));
            Assert.Single(n.Advance(View("due", "Wed 16:00"), true));
        }

        [Fact]
        public void A_first_ever_reading_that_is_already_due_does_not_fire()
        {
            var n = new ResetNotifier();
            Assert.Empty(n.Advance(View("due", "due"), true));
        }
    }
}
