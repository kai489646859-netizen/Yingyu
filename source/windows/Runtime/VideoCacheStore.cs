using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Yingyu.Update;

// Persistent, independently reusable raw ranges. These are neither decoded
// packets nor a completed offline download. Filenames contain hashes only.
public static class VideoCacheSettings
{
    public static IReadOnlyDictionary<int, string> Choices { get; } = new Dictionary<int, string>
    { [0] = "不缓存", [2] = "2 GB", [5] = "5 GB", [10] = "10 GB", [20] = "20 GB", [50] = "50 GB", [-1] = "不限制" };
    static readonly object Gate = new();
    static int? _limit;
    static VideoCacheStore? _store;
    public static string? Warning { get; internal set; }
    static string SettingsPath => Path.Combine(CachePaths.UserDataRoot, "video-cache-settings-v1.json");
    public static int LimitGB
    {
        get
        {
            lock (Gate)
            {
                if (_limit is { } value) return value;
                try
                {
                    if (File.Exists(SettingsPath))
                    {
                        var saved = JsonSerializer.Deserialize<Policy>(File.ReadAllText(SettingsPath));
                        if (saved != null && Choices.ContainsKey(saved.GB)) return (_limit = saved.GB).Value;
                    }
                }
                catch (Exception e) when (e is IOException or UnauthorizedAccessException or JsonException)
                { Warning = "视频缓存设置读取失败，使用临时缓冲"; }
                return (_limit = 0).Value;
            }
        }
    }
    internal static VideoCacheStore Store
    {
        get
        {
            lock (Gate) return _store ??= new VideoCacheStore(CachePaths.Video, Bytes(LimitGB));
        }
    }
    public static long UsedBytes => Store.UsedBytes;
    public static void Configure(int gigabytes)
    {
        if (!Choices.ContainsKey(gigabytes)) throw new ArgumentOutOfRangeException(nameof(gigabytes));
        lock (Gate)
        {
            Directory.CreateDirectory(CachePaths.UserDataRoot);
            string path = SettingsPath, temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
            try
            {
                File.WriteAllText(temporary, JsonSerializer.Serialize(new Policy(gigabytes)));
                File.Move(temporary, path, true);
                _limit = gigabytes;
                if (_store != null) _store.Configure(Bytes(gigabytes));
                Warning = null;
            }
            finally { if (File.Exists(temporary)) File.Delete(temporary); }
        }
    }
    public static void Clear() { Store.Clear(); Warning = null; }
    internal static long Bytes(int value) => value < 0 ? -1 : value * 1024L * 1024 * 1024;
    sealed record Policy(int GB);
}

