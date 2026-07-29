// The widget window: glass shell, state-file reader, freshness, right-click menu,
// drag, hover-to-opaque, single instance (tickets 02/03/04; ADR 0005, 0006, 0007).
//
// Why Avalonia and not WPF (ADR 0008): real acrylic can only be clipped to a custom
// corner radius by whoever OWNS the backdrop visual. WPF has no Compositor on its
// HwndTarget, so it must ask DWM for a backdrop and inherits DWM's corner enum —
// which has no radius parameter. Avalonia's WinUIComposition backend owns the
// visual, so WinUICompositionBackdropCornerRadius gives us the locked 26px pill
// AND real blur together, which the WPF build could never have.

using System;
using System.Collections.Generic;
using System.Reflection;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Themes.Fluent;
using Avalonia.Threading;

namespace Oriel
{
    internal static class Program
    {
        // The locked visual spec's pill radius (ADR 0006). Must be handed to the
        // platform at AppBuilder time so the backdrop visual is clipped to match.
        public const float CornerRadius = 26f;

        private static SingleInstanceGate _singleInstance;

        [System.Runtime.InteropServices.DllImport("kernel32.dll")]
        private static extern bool AttachConsole(uint processId);

        /// `--startup on|off|status`. Exit codes are for scripts:
        /// 0 = the command did what you asked (for `status`, that means enabled),
        /// 1 = `status` and startup is off — a report, not a failure,
        /// 2 = you asked for a verb that does not exist,
        /// 3 = the registry would not take the change.
        private static int RunStartupCommand(string verb)
        {
            switch (verb)
            {
                case "on":
                case "off":
                    var want = verb == "on";
                    Startup.SetEnabled(want);
                    var got = Startup.IsEnabled();
                    Console.Out.WriteLine(Describe(got));
                    return got == want ? 0 : 3;

                case "status":
                    var enabled = Startup.IsEnabled();
                    Console.Out.WriteLine(Describe(enabled));
                    return enabled ? 0 : 1;

                default:
                    Console.Error.WriteLine($"unknown verb '{verb}' — expected: --startup on|off|status");
                    return 2;
            }
        }

        private static string Describe(bool enabled) =>
            enabled ? "enabled: " + Startup.TargetExe : "disabled";

        [STAThread]
        public static void Main(string[] args)
        {
            // `--startup on|off|status`: manage the Run-key registration without the
            // UI, so a stale entry can be repaired from a script (and so the build's
            // launch story is checkable end to end). Runs before the single-instance
            // gate — asking about startup while the widget is up must still answer.
            if (args.Length > 0 && args[0] == "--startup")
            {
                // The widget is a GUI-subsystem binary (no console window on launch —
                // that is the whole point), so borrow the calling shell's console just
                // for this one line rather than opening one.
                AttachConsole(unchecked((uint)-1));
                Environment.Exit(RunStartupCommand(args.Length > 1 ? args[1] : "status"));
                return;
            }

            // Single instance (ADR 0007): a second launch exits quietly rather than
            // stacking a duplicate pill on the desktop.
            _singleInstance = new SingleInstanceGate();
            if (!_singleInstance.IsOwner)
            {
                _singleInstance.Dispose();
                return;
            }

            try
            {
                AppBuilder.Configure<App>()
                    .UsePlatformDetect()
                    .With(new Win32PlatformOptions
                    {
                        CompositionMode = new[] { Win32CompositionMode.WinUIComposition },
                        WinUICompositionBackdropCornerRadius = CornerRadius,
                    })
                    .StartWithClassicDesktopLifetime(args);
            }
            finally
            {
                _singleInstance.Dispose();
            }
        }
    }

    internal sealed class App : Application
    {
        public override void Initialize() => Styles.Add(new FluentTheme());

        public override void OnFrameworkInitializationCompleted()
        {
            if (ApplicationLifetime is IClassicDesktopStyleApplicationLifetime desktop)
            {
                desktop.MainWindow = new WidgetWindow();
                desktop.ShutdownMode = ShutdownMode.OnMainWindowClose;
            }
            base.OnFrameworkInitializationCompleted();
        }
    }

