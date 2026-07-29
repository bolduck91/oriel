// One widget per desktop session (ADR 0007).
//
// Every test here takes a gate name of its own. That is the whole point: the WPF
// lifecycle test this replaces asserted it could take the PRODUCTION mutex, so it
// failed whenever the widget it was testing was actually running. A suite that only
// passes when the app is closed is a suite nobody runs.

using System;
using Xunit;

namespace Oriel.Tests
{
    public class SingleInstanceTests
    {
        private static string FreshName() => @"Local\oriel-test-" + Guid.NewGuid().ToString("N");

        [Fact]
        public void The_first_holder_owns_the_gate()
        {
            using var first = new SingleInstanceGate(FreshName());
            Assert.True(first.IsOwner);
        }

        [Fact]
        public void A_second_holder_is_turned_away()
        {
            var name = FreshName();
            using var first = new SingleInstanceGate(name);
            using var second = new SingleInstanceGate(name);

            Assert.True(first.IsOwner);
            Assert.False(second.IsOwner);
        }

        [Fact]
        public void Releasing_the_gate_lets_the_next_launch_in()
        {
            var name = FreshName();
            using (var first = new SingleInstanceGate(name)) Assert.True(first.IsOwner);

            using var next = new SingleInstanceGate(name);
            Assert.True(next.IsOwner);
        }

        [Fact]
        public void Gates_with_different_names_do_not_collide()
        {
            using var a = new SingleInstanceGate(FreshName());
            using var b = new SingleInstanceGate(FreshName());

            Assert.True(a.IsOwner);
            Assert.True(b.IsOwner);
        }

        // Disposing a gate you never owned must not release the owner's claim, or the
        // second launch would knock the running widget's gate open on its way out.
        [Fact]
        public void A_rejected_holder_disposing_does_not_free_the_owners_gate()
        {
            var name = FreshName();
            using var owner = new SingleInstanceGate(name);

            using (var rejected = new SingleInstanceGate(name)) Assert.False(rejected.IsOwner);

            using var another = new SingleInstanceGate(name);
            Assert.False(another.IsOwner);
        }

        [Fact]
        public void The_shipped_gate_name_is_session_local()
        {
            // Local\ scopes the gate to the logon session: two users on the same machine
            // each get their own widget, which a Global\ name would prevent.
            Assert.StartsWith(@"Local\", SingleInstanceGate.WidgetGateName);
        }
    }
}