internal sealed class VideoCacheStore
{
    readonly string _directory;
    readonly object _gate = new();
    readonly Dictionary<string, Entry> _entries = new(StringComparer.Ordinal);
    readonly Dictionary<object, (string Identity, long Start, long End)> _readers = new();
    long _used, _limit;
    bool _loaded;
    const int HeaderBytes = 48;
    internal const int BlockBytes = 256 * 1024;
    internal VideoCacheStore(string directory, long limit) { _directory = Path.GetFullPath(directory); _limit = limit; }
    internal static string Hash(params string[] parts)
    {
        var text = new StringBuilder();
        foreach (string part in parts) text.Append(part.Length).Append(':').Append(part);
        return Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(text.ToString())));
    }
    static string Name(string identity, long start, int length) => Hash(identity, start.ToString(System.Globalization.CultureInfo.InvariantCulture), length.ToString(System.Globalization.CultureInfo.InvariantCulture)) + ".vblock";
    void Load()
    {
        if (_loaded) return;
        Directory.CreateDirectory(_directory);
        foreach (string file in Directory.EnumerateFiles(_directory, "*", SearchOption.TopDirectoryOnly))
        {
            string name = Path.GetFileName(file);
            // Only our exact private file formats may be removed or read.
            if (name.Length == 73 && name.EndsWith(".vpartial", StringComparison.Ordinal) && name[..64].All(Uri.IsHexDigit))
            { File.Delete(file); continue; }
            if (name.Length != 71 || !name.EndsWith(".vblock", StringComparison.Ordinal) || !name[..64].All(Uri.IsHexDigit)) continue;
            var stat = new FileInfo(file);
            _entries[name] = new Entry(stat.Length, stat.LastWriteTimeUtc);
            _used += stat.Length;
        }
        _loaded = true;
        Trim(0);
    }
    internal long UsedBytes { get { lock (_gate) { Load(); return _used; } } }
    internal void Configure(long limit) { lock (_gate) { _limit = limit; Load(); Trim(0); } }
    internal Lease Begin(string identity)
    {
        lock (_gate)
        {
            Load(); var lease = new Lease(this);
            _readers[lease] = (identity, 0, 0);
            return lease;
        }
    }
    internal sealed class Lease(VideoCacheStore owner) : IDisposable
    {
        internal void Protect(long start, long end) { lock (owner._gate) if (owner._readers.TryGetValue(this, out var current)) owner._readers[this] = (current.Identity, start, end); }
        public void Dispose() { lock (owner._gate) { owner._readers.Remove(this); owner.Trim(0); } }
    }
    bool Protected(Entry entry) => entry.Identity != null && _readers.Values.Any(r => r.Identity == entry.Identity && entry.Start < r.End && entry.Start + entry.Length > r.Start);
    bool Trim(long incoming)
    {
        if (_limit < 0) return true;
        foreach (var pair in _entries.OrderBy(p => p.Value.Used).ToArray())
        {
            if (_used + incoming <= _limit) return true;
            if (Protected(pair.Value)) continue;
            try { File.Delete(Path.Combine(_directory, pair.Key)); _entries.Remove(pair.Key); _used -= pair.Value.Size; }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { VideoCacheSettings.Warning = "部分视频片段暂时无法清理"; }
        }
        return _used + incoming <= _limit;
    }
    internal byte[]? Read(string identity, long start, int length)
    {
        lock (_gate)
        {
            Load(); string name = Name(identity, start, length);
            if (!_entries.TryGetValue(name, out var entry)) return null;
            entry.Identity = identity; entry.Start = start; entry.Length = length;
            try
            {
                if (entry.Size != length + HeaderBytes) throw new InvalidDataException();
                byte[] all = File.ReadAllBytes(Path.Combine(_directory, name));
                if (all.Length != length + HeaderBytes || BitConverter.ToInt32(all, 0) != 0x59564331 || BitConverter.ToInt64(all, 4) != start || BitConverter.ToInt32(all, 12) != length
                    || !CryptographicOperations.FixedTimeEquals(all.AsSpan(16, 32), SHA256.HashData(all.AsSpan(HeaderBytes)))) throw new InvalidDataException();
                entry.Used = DateTime.UtcNow;
                if (entry.Used - entry.SavedUse >= TimeSpan.FromMinutes(1))
                { File.SetLastWriteTimeUtc(Path.Combine(_directory, name), entry.Used); entry.SavedUse = entry.Used; }
                return all.AsSpan(HeaderBytes).ToArray();
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException or InvalidDataException)
            {
                try { File.Delete(Path.Combine(_directory, name)); _entries.Remove(name); _used -= entry.Size; } catch (Exception removeError) when (removeError is IOException or UnauthorizedAccessException) { }
                VideoCacheSettings.Warning = "视频缓存读取失败，继续从片源读取"; return null;
            }
        }
    }
    internal bool Write(string identity, long start, byte[] bytes)
    {
        if (bytes.Length is <= 0 or > BlockBytes || start < 0) return false;
        lock (_gate)
        {
            Load(); if (_limit == 0) return false;
            string name = Name(identity, start, bytes.Length);
            if (_entries.ContainsKey(name)) return true;
            long size = bytes.Length + HeaderBytes;
            if (!Trim(size)) return false;
            string temporary = Path.Combine(_directory, Hash(Guid.NewGuid().ToString("N")) + ".vpartial");
            try
            {
                using (var file = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
                using (var writer = new BinaryWriter(file))
                { writer.Write(0x59564331); writer.Write(start); writer.Write(bytes.Length); writer.Write(SHA256.HashData(bytes)); writer.Write(bytes); file.Flush(); }
                File.Move(temporary, Path.Combine(_directory, name));
                _entries.Add(name, new Entry(size, DateTime.UtcNow) { Identity = identity, Start = start, Length = bytes.Length });
                _used += size; return true;
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            { VideoCacheSettings.Warning = "视频缓存无法写入或空间不足，继续直接播放"; return false; }
            finally { try { if (File.Exists(temporary)) File.Delete(temporary); } catch (IOException) { } }
        }
    }
    internal void Clear()
    {
        lock (_gate)
        {
            Load(); if (_readers.Count != 0) throw new InvalidOperationException("播放中请先退出视频再清理视频缓存");
            foreach (string name in _entries.Keys.ToArray())
            { File.Delete(Path.Combine(_directory, name)); _used -= _entries[name].Size; _entries.Remove(name); }
        }
    }
    sealed class Entry(long size, DateTime used)
    {
        internal long Size = size, Start;
        internal int Length;
        internal string? Identity;
        internal DateTime Used = used, SavedUse = used;
    }
}
