using System.Collections.Concurrent;
using System.Diagnostics;
using System.Text.Json;
using System.Net;

namespace Yingyu.Update;

public sealed record AndroidImageOptions(int CacheGB = 5, int AutoCleanDays = 0, int SpacingMilliseconds = 400, int RequestLimit = 3)
{
    public AndroidImageOptions Validate() => new(
        new[] { 1, 5, 10 }.Contains(CacheGB) ? CacheGB : 5,
        new[] { 0, 15, 30, 60 }.Contains(AutoCleanDays) ? AutoCleanDays : 0,
        new[] { 400, 1000, 2000 }.Contains(SpacingMilliseconds) ? SpacingMilliseconds : 400,
        new[] { 0, 1, 2, 3 }.Contains(RequestLimit) ? RequestLimit : 3);
}

// Shared by wall posters and detail artwork. Admission and complete response
// bodies have separate gates: releasing a start never releases a body slot.
public sealed class AndroidImageScheduler
{
    readonly SemaphoreSlim bodies = new(2, 2), admission = new(1, 1);
    readonly Func<long> clock;
    readonly Func<int, CancellationToken, Task> delay;
    readonly Func<AndroidImageOptions> options;
    readonly object sync = new();
    readonly HashSet<CancellationTokenSource> active = new();
    readonly Dictionary<string, (long Until, int Failures)> cooldown = new();
    readonly List<long> starts = new();
    long? lastStart;
    bool paused;
    public AndroidImageScheduler(Func<AndroidImageOptions> options, Func<long>? clock = null,
        Func<int, CancellationToken, Task>? delay = null)
    {
        this.options = options;
        this.clock = clock ?? (() => Environment.TickCount64);
        this.delay = delay ?? ((milliseconds, token) => Task.Delay(milliseconds, token));
    }
    public bool Paused { get { lock (sync) return paused; } }
    public void Pause(bool value)
    {
        CancellationTokenSource[] abort;
        lock (sync) { if (paused == value) return; paused = value; abort = value ? active.ToArray() : []; }
        foreach (var source in abort) { try { source.Cancel(); } catch (ObjectDisposedException) { } }
    }
    public TimeSpan RetryDelay(string origin)
    {
        lock (sync) return cooldown.TryGetValue(origin, out var entry)
            ? TimeSpan.FromMilliseconds(Math.Max(0, entry.Until - clock())) : TimeSpan.Zero;
    }
    public void CoolDown(string origin, int? seconds = null)
    {
        lock (sync)
        {
            var previous = cooldown.GetValueOrDefault(origin);
            int failures = Math.Min(4, previous.Failures + 1);
            long until = clock() + Math.Max(30, seconds ?? 30 * (1 << (failures - 1))) * 1000L;
            cooldown[origin] = (Math.Max(previous.Until, until), failures);
        }
    }
    void Check(string origin, Func<bool> visible, CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        if (Paused || !visible() || RetryDelay(origin) > TimeSpan.Zero) throw new OperationCanceledException(token);
    }
    public async Task<bool> RunAsync(string origin, Func<CancellationToken, Task<bool>> send,
        Func<bool> visible, CancellationToken token)
    {
        bool acquired = false;
        using var abort = CancellationTokenSource.CreateLinkedTokenSource(token);
        using var finished = new CancellationTokenSource();
        Task? monitor = null;
        try
        {
            Check(origin, visible, token);
            await bodies.WaitAsync(token).ConfigureAwait(false); acquired = true;
            await admission.WaitAsync(token).ConfigureAwait(false);
            try
            {
                while (true)
                {
                    Check(origin, visible, token);
                    var settings = options().Validate();
                    long now = clock();
                    starts.RemoveAll(at => now - at >= 1000);
                    long wait = lastStart.HasValue ? settings.SpacingMilliseconds - (now - lastStart.Value) : 0;
                    if (settings.RequestLimit > 0 && starts.Count >= settings.RequestLimit)
                        wait = Math.Max(wait, starts[starts.Count - settings.RequestLimit] + 1000 - now);
                    if (wait <= 0) break;
                    await delay((int)Math.Min(wait, 100), token).ConfigureAwait(false);
                }
                Check(origin, visible, token);
                long at = clock(); lastStart = at; starts.Add(at);
                if (starts.Count > 3) starts.RemoveAt(0);
                lock (sync) { if (paused) throw new OperationCanceledException(token); active.Add(abort); }
            }
            finally { admission.Release(); }
            monitor = Monitor();
            bool result = await send(abort.Token).ConfigureAwait(false);
            // A success already in flight must not erase a newer explicit
            // server rate limit. Expired entries no longer delay admission.
            if (result) lock (sync)
                if (cooldown.TryGetValue(origin,out var entry)&&entry.Until<=clock())cooldown.Remove(origin);
            return result;
        }
        catch (OperationCanceledException) when (!token.IsCancellationRequested)
        {
            // A single image timeout is resource-local. The cache/card retry
            // retains its own bounded delay; unrelated posters keep moving.
            return false;
        }
        catch (Exception error) when (!token.IsCancellationRequested)
        {
            // Only explicit server-wide pressure pauses this origin. A 404,
            // broken image, transport error or ordinary 5xx cannot freeze all
            // healthy images for 30--240 seconds.
            if (error is HttpRequestException { StatusCode: HttpStatusCode.TooManyRequests }
                || error is HttpRequestException { StatusCode: HttpStatusCode.ServiceUnavailable }
                    && error.Data["ImageRetryAfterSeconds"] is int)
                CoolDown(origin, error.Data["ImageRetryAfterSeconds"] is int seconds ? seconds : null);
            throw;
        }
        finally
        {
            finished.Cancel();
            if (monitor != null) { try { await monitor.ConfigureAwait(false); } catch (OperationCanceledException) { } }
            lock (sync) active.Remove(abort);
            if (acquired) bodies.Release();
        }
        async Task Monitor()
        {
            while (!finished.IsCancellationRequested)
            {
                if (Paused || !visible()) { abort.Cancel(); return; }
                await Task.Delay(20, finished.Token).ConfigureAwait(false);
            }
        }
    }
}

