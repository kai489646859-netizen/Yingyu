using System.Diagnostics;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

namespace Yingyu.Update;

// Only immutable copies of blocks consumed during successful disc preparation.
// A fresh authenticated source probe and a strong ETag are required on every open.
// No URLs/credentials are retained; no disk writes or additional network reads.
internal static class BlurayPreparationCache
{
    internal const int MaximumBytes = 4 * 1024 * 1024;
    static readonly object Gate = new();
    static readonly Dictionary<string, Entry> Entries = new();
    sealed record Entry(Dictionary<long, byte[]> Blocks, long Created);
    internal static string? Key(Uri original, string? etag, long length, IReadOnlyDictionary<string, string> headers)
        => KeyCore(original, etag, length, headers, "0.0.0");

    internal static IReadOnlyList<string> LookupKeys(Uri original, string? etag, long length,
        IReadOnlyDictionary<string, string> headers)
    {
        // The two old slots are only hashes. Reconstruct the preceding release's
        // exact key under the CURRENT freshly authenticated source/ETag/length;
        // never accept a slot merely because its directory bytes look similar.
        var keys = new List<string>();
        foreach (string? version in new string?[] { "0.0.0", null, "0.5.9" })
            if (KeyCore(original, etag, length, headers, version) is { } key && !keys.Contains(key)) keys.Add(key);
        return keys;
    }

    static string? KeyCore(Uri original, string? etag, long length,
        IReadOnlyDictionary<string, string> headers, string? replacementVersion)
    {
        if (length <= 0 || string.IsNullOrWhiteSpace(etag) || etag.StartsWith("W/", StringComparison.OrdinalIgnoreCase)) return null;
        string[] parts = original.Query.TrimStart('?').Split('&');
        string? version = replacementVersion == null ? null : ClientVersion(parts);
        string query = string.Join("&", parts.Where(part =>
            !Uri.UnescapeDataString(part.Split('=')[0]).Equals("PlaySessionId", StringComparison.OrdinalIgnoreCase))
            .Select(part => version != null && Uri.UnescapeDataString(part.Split('=')[0]).Equals("X-Emby-Client-Version", StringComparison.OrdinalIgnoreCase)
                ? part[..(part.IndexOf('=') + 1)] + replacementVersion : part));
        var text = new StringBuilder();
        void Add(string value) => text.Append(value.Length).Append(':').Append(value);
        Add(original.GetLeftPart(UriPartial.Path)); Add(query); Add(etag); Add(length.ToString(System.Globalization.CultureInfo.InvariantCulture));
        foreach (var pair in headers.OrderBy(p => p.Key, StringComparer.OrdinalIgnoreCase))
        {
            Add(pair.Key.ToLowerInvariant());
            Add(version == null ? pair.Value : HeaderVersion(pair.Key, pair.Value, version, replacementVersion!));
        }
        return Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(text.ToString())));
    }

    static string? ClientVersion(string[] parts)
    {
        string? One(string key)
        {
            var values = parts.Select(p => p.Split('=', 2)).Where(p => p.Length == 2
                && Uri.UnescapeDataString(p[0]).Equals(key, StringComparison.OrdinalIgnoreCase)).ToArray();
            return values.Length == 1 ? Uri.UnescapeDataString(values[0][1]) : null;
        }
        string? version = One("X-Emby-Client-Version");
        return One("X-Emby-Client") == "Yingyu" && One("X-Emby-Device-Name") == "Windows Desktop"
            && !string.IsNullOrWhiteSpace(One("X-Emby-Device-Id")) && version is { Length: <= 32 }
            && Regex.IsMatch(version, @"\A[0-9]+\.[0-9]+\.[0-9]+\z", RegexOptions.CultureInvariant)
                ? version : null;
    }

    static string HeaderVersion(string name, string value, string version, string replacement)
    {
        // Normalize only our generated application-version fields. Retain every
        // token, account, device, custom header, signed query and source identity.
        // These strings are used solely for hashing; outgoing requests are untouched.
        if (name.Equals("User-Agent", StringComparison.OrdinalIgnoreCase) && value == "Yingyu/" + version)
            return "Yingyu/" + replacement;
        if (name.Equals("X-Emby-Authorization", StringComparison.OrdinalIgnoreCase) && value.Length <= 16384
            && Regex.IsMatch(value, "\\AEmby Client=\"Yingyu\", Device=\"Windows Desktop\", DeviceId=\"[^\"\\\\\\r\\n]+\", Version=\""
                + Regex.Escape(version) + "\", UserId=\"[^\"\\\\\\r\\n]+\", Token=\"[^\"\\\\\\r\\n]+\"\\z", RegexOptions.CultureInvariant))
            return value.Replace(", Version=\"" + version + "\", UserId=", ", Version=\"" + replacement + "\", UserId=", StringComparison.Ordinal);
        return value;
    }
    internal static bool Restore(string? key, BlurayBlockCache cache)
    {
        if (key == null) return false;
        lock (Gate)
        {
            if (!Entries.TryGetValue(key, out var entry)) return false;
            if (Stopwatch.GetElapsedTime(entry.Created).TotalMinutes >= 5) { Entries.Remove(key); return false; }
            foreach (var pair in entry.Blocks) cache.Publish(pair.Key, (byte[])pair.Value.Clone());
            return true;
        }
    }
    internal static void Save(string? key, BlurayBlockCache cache)
    {
        if (key == null) return;
        var snapshot = cache.Snapshot(MaximumBytes);
        if (snapshot == null || snapshot.Count == 0) return;
        lock (Gate)
        {
            if (!Entries.ContainsKey(key) && Entries.Count >= 2)
                Entries.Remove(Entries.MinBy(p => p.Value.Created).Key);
            Entries[key] = new Entry(snapshot, Stopwatch.GetTimestamp());
        }
    }
}
