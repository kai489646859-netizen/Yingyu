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
        string label=TrackLabels.Format(language,title,codec,channels,true);
        lock(Captions){Captions.Remove(track);Captions.Add(track,new Caption(label));}
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
