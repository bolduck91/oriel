// The headless Avalonia platform these tests run on (ticket 07).
//
// Every [AvaloniaFact] below runs on a real Avalonia dispatcher with a real
// visual tree, but no window ever reaches a screen — which is what lets the
// skins, the menu and the shadow geometry be checked on a build machine with no
// display attached.

using Avalonia;
using Avalonia.Headless;
using Avalonia.Themes.Fluent;

[assembly: AvaloniaTestApplication(typeof(Oriel.UiTests.TestAppBuilder))]

namespace Oriel.UiTests
{
    public class TestApp : Application
    {
        public override void Initialize() => Styles.Add(new FluentTheme());
    }

    public static class TestAppBuilder
    {
        public static AppBuilder BuildAvaloniaApp()
            => AppBuilder.Configure<TestApp>().UseHeadless(new AvaloniaHeadlessPlatformOptions());
    }
}
