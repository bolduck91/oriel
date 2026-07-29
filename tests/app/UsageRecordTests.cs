// Reading the tee's current.json. The contract that matters here is negative: every
// unhappy path yields null so the caller can hold the last good record, because a
// fabricated zero would read as "you have used nothing" — the most misleading thing
// this widget could say (ADR 0002).

using System;
using System.IO;
using Xunit;

namespace Oriel.Tests
{
    public class UsageRecordTests
    {
        [Fact]
        public void Reads_a_well_formed_record()
        {
            using var f = new TempFile(@"{
                ""five_hour"": { ""used_percentage"": 63.5, ""resets_at"": 1700008017 },
                ""seven_day"": { ""used_percentage"": 15, ""resets_at"": 1700259200 },
                ""written_at"": 1700000000
            }");

            var rec = UsageRecord.TryRead(f.Path);

            Assert.NotNull(rec);
            Assert.Equal(63.5, rec.FiveHour.UsedPercentage);
            Assert.Equal(1700008017, rec.FiveHour.ResetsAt);
            Assert.Equal(15, rec.SevenDay.UsedPercentage);
            Assert.Equal(1700259200, rec.SevenDay.ResetsAt);
            Assert.Equal(1700000000, rec.WrittenAt);
        }

        [Fact]
        public void A_missing_file_yields_null_not_a_zeroed_record()
        {
            var path = Path.Combine(Path.GetTempPath(), "oriel-missing-" + Guid.NewGuid().ToString("N") + ".json");
            Assert.Null(UsageRecord.TryRead(path));
        }

        [Theory]
        [InlineData("")]                                    // truncated to nothing
        [InlineData("   \r\n")]                             // whitespace only
        [InlineData("{ not valid json")]                    // corrupt
        [InlineData("null")]                                // valid JSON, no record
        [InlineData("{}")]                                  // no windows at all
        [InlineData(@"{ ""five_hour"": { ""used_percentage"": 63, ""resets_at"": 1 } }")]  // half a record
        [InlineData(@"{ ""seven_day"": { ""used_percentage"": 15, ""resets_at"": 1 } }")]
        public void An_unreadable_or_partial_file_yields_null(string content)
        {
            using var f = new TempFile(content);
            Assert.Null(UsageRecord.TryRead(f.Path));
        }

        [Fact]
        public void A_directory_where_the_state_file_should_be_yields_null_rather_than_throwing()
        {
            var dir = Path.Combine(Path.GetTempPath(), "oriel-dir-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(dir);
            try { Assert.Null(UsageRecord.TryRead(dir)); }
            finally { Directory.Delete(dir); }
        }

        // The two halves composed, which is the checkbox as written: no state file on disk
        // must reach the renderer as the explicit empty state, not as a 0% reading.
        [Fact]
        public void A_missing_state_file_reaches_the_view_as_the_empty_state()
        {
            using var f = new TempFile();   // a path, deliberately with no file at it

            var v = WidgetView.Build(UsageRecord.TryRead(f.Path), new WidgetConfig().Validated(), 1700000000);

            Assert.False(v.HasData);
            Assert.Null(v.Five);
            Assert.Null(v.Seven);
        }

        [Fact]
        public void The_state_file_the_widget_reads_is_the_one_the_tee_writes()
        {
            Assert.Equal(Path.Combine(Paths.Dir, "current.json"), Paths.StateFile);
            Assert.Equal(Path.Combine(Paths.Dir, "config.json"), Paths.ConfigFile);
            Assert.EndsWith(Path.Combine(".claude", "oriel"), Paths.Dir);
        }
    }
}