    internal sealed class WidgetWindow : Window
    {
        private readonly Border _card;
        private readonly ContentControl _slot;
        private readonly LayoutTransformControl _scaler;
        /// The live config, and the one path a preference change takes to disk and back
        /// into the render (ticket 07). Read through _prefs.Config at every use rather
        /// than through a forwarding property still named for the field it replaced.
        private readonly PreferenceStore _prefs;
        private UsageRecord _lastRecord;
        private ShadowWindow _shadow;
        private readonly ResetNotifier _notifier = new();
        private bool _hovered;
        private bool _positionRestored;

        public WidgetWindow()
        {
            _prefs = new PreferenceStore(WidgetConfig.Read(Paths.ConfigFile), Paths.ConfigFile);
            _prefs.Changed += OnPreferencesChanged;

            SystemDecorations = SystemDecorations.None;
            Background = Brushes.Transparent;
            SizeToContent = SizeToContent.WidthAndHeight;
            CanResize = false;
            ShowInTaskbar = false;
            Topmost = true;
            Title = "Oriel";

            _slot = new ContentControl();

            // The blur comes from the WINDOW (TransparencyLevelHint -> the WinUI
            // composition host backdrop), which samples the live windows behind us.
            // The tint is then a plain semi-transparent brush painted ON TOP of it.
            //
            // Do NOT reach for ExperimentalAcrylicBorder here: its Digger material
            // samples the desktop wallpaper, not the windows behind, so it lays an
            // opaque sheet over the real blur and the glass goes dead.
            _card = new Border
            {
                CornerRadius = new CornerRadius(Program.CornerRadius),
                Padding = new Thickness(15, 15, 18, 15),
                BorderThickness = new Thickness(1),
                BorderBrush = Glass.Hairline(),
                Background = Glass.Tint(_prefs.Config.Tint),
                Child = _slot,
            };

            // The card must fill the window EXACTLY. The WinUI composition backdrop is
            // clipped to the window rect, so any margin left around the card fills with
            // a blurred, 26px-rounded halo instead of staying transparent (measured
            // during ticket 05). That is why the spec's drop shadow lives in its own
            // window — see ShadowWindow — rather than in a BoxShadow here.
            _scaler = new LayoutTransformControl { Child = _card };
            Content = _scaler;

            ApplyAppearance();
            UpdateContent();

            _card.ContextMenu = BuildMenu();

            // drag anywhere on the pill; position persists via PositionChanged
            PointerPressed += (_, e) =>
            {
                if (e.GetCurrentPoint(this).Properties.IsLeftButtonPressed) BeginMoveDrag(e);
            };
            PositionChanged += (_, _) =>
            {
                if (!_positionRestored) return;
                _prefs.Config.X = Position.X;
                _prefs.Config.Y = Position.Y;
                _prefs.Config.Write(Paths.ConfigFile);
                SyncShadow();
            };

            // hover snaps to full opacity when opacity is dialled down
            PointerEntered += (_, _) => { _hovered = true; Opacity = 1.0; SyncShadow(); };
            PointerExited += (_, _) => { _hovered = false; Opacity = _prefs.Config.Opacity / 100.0; SyncShadow(); };

            Opened += (_, _) =>
            {
                RestorePosition();

                // Shown after the pill exists so it can be parked directly beneath it.
                _shadow = new ShadowWindow();
                _shadow.Show();
                SyncShadow();
                // If startup is on but points at an old location (repo moved, or it
                // was enabled from a dev build), quietly re-point it at this exe.
                Startup.RepairIfStale();
                // What the compositor actually granted, now that there is a real window
                // to grant it — see WriteDiagnostics.
                WriteDiagnostics();
                CheckForUpdate();
            };

            // 1-second heartbeat: refresh data + keep the countdown live
            var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
            timer.Tick += (_, _) => UpdateContent();
            timer.Start();
            Closed += (_, _) =>
            {
                timer.Stop();
                // The shadow is a second top-level window; without this, Quit would
                // leave it floating on the desktop with nothing to cast it.
                try { _shadow?.Close(); } catch { }
            };
        }

        private void RestorePosition()
        {
            var screens = new List<(int, int, int, int)>();
            foreach (var s in Screens.All)
                screens.Add((s.Bounds.X, s.Bounds.Y, s.Bounds.Width, s.Bounds.Height));
            var repaired = _prefs.Config.RepairPosition(screens);

            if (_prefs.Config.X is int x && _prefs.Config.Y is int y) Position = new PixelPoint(x, y);
            _positionRestored = true;

            // PositionChanged is deliberately ignored until the restore is done, so a
            // repair would otherwise never reach the file. Write it here instead.
            if (repaired) _prefs.Config.Write(Paths.ConfigFile);
        }

