// The right-click menu, lifted out of the window (ticket 07).
//
// It used to be a private method on WidgetWindow, which made it untestable for a
// blunt reason: constructing that window needs a display, a composition backdrop
// and Win32 window styles. The menu itself needs none of those — it needs the
// current preferences, somewhere to send a change, and the two host actions
// (start-with-Windows, quit) that are not preferences at all.
//
// So those are the only things it takes. Everything the menu shows is then a pure
// function of the config, which is what makes the radio ticks checkable.

using System;
using System.Collections.Generic;
using Avalonia.Controls;

namespace Oriel
{
    /// Start-with-Windows is a registry write, so it is behind an interface: a test
    /// must be able to build this menu without touching the user's Run key.
    public interface IStartupToggle
    {
        bool IsEnabled { get; }
        void SetEnabled(bool enabled);
    }

    public static class WidgetMenu
    {
        public const string SkinHeader = "Skin";
        public const string SizeHeader = "Size";
        public const string OpacityHeader = "Opacity";
        public const string TintHeader = "Tint";
        public const string BlurHeader = "Blur";
        public const string AccentHeader = "Accent";
        public const string StartupHeader = "Start with Windows";
        public const string NotificationsHeader = "Reset notifications";
        public const string UpdateCheckHeader = "Check for updates";
        public const string QuitHeader = "Quit";

        /// The interchangeable preferences — **skin**, size, accent — read their options
        /// off the single declaration in Preferences (ticket 01), so the labels and the
        /// order live with the ids rather than being restated here.
        private static MenuItem RadioSubmenu(PreferenceStore prefs, string header,
                                             PreferenceOptions options,
                                             Func<WidgetConfig, string> get, Action<WidgetConfig, string> set)
        {
            var pairs = new (string Label, string Value)[options.Count];
            for (var i = 0; i < options.Count; i++) pairs[i] = (options[i].Label, options[i].Id);
            return RadioSubmenu(prefs, header, pairs, get, set);
        }

        private static MenuItem RadioSubmenu<T>(PreferenceStore prefs, string header,
                                                (string Label, T Value)[] options,
                                                Func<WidgetConfig, T> get, Action<WidgetConfig, T> set)
        {
            var mi = new MenuItem { Header = header };
            var current = get(prefs.Config);
            foreach (var (label, value) in options)
            {
                var child = new MenuItem
                {
                    Header = label,
                    ToggleType = MenuItemToggleType.Radio,
                    IsChecked = EqualityComparer<T>.Default.Equals(value, current),
                };
                var captured = value;
                child.Click += (_, _) => prefs.Apply(c => set(c, captured));
                mi.Items.Add(child);
            }
            return mi;
        }

        public static ContextMenu Build(PreferenceStore prefs, IStartupToggle startup, Action close)
        {
            var menu = new ContextMenu();

            menu.Items.Add(RadioSubmenu(prefs, SkinHeader, Preferences.Skins,
                c => c.Skin, (c, v) => c.Skin = v));

            menu.Items.Add(RadioSubmenu(prefs, SizeHeader, Preferences.Sizes,
                c => c.Size, (c, v) => c.Size = v));

            menu.Items.Add(RadioSubmenu(prefs, OpacityHeader, new[]
            {
                ("100%", 100), ("85%", 85), ("70%", 70), ("55%", 55), ("40%", 40),
            }, c => c.Opacity, (c, v) => c.Opacity = v));

            menu.Items.Add(RadioSubmenu(prefs, TintHeader, new[]
            {
                ("Lighter (60%)", 60), ("Default (75%)", 75), ("Darker (90%)", 90),
            }, c => c.Tint, (c, v) => c.Tint = v));

            // Next to tint, because the two are neighbouring levers on the same glass:
            // blur is what is behind it, tint is the ground laid over that (ticket 02).
            menu.Items.Add(RadioSubmenu(prefs, BlurHeader, Preferences.Blurs,
                c => c.Blur, (c, v) => c.Blur = v));

            menu.Items.Add(RadioSubmenu(prefs, AccentHeader, Preferences.Accents,
                c => c.Accent, (c, v) => c.Accent = v));

            menu.Items.Add(new Separator());

            var startItem = new MenuItem
            {
                Header = StartupHeader,
                ToggleType = MenuItemToggleType.CheckBox,
                IsChecked = startup.IsEnabled,
            };
            startItem.Click += (_, _) =>
            {
                // Read through the toggle rather than trusting the tick: the registry
                // is the truth, and something else may have changed it.
                var enable = !startup.IsEnabled;
                startup.SetEnabled(enable);
                prefs.Apply(c => c.StartWithWindows = enable);
            };
            menu.Items.Add(startItem);

            var notifyItem = new MenuItem
            {
                Header = NotificationsHeader,
                ToggleType = MenuItemToggleType.CheckBox,
                IsChecked = prefs.Config.ResetNotifications,
            };
            notifyItem.Click += (_, _) => prefs.Apply(c => c.ResetNotifications = !c.ResetNotifications);
            menu.Items.Add(notifyItem);

            // Beside the other switches rather than buried somewhere "advanced": it is
            // the only thing here that reaches the network, so it should be as easy to
            // turn off as anything else is to turn on (ADR 0012).
            var updateItem = new MenuItem
            {
                Header = UpdateCheckHeader,
                ToggleType = MenuItemToggleType.CheckBox,
                IsChecked = prefs.Config.CheckForUpdates,
            };
            updateItem.Click += (_, _) => prefs.Apply(c => c.CheckForUpdates = !c.CheckForUpdates);
            menu.Items.Add(updateItem);

            menu.Items.Add(new Separator());

            var quit = new MenuItem { Header = QuitHeader };
            quit.Click += (_, _) => close();
            menu.Items.Add(quit);

            return menu;
        }
    }
}
