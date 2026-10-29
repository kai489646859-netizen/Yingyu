using System.Security.Cryptography;
using System.Text;

namespace Yingyu.Update;

/// <summary>Application-owned cache paths. User accounts keep their existing identity.</summary>
public static partial class CachePaths
{
    public const string ApplicationId = "8E1C8179-C475-4BC7-A797-5E769E477C0C";
    static readonly Lazy<CacheLayout> Layout = new(() =>
    {
        var layout = new CacheLayout(AppContext.BaseDirectory,
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "映屿"));
        InitializeMigrationObserver(layout);
        return layout;
    });
    // The UI-free layout remains independently testable. The production part
    // binds one static observer before any migration can be queued.
    static partial void InitializeMigrationObserver(CacheLayout layout);
    public static string InstallRoot => Layout.Value.InstallRoot;
    public static string CacheRoot => Layout.Value.EnsureCache();
    public static string Posters => Layout.Value.DirectoryFor("Posters");
    public static string Artwork => Layout.Value.DirectoryFor("Artwork");
    public static string Metadata => Layout.Value.DirectoryFor("Metadata");
    public static string Video => Layout.Value.DirectoryFor("Video");
    public static string Models => Layout.Value.DirectoryFor("Models");
    public static string Temporary => Layout.Value.DirectoryFor("Temp");
    public static string Shaders => RedirectLegacyCachePath(Path.Combine(UserDataRoot, "Cache", "MpvShaders"));
    public static string Certificates => Layout.Value.DirectoryFor("Certificates");
    public static string UserDataRoot => Layout.Value.UserDataRoot;
    public static string BlurayMetadata => RedirectLegacyCachePath(Path.Combine(UserDataRoot, "Cache", "BlurayMetadata"));
    public static string ResumeArtwork => Layout.Value.CopyLegacyTree(Path.Combine(UserDataRoot, "继续观看封面记忆"), "Metadata/ResumeArtwork");

    // Constructors only establish the selected destination. Legacy bytes are
    // copied later on one background worker; they never delay the first page.
    public static void PrepareLegacyPictures() => Layout.Value.CopyLegacyPictures();
    public static void SetMigrationPaused(bool value) => Layout.Value.MigrationPaused = value;
    public static Task WaitForMigrationsAsync() => Layout.Value.WaitForMigrationsAsync();
    public static void CancelMigrations() => Layout.Value.CancelMigrations();
    public static void ReportMigrations(Action<string, long> report) => Layout.Value.MigrationReport = report;
    public static int PendingMigrations => Layout.Value.PendingMigrations;

    public static string RedirectSearch(string original) => Redirect(original, "Cache/Search", "Metadata/Search");
    public static string RedirectInitialization(string original) => Redirect(original, "Cache/ArtworkInitialization", "Metadata/ArtworkInitialization");
    public static string RedirectTranslations(string original) => Redirect(original, "Cache/Translations", "Metadata/Translations");
    public static string RedirectModels(string original) => Redirect(original, "Translation/Offline/1.0.0", "Models/Translation/Offline/1.0.0");
    public static string RedirectNetworkIso(string original)
    {
        if (!CacheLayout.SamePath(original, Path.Combine(UserDataRoot, "Cache", "NetworkIso")))
            throw new IOException("原盘临时目录来源身份不匹配。");
        return Layout.Value.DirectoryFor("Temp/NetworkIso");
    }
    public static string RedirectSubtitles(string original)
    {
        var root = Path.Combine(UserDataRoot, "Cache", "Subtitles");
        if (!CacheLayout.IsWithin(root, original)) throw new IOException("字幕临时目录来源身份不匹配。");
        var name = Path.GetRelativePath(root, original);
        if (!Guid.TryParseExact(name, "N", out _)) throw new IOException("字幕临时目录身份无效。");
        return Layout.Value.DirectoryFor("Temp/Subtitles/" + name);
    }
    static string Redirect(string original, string legacy, string destination)
    {
        var layout = Layout.Value;
        var expected = Path.Combine(layout.UserDataRoot, legacy.Replace('/', Path.DirectorySeparatorChar));
        if (!CacheLayout.SamePath(original, expected))
            throw new IOException("旧缓存来源身份不匹配，未重定位或复制。");
        return layout.CopyLegacyTree(expected, destination);
    }

    // Only the exact legacy app cache is eligible, never arbitrary preferences
    // or user-selected download directories.
    public static string RedirectLegacyCachePath(string original)
    {
        var layout = Layout.Value;
        var sourceRoot = Path.Combine(layout.UserDataRoot, "Cache");
        var source = CacheLayout.Absolute(original);
        if (!CacheLayout.IsWithin(sourceRoot, source))
            throw new IOException("旧缓存路径不属于映屿，已拒绝重定位。");
        var relative = Path.GetRelativePath(sourceRoot, source);
        var target = relative.StartsWith("Search", StringComparison.OrdinalIgnoreCase)
            || relative.StartsWith("ArtworkInitialization", StringComparison.OrdinalIgnoreCase)
            || relative.StartsWith("Translations", StringComparison.OrdinalIgnoreCase)
            || relative.StartsWith("BlurayMetadata", StringComparison.OrdinalIgnoreCase)
            || relative.StartsWith("ResumeArtwork", StringComparison.OrdinalIgnoreCase)
            ? Path.Combine("Metadata", relative)
            : relative.Equals("MpvShaders", StringComparison.OrdinalIgnoreCase) ? "Shaders"
            : relative.Equals("NetworkIso", StringComparison.OrdinalIgnoreCase) ? "Temp/NetworkIso"
            : relative.Replace('\\', '/');
        return layout.CopyLegacyTree(source, target);
    }
}