        private void ApplyAppearance()
        {
            var scale = Preferences.Sizes.ValueOf(_prefs.Config.Size);
            _scaler.LayoutTransform = new ScaleTransform(scale, scale);
            _card.Background = Glass.Tint(_prefs.Config.Tint);
            // The blur is the WINDOW's backdrop, not the card's: the composition host
            // backdrop samples the live windows behind us, and the tint is a plain
            // semi-transparent brush painted on top of it. Reaching for an
            // ExperimentalAcrylicBorder here instead samples the desktop WALLPAPER, which
            // lays an opaque sheet over the real blur and kills the glass.
            //
            // Applied here rather than once in the constructor, so the preference is live:
            // the hint is a styled property, and setting it pushes the new chain at the
            // platform (ADR 0010).
            TransparencyLevelHint = Glass.Backdrop(_prefs.Config.Blur);
            if (!_hovered) Opacity = _prefs.Config.Opacity / 100.0;
            WriteDiagnostics();
        }

        /// CLAUDE_WIDGET_DIAG=<path> records what the compositor actually granted. Asking
        /// for AcrylicBlur is not the same as getting it, and that gap is exactly what
        /// shipped a blur-less widget for weeks (ADR 0008) — so this dumps the **blur** step
        /// chosen, the chain requested for it, and the level that came back. Appends, so
        /// switching the preference leaves a trail rather than only its last state.
        private void WriteDiagnostics()
        {
            var diag = Environment.GetEnvironmentVariable("CLAUDE_WIDGET_DIAG");
            if (string.IsNullOrEmpty(diag)) return;
            try
            {
                var requested = string.Join(",", Glass.Backdrop(_prefs.Config.Blur));
                System.IO.File.AppendAllText(diag, string.Join(Environment.NewLine, new[]
                {
                    $"blur={_prefs.Config.Blur}",
                    $"requested={requested}",
                    $"actual={ActualTransparencyLevel}",
                    $"opacity={Opacity}",
                    $"tint={_prefs.Config.Tint}",
                    $"background={Background}",
                    "",
                    "",
                }));
            }
            catch { }
        }

        private void UpdateContent()
        {
            var now = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
            var record = UsageRecord.TryRead(Paths.StateFile);
            if (record != null) _lastRecord = record;   // transient read race -> keep last good

            var view = WidgetView.Build(_lastRecord, _prefs.Config, now);
            _slot.Content = Skins.Build(_prefs.Config.Skin, view);

            foreach (var message in _notifier.Advance(view, _prefs.Config.ResetNotifications)) Toast(message);

            // The pill resizes with its contents (a countdown crossing the hour loses a
            // digit), so the shadow has to be re-fitted after every render.
            SyncShadow();
        }

        /// The spec's drop shadow is a companion window — it cannot live inside this
        /// one without turning the space around the pill into a blurred halo. See
        /// Shadow.cs.
        private void SyncShadow()
        {
            if (_shadow == null || !_positionRestored) return;
            var scale = Preferences.Sizes.ValueOf(_prefs.Config.Size);
            _shadow.SyncTo(this, Program.CornerRadius * scale, scale);
        }

        private void Toast(string text)
        {
            try
            {
                var toast = new Window
                {
                    SystemDecorations = SystemDecorations.None,
                    Background = Brushes.Transparent,
                    SizeToContent = SizeToContent.WidthAndHeight,
                    ShowInTaskbar = false,
                    Topmost = true,
                    CanResize = false,
                    Position = new PixelPoint(Position.X, Math.Max(0, Position.Y - 46)),
                    Content = new Border
                    {
                        CornerRadius = new CornerRadius(12),
                        Background = Glass.Tint(90),
                        Padding = new Thickness(12, 8, 12, 8),
                        Child = Ui.Mono(text, Ui.SecondaryHex, 12),
                    },
                };
                toast.Show();
                DispatcherTimer.RunOnce(() => { try { toast.Close(); } catch { } }, TimeSpan.FromSeconds(4));
            }
            catch { /* notifications are a stretch feature; never take the widget down */ }
        }

