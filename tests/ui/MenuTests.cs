// The right-click menu, and the path from clicking an item to config.json (ticket 07).
//
// This is the chain that had no automated cover at all: a menu click mutates the
// config, persists it, and rebuilds the menu so the ticks match. Every step was
// private to the window, so the only way to check any of it was to right-click the
// running widget and look.

using System;
using System.IO;
using System.Linq;
using Avalonia.Controls;
using Avalonia.Headless.XUnit;
using Avalonia.Interactivity;
using Xunit;

namespace Oriel.UiTests
{
    /// A startup toggle that records instead of touching the user's Run key.
    internal sealed class FakeStartupToggle : IStartupToggle
    {
        public bool IsEnabled { get; set; }
        public int SetCalls { get; private set; }

        public void SetEnabled(bool enabled)
        {
            IsEnabled = enabled;
            SetCalls++;
        }
    }

    /// A config path in a temp directory, cleaned up with the test.
    internal sealed class TempConfig : IDisposable
    {
        private readonly string _dir;
        public string Path { get; }

        public TempConfig()
        {
            _dir = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "oriel-ui-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(_dir);
            Path = System.IO.Path.Combine(_dir, "config.json");
        }

        public void Dispose()
        {
            try { Directory.Delete(_dir, recursive: true); } catch { }
        }
    }

    public class MenuTests
    {
        private static (PreferenceStore Prefs, FakeStartupToggle Startup, ContextMenu Menu) BuildMenu(
            TempConfig cfgFile, WidgetConfig config = null, Action close = null)
        {
            var prefs = new PreferenceStore(config ?? new WidgetConfig().Validated(), cfgFile.Path);
            var startup = new FakeStartupToggle();
            var menu = WidgetMenu.Build(prefs, startup, close ?? (() => { }));
            return (prefs, startup, menu);
        }

        private static MenuItem Item(ContextMenu menu, string header)
            => menu.Items.OfType<MenuItem>().Single(i => (string)i.Header == header);

        private static MenuItem Child(MenuItem parent, string header)
            => parent.Items.OfType<MenuItem>().Single(i => (string)i.Header == header);

        private static void Click(MenuItem item)
            => item.RaiseEvent(new RoutedEventArgs(MenuItem.ClickEvent));

        [AvaloniaFact]
        public void The_menu_has_every_expected_item()
        {
            using var cfg = new TempConfig();
            var (_, _, menu) = BuildMenu(cfg);

            var headers = menu.Items.OfType<MenuItem>().Select(i => (string)i.Header).ToArray();

            Assert.Equal(new[]
            {
                WidgetMenu.SkinHeader, WidgetMenu.SizeHeader, WidgetMenu.OpacityHeader,
                WidgetMenu.TintHeader, WidgetMenu.BlurHeader, WidgetMenu.AccentHeader,
                WidgetMenu.StartupHeader, WidgetMenu.NotificationsHeader, WidgetMenu.UpdateCheckHeader,
                WidgetMenu.QuitHeader,
            }, headers);
        }

        [AvaloniaFact]
        public void The_update_check_can_be_switched_off_and_the_setting_persists()
        {
            // It is the only thing in Oriel that reaches the network, so being able to
            // turn it off from the same menu as everything else is the point (ADR 0012).
            using var cfg = new TempConfig();
            var (_, _, menu) = BuildMenu(cfg);

            Assert.True(Item(menu, WidgetMenu.UpdateCheckHeader).IsChecked);

            Click(Item(menu, WidgetMenu.UpdateCheckHeader));

            Assert.False(WidgetConfig.Read(cfg.Path).CheckForUpdates);
        }

        [AvaloniaFact]
        public void The_skin_submenu_offers_exactly_the_four_skins()
        {
            using var cfg = new TempConfig();
            var (_, _, menu) = BuildMenu(cfg);

            var skins = Item(menu, WidgetMenu.SkinHeader).Items.OfType<MenuItem>().ToArray();

            Assert.Equal(4, skins.Length);
            Assert.Equal(WidgetConfig.ValidSkins.Length, skins.Length);
        }

