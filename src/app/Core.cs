// Pure widget logic. Ported 1:1 from the retired PowerShell widget's src/core/*.ps1,
// which ADR 0008 superseded and ticket 06 deleted — look in git history, not on disk.
//
// Deliberately free of any Avalonia reference so it stays unit-testable without a
// window, exactly as the PowerShell original was. The tee (src/tee/*.ps1) is
// unchanged and still owns normalization + writing current.json; this side only
// ever READS that file, which is what keeps the ToS-clean guarantee intact.

using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Threading;

namespace Oriel
{
    // ---- paths -------------------------------------------------------------

    public static class Paths
    {
        public static string Dir => Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".claude", "oriel");

        public static string StateFile => Path.Combine(Dir, "current.json");
        public static string ConfigFile => Path.Combine(Dir, "config.json");
    }

    // ---- the tee's record --------------------------------------------------

    public sealed class Window5
    {
        [JsonPropertyName("used_percentage")] public double UsedPercentage { get; set; }
        [JsonPropertyName("resets_at")] public long ResetsAt { get; set; }
    }

    public sealed class UsageRecord
    {
        [JsonPropertyName("five_hour")] public Window5 FiveHour { get; set; }
        [JsonPropertyName("seven_day")] public Window5 SevenDay { get; set; }
        [JsonPropertyName("written_at")] public long WrittenAt { get; set; }

        /// Defensive read: a missing, empty, partial or corrupt file yields null so
        /// the caller can keep the last good record rather than show fabricated zeros.
        public static UsageRecord TryRead(string path)
        {
            try
            {
                if (!File.Exists(path)) return null;
                var raw = File.ReadAllText(path);
                if (string.IsNullOrWhiteSpace(raw)) return null;
                var rec = JsonSerializer.Deserialize<UsageRecord>(raw);
                if (rec?.FiveHour == null || rec.SevenDay == null) return null;
                return rec;
            }
            catch { return null; }
        }
    }

    // ---- time formatting ----------------------------------------------------

    public static class TimeFormat
    {
        private static readonly string[] Dow = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };

        /// "2h13m" above an hour, "5m04s" below it.
        public static string Duration(long seconds)
        {
            if (seconds < 0) seconds = 0;
            var h = seconds / 3600;
            var m = (seconds % 3600) / 60;
            var s = seconds % 60;
            return h > 0
                ? string.Format(CultureInfo.InvariantCulture, "{0}h{1:d2}m", h, m)
                : string.Format(CultureInfo.InvariantCulture, "{0}m{1:d2}s", m, s);
        }

        /// 5-hour window: live countdown, "due" at/after the reset instant. Derived
        /// from absolute resets_at, so it is never stale (ADR 0004).
        public static string Countdown(long now, long resetsAt)
        {
            var remaining = resetsAt - now;
            return remaining <= 0 ? "due" : Duration(remaining);
        }

        /// 7-day window: absolute weekday+clock while > 24h out, else "in <countdown>".
        public static string Adaptive(long now, long resetsAt)
        {
            var remaining = resetsAt - now;
            if (remaining <= 0) return "due";
            if (remaining > 86400)
            {
                var local = DateTimeOffset.FromUnixTimeSeconds(resetsAt).ToLocalTime();
                return string.Format(CultureInfo.InvariantCulture, "{0} {1:HH\\:mm}", Dow[(int)local.DayOfWeek], local);
            }
            return "in " + Duration(remaining);
        }

        public static string Clock(long unix) =>
            DateTimeOffset.FromUnixTimeSeconds(unix).ToLocalTime().ToString("HH:mm", CultureInfo.InvariantCulture);

        public static string WeekdayClock(long unix)
        {
            var local = DateTimeOffset.FromUnixTimeSeconds(unix).ToLocalTime();
            return string.Format(CultureInfo.InvariantCulture, "{0} {1:HH\\:mm}", Dow[(int)local.DayOfWeek], local);
        }
    }

    // ---- interchangeable preferences ---------------------------------------

    /// One option of an interchangeable preference — one **skin**, one size, one accent.
    /// Carries the id persisted in config.json and the label the right-click menu shows,
    /// so the two can no longer be declared apart and drift (ticket 01).
    public class PreferenceOption
    {
        public PreferenceOption(string id, string label)
        {
            Id = id;
            Label = label;
        }

        public string Id { get; }
        public string Label { get; }
    }

    /// ...and whatever the render path needs from it: a size's layout scale, an accent's
    /// severity palette.
    public sealed class PreferenceOption<T> : PreferenceOption
    {
        public PreferenceOption(string id, string label, T value) : base(id, label) => Value = value;

        public T Value { get; }
    }

    /// A complete set of interchangeable options, declared once. Validation rejects
    /// against `Ids`, the menu enumerates it for its labels, and the render path asks it
    /// for values — so adding an option is one edit and the three cannot disagree.
    public class PreferenceOptions : IReadOnlyList<PreferenceOption>
    {
        private readonly PreferenceOption[] _options;
        private readonly string[] _ids;

        /// The FIRST option is the default: what a fresh config starts on and what
        /// validation falls back to.
        public PreferenceOptions(params PreferenceOption[] options)
        {
            if (options == null || options.Length == 0)
                throw new ArgumentException("a preference needs at least one option", nameof(options));

            _options = options;
            var ids = Array.ConvertAll(options, o => o.Id);
            if (new HashSet<string>(ids, StringComparer.Ordinal).Count != ids.Length)
                throw new ArgumentException("two options share an id", nameof(options));

            _ids = ids;
            DefaultId = ids[0];
        }

        /// A fresh copy each time: validation reads the set on every load, so handing out
        /// the array it reads would let a caller reorder or blank the valid ids.
        public string[] Ids => (string[])_ids.Clone();

        public string DefaultId { get; }

        public bool Contains(string id) => id != null && Array.IndexOf(_ids, id) >= 0;

        /// The validation step: a recognised id survives, anything else — unknown, null,
        /// hand-edited, hostile — becomes the default.
        public string Pick(string id) => Contains(id) ? id : DefaultId;

        public int Count => _options.Length;
        public PreferenceOption this[int index] => _options[index];
        public IEnumerator<PreferenceOption> GetEnumerator() => ((IEnumerable<PreferenceOption>)_options).GetEnumerator();
        IEnumerator IEnumerable.GetEnumerator() => GetEnumerator();
    }

    public sealed class PreferenceOptions<T> : PreferenceOptions
    {
        private readonly PreferenceOption<T>[] _typed;

        public PreferenceOptions(params PreferenceOption<T>[] options) : base(options) => _typed = options;

        /// What the render path needs, for ANY id. An id the set does not know yields the
        /// default's value rather than throwing: this runs while painting the window, in
        /// front of the user, so it falls back the way skin building already does.
        public T ValueOf(string id)
        {
            foreach (var o in _typed)
                if (string.Equals(o.Id, id, StringComparison.Ordinal)) return o.Value;
            return _typed[0].Value;
        }
    }

    /// The render-path half of a preference whose value cannot be declared with its id —
    /// the **skin** builders and the **blur** backdrops, both of which are Avalonia and so
    /// cannot live in this file (ADR 0008). Keyed by the same ids, with the same two
    /// properties the declaration has: a lookup that falls back rather than throwing, and
    /// the id set, so a test can hold the two halves against each other.
    ///
    /// It exists because there are two of them and they were the same ten lines twice.
    public sealed class RenderMap<T>
    {
        private readonly Dictionary<string, T> _byId;
        private readonly T _fallback;

        /// `fallback` is passed rather than looked up by default id, so the map cannot
        /// throw even if the default itself is missing an entry.
        public RenderMap(T fallback, params (string Id, T Value)[] entries)
        {
            _fallback = fallback;
            _byId = new Dictionary<string, T>(StringComparer.Ordinal);
            foreach (var (id, value) in entries) _byId.Add(id, value);
        }

        /// Every id that can actually be rendered — what the agreement test compares
        /// against the declared ids.
        public IReadOnlyCollection<string> Ids => _byId.Keys;

        /// The last line before the user sees it: an id with no entry falls back rather
        /// than throwing (ticket 01).
        public T For(string id) => id != null && _byId.TryGetValue(id, out var value) ? value : _fallback;
    }

    /// The three green/amber/red hexes one accent offers, keyed by severity band.
    public sealed class SeverityPalette
    {
        public SeverityPalette(string green, string amber, string red)
        {
            Green = green;
            Amber = amber;
            Red = red;
        }

        public string Green { get; }
        public string Amber { get; }
        public string Red { get; }

        public string For(string band) => band switch
        {
            "red" => Red,
            "amber" => Amber,
            _ => Green,
        };
    }

    /// **The** declaration of every interchangeable preference (ticket 01). One entry per
    /// option, in menu order, carrying its id, its label and its render-path value.
    ///
    /// Skin is the one set whose render-path entry is not here, and cannot be: building a
    /// skin is Avalonia work and this file is deliberately Avalonia-free so the logic
    /// layer stays testable with no window (ADR 0008). The builders therefore live beside
    /// the skins themselves in Skins.cs, keyed by these same ids, and SkinTests asserts
    /// the two sets match exactly in both directions — a valid id with no builder, or a
    /// builder no menu entry can reach, fails the suite.
    public static class Preferences
    {
        public static readonly PreferenceOptions Skins = new(
            new PreferenceOption("twin", "Twin rings"),
            new PreferenceOption("sidecar", "Sidecar ring"),
            new PreferenceOption("inline", "Inline arcs"),
            new PreferenceOption("concentric", "Concentric gauge"));

        /// Value: the layout scale the window applies to the whole card.
        public static readonly PreferenceOptions<double> Sizes = new(
            new PreferenceOption<double>("small", "Small", 0.85),
            new PreferenceOption<double>("medium", "Medium", 1.0),
            new PreferenceOption<double>("large", "Large", 1.25));

        /// **Blur** — whether the glass blurs the windows behind it (CONTEXT.md).
        ///
        /// A named step rather than a radius, because the platform takes a level and not a
        /// number: there is no supported way to ask for "30". Two steps rather than three,
        /// because a middle one was measured asking for a blur the compositor will not grant
        /// (ADR 0010). The render-path entry — the transparency levels the window asks for,
        /// in fallback order — lives in Glass.cs, for the same reason the skin builders do.
        public static readonly PreferenceOptions Blurs = new(
            new PreferenceOption("full", "Full (acrylic)"),
            new PreferenceOption("off", "Off"));

        /// Value: the severity palette (CONTEXT.md **severity colour**), pastel by default.
        public static readonly PreferenceOptions<SeverityPalette> Accents = new(
            new PreferenceOption<SeverityPalette>("pastel", "Pastel",
                new SeverityPalette("#a6e3a1", "#f9e2af", "#f38ba8")),
            new PreferenceOption<SeverityPalette>("vivid", "Vivid",
                new SeverityPalette("#34d399", "#fbbf24", "#f87171")),
            new PreferenceOption<SeverityPalette>("muted", "Muted",
                new SeverityPalette("#8fb89a", "#cbb98a", "#c99098")));
    }

    // ---- severity -----------------------------------------------------------

    public static class Severity
    {
        // Bands: green < 50, amber < 80, red >= 80 (CONTEXT.md). Red = heavy use.
        public static string Band(double pct) => pct < 50 ? "green" : pct < 80 ? "amber" : "red";

        /// The single neutral grey the percentages drain to when stale — the ONLY
        /// staleness signal (ADR 0004).
        public const string StaleHex = "#585b70";

        public static string Hex(double pct, bool isStale, string accent)
            => isStale ? StaleHex : Preferences.Accents.ValueOf(accent).For(Band(pct));
    }

    // ---- freshness + pace ---------------------------------------------------

    public static class Freshness
    {
        public const int DefaultThresholdSeconds = 180;

        public static bool IsStale(long now, long writtenAt, int thresholdSeconds = DefaultThresholdSeconds)
            => (now - writtenAt) > thresholdSeconds;
    }

    public static class Pace
    {
        public const long FiveHourSeconds = 5 * 3600;
        public const long SevenDaySeconds = 7 * 86400;

        /// We only know resets_at, not the window start, so elapsed is inferred as
        /// window - remaining and clamped; a just-reset window clamps to 0.
        public static double ElapsedFraction(long now, long resetsAt, long windowSeconds)
        {
            if (windowSeconds <= 0) return 0.0;
            var remaining = resetsAt - now;
            var fraction = (double)(windowSeconds - remaining) / windowSeconds;
            if (fraction < 0) return 0.0;
            if (fraction > 1) return 1.0;
            return fraction;
        }

        /// Burning ahead of the clock. Epsilon keeps "exactly on pace" from reading as over.
        public static bool IsOverPace(double usedPercentage, double elapsedFraction, double epsilon = 0.001)
            => (usedPercentage / 100.0) > (elapsedFraction + epsilon);
    }

    // ---- view model ---------------------------------------------------------

    public sealed class WindowView
    {
        public double Pct;
        public string ColorHex;
        public string ResetText;       // countdown (5h) or adaptive (7d)
        public string ResetClockText;  // absolute, for the dual-reset tooltip
        public double ElapsedFraction;
        public bool OverPace;
        /// The window has reached its reset instant. A fact about the clock, not about
        /// the wording — so reset notifications key off this rather than sniffing
        /// ResetText for "due", which would fail silently if the copy ever changed.
        public bool IsDue;
    }

    public sealed class WidgetView
    {
        public bool HasData;
        public bool IsStale;
        public WindowView Five;
        public WindowView Seven;

        public static WidgetView Build(UsageRecord record, WidgetConfig cfg, long now,
                                       int thresholdSeconds = Freshness.DefaultThresholdSeconds)
        {
            // First run / no tee yet: explicit empty state, never fabricated zeros.
            if (record == null) return new WidgetView { HasData = false, IsStale = false };

            var isStale = Freshness.IsStale(now, record.WrittenAt, thresholdSeconds);
            var accent = cfg.Accent;

            var fivePct = record.FiveHour.UsedPercentage;
            var sevenPct = record.SevenDay.UsedPercentage;
            var fiveReset = record.FiveHour.ResetsAt;
            var sevenReset = record.SevenDay.ResetsAt;
            var sevenElapsed = Pace.ElapsedFraction(now, sevenReset, Pace.SevenDaySeconds);

            return new WidgetView
            {
                HasData = true,
                IsStale = isStale,
                Five = new WindowView
                {
                    Pct = fivePct,
                    ColorHex = Severity.Hex(fivePct, isStale, accent),
                    ResetText = TimeFormat.Countdown(now, fiveReset),
                    ResetClockText = TimeFormat.Clock(fiveReset),
                    ElapsedFraction = Pace.ElapsedFraction(now, fiveReset, Pace.FiveHourSeconds),
                    OverPace = false,
                    IsDue = fiveReset <= now,
                },
                Seven = new WindowView
                {
                    Pct = sevenPct,
                    ColorHex = Severity.Hex(sevenPct, isStale, accent),
                    ResetText = TimeFormat.Adaptive(now, sevenReset),
                    ResetClockText = TimeFormat.WeekdayClock(sevenReset),
                    ElapsedFraction = sevenElapsed,
                    OverPace = !isStale && Pace.IsOverPace(sevenPct, sevenElapsed),
                    IsDue = sevenReset <= now,
                },
            };
        }
    }

    // ---- single instance ----------------------------------------------------

    /// One widget per desktop session (ADR 0007): a second launch exits quietly
    /// rather than stacking a duplicate pill on the desktop.
    ///
    /// A named mutex rather than a process scan, because the check has to be atomic —
    /// two launches racing (a double-click, or startup plus a manual run) would both
    /// see "no widget yet" and both open.
    public sealed class SingleInstanceGate : IDisposable
    {
        /// `Local\` scopes the gate to the logon session, so two users signed into the
        /// same machine each get their own widget.
        public const string WidgetGateName = @"Local\Oriel_SingleInstance_v1";

        private readonly Mutex _mutex;

        /// True if this process is the one that may open a window.
        public bool IsOwner { get; }

        public SingleInstanceGate(string name = WidgetGateName)
        {
            _mutex = new Mutex(true, name, out var createdNew);
            IsOwner = createdNew;
        }

        public void Dispose()
        {
            // Only the owner may release: a turned-away launch calling ReleaseMutex
            // would throw, and worse, must never open the gate on the widget that IS
            // running.
            if (IsOwner)
            {
                try { _mutex.ReleaseMutex(); } catch { }
            }
            _mutex.Dispose();
        }
    }

    // ---- reset notifications -----------------------------------------------

    /// Decides WHEN a reset is worth announcing. Edge-triggered, not state-triggered:
    /// a window reads "due" from the moment it expires until the tee writes a fresh
    /// one, and on a 1-second heartbeat that is hundreds of ticks. Announcing the
    /// state would bury the desktop in toasts; only the crossing is news.
    ///
    /// Kept out of the window class on purpose — this is the one notification rule
    /// that a screenshot can never check.
    public sealed class ResetNotifier
    {
        private static readonly string[] Nothing = Array.Empty<string>();

        private bool _fiveDue, _sevenDue;
        private bool _primed;

        /// Feed each rendered view in; get back the announcements this tick earned.
        ///
        /// The due-flags are tracked even while `enabled` is false, so switching the
        /// preference on cannot replay a reset the user already lived through.
        public IReadOnlyList<string> Advance(WidgetView view, bool enabled)
        {
            // No data yet means no windows to have reset — but it is a gap in the
            // record, not a recovery, so remember nothing and forget nothing either.
            if (view == null || !view.HasData) return Nothing;

            var fiveDue = view.Five?.IsDue == true;
            var sevenDue = view.Seven?.IsDue == true;

            List<string> fired = null;
            // The first reading establishes where things stand. Launching the widget
            // into an already-expired window is not a reset the user just missed.
            if (enabled && _primed)
            {
                if (fiveDue && !_fiveDue) (fired ??= new List<string>()).Add("5-hour limit reset");
                if (sevenDue && !_sevenDue) (fired ??= new List<string>()).Add("7-day limit reset");
            }

            _fiveDue = fiveDue;
            _sevenDue = sevenDue;
            _primed = true;
            return (IReadOnlyList<string>)fired ?? Nothing;
        }
    }

    // ---- update check -------------------------------------------------------

    /// What the widget says when a newer release exists. Null everywhere else.
    public sealed class ReleaseNotice
    {
        public ReleaseNotice(string version, string url)
        {
            Version = version;
            Url = url;
        }

        public string Version { get; }
        public string Url { get; }
    }

    /// "Is there a newer Oriel?" — asked once at startup, answered without downloading
    /// or replacing anything (ADR 0012).
    ///
    /// **On the never-reach-the-network guardrail.** The tee carries an explicit ban on
    /// network calls (ADR 0002), and this is the first code in the project to break the
    /// silence, so it is worth saying out loud which guardrail is which. The one that
    /// must not weaken is about *Anthropic's API*: Oriel reads only what Claude Code
    /// pushes to the statusline and touches no credentials, which is what keeps it
    /// ToS-clean. Asking a release host whether a tag exists is a different act
    /// entirely — it sends nothing, carries no token, and reads nothing about the user.
    /// It is nonetheless announced at install time and switchable, because a network
    /// call nobody mentioned is a surprise regardless of how harmless it is.
    ///
    /// The comparison and the decision to surface or stay quiet are pure and live here;
    /// the fetch is injected, so the tests involve no network at all.
    public static class UpdateCheck
    {
        public const string LatestReleaseApi = "https://api.github.com/repos/bolduck91/oriel/releases/latest";
        public const string ReleasesPage = "https://github.com/bolduck91/oriel/releases/latest";

        /// Tolerant of the `v` prefix a git tag usually carries, and of a two- or
        /// four-part version. Returns null for anything it cannot read as a version,
        /// which is the same as "no news": a release named something unexpected must
        /// never be announced as an upgrade.
        public static Version ParseVersion(string raw)
        {
            if (string.IsNullOrWhiteSpace(raw)) return null;
            var text = raw.Trim();
            if (text.StartsWith("v", StringComparison.OrdinalIgnoreCase)) text = text.Substring(1);
            // A pre-release suffix is not a version component; drop it rather than fail.
            var dash = text.IndexOf('-');
            if (dash > 0) text = text.Substring(0, dash);
            return Version.TryParse(text, out var parsed) ? parsed : null;
        }

        /// Strictly newer. Equal is not news, and older is certainly not — a user who
        /// has built ahead of the last release must not be told to downgrade.
        public static bool IsNewer(string current, string candidate)
        {
            var now = ParseVersion(current);
            var next = ParseVersion(candidate);
            if (now == null || next == null) return false;
            return next > now;
        }

        /// The whole decision, with the network behind `fetch`.
        ///
        /// `fetch` returns the release host's raw response, or null/throws when there is
        /// no network. Every failure path returns null, because a machine with no
        /// network must see nothing at all rather than an error it did not ask for.
        public static ReleaseNotice Evaluate(string currentVersion, Func<string> fetch)
        {
            if (fetch == null) return null;
            try
            {
                var body = fetch();
                if (string.IsNullOrWhiteSpace(body)) return null;

                using var doc = JsonDocument.Parse(body);
                if (doc.RootElement.ValueKind != JsonValueKind.Object) return null;

                var tag = doc.RootElement.TryGetProperty("tag_name", out var t) ? t.GetString() : null;
                if (!IsNewer(currentVersion, tag)) return null;

                var url = doc.RootElement.TryGetProperty("html_url", out var u) ? u.GetString() : null;
                if (string.IsNullOrWhiteSpace(url)) url = ReleasesPage;

                return new ReleaseNotice(tag.Trim(), url);
            }
            catch { return null; }   // no network, malformed body, anything: stay quiet
        }
    }

    // ---- config -------------------------------------------------------------

    /// Reads `blur` from a config file written before it became a named step (ADR 0010),
    /// where it was a number in 0–60 that nothing consumed.
    ///
    /// This is not politeness. `WidgetConfig.Read` wraps the whole deserialize in a catch
    /// that falls back to defaults, so a number landing on a string property would quietly
    /// reset the user's skin, size, opacity, tint, accent and window position as well —
    /// one inert key taking every live one down with it. Anything that is not a string is
    /// consumed and discarded, leaving validation to supply the default.
    ///
    /// The discarded number is not translated into a step, because it never reached the
    /// screen: there is no visual the user chose and no intent to preserve.
    internal sealed class LegacyBlurConverter : JsonConverter<string>
    {
        public override string Read(ref Utf8JsonReader reader, Type type, JsonSerializerOptions options)
        {
            if (reader.TokenType == JsonTokenType.String) return reader.GetString();
            // A container has to be walked to its end token, or the rest of the object is
            // read as though its keys belonged to the blur value.
            if (reader.TokenType is JsonTokenType.StartObject or JsonTokenType.StartArray) reader.Skip();
            return null;
        }

        public override void Write(Utf8JsonWriter writer, string value, JsonSerializerOptions options)
            => writer.WriteStringValue(value);
    }

    public sealed class WidgetConfig
    {
        // The defaults come off the same declaration validation falls back to, so
        // "what a fresh config starts on" cannot drift from "what a bad value becomes".
        [JsonPropertyName("skin")] public string Skin { get; set; } = Preferences.Skins.DefaultId;
        [JsonPropertyName("size")] public string Size { get; set; } = Preferences.Sizes.DefaultId;
        [JsonPropertyName("opacity")] public int Opacity { get; set; } = 100;
        [JsonPropertyName("tint")] public int Tint { get; set; } = 75;
        // Real blur at last: Avalonia owns the backdrop visual, so this is finally a live
        // value rather than the inert setting it was under WPF (ADR 0008). A named step
        // rather than the radius it used to pretend to be — the platform takes a level, not
        // a number (ADR 0010) — read tolerantly so a pre-ADR-0010 file still loads.
        [JsonPropertyName("blur")]
        [JsonConverter(typeof(LegacyBlurConverter))]
        public string Blur { get; set; } = Preferences.Blurs.DefaultId;
        [JsonPropertyName("accent")] public string Accent { get; set; } = Preferences.Accents.DefaultId;
        [JsonPropertyName("startWithWindows")] public bool StartWithWindows { get; set; }
        [JsonPropertyName("resetNotifications")] public bool ResetNotifications { get; set; }
        // On by default, and announced during install — a user who wants to run
        // something that talks to nothing turns it off here (ADR 0012). Default-true on
        // a bool means the JSON name has to be absent-tolerant, which it is: a config
        // written before this existed loads as true, which is the announced behaviour.
        [JsonPropertyName("checkForUpdates")] public bool CheckForUpdates { get; set; } = true;
        [JsonPropertyName("x")] public int? X { get; set; }
        [JsonPropertyName("y")] public int? Y { get; set; }

        // Derived from the single declaration in Preferences, so a set can no longer
        // gain an option that validation rejects — or reject one the menu offers.
        /// The **tint** band, named because the brush that paints it clamps to the same
        /// bounds — a card that was fully clear or fully opaque would stop being glass, and
        /// the two clamps live in different files.
        public const int MinTint = 50;
        public const int MaxTint = 97;

        // Properties rather than fields, so each caller gets its own copy: caching one
        // clone in a public mutable static would hand every caller the SAME array and
        // undo the very protection Ids exists for.
        public static string[] ValidSkins => Preferences.Skins.Ids;
        public static string[] ValidSizes => Preferences.Sizes.Ids;
        public static string[] ValidAccents => Preferences.Accents.Ids;
        public static string[] ValidBlurs => Preferences.Blurs.Ids;

        private static int Clamp(int v, int min, int max) => v < min ? min : v > max ? max : v;

        /// Validate every field so the rest of the widget can trust the result —
        /// a partial or hostile file can never produce an invalid config.
        public WidgetConfig Validated() => new()
        {
            Skin = Preferences.Skins.Pick(Skin),
            Size = Preferences.Sizes.Pick(Size),
            Accent = Preferences.Accents.Pick(Accent),
            Blur = Preferences.Blurs.Pick(Blur),
            Opacity = Clamp(Opacity, 40, 100),
            Tint = Clamp(Tint, MinTint, MaxTint),
            StartWithWindows = StartWithWindows,
            ResetNotifications = ResetNotifications,
            CheckForUpdates = CheckForUpdates,
            X = X,
            Y = Y,
        };

        public static WidgetConfig Read(string path)
        {
            try
            {
                if (!File.Exists(path)) return new WidgetConfig().Validated();
                var raw = File.ReadAllText(path);
                var cfg = JsonSerializer.Deserialize<WidgetConfig>(raw);
                return (cfg ?? new WidgetConfig()).Validated();
            }
            catch { return new WidgetConfig().Validated(); }   // corrupt -> defaults
        }

        private static readonly JsonSerializerOptions WriteOpts = new() { WriteIndented = true };

        /// Atomic write (temp + replace) so a crash mid-write can never leave a
        /// half-written config — same contract as src/tee/AtomicWrite.ps1.
        public void Write(string path)
        {
            var tmp = path + ".tmp";
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(path));
                File.WriteAllText(tmp, JsonSerializer.Serialize(this, WriteOpts));
                File.Move(tmp, path, overwrite: true);
            }
            catch { /* preferences are best-effort; never take the widget down */ }
            finally
            {
                // The move is what removes the temp, so any failure after the write
                // strands it. The catch above makes that silent, which is why the
                // cleanup has to live here rather than in it (ticket 09). After a
                // successful move there is nothing left to delete.
                try { if (File.Exists(tmp)) File.Delete(tmp); } catch { }
            }
        }

        /// If the remembered position lands on no current screen (monitor unplugged),
        /// clamp back onto the primary so the widget can never open off-screen (ADR 0005).
        ///
        /// Returns true when it moved the widget, so the caller can persist the repair
        /// rather than leaving dead coordinates in the file to be fixed up on every
        /// launch for ever.
        public bool RepairPosition(IReadOnlyList<(int X, int Y, int W, int H)> screens)
        {
            if (X == null || Y == null || screens == null || screens.Count == 0) return false;
            foreach (var s in screens)
                if (X >= s.X && X < s.X + s.W && Y >= s.Y && Y < s.Y + s.H) return false;
            X = screens[0].X + 40;
            Y = screens[0].Y + 40;
            return true;
        }
    }

    /// The preference-change step, lifted out of the window (ticket 07).
    ///
    /// Every preference the menu offers follows the same path: mutate the config,
    /// persist it, then let the window re-render and rebuild its menu so the radio
    /// ticks match what was just chosen. That path is logic, not rendering, and it
    /// was previously a private method on the window — which meant the only way to
    /// check that a menu click actually reached config.json was to look.
    ///
    /// Deliberately free of Avalonia, so it can be tested with no display at all.
    public sealed class PreferenceStore
    {
        private readonly string _path;

        public PreferenceStore(WidgetConfig config, string path)
        {
            Config = config ?? new WidgetConfig().Validated();
            _path = path;
        }

        public WidgetConfig Config { get; }

        /// Raised after the change has been persisted, so a handler that re-reads
        /// the file sees the new value rather than the old one.
        public event Action Changed;

        public void Apply(Action<WidgetConfig> mutate)
        {
            if (mutate == null) return;
            mutate(Config);
            Config.Write(_path);
            Changed?.Invoke();
        }
    }
}
