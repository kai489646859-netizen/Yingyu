using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using EmbyDesktop.Core.Models;
using EmbyDesktop.Core.Services;

namespace Yingyu.Update;

public static class ResumeArtwork
{
    // The next episode must resolve its current Emby image identity. If its
    // candidate points to the same parent image, the ordinary disk cache hits;
    // an unrelated old episode still is not retained as the new episode's image.
    public static bool CanReuse(string source, string target, bool fromLandscape, bool toLandscape,
        bool usable, object? previous, EmbyItem current)
    {
        if (previous != null)
        {
            var prior = (EmbyItem)previous.GetType().GetProperty("Item")!.GetValue(previous)!;
            source = prior.Id;
            if (!(bool)previous.GetType().GetProperty("UsesLandscapeFallback", BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic)!.GetValue(previous)!
                && !string.Equals(prior.Id,current.Id,StringComparison.OrdinalIgnoreCase)) return false;
        }
        return ArtworkReusePolicy.CanReuse(source, target, fromLandscape, toLandscape, usable);
    }
    public static bool IsLandscape(int width,int height) => height > 0 && width > height;

    // The caller is exclusively the resume-card landscape branch. All downloads,
    // decoding, cancellation, stale refresh and retry remain in the original code.
    public static IReadOnlyList<MediaArtworkCandidate> Candidates(EmbyItem item, object page)
        => Expand(item, _ => Array.Empty<EmbyItem>());

    // Only image owners and tags declared by the current Emby item are valid.
    // The callback is retained for the existing binary seam but deliberately is
    // not used: stale cached metadata, series memories and old episode stills
    // must not turn an absent image into a second emergency layout.
    internal static IReadOnlyList<MediaArtworkCandidate> Expand(EmbyItem item, Func<string, IEnumerable<EmbyItem>> find)
        => string.IsNullOrWhiteSpace(item.Id) ? Array.Empty<MediaArtworkCandidate>()
            : MediaArtworkPolicy.GetLandscapeCandidates(item).Where(c => c.ImageType is "Thumb" or "Backdrop")
                .OrderBy(c => c.ImageType=="Thumb"?0:1).ToArray();

    // Called only after a bitmap was successfully assigned, never for a failed URL.
    public static void Remember(object page, EmbyItem item, MediaArtworkCandidate candidate)
    {
        try
        {
            var session = Access.Get<EmbySession?>(page, "_session");
            if (session == null) return;
            string path = MemoryPath(session, item), value = Identity(candidate);
            string? seriesPath = SeriesPath(session, item);
            string? seriesValue = SerializeSeries(item, candidate);
            _ = Task.Run(() =>
            {
                try
                {
                    Directory.CreateDirectory(Path.GetDirectoryName(path)!);
                    if (!File.Exists(path) || File.ReadAllText(path) != value)
                        File.WriteAllText(path, value, new UTF8Encoding(false));
                    if (seriesPath != null && seriesValue != null)
                        SaveSeries(seriesPath, seriesValue);
                }
                catch { }
            });
        }
        catch { }
    }
    sealed record SeriesMemory(string SeriesId, MediaArtworkCandidate Candidate);
    internal static string? SerializeSeries(EmbyItem item, MediaArtworkCandidate candidate)
    {
        if (!item.Type.Equals("Episode", StringComparison.OrdinalIgnoreCase) || string.IsNullOrWhiteSpace(item.SeriesId)
            || candidate.IsPortraitFallback) return null;
        string text = JsonSerializer.Serialize(new SeriesMemory(item.SeriesId, candidate));
        return ParseSeries(item, text) == null ? null : text;
    }
    internal static MediaArtworkCandidate? ParseSeries(EmbyItem item, string text)
    {
        try
        {
            if (text.Length > 4096 || !item.Type.Equals("Episode", StringComparison.OrdinalIgnoreCase)
                || string.IsNullOrWhiteSpace(item.SeriesId)) return null;
            var saved = JsonSerializer.Deserialize<SeriesMemory>(text);
            if (saved == null || !string.Equals(saved.SeriesId, item.SeriesId, StringComparison.OrdinalIgnoreCase)) return null;
            var c = saved.Candidate;
            return c != null && !c.IsPortraitFallback && c.ItemId is { Length: > 0 and <= 256 }
                && c.ImageTag is { Length: > 0 and <= 1024 } && c.ImageType is "Thumb" or "Backdrop" or "Primary" ? c : null;
        }
        catch (JsonException) { return null; }
    }
    static void SaveSeries(string path, string value)
    {
        if (File.Exists(path) && new FileInfo(path).Length <= 4096 && File.ReadAllText(path) == value) return;
        string temporary = path + ".tmp-" + Guid.NewGuid().ToString("N");
        try
        {
            File.WriteAllText(temporary, value, new UTF8Encoding(false));
            File.Move(temporary, path, true);
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
    static string? SeriesPath(EmbySession session, EmbyItem item) =>
        item.Type.Equals("Episode", StringComparison.OrdinalIgnoreCase) && !string.IsNullOrWhiteSpace(item.SeriesId)
            ? Path.Combine(Path.GetDirectoryName(MemoryPath(session, item))!, "series-" + Hash(item.SeriesId) + ".json") : null;
    static string Hash(params string?[] values) => Convert.ToHexStringLower(
        SHA256.HashData(Encoding.UTF8.GetBytes(string.Join("\0", values))));
    static string Identity(MediaArtworkCandidate c) => Hash(c.ItemId, c.ImageType, c.ImageTag);
    static string MemoryPath(EmbySession session, EmbyItem item) => Path.Combine(
        CachePaths.ResumeArtwork, Hash(session.ServerId, session.UserId), Hash(item.Id) + ".txt");
}
