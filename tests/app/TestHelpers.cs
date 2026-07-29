// Shared fixtures for the core tests.

using System;
using System.IO;

namespace Oriel.Tests
{
    internal static class LocalTime
    {
        /// A wall-clock instant as epoch seconds, the same units the tee stamps.
        ///
        /// The absolute reset renderings are local-time by design, so a test that hard-codes
        /// an epoch constant would assert a different clock face in every timezone. Going the
        /// other way — naming the wall-clock time and deriving the epoch — lets the expected
        /// string be a literal like "Wed 14:30", which pins the actual FORMAT (weekday
        /// abbreviation, 24h, zero-padded) rather than re-deriving it from the production
        /// code's own recipe and comparing it to itself.
        public static long Unix(int year, int month, int day, int hour, int minute)
            => new DateTimeOffset(new DateTime(year, month, day, hour, minute, 0, DateTimeKind.Local))
                .ToUnixTimeSeconds();
    }

    /// A temp file that deletes itself, so a failing assert cannot leave litter behind.
    internal sealed class TempFile : IDisposable
    {
        public string Path { get; }

        public TempFile(string content = null)
        {
            Path = System.IO.Path.Combine(System.IO.Path.GetTempPath(),
                "oriel-test-" + Guid.NewGuid().ToString("N") + ".json");
            if (content != null) File.WriteAllText(Path, content);
        }

        public void Dispose()
        {
            try { if (File.Exists(Path)) File.Delete(Path); } catch { }
        }
    }
}
