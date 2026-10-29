using System.Globalization;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using Richasy.MpvKernel.Core.Models;

namespace Yingyu.Update;

// Display-only metadata. Never changes the track's ID, language preference,
// current selection, codec/title fields, ordering or presence in MPV's list.
internal static class DiscAudioLabels
{
    sealed record Caption(string Text);
    static readonly ConditionalWeakTable<MpvTrackInfo, Caption> Captions = new();
    internal static string? AudioLanguage(Uri uri, ushort pid) => NetworkBluray.Active.TryGetValue(uri.ToString(), out var disc)
        && disc.AudioLanguages.TryGetValue(pid, out var language) ? language : null;
    internal static bool Contains(MpvTrackInfo track) => Captions.TryGetValue(track, out _);
    internal static string? Get(MpvTrackInfo track) => Captions.TryGetValue(track, out var value) ? value.Text : null;
    internal static void Remember(MpvTrackInfo track, string? language, string? codec, string? channels, string? title)
    {
        string tag = language?.Trim().ToLowerInvariant() ?? "";
        string name = tag switch
        {
            "zh" or "zho" or "chi" => "中文", "eng" or "en" => "英语", "jpn" or "ja" => "日语",
            "kor" or "ko" => "韩语", "fre" or "fra" or "fr" => "法语", "ger" or "deu" or "de" => "德语",
            "spa" or "es" => "西班牙语", "ita" or "it" => "意大利语", "rus" or "ru" => "俄语",
            "por" or "pt" => "葡萄牙语", "tha" or "th" => "泰语", "vie" or "vi" => "越南语",
            "" or "und" or "unknown" => "语言未知", _ => tag
        };
        string kind = codec?.Trim().ToLowerInvariant() switch
        {
            "ac3" => "AC-3", "eac3" => "E-AC-3", "truehd" => "TrueHD", "dts" => "DTS",
            "aac" => "AAC", "flac" => "FLAC", null or "" => "", var value => value.ToUpperInvariant()
        };
        var parts = new List<string> { name };
        if (kind.Length > 0) parts.Add(kind);
        if (int.TryParse(channels, NumberStyles.Integer, CultureInfo.InvariantCulture, out int count) && count is > 0 and <= 64)
            parts.Add(count.ToString(CultureInfo.InvariantCulture) + " 声道");
        parts.Add("轨道 " + track.Id.ToString(CultureInfo.InvariantCulture));
        if (!string.IsNullOrWhiteSpace(title)) parts.Add(title.Trim());
        lock (Captions) { Captions.Remove(track); Captions.Add(track, new Caption(string.Join(" · ", parts))); }
    }
    internal static IReadOnlyDictionary<ushort, string> ReadLanguages(IntPtr info)
    {
        // Bundled libbluray 1.5.0 Windows x64 header, same selected title as PG.
        var found = new Dictionary<ushort, string>(); var conflicts = new HashSet<ushort>();
        if (info == IntPtr.Zero) return found;
        int clips = Marshal.ReadInt32(info, 16); IntPtr list = Marshal.ReadIntPtr(info, 32);
        if (clips is < 0 or > 10000 || list == IntPtr.Zero) return found;
        for (int i = 0; i < clips; i++)
        {
            IntPtr clip = IntPtr.Add(list, checked(i * 104));
            int count = Marshal.ReadByte(clip, 9); IntPtr streams = Marshal.ReadIntPtr(clip, 24);
            if (streams == IntPtr.Zero) continue;
            for (int j = 0; j < count; j++)
            {
                IntPtr stream = IntPtr.Add(streams, j * 16);
                ushort pid = unchecked((ushort)Marshal.ReadInt16(stream, 8));
                string language = new(new[] { (char)Marshal.ReadByte(stream, 4), (char)Marshal.ReadByte(stream, 5), (char)Marshal.ReadByte(stream, 6) });
                if (pid == 0 || language == "und" || !language.All(c => c is >= 'a' and <= 'z')) continue;
                if (found.TryGetValue(pid, out var old) && old != language) conflicts.Add(pid);
                else found[pid] = language;
            }
        }
        foreach (var pid in conflicts) found.Remove(pid);
        return found;
    }
}
