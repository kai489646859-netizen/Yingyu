using System.Globalization;
using System.Text;

namespace Yingyu.Update;

internal static class VideoQuality
{
    internal static readonly string[] Labels = ["原画", "动漫", "真人影视", "高画质", "低性能"];
    internal const int MaxShaders = 8;
    internal const int MaxShaderBytes = 8 * 1024 * 1024;

    internal static string Name(int preset) => Labels[NormalizePreset(preset)];
    internal static int NormalizePreset(int preset) => preset >= 0 && preset < Labels.Length ? preset : 0;

    internal static string[] NormalizeShaders(IEnumerable<string>? paths) => (paths ?? [])
        .Where(IsSupportedPath).Distinct(StringComparer.OrdinalIgnoreCase).Take(MaxShaders).ToArray();

    internal static bool IsSupportedPath(string? path) => path is { Length: >= 4 and <= 520 }
        && char.IsAsciiLetter(path[0]) && path[1] == ':' && path[2] == '\\'
        && path.IndexOfAny([';', '\r', '\n', '\0']) < 0
        && Path.GetExtension(path).Equals(".glsl", StringComparison.OrdinalIgnoreCase);

    internal static void Append(List<string> options, int preset, bool hdr, bool compatibility,
        bool shadersEnabled, IReadOnlyList<string> shaders)
    {
        if (hdr) return;
        string[] quality = preset switch
        {
            1 => ["scale=ewa_lanczossharp", "cscale=ewa_lanczos", "deband=yes", "deband-iterations=2", "deband-threshold=48", "deband-grain=0"],
            2 => ["scale=lanczos", "cscale=bicubic", "deband=yes", "deband-iterations=1", "deband-threshold=32", "deband-grain=24"],
            3 => ["scale=ewa_lanczossharp", "cscale=ewa_lanczos", "dscale=ewa_lanczos", "deband=yes", "deband-iterations=2", "deband-threshold=40", "deband-grain=24"],
            4 => ["scale=bilinear", "cscale=bilinear", "dscale=bilinear", "deband=no", "correct-downscaling=no", "sigmoid-upscaling=no"],
            _ => []
        };
        foreach (string value in quality)
        {
            string key = value[..(value.IndexOf('=') + 1)];
            options.RemoveAll(existing => existing.StartsWith(key, StringComparison.Ordinal));
            options.Add(value);
        }
        if (compatibility || !shadersEnabled) return;
        string list = string.Join(';', NormalizeShaders(shaders));
        if (list.Length == 0) return;
        string size = Encoding.UTF8.GetByteCount(list).ToString(CultureInfo.InvariantCulture);
        options.Add($"glsl-shaders=%{size}%{list}");
    }
}