        [AvaloniaFact]
        public void The_radio_ticks_reflect_the_current_config()
        {
            using var cfg = new TempConfig();
            var current = new WidgetConfig { Skin = "inline", Size = "large", Accent = "muted" }.Validated();
            var (_, _, menu) = BuildMenu(cfg, current);

            Assert.True(Child(Item(menu, WidgetMenu.SkinHeader), "Inline arcs").IsChecked);
            Assert.False(Child(Item(menu, WidgetMenu.SkinHeader), "Twin rings").IsChecked);
            Assert.True(Child(Item(menu, WidgetMenu.SizeHeader), "Large").IsChecked);
            Assert.True(Child(Item(menu, WidgetMenu.AccentHeader), "Muted").IsChecked);
        }

        [AvaloniaFact]
        public void Exactly_one_option_is_ticked_in_each_radio_submenu()
        {
            using var cfg = new TempConfig();
            var (_, _, menu) = BuildMenu(cfg);

            foreach (var header in new[]
            {
                WidgetMenu.SkinHeader, WidgetMenu.SizeHeader, WidgetMenu.OpacityHeader,
                WidgetMenu.TintHeader, WidgetMenu.BlurHeader, WidgetMenu.AccentHeader,
            })
            {
                var ticked = Item(menu, header).Items.OfType<MenuItem>().Count(i => i.IsChecked);
                Assert.True(ticked == 1, $"'{header}' had {ticked} ticked options, expected exactly 1");
            }
        }

        [AvaloniaFact]
        public void Choosing_a_skin_reaches_config_json_and_the_rendered_view()
        {
            // The whole chain the ticket asks for, end to end.
            using var cfg = new TempConfig();
            var (prefs, _, menu) = BuildMenu(cfg);
            Assert.Equal("twin", prefs.Config.Skin);

            Click(Child(Item(menu, WidgetMenu.SkinHeader), "Concentric gauge"));

            // ...through to the file on disk
            Assert.Equal("concentric", WidgetConfig.Read(cfg.Path).Skin);
            // ...and back into what gets rendered
            Assert.Equal("concentric", prefs.Config.Skin);
            Assert.NotNull(Skins.Build(prefs.Config.Skin, WidgetView.Build(null, prefs.Config, 0)));
        }

        [AvaloniaFact]
        public void A_rebuilt_menu_shows_the_new_choice_ticked()
        {
            // The window rebuilds the menu after every change; this is what that buys.
            using var cfg = new TempConfig();
            var (prefs, startup, menu) = BuildMenu(cfg);

            Click(Child(Item(menu, WidgetMenu.SkinHeader), "Sidecar ring"));
            var rebuilt = WidgetMenu.Build(prefs, startup, () => { });

            Assert.True(Child(Item(rebuilt, WidgetMenu.SkinHeader), "Sidecar ring").IsChecked);
            Assert.False(Child(Item(rebuilt, WidgetMenu.SkinHeader), "Twin rings").IsChecked);
        }

        [AvaloniaFact]
        public void Choosing_a_numeric_preference_persists_it()
        {
            using var cfg = new TempConfig();
            var (_, _, menu) = BuildMenu(cfg);

            Click(Child(Item(menu, WidgetMenu.OpacityHeader), "55%"));
            Click(Child(Item(menu, WidgetMenu.TintHeader), "Darker (90%)"));

            var saved = WidgetConfig.Read(cfg.Path);
            Assert.Equal(55, saved.Opacity);
            Assert.Equal(90, saved.Tint);
        }

        // The preference that was read, validated, clamped, persisted — and then consumed
        // by nothing, with no menu entry either (ticket 02). What makes it live is that the
        // chosen step reaches both the file and the backdrop the window asks for.
        [AvaloniaFact]
        public void Choosing_a_blur_step_reaches_config_json_and_the_backdrop()
        {
            using var cfg = new TempConfig();
            var (prefs, _, menu) = BuildMenu(cfg);
            Assert.Equal("full", prefs.Config.Blur);

            Click(Child(Item(menu, WidgetMenu.BlurHeader), "Off"));

            Assert.Equal("off", WidgetConfig.Read(cfg.Path).Blur);
            Assert.Equal("off", prefs.Config.Blur);
            Assert.NotEqual(Glass.Backdrop("full"), Glass.Backdrop(prefs.Config.Blur));
        }

