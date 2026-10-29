using System.Text.Json;

namespace Yingyu.Update;

// Desktop preferences; HdrExperimental is captured at the next media load.
public sealed record DesktopThemeOptions
{
    public int Mode { get; init; } = 1; // 0 system, 1 light, 2 dark
    public int Preset { get; init; }
    public int Accent { get; init; } = 5;
    public int Density { get; init; } = 1; // Legacy field retained; always comfortable.
    public int Corners { get; init; } // soft, crisp, square
    public bool ReducedMotion { get; init; }
    public bool HdrExperimental { get; init; } // Missing in older settings => false (SDR).
    public bool VideoClickPause { get; init; } = true;
    public int SeekStepSeconds { get; init; } = 5;
    public bool KeyboardVolumeKeys { get; init; } = true;
    public bool RightHoldBoost { get; init; } = true;
    public int PauseKey { get; init; } = 32;
    public int FullScreenKey { get; init; } = 70;
    public int MuteKey { get; init; } = 77;
    public DesktopThemeOptions Validate() => this with
    {
        Mode = Mode is >= 0 and <= 2 ? Mode : 1,
        Preset = 0, // Legacy desktop presets migrate to the Android palette.
        Accent = Accent is 5 or 6 or 7 or 9 ? Accent : 5,
        Density = 1,
        Corners = Corners is >= 0 and <= 2 ? Corners : 0,
        SeekStepSeconds = SeekStepSeconds is 5 or 10 or 30 ? SeekStepSeconds : 5,
        PauseKey = PauseKey is 32 or 75 or 80 ? PauseKey : 32,
        FullScreenKey = FullScreenKey is 70 or 122 or 71 ? FullScreenKey : 70,
        MuteKey = MuteKey is 77 or 86 ? MuteKey : 77,
    };
    public double Radius => Corners switch { 1 => 8, 2 => 0, _ => 16 };
    public double PosterWidth => 176;
}

public readonly record struct DesktopThemeGrid(double ItemWidth, double ItemHeight, double CardWidth, double ArtworkHeight, int Columns)
{
    public static DesktopThemeGrid Resolve(DesktopThemeOptions options, double availableWidth, double rasterizationScale)
    {
        double preferred = options.Validate().PosterWidth;
        double width = double.IsFinite(availableWidth) && availableWidth > 0 ? Math.Min(availableWidth, 32768) : preferred + 14;
        int columns = Math.Max(1, (int)Math.Floor(width / (preferred + 14)));
        double scale = double.IsFinite(rasterizationScale) ? Math.Clamp(rasterizationScale, 1, 8) : 1;
        double item = Math.Max(1, Math.Floor((width / columns - 1) * scale) / scale);
        double card = Math.Max(1, item - 14), artwork = card * 1.5;
        return new(item, artwork + 84, card, artwork, columns);
    }
}

public readonly record struct DesktopThemePalette(uint Background, uint Surface, uint Sidebar,
    uint Text, uint Secondary, uint Outline, uint Accent, uint Selection, uint Hover)
{
    public static DesktopThemePalette Resolve(DesktopThemeOptions raw, bool dark)
    {
        var value = raw.Validate();
        var palette = new DesktopThemePalette(0,0,0,0,0,dark?0xFF464650:0xFFD5D5DE,0,0,0);
        uint accent = value.Accent switch
        {
            5 => dark ? 0xFFC9B9E3 : 0xFF725D99,
            6 => dark ? 0xFFE0BAB2 : 0xFF8A5752,
            7 => dark ? 0xFFA4CDB3 : 0xFF367555,
            9 => dark ? 0xFF9CCCD6 : 0xFF2E7184,
            _ => dark ? 0xFFC9B9E3 : 0xFF725D99,
        };
        uint background=dark?Blend(0xFF121419,accent,.08):0xFFDADCE3;
        palette=palette with { Background=background, Surface=dark?Blend(0xFF202329,accent,.07):0xFFF7F5F6, Sidebar=dark?Blend(background,accent,.13):background, Text=dark?0xFFF5F5F7:0xFF1B1B1F, Secondary=dark?0xFFC7C7CC:0xFF5B5B63 };
        return palette with { Accent = accent,
            Selection = Blend(palette.Surface, accent, dark ? .38 : .30),
            Hover = Blend(palette.Surface, accent, dark ? .18 : .12) };
    }
    static uint Blend(uint background, uint foreground, double factor)
    {
        uint Channel(int shift) => (uint)Math.Round(((background >> shift) & 255) * (1 - factor) + ((foreground >> shift) & 255) * factor);
        return 0xFF000000 | Channel(16) << 16 | Channel(8) << 8 | Channel(0);
    }
}

public static class DesktopThemeStore
{
    public static DesktopThemeOptions Load(string path)
    {
        try
        {
            if (new FileInfo(path) is { Exists: true, Length: <= 65536 })
                return (JsonSerializer.Deserialize<DesktopThemeOptions>(File.ReadAllText(path)) ?? new()).Validate();
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException) { }
        return new();
    }
    // Publish preferences only after the complete file has been written. A failed
    // save leaves the previous on-disk preferences and the active UI unchanged.
    public static void Save(string path, DesktopThemeOptions value)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(path))!);
        string temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            File.WriteAllText(temporary, JsonSerializer.Serialize(value.Validate()));
            File.Move(temporary, path, true);
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
}