public sealed record AndroidImageFile(string Path, long Bytes, DateTime Used, bool Artwork);
public sealed class AndroidImageDisk
{
    readonly string posters, artwork;
    readonly Func<DateTime> now;
    readonly Func<long> limit;
    readonly Func<int> days;
    readonly SemaphoreSlim gate = new(1, 1);
    readonly Dictionary<string, AndroidImageFile> entries = new(StringComparer.OrdinalIgnoreCase);
    bool loaded;
    DateTime nextExpiry;
    public AndroidImageDisk(string posters, string artwork, Func<long> limit, Func<int> days, Func<DateTime>? now = null)
    { this.posters = Path.GetFullPath(posters); this.artwork = Path.GetFullPath(artwork); this.limit = limit; this.days = days; this.now = now ?? (() => DateTime.UtcNow); }
    static bool Within(string file, string root) => Path.GetFullPath(file).StartsWith(root.TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase);
    bool Managed(string path) => Within(path, posters) || Within(path, artwork);
    static IEnumerable<string> Files(string root)
    {
        if (!Directory.Exists(root)) yield break;
        var pending = new Stack<string>(); pending.Push(root);
        while (pending.TryPop(out var current))
        {
            if ((File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0) throw new IOException("图片缓存目录不可为链接。");
            foreach (string file in Directory.EnumerateFiles(current))
                if ((File.GetAttributes(file) & FileAttributes.ReparsePoint) == 0) yield return file;
            foreach (string child in Directory.EnumerateDirectories(current)) pending.Push(child);
        }
    }
    static IEnumerable<string> Images(string root) => Files(root).Where(path => path.EndsWith(".image", StringComparison.OrdinalIgnoreCase));
    public bool HasAnyUsableFile() => Images(posters).Concat(Images(artwork)).Any(path => new FileInfo(path) is { Exists: true, Length: > 0 });
    bool ValidAlias(string path, bool work)
    {
        var file = new FileInfo(path);
        if (!file.Exists || file.Length > 65536) return false;
        string relative;
        if (work)
        {
            using var json = JsonDocument.Parse(File.ReadAllText(path));
            if (!json.RootElement.TryGetProperty("Work", out var owner) || owner.ValueKind != JsonValueKind.Object
                || !json.RootElement.TryGetProperty("RelativePath", out var value) || value.ValueKind != JsonValueKind.String) return false;
            relative = value.GetString() ?? "";
        }
        else relative = File.ReadAllText(path).Trim();
        if (string.IsNullOrWhiteSpace(relative) || Path.IsPathFullyQualified(relative)) return false;
        string root = Path.GetDirectoryName(posters)!;
        foreach (string candidate in new[] { Path.Combine(root, relative), Path.Combine(posters, relative),
            Path.Combine(artwork, relative.StartsWith("_detail", StringComparison.OrdinalIgnoreCase) ? relative[7..].TrimStart('\\', '/') : relative) })
        {
            string full = Path.GetFullPath(candidate);
            if (Managed(full) && new FileInfo(full) is { Exists: true, Length: > 0 } target
                && (target.Attributes & FileAttributes.ReparsePoint) == 0) return true;
        }
        return false;
    }
    public (int Valid, int Removed) Validate(CancellationToken token = default)
    {
        gate.Wait(token);
        try
        {
            int valid = 0, removed = 0;
            // Enumerate the two owned picture roots, never their Cache parent.
            foreach (string path in Files(posters).Concat(Files(artwork)).ToArray())
            {
                token.ThrowIfCancellationRequested();
                try
                {
                    string extension = Path.GetExtension(path);
                    bool remove = false;
                    if (extension.Equals(".image", StringComparison.OrdinalIgnoreCase))
                    { if (new FileInfo(path).Length > 0) valid++; else remove = true; }
                    else if (extension.Equals(".tmp", StringComparison.OrdinalIgnoreCase))
                        remove = now() - File.GetLastWriteTimeUtc(path) >= TimeSpan.FromHours(1);
                    else if (extension.Equals(".work", StringComparison.OrdinalIgnoreCase))
                    {
                        try { remove = !ValidAlias(path, true); }
                        catch (Exception error) when (error is JsonException or ArgumentException or NotSupportedException) { remove = true; }
                    }
                    else if (extension.Equals(".link", StringComparison.OrdinalIgnoreCase)
                        && path.Contains(Path.DirectorySeparatorChar + "_shared" + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
                        remove = !ValidAlias(path, false);
                    if (remove)
                    {
                        if (!Managed(path)) throw new IOException("图片缓存路径无效。");
                        File.Delete(path); entries.Remove(Path.GetFullPath(path)); removed++;
                    }
                }
                catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException) { }
            }
            return (valid, removed);
        }
        finally { gate.Release(); }
    }
    public void RemoveOwners(IReadOnlySet<string> owners, IEnumerable<string> exactDirectories, CancellationToken token = default)
    {
        if (owners.Count == 0) return;
        gate.Wait(token);
        try
        {
            var selected = new HashSet<string>(exactDirectories.Where(Managed), StringComparer.OrdinalIgnoreCase);
            foreach (string path in Files(posters).Concat(Files(artwork)).Where(path => Path.GetFileName(path).Equals("resource.owner", StringComparison.OrdinalIgnoreCase)))
            {
                token.ThrowIfCancellationRequested();
                if (new FileInfo(path).Length <= 256 && owners.Contains(File.ReadAllText(path).Trim())) selected.Add(Path.GetDirectoryName(path)!);
            }
            foreach (string directory in selected)
            {
                token.ThrowIfCancellationRequested();
                if (!Managed(directory + Path.DirectorySeparatorChar + "guard.image") || !Directory.Exists(directory)) continue;
                if ((File.GetAttributes(directory) & FileAttributes.ReparsePoint) != 0) throw new IOException("图片缓存目录不可为链接。");
                foreach (string path in Directory.EnumerateFiles(directory, "*.image"))
                {
                    token.ThrowIfCancellationRequested();
                    if (!Managed(path) || (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0) continue;
                    File.Delete(path); entries.Remove(Path.GetFullPath(path));
                }
            }
        }
        finally { gate.Release(); }
    }
    void Track(string path)
    {
        if (!Managed(path)) return;
        var file = new FileInfo(path);
        if (file.Exists && (file.Attributes & FileAttributes.ReparsePoint) == 0)
            entries[file.FullName] = new(file.FullName, file.Length, file.LastAccessTimeUtc > file.LastWriteTimeUtc ? file.LastAccessTimeUtc : file.LastWriteTimeUtc, Within(path, artwork));
        else entries.Remove(file.FullName);
    }
    void Load()
    {
        if (loaded) return;
        foreach (string file in Images(posters).Concat(Images(artwork))) Track(file);
        loaded = true;
    }
    public async Task<(long Bytes, int Count)> Statistics(CancellationToken token = default)
    {
        await gate.WaitAsync(token).ConfigureAwait(false);
        try { await Task.Run(Load, token).ConfigureAwait(false); return (entries.Values.Sum(e => e.Bytes), entries.Count); }
        finally { gate.Release(); }
    }
    public async Task Touch(string path, CancellationToken token = default)
    {
        if (!Managed(path) || !File.Exists(path)) return;
        await gate.WaitAsync(token).ConfigureAwait(false);
        try { File.SetLastAccessTimeUtc(path, now()); Track(path); }
        finally { gate.Release(); }
    }
    public async Task Trim(string? protect = null, CancellationToken token = default, bool forceExpiry = false)
    {
        await gate.WaitAsync(token).ConfigureAwait(false);
        try
        {
            await Task.Run(() =>
            {
                token.ThrowIfCancellationRequested(); Load();
                if (!string.IsNullOrWhiteSpace(protect)) Track(protect);
                long total = entries.Values.Sum(e => e.Bytes), budget = limit();
                if (total <= budget && !forceExpiry && now() < nextExpiry) return;
                bool protectArtwork = protect != null && entries.GetValueOrDefault(protect)?.Artwork == true;
                foreach (var file in entries.Values.OrderBy(e => e.Artwork ? 0 : 1).ThenBy(e => e.Used).ToArray())
                {
                    token.ThrowIfCancellationRequested();
                    if (string.Equals(file.Path, protect, StringComparison.OrdinalIgnoreCase)) continue;
                    if (!file.Artwork && protectArtwork && total > budget) break;
                    bool expired = days() > 0 && file.Artwork && now() - file.Used >= TimeSpan.FromDays(days());
                    if (total <= budget && !expired) continue;
                    if (!Managed(file.Path)) throw new IOException("图片缓存路径无效。");
                    if (File.Exists(file.Path)) File.Delete(file.Path);
                    entries.Remove(file.Path); total -= file.Bytes;
                }
                nextExpiry = now().AddHours(12);
            }, token).ConfigureAwait(false);
        }
        finally { gate.Release(); }
    }
    public async Task<(long Bytes, int Count)> Clear(bool clearArtwork, CancellationToken token = default)
    {
        await gate.WaitAsync(token).ConfigureAwait(false);
        try
        {
            return await Task.Run(() =>
            {
                Load(); long bytes = 0; int count = 0;
                foreach (var path in Images(clearArtwork ? artwork : posters).ToArray())
                {
                    token.ThrowIfCancellationRequested();
                    if (!Managed(path)) throw new IOException("图片缓存路径无效。");
                    var length = new FileInfo(path).Length; File.Delete(path);
                    entries.Remove(Path.GetFullPath(path)); bytes += length; count++;
                }
                return (bytes, count);
            }, token).ConfigureAwait(false);
        }
        finally { gate.Release(); }
    }
}