        [AvaloniaFact]
        public void The_blur_submenu_offers_exactly_the_declared_steps()
        {
            using var cfg = new TempConfig();
            var (_, _, menu) = BuildMenu(cfg);

            var labels = Item(menu, WidgetMenu.BlurHeader).Items.OfType<MenuItem>()
                                                          .Select(i => (string)i.Header).ToArray();

            Assert.Equal(new[] { "Full (acrylic)", "Off" }, labels);
        }

        [AvaloniaFact]
        public void The_change_notification_fires_so_the_window_can_re_render()
        {
            using var cfg = new TempConfig();
            var (prefs, _, menu) = BuildMenu(cfg);
            var renders = 0;
            prefs.Changed += () => renders++;

            Click(Child(Item(menu, WidgetMenu.SkinHeader), "Inline arcs"));

            Assert.Equal(1, renders);
        }

        [AvaloniaFact]
        public void The_notification_fires_after_the_file_is_written()
        {
            // Ordering matters: the window's handler re-renders from the config, and a
            // handler that re-read the file must not see the previous value.
            using var cfg = new TempConfig();
            var (prefs, _, menu) = BuildMenu(cfg);
            string skinOnDiskWhenNotified = null;
            prefs.Changed += () => skinOnDiskWhenNotified = WidgetConfig.Read(cfg.Path).Skin;

            Click(Child(Item(menu, WidgetMenu.SkinHeader), "Inline arcs"));

            Assert.Equal("inline", skinOnDiskWhenNotified);
        }

        [AvaloniaFact]
        public void Reset_notifications_toggles_and_persists()
        {
            using var cfg = new TempConfig();
            var (_, _, menu) = BuildMenu(cfg);
            Assert.False(Item(menu, WidgetMenu.NotificationsHeader).IsChecked);

            Click(Item(menu, WidgetMenu.NotificationsHeader));

            Assert.True(WidgetConfig.Read(cfg.Path).ResetNotifications);
        }

        [AvaloniaFact]
        public void Start_with_windows_reflects_the_toggle_rather_than_the_config()
        {
            // The registry is the truth: something else may have changed it since the
            // config was written, so the tick must come from the toggle.
            using var cfg = new TempConfig();
            var prefs = new PreferenceStore(new WidgetConfig { StartWithWindows = false }.Validated(), cfg.Path);
            var startup = new FakeStartupToggle { IsEnabled = true };

            var menu = WidgetMenu.Build(prefs, startup, () => { });

            Assert.True(Item(menu, WidgetMenu.StartupHeader).IsChecked);
        }

        [AvaloniaFact]
        public void Clicking_start_with_windows_flips_both_the_registry_and_the_config()
        {
            using var cfg = new TempConfig();
            var (_, startup, menu) = BuildMenu(cfg);
            Assert.False(startup.IsEnabled);

            Click(Item(menu, WidgetMenu.StartupHeader));

            Assert.True(startup.IsEnabled);
            Assert.Equal(1, startup.SetCalls);
            Assert.True(WidgetConfig.Read(cfg.Path).StartWithWindows);
        }

        [AvaloniaFact]
        public void Quit_invokes_the_close_action()
        {
            using var cfg = new TempConfig();
            var closed = 0;
            var (_, _, menu) = BuildMenu(cfg, close: () => closed++);

            Click(Item(menu, WidgetMenu.QuitHeader));

            Assert.Equal(1, closed);
        }

        [AvaloniaFact]
        public void A_preference_write_that_fails_does_not_take_the_widget_down()
        {
            // Preferences are best-effort by design. A directory where the file should
            // be makes every write fail; the menu must still work.
            using var cfg = new TempConfig();
            Directory.CreateDirectory(cfg.Path);   // the config path is now a directory
            var (prefs, _, menu) = BuildMenu(cfg);

            var ex = Record.Exception(() => Click(Child(Item(menu, WidgetMenu.SkinHeader), "Inline arcs")));

            Assert.Null(ex);
            Assert.Equal("inline", prefs.Config.Skin);   // in-memory change still applied
        }
    }
}
