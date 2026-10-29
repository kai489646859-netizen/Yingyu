using Windows.UI;
using Windows.UI.ViewManagement;

namespace Yingyu.Update;

public readonly record struct DesktopThemeSystemSnapshot(bool HighContrast, bool AnimationsEnabled, uint? Background, uint? Foreground);

// Desktop supports reading these properties, but HighContrastChanged requires
// CoreWindow and cannot be subscribed by this WinUI desktop application. The
// page rechecks this small snapshot on its supported load/theme/focus callbacks.
public sealed class DesktopThemeSystemEvents
{
    readonly Func<bool> highContrast, animations;
    readonly Func<uint> background, foreground;
    readonly Action<Exception> report;
    readonly HashSet<string> reported = new(StringComparer.Ordinal);
    public DesktopThemeSystemEvents(Action<Exception> report)
    {
        this.report = report;
        var accessibility = new Lazy<AccessibilitySettings>(() => new());
        var ui = new Lazy<UISettings>(() => new());
        highContrast = () => accessibility.Value.HighContrast;
        animations = () => ui.Value.AnimationsEnabled;
        background = () => Pack(ui.Value.GetColorValue(UIColorType.Background));
        foreground = () => Pack(ui.Value.GetColorValue(UIColorType.Foreground));
    }
    // The same execution boundary is exercised with injected constructor,
    // property and callback failures without constructing a product window.
    public DesktopThemeSystemEvents(Func<bool> highContrast, Func<bool> animations,
        Func<uint> background, Func<uint> foreground, Action<Exception> report)
    { this.highContrast = highContrast; this.animations = animations; this.background = background; this.foreground = foreground; this.report = report; }
    static uint Pack(Color color) => (uint)color.A << 24 | (uint)color.R << 16 | (uint)color.G << 8 | color.B;
    T Optional<T>(string stage, Func<T> read, T fallback)
    {
        try { return read(); }
        catch (Exception error) { Report(stage, error); return fallback; }
    }
    void Report(string stage, Exception error)
    {
        lock (reported) { if (!reported.Add(stage)) return; }
        try { report(error); } catch (Exception) { /* A logging failure cannot escape a UI callback. */ }
    }
    public DesktopThemeSystemSnapshot Read()
    {
        bool contrast = Optional("read-contrast", highContrast, false);
        bool motion = Optional("read-animation", animations, false);
        uint? back = null, fore = null;
        if (contrast)
        {
            Run("read-contrast-colors", () => { uint b = background(), f = foreground(); back = b; fore = f; });
        }
        return new(contrast, motion, back, fore);
    }
    public bool Run(string stage, Action action)
    {
        try { action(); return true; }
        catch (Exception error) { Report(stage, error); return false; }
    }
}