        // ---- update check (ticket 10) --------------------------------------

        /// Ask once, off the UI thread, and never block the window on the answer.
        ///
        /// A machine with no network must see nothing at all — no dialog, no delay, no
        /// error — so every failure inside Evaluate returns null and this does nothing.
        /// It downloads and replaces nothing: an update can never break a working
        /// install behind the user's back (ADR 0012).
        private void CheckForUpdate()
        {
            if (!_prefs.Config.CheckForUpdates) return;

            System.Threading.Tasks.Task.Run(() =>
            {
                var notice = UpdateCheck.Evaluate(AppVersion.Current, Releases.Fetch);
                if (notice == null) return;
                Dispatcher.UIThread.Post(() => ShowUpdateNotice(notice));
            });
        }

        /// Visible and dismissible, with a link. Deliberately not a modal: the widget's
        /// whole job is to sit there quietly, and a version check has not earned the
        /// right to interrupt anyone.
        private void ShowUpdateNotice(ReleaseNotice notice)
        {
            try
            {
                Window window = null;
                var text = new StackPanel { Spacing = 2 };
                text.Children.Add(Ui.Mono($"Oriel {notice.Version} is available", Ui.SecondaryHex, 12, bold: true));
                text.Children.Add(Ui.Mono("click to open · you are on " + AppVersion.Current, Ui.ElapsedHex, 10));

                window = new Window
                {
                    SystemDecorations = SystemDecorations.None,
                    Background = Brushes.Transparent,
                    SizeToContent = SizeToContent.WidthAndHeight,
                    ShowInTaskbar = false,
                    Topmost = true,
                    CanResize = false,
                    Title = "Oriel (update)",
                    Position = new PixelPoint(Position.X, Math.Max(0, Position.Y - 64)),
                    Content = new Border
                    {
                        CornerRadius = new CornerRadius(12),
                        Background = Glass.Tint(92),
                        Padding = new Thickness(12, 8, 12, 8),
                        Child = text,
                    },
                };

                window.PointerPressed += (_, e) =>
                {
                    if (e.GetCurrentPoint(window).Properties.IsLeftButtonPressed) OpenInBrowser(notice.Url);
                    try { window.Close(); } catch { }
                };
                window.Show();
            }
            catch { /* a version notice must never be able to take the widget down */ }
        }

        private static void OpenInBrowser(string url)
        {
            try
            {
                System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo
                {
                    FileName = url,
                    UseShellExecute = true,
                });
            }
            catch { }
        }

        // ---- right-click menu ----------------------------------------------

        /// Runs after the store has persisted a change: repaint, re-render, and
        /// rebuild the menu so the radio ticks reflect what was just chosen.
        private void OnPreferencesChanged()
        {
            ApplyAppearance();
            UpdateContent();
            _card.ContextMenu = BuildMenu();
        }

