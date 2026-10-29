using System.Security.Cryptography;
using System.Text;

namespace Yingyu.Update;

// Only directory blocks already consumed by a successful preparation are saved.
// Callers must freshly authenticate/probe and compute the existing strong-ETag
// identity first. Two private slots, no user media/URL/header text in filenames.
internal sealed class BlurayMetadataStore(string directory)
{
    readonly object _gate = new();
    const int MaxFile = BlurayPreparationCache.MaximumBytes + 64 * 1024;
    static bool ValidKey(string? key) => key is { Length: 64 } && key.All(Uri.IsHexDigit);
    internal bool Restore(string? key, BlurayBlockCache cache)
    {
        if (!ValidKey(key)) return false;
        lock (_gate)
        {
            for (int slot = 0; slot < 2; slot++)
            {
                var blocks = Read(Path.Combine(directory, $"slot-{slot}.bdmeta"), key!);
                if (blocks == null) continue;
                foreach (var pair in blocks) cache.Publish(pair.Key, pair.Value);
                return true;
            }
            return false;
        }
    }
    internal void Save(string? key, BlurayBlockCache cache)
    {
        if (!ValidKey(key)) return;
        var blocks = cache.Snapshot(BlurayPreparationCache.MaximumBytes);
        if (blocks == null || blocks.Count == 0) return;
        using var memory = new MemoryStream();
        using (var writer = new BinaryWriter(memory, Encoding.UTF8, true))
        {
            writer.Write(0x59424431); writer.Write(DateTime.UtcNow.Ticks); writer.Write(key!); writer.Write(blocks.Count);
            foreach (var pair in blocks) { writer.Write(pair.Key); writer.Write(pair.Value.Length); writer.Write(pair.Value); }
        }
        byte[] data = memory.ToArray();
        if (data.Length + 32 > MaxFile) return;
        lock (_gate)
        {
            Directory.CreateDirectory(directory);
            string[] slots = [Path.Combine(directory, "slot-0.bdmeta"), Path.Combine(directory, "slot-1.bdmeta")];
            string target = slots.FirstOrDefault(p => Read(p, key!) != null)
                ?? slots.FirstOrDefault(p => !File.Exists(p)) ?? slots.MinBy(File.GetLastWriteTimeUtc)!;
            string temporary = Path.Combine(directory, Guid.NewGuid().ToString("N") + ".tmp");
            try
            {
                using (var file = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
                { file.Write(data); file.Write(SHA256.HashData(data)); file.Flush(); }
                File.Move(temporary, target, true);
            }
            finally { if (File.Exists(temporary)) File.Delete(temporary); }
        }
    }
    static Dictionary<long, byte[]>? Read(string path, string key)
    {
        try
        {
            using var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read | FileShare.Delete);
            if (file.Length is < 113 or > MaxFile) return null;
            byte[] all = new byte[(int)file.Length]; file.ReadExactly(all);
            ReadOnlySpan<byte> data = all.AsSpan(0, all.Length - 32);
            if (!CryptographicOperations.FixedTimeEquals(SHA256.HashData(data), all.AsSpan(all.Length - 32))) return null;
            using var reader = new BinaryReader(new MemoryStream(all, 0, all.Length - 32, false), Encoding.UTF8);
            if (reader.ReadInt32() != 0x59424431) return null;
            var age = DateTime.UtcNow - new DateTime(reader.ReadInt64(), DateTimeKind.Utc);
            if (age < TimeSpan.Zero || age >= TimeSpan.FromHours(24) || reader.ReadString() != key) return null;
            int count = reader.ReadInt32(); if (count is <= 0 or > 512) return null;
            var result = new Dictionary<long, byte[]>(); int total = 0;
            for (int i = 0; i < count; i++)
            {
                long index = reader.ReadInt64(); int length = reader.ReadInt32();
                if (index < 0 || index > long.MaxValue / (64 * 1024) || length is <= 0 or > 64 * 1024
                    || (total += length) > BlurayPreparationCache.MaximumBytes || result.ContainsKey(index)) return null;
                byte[] bytes = reader.ReadBytes(length); if (bytes.Length != length) return null;
                result.Add(index, bytes);
            }
            return reader.BaseStream.Position == reader.BaseStream.Length ? result : null;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or ArgumentException or OverflowException) { return null; }
    }
}
