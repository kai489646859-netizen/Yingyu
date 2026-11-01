using System.Security.Cryptography;
using System.Text.Json;

namespace Yingyu.Update;

// No accounts are parsed or rewritten. Publish one complete verified directory,
// before any store or log writer can use it. Never delete the legacy source.
public static class StorageMigration
{
    public const string Marker = ".yingyu-data-owner-v1";
    const string Identity = "Yingyu:8E1C8179-C475-4BC7-A797-5E769E477C0C:data-v1";
    sealed record Receipt(string Identity, string User, string Source, Dictionary<string,string> Files);

    public static string Prepare(string installation, string legacy, string user, Action<string>? checkpoint = null, Action<string>? secureDirectory = null)
    {
        installation = CacheLayout.Absolute(installation); legacy = CacheLayout.Absolute(legacy);
        if (installation.Length <= 3 || string.IsNullOrWhiteSpace(user)) throw new IOException("数据目录身份无效。");
        CacheLayout.RejectLinks(installation); CacheLayout.RejectLinks(legacy);
        string target = Path.Combine(installation, "Data");
        string stage = Path.Combine(installation, ".Data.migrating-v1-" + Guid.NewGuid().ToString("N"));
        string gate = Path.Combine(installation, ".yingyu-data-migration.lock");
        CacheLayout.RejectLinks(target); CacheLayout.RejectLinks(stage); CacheLayout.RejectLinks(gate);
        Directory.CreateDirectory(installation);
        using var locked = new FileStream(gate, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
        if (Directory.Exists(target))
        {
            ValidateOwner(target, user);
            ValidateReceipt(target, user);
            // Once committed, current records win, including intentional deletion.
            // Never resurrect a removed account from the old C-drive copy.
            return target;
        }
        foreach(var previous in Directory.EnumerateDirectories(installation,".Data.migrating-v1-*"))
        {
            if(!Guid.TryParseExact(Path.GetFileName(previous)[".Data.migrating-v1-".Length..],"N",out _))continue;
            // A power loss before the initial marker is written leaves an orphan;
            // never adopt or delete an unmarked directory. It cannot block retry.
            try { ValidateOwner(previous, user); } catch(IOException) { continue; }
            // An interrupted, unpublished stage is exclusively ours. Validate the
            // whole tree first, then remove individual entries, never follow links.
            var stale = Files(previous).ToArray();
            var dirs = Directory.GetDirectories(previous, "*", SearchOption.AllDirectories);
            foreach (var dir in dirs) CacheLayout.RejectLinks(dir);
            foreach (var file in stale) File.Delete(file);
            foreach (var dir in dirs.OrderByDescending(p => p.Length)) Directory.Delete(dir);
            Directory.Delete(previous);
        }
        Directory.CreateDirectory(stage);
        secureDirectory?.Invoke(stage);
        WriteReceipt(stage, new(Identity, user, legacy, new()));
        checkpoint?.Invoke("stage-created");
        var selected = Directory.Exists(legacy) ? Files(legacy, true).Where(f => Personal(Path.GetRelativePath(legacy,f))).Order().ToArray() : [];
        var held = new List<FileStream>();
        var hashes = new Dictionary<string,string>(StringComparer.OrdinalIgnoreCase);
        try
        {
            // Holding read-only handles denies writes/deletes while the snapshot
            // is copied. A running old writer causes a safe retry, not split data.
            foreach (var source in selected) held.Add(new FileStream(source, FileMode.Open, FileAccess.Read, FileShare.Read));
            for (int i=0; i<selected.Length; i++)
            {
                var source=held[i]; string relative=Path.GetRelativePath(legacy, selected[i]);
                if(Path.GetFileName(legacy).Equals("EmbyDesktop",StringComparison.OrdinalIgnoreCase)) relative=OriginalName(relative);
                string output=Path.Combine(stage, relative);
                Directory.CreateDirectory(Path.GetDirectoryName(output)!); CacheLayout.RejectLinks(output);
                using (var dest=new FileStream(output, FileMode.CreateNew, FileAccess.Write, FileShare.None))
                { source.CopyTo(dest); dest.Flush(true); }
                source.Position=0; string expected=Convert.ToHexStringLower(SHA256.HashData(source));
                using(var copied=File.OpenRead(output))
                    if(copied.Length!=source.Length || Convert.ToHexStringLower(SHA256.HashData(copied))!=expected)
                        throw new IOException("数据迁移校验失败，旧资料未改动。");
                File.SetLastWriteTimeUtc(output,File.GetLastWriteTimeUtc(selected[i]));
                hashes.Add(relative,expected); checkpoint?.Invoke("file-verified");
            }
            var current=Directory.Exists(legacy)?Files(legacy, true).Where(f=>Personal(Path.GetRelativePath(legacy,f))).Order().ToArray():[];
            if(!selected.SequenceEqual(current,StringComparer.OrdinalIgnoreCase)) throw new IOException("旧资料仍在变化，请关闭旧版后重试。");
            checkpoint?.Invoke("before-commit");
            using(var manifest=new FileStream(Path.Combine(stage,".yingyu-data-receipt-v1.json"),FileMode.CreateNew,FileAccess.Write,FileShare.None))
            { JsonSerializer.Serialize(manifest,new Receipt(Identity,user,legacy,hashes)); manifest.Flush(true); }
            CacheLayout.RejectLinks(target); CacheLayout.RejectLinks(stage);
            Directory.Move(stage,target); // Atomic on the same volume; no partial Data is visible.
            return target;
        }
        finally { foreach(var file in held) file.Dispose(); }
    }

    static bool Personal(string relative)
    {
        var parts=relative.Split(Path.DirectorySeparatorChar,Path.AltDirectorySeparatorChar);
        if(parts[0].Equals("Cache",StringComparison.OrdinalIgnoreCase))
            return parts.Length>1 && parts[1].Equals("PlaybackSync",StringComparison.OrdinalIgnoreCase);
        return !parts[0].Equals("继续观看封面记忆",StringComparison.OrdinalIgnoreCase)
            && !parts[0].Equals("Translation",StringComparison.OrdinalIgnoreCase)
            && !parts[0].Equals(Marker,StringComparison.OrdinalIgnoreCase)
            && !parts[0].Equals(".yingyu-data-receipt-v1.json",StringComparison.OrdinalIgnoreCase);
    }
    static string OriginalName(string relative)
    {
        var parts=relative.Split(Path.DirectorySeparatorChar,Path.AltDirectorySeparatorChar);
        if(parts[0].Equals("Logs",StringComparison.OrdinalIgnoreCase))parts[0]="日志";
        if(parts[^1].StartsWith("EmbyDesktop.log",StringComparison.OrdinalIgnoreCase))parts[^1]="映屿.log"+parts[^1]["EmbyDesktop.log".Length..];
        return Path.Combine(parts);
    }
    static IEnumerable<string> Files(string root, bool personalOnly = false)
    {
        var pending=new Stack<string>(); pending.Push(root);
        while(pending.Count>0)
        {
            var dir=pending.Pop(); CacheLayout.RejectLinks(dir);
            foreach(var entry in Directory.EnumerateFileSystemEntries(dir))
            {
                if(!CacheLayout.IsWithin(root,entry))throw new IOException("资料目录越界。");
                if(personalOnly)
                {
                    var parts=Path.GetRelativePath(root,entry).Split(Path.DirectorySeparatorChar,Path.AltDirectorySeparatorChar);
                    if(parts[0].Equals("Translation",StringComparison.OrdinalIgnoreCase)||parts[0].Equals("继续观看封面记忆",StringComparison.OrdinalIgnoreCase))continue;
                    if(parts[0].Equals("Cache",StringComparison.OrdinalIgnoreCase)&&parts.Length>1&&!parts[1].Equals("PlaybackSync",StringComparison.OrdinalIgnoreCase))continue;
                }
                CacheLayout.RejectLinks(entry);
                if(Directory.Exists(entry))pending.Push(entry); else yield return entry;
            }
        }
    }
    static void ValidateOwner(string root,string user)
    {
        var path=Path.Combine(root,Marker); CacheLayout.RejectLinks(path);
        Receipt? receipt=null;
        try { receipt=JsonSerializer.Deserialize<Receipt>(File.ReadAllText(path)); } catch(Exception e) when(e is IOException or JsonException) { }
        if(receipt?.Identity!=Identity || receipt.User!=user)
            throw new IOException("Data 目录已有其他资料或属于另一位 Windows 用户，未覆盖。请使用自己的安装目录。");
    }
    static void ValidateReceipt(string root,string user)
    {
        var path=Path.Combine(root,".yingyu-data-receipt-v1.json"); CacheLayout.RejectLinks(path);
        Receipt? receipt=null;
        try { receipt=JsonSerializer.Deserialize<Receipt>(File.ReadAllText(path)); } catch(Exception e) when(e is IOException or JsonException) { }
        if(receipt?.Identity!=Identity || receipt.User!=user || receipt.Files==null)
            throw new IOException("Data 的迁移完成记录无效，未读取不完整资料。");
    }
    static void WriteReceipt(string root,Receipt receipt)
    {
        var path=Path.Combine(root,Marker); CacheLayout.RejectLinks(path);
        // Marker replacement is only inside the unpublished stage. Data never
        // exists until a complete durable marker and all payloads are ready.
        using var stream=new FileStream(path,FileMode.Create,FileAccess.Write,FileShare.None);
        JsonSerializer.Serialize(stream,receipt); stream.Flush(true);
    }
}