        /// The menu itself lives in Menu.cs so it can be built without a window
        /// (ticket 07). All this supplies is the two host actions that are not
        /// preferences: the registry-backed startup toggle, and quit.
        private ContextMenu BuildMenu()
            => WidgetMenu.Build(_prefs, new RegistryStartupToggle(), Close);
    }

    /// What this build calls itself. Read off the assembly rather than restated as a
    /// constant, so cutting a release means editing the version in exactly one place —
    /// the csproj — and the notice can never advertise a version the binary is not.
    internal static class AppVersion
    {
        public static string Current
        {
            get
            {
                try
                {
                    var asm = Assembly.GetEntryAssembly();
                    var info = asm?.GetCustomAttribute<AssemblyInformationalVersionAttribute>();
                    var raw = info?.InformationalVersion;
                    if (!string.IsNullOrWhiteSpace(raw))
                    {
                        // The SDK appends "+<commit sha>" when the repo is a git checkout.
                        var plus = raw.IndexOf('+');
                        return plus > 0 ? raw.Substring(0, plus) : raw;
                    }
                    var version = asm?.GetName().Version;
                    if (version != null) return version.ToString(3);
                }
                catch { }
                return "0.0.0";
            }
        }
    }

    /// The only network call in Oriel, and the only impure half of the update check.
    ///
    /// It sends nothing about the user: no token, no identifier, no telemetry — a
    /// public unauthenticated GET for one tag name. The guardrail this does NOT touch
    /// is the tee's, which is about Anthropic's API and credentials (ADR 0002 vs 0012).
    internal static class Releases
    {
        // Short, because this runs at startup and a slow or captive network must not be
        // something the user notices. Nothing is retried: there is always next launch.
        private static readonly TimeSpan Timeout = TimeSpan.FromSeconds(5);

        public static string Fetch()
        {
            using var http = new System.Net.Http.HttpClient { Timeout = Timeout };
            // The release API rejects requests without one.
            http.DefaultRequestHeaders.Add("User-Agent", "Oriel/" + AppVersion.Current);
            http.DefaultRequestHeaders.Add("Accept", "application/vnd.github+json");
            return http.GetStringAsync(UpdateCheck.LatestReleaseApi).GetAwaiter().GetResult();
        }
    }

    /// The real startup toggle: the per-user Run key. Behind an interface only so a
    /// test can build the menu without writing to the user's registry (ticket 07).
    [System.Runtime.Versioning.SupportedOSPlatform("windows")]
    internal sealed class RegistryStartupToggle : IStartupToggle
    {
        public bool IsEnabled => Startup.IsEnabled();
        public void SetEnabled(bool enabled) => Startup.SetEnabled(enabled);
    }

    /// Start-with-Windows via the per-user Run key — no admin, no scheduled task,
    /// off by default (ADR 0007).
    [System.Runtime.Versioning.SupportedOSPlatform("windows")]
    internal static class Startup
    {
        private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
        private const string ValueName = "Oriel";

        public const string PublishedExeName = "Oriel.exe";

        /// What we register. Normally just the running executable — but a developer
        /// build lives under `src/app/bin/...`, which is git-ignored and deleted by
        /// the next clean rebuild. Registering that path would give the user a
        /// startup entry that silently stops working (ticket 03), so a run from a
        /// dev output registers the published `dist` executable instead.
        ///
        /// If nothing has been published yet there is no better path to offer, so we
        /// fall back to the running one: a startup entry that works until the next
        /// clean rebuild beats one that points at a file that has never existed.
        public static string ResolveTargetExe(string processPath, Func<string, bool> fileExists)
        {
            if (string.IsNullOrEmpty(processPath)) return processPath;

            var dir = System.IO.Path.GetDirectoryName(processPath);
            if (string.IsNullOrEmpty(dir)) return processPath;

            var passedBin = false;
            for (var a = new System.IO.DirectoryInfo(dir); a != null; a = a.Parent)
            {
                if (string.Equals(a.Name, "bin", StringComparison.OrdinalIgnoreCase))
                {
                    passedBin = true;
                    continue;
                }
                if (!passedBin) continue;

                // Above the bin/ output: the first ancestor holding a published
                // dist/ is the repo root.
                var published = System.IO.Path.Combine(a.FullName, "dist", PublishedExeName);
                if (fileExists(published)) return published;
            }
            return processPath;
        }

        public static string TargetExe => ResolveTargetExe(Environment.ProcessPath, System.IO.File.Exists);

        private static string RegisteredValue()
        {
            try
            {
                using var k = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(RunKey);
                return k?.GetValue(ValueName) as string;
            }
            catch { return null; }
        }

        public static bool IsEnabled() => RegisteredValue() != null;

        public static void SetEnabled(bool enabled)
        {
            try
            {
                using var k = Microsoft.Win32.Registry.CurrentUser.CreateSubKey(RunKey, writable: true);
                if (k == null) return;
                if (enabled) k.SetValue(ValueName, Quote(TargetExe));
                else k.DeleteValue(ValueName, throwOnMissingValue: false);
            }
            catch { /* best-effort */ }
        }

        /// Rewrite a registration that points somewhere else — the repo moved, or it
        /// was first enabled from a dev build. Keeps "survives a rebuild" true even
        /// when the executable's home changes.
        public static void RepairIfStale()
        {
            var current = RegisteredValue();
            if (current == null) return;
            var want = Quote(TargetExe);
            if (!string.Equals(current, want, StringComparison.OrdinalIgnoreCase)) SetEnabled(true);
        }

        private static string Quote(string path) => "\"" + path + "\"";
    }
}