/// <summary>Pure, injectable path/file policy used by production and isolated tests.</summary>
public sealed class CacheLayout
{
    public const string MarkerName = ".yingyu-cache-owner-v1";
    public const string MarkerContent = "Yingyu:" + CachePaths.ApplicationId;
    readonly object gate = new();
    readonly object migrationGate = new();
    readonly Dictionary<string, Task> migrations = new(StringComparer.OrdinalIgnoreCase);
    readonly SemaphoreSlim migrationWorker = new(1, 1);
    CancellationTokenSource migrationCancellation = new();
    volatile bool migrationPaused;
    public bool MigrationPaused { get => migrationPaused; set => migrationPaused = value; }
    public Exception? LastMigrationError { get; private set; }
    public Action<string, long>? MigrationReport { get; set; }
    public Action<string>? PictureImported { get; set; }
    public int PendingMigrations { get { lock (migrationGate) return migrations.Values.Count(task => !task.IsCompleted); } }
    public string InstallRoot { get; }
    public string UserDataRoot { get; }
    public string CacheRoot => Path.Combine(InstallRoot, "Cache");
    public CacheLayout(string installationDirectory, string userDataDirectory)
    {
        InstallRoot = Absolute(installationDirectory);
        UserDataRoot = Absolute(userDataDirectory);
        if (SamePath(InstallRoot, Path.GetPathRoot(InstallRoot)!))
            throw new IOException("请选择映屿专用安装文件夹。");
        if (!Path.GetFileName(UserDataRoot).Equals("映屿", StringComparison.Ordinal))
            throw new IOException("个人数据目录身份不匹配。");
    }
    public static string Absolute(string value)
    {
        if (string.IsNullOrWhiteSpace(value) || !Path.IsPathFullyQualified(value))
            throw new IOException("必须使用完整绝对路径。");
        return Path.TrimEndingDirectorySeparator(Path.GetFullPath(value));
    }
    public static bool SamePath(string left, string right) =>
        Absolute(left).Equals(Absolute(right), StringComparison.OrdinalIgnoreCase);
    public static bool IsWithin(string parent, string path)
    {
        parent = Absolute(parent); path = Absolute(path);
        return path.StartsWith(parent + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase);
    }
    public static void RejectLinks(string path)
    {
        var current = Absolute(path);
        while (!string.IsNullOrEmpty(current))
        {
            if ((Directory.Exists(current) || File.Exists(current))
                && (File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0)
                throw new IOException("缓存路径含链接或重解析点，操作已停止。");
            current = Path.GetDirectoryName(current);
        }
    }
    public string EnsureCache()
    {
        lock (gate)
        {
            RejectLinks(CacheRoot);
            Directory.CreateDirectory(CacheRoot);
            var marker = Path.Combine(CacheRoot, MarkerName);
            if (File.Exists(marker))
            {
                if (File.ReadAllText(marker) != MarkerContent)
                    throw new IOException("缓存目录属于其他程序，映屿没有写入。");
            }
            else File.WriteAllText(marker, MarkerContent, new UTF8Encoding(false));
            return CacheRoot;
        }
    }
    public string DirectoryFor(string relative)
    {
        var root = EnsureCache();
        var target = Absolute(Path.Combine(root, relative.Replace('/', Path.DirectorySeparatorChar)));
        if (!IsWithin(root, target)) throw new IOException("缓存子目录越界。");
        RejectLinks(target);
        Directory.CreateDirectory(target);
        return target;
    }
    public void CopyLegacyPictures()
    {
        var legacy = Path.Combine(UserDataRoot, "Cache", "Posters");
        var target = DirectoryFor("Posters");
        QueueMigration(legacy + "|pictures", async token =>
        {
            if (!Directory.Exists(legacy)) return;
            RejectLinks(legacy);
            var artworkRoot = DirectoryFor("Artwork");
            foreach (var file in EnumerateRegularFiles(legacy))
            {
                await WaitWhilePaused(token).ConfigureAwait(false);
                var relative = Path.GetRelativePath(legacy, file);
                var parts = relative.Split(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
                var artwork = parts[0].Equals("_detail", StringComparison.OrdinalIgnoreCase);
                var root = artwork ? artworkRoot : target;
                var suffix = artwork ? Path.Combine(parts.Skip(1).ToArray()) : relative;
                if (suffix.Length != 0) await CopyVerified(file, Absolute(Path.Combine(root, suffix)), root, token).ConfigureAwait(false);
            }
        });
    }
    public string CopyLegacyTree(string expectedLegacy, string relativeDestination)
    {
        var source = Absolute(expectedLegacy);
        if (!IsWithin(UserDataRoot, source)) throw new IOException("旧缓存来源越界。");
        var target = DirectoryFor(relativeDestination);
        QueueMigration(source + "|" + target, async token =>
        {
            if (Directory.Exists(source))
            {
                RejectLinks(source);
                foreach (var file in EnumerateRegularFiles(source))
                {
                    await WaitWhilePaused(token).ConfigureAwait(false);
                    await CopyVerified(file, Absolute(Path.Combine(target, Path.GetRelativePath(source, file))), target, token).ConfigureAwait(false);
                }
            }
        });
        return target;
    }
    void QueueMigration(string key, Func<CancellationToken, Task> copy)
    {
        lock (migrationGate)
        {
            if (migrations.ContainsKey(key)) return;
            var token = migrationCancellation.Token;
            migrations[key] = Task.Run(async () =>
            {
                bool acquired = false;
                long started = Environment.TickCount64;
                try
                {
                    // Give construction/first paint a short head start; no
                    // legacy enumeration/body reading happens on that thread.
                    await Task.Delay(500, token).ConfigureAwait(false);
                    await migrationWorker.WaitAsync(token).ConfigureAwait(false); acquired = true;
                    await WaitWhilePaused(token).ConfigureAwait(false);
                    MigrationReport?.Invoke("cache-migration-start", Environment.TickCount64 - started);
                    await copy(token).ConfigureAwait(false);
                    MigrationReport?.Invoke("cache-migration-complete", Environment.TickCount64 - started);
                }
                catch (Exception error) when (error is IOException or UnauthorizedAccessException or OperationCanceledException)
                {
                    LastMigrationError = error;
                    MigrationReport?.Invoke(error is OperationCanceledException ? "cache-migration-cancelled" : "cache-migration-incomplete", Environment.TickCount64 - started);
                    lock (migrationGate)
                        if (token == migrationCancellation.Token) migrations.Remove(key); // Next demand may retry.
                }
                finally { if (acquired) migrationWorker.Release(); }
            });
        }
    }
    async Task WaitWhilePaused(CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        while (migrationPaused) await Task.Delay(100, token).ConfigureAwait(false);
    }
    public Task WaitForMigrationsAsync()
    { lock (migrationGate) return Task.WhenAll(migrations.Values.ToArray()); }
    public void CancelMigrations()
    {
        lock (migrationGate)
        {
            var old = migrationCancellation;
            migrationCancellation = new();
            old.Cancel(); old.Dispose();
            migrations.Clear();
        }
    }
    static IEnumerable<string> EnumerateRegularFiles(string root)
    {
        var pending = new Stack<string>(); pending.Push(Absolute(root));
        while (pending.Count != 0)
        {
            var directory = pending.Pop(); RejectLinks(directory);
            foreach (var entry in Directory.EnumerateFileSystemEntries(directory))
            {
                var absolute = Absolute(entry);
                if (!IsWithin(root, absolute)) throw new IOException("缓存枚举越界。");
                RejectLinks(absolute);
                if (Directory.Exists(absolute)) pending.Push(absolute);
                else yield return absolute;
            }
        }
    }
    async Task CopyVerified(string source, string destination, string targetRoot, CancellationToken token)
    {
        if (!IsWithin(targetRoot, destination)) throw new IOException("缓存复制目标越界。");
        RejectLinks(source); RejectLinks(destination);
        // Existing destination files are newer application state, never replace.
        if (File.Exists(destination)) return;
        Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
        var staging = destination + ".migrating-" + Guid.NewGuid().ToString("N");
        try
        {
            await using var sourceStream = new FileStream(source, FileMode.Open, FileAccess.Read, FileShare.Read, 65536, true);
            await using (var output = new FileStream(staging, FileMode.CreateNew, FileAccess.Write, FileShare.None, 65536, true))
            {
                byte[] buffer = new byte[65536]; int read;
                while ((read = await sourceStream.ReadAsync(buffer, token).ConfigureAwait(false)) != 0)
                {
                    await WaitWhilePaused(token).ConfigureAwait(false);
                    await output.WriteAsync(buffer.AsMemory(0, read), token).ConfigureAwait(false);
                }
                await output.FlushAsync(token).ConfigureAwait(false);
            }
            sourceStream.Position = 0;
            await using var copiedStream = File.OpenRead(staging);
            var sourceHash = await SHA256.HashDataAsync(sourceStream, token).ConfigureAwait(false);
            var copiedHash = await SHA256.HashDataAsync(copiedStream, token).ConfigureAwait(false);
            if (sourceStream.Length != copiedStream.Length || !sourceHash.AsSpan().SequenceEqual(copiedHash))
                throw new IOException("旧缓存复制核对失败，已保留旧源。");
            copiedStream.Dispose();
            File.SetLastWriteTimeUtc(staging, File.GetLastWriteTimeUtc(source));
            token.ThrowIfCancellationRequested(); RejectLinks(destination);
            bool published = false;
            try { File.Move(staging, destination, false); published = true; }
            catch (IOException) when (File.Exists(destination)) { } // A live writer won the race.
            if (published && destination.EndsWith(".image", StringComparison.OrdinalIgnoreCase))
            {
                // Tracking is advisory and cannot turn a verified publication
                // into a failed migration. No filename is written to logs.
                try { PictureImported?.Invoke(destination); } catch (Exception) { }
            }
        }
        finally { if (File.Exists(staging)) File.Delete(staging); }
    }
    // Only our current marked cache. Never walk paths retained in old settings.
    public void RemoveCache(bool keepPersonalInformation)
    {
        if (keepPersonalInformation || !Directory.Exists(CacheRoot)) return;
        Task pending = WaitForMigrationsAsync();
        CancelMigrations();
        pending.GetAwaiter().GetResult(); // Explicit deletion must not race a publisher.
        RejectLinks(CacheRoot);
        var marker = Path.Combine(CacheRoot, MarkerName);
        if (!File.Exists(marker) || File.ReadAllText(marker) != MarkerContent)
            throw new IOException("缓存归属无法确认，未删除。");
        // Validate every descendant before deleting any of them.
        var files = EnumerateRegularFiles(CacheRoot).ToList();
        foreach (var file in files) File.Delete(file);
        var dirs = Directory.GetDirectories(CacheRoot, "*", SearchOption.AllDirectories)
            .OrderByDescending(p => p.Length).ToList();
        foreach (var directory in dirs) { RejectLinks(directory); Directory.Delete(directory, false); }
        Directory.Delete(CacheRoot, false);
    }
}
