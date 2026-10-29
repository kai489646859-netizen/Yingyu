using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Net;
using EmbyDesktop.Core.Models;
using EmbyDesktop.Core.Services;

namespace Yingyu.Update;

public static class AndroidCacheImages
{
    static readonly Lazy<AndroidImageDisk> Disk = new(() => new(CachePaths.Posters, CachePaths.Artwork,
        () => (long)AndroidCacheRuntime.Options.CacheGB * 1024 * 1024 * 1024,
        () => AndroidCacheRuntime.Options.AutoCleanDays));
    public static readonly AndroidImageScheduler Scheduler = new(() => AndroidCacheRuntime.Options);
    // Probe known size/quality variants; shared hits require proven work identity.
    // No directory scan, stale image, network admission or cache rewrite.
    internal static PosterCacheResult? TryCached(PosterCacheService cache,PosterCacheRequest request)
    {
        var hit=cache.TryGetCached(request,false);
        if(hit is not null||string.IsNullOrWhiteSpace(request.ImageTag))return hit;
        foreach(int width in new[]{request.Width,360,480,700,720,960,1280,1920,2560}.Distinct())
            foreach(int quality in new[]{request.Quality,85,90}.Distinct())
            {
                if(width==request.Width&&quality==request.Quality)continue;
                var variant=new PosterCacheRequest(request.ServerId,request.UserId,request.ItemId,request.ImageType,request.ImageTag,width,quality,request.Retention,request.Work);
                // Most variants do not exist. The full cache entry performs
                // owner/index registration and repeats shared-work resolution;
                // reserve it for a positive read-only preflight. Otherwise a
                // wall of uncached cards can crowd out local cache hits with
                // dozens of full lookups per image.
                string? exact=(string?)Access.Call(cache,"BuildExactPath",variant);
                string? browse=variant.Retention==PosterCacheRetention.Detail?(string?)Access.Call(cache,"TryGetSharedBrowsePath",variant):null;
                bool Usable(string? path)=>path!=null&&new FileInfo(path) is {Exists:true,Length:>0};
                if(!Usable(exact)&&!Usable(browse)&&ResolveWork(cache,variant)==null
                    &&ResolveShared(cache,(string?)Access.Call(cache,"BuildSharedAliasPath",variant))==null)continue;
                hit=cache.TryGetCached(variant,false);
                if(hit is not null&&!hit.IsStale)return hit;
            }
        return null;
    }
    public static string Hash(string value) => Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(value)));
    public static ArtworkRequestSizes Sizes(ArtworkSizePreference _) => new(360, 360, 1280);
    public static string DirectoryFor(object cache, PosterCacheRequest request)
    {
        string identity = string.Join('|', request.ServerId, request.UserId, request.ItemId, request.ImageType,
            Math.Clamp(request.Width, 64, 3840), Math.Clamp(request.Quality, 1, 100));
        string hash = Hash(identity);
        return Path.Combine(request.Retention == PosterCacheRetention.Detail ? CachePaths.Artwork : CachePaths.Posters, hash[..2], hash);
    }
    public static string? ResolveShared(object cache, string? alias)
    {
        if (alias == null || !File.Exists(alias)) return null;
        try { return ResolveRelative(File.ReadAllText(alias).Trim()); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { return null; }
    }
    static string? ResolveRelative(string relative)
    {
        if (Path.IsPathFullyQualified(relative)) return null;
        foreach (string path in new[] { Path.Combine(CachePaths.CacheRoot, relative), Path.Combine(CachePaths.Posters, relative),
            Path.Combine(CachePaths.Artwork, relative.StartsWith("_detail", StringComparison.OrdinalIgnoreCase) ? relative[7..].TrimStart('\\', '/') : relative) })
        {
            string full = Path.GetFullPath(path);
            if (!Managed(full)) continue;
            var file = new FileInfo(full);
            if (file.Exists && file.Length > 0 && (file.Attributes & FileAttributes.ReparsePoint) == 0) return full;
        }
        return null;
    }
    static bool Managed(string path) => new[] { CachePaths.Posters, CachePaths.Artwork }.Any(root =>
        path.StartsWith(Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase));
    public static string? ResolveWork(object cache, PosterCacheRequest request)
    {
        if (request.Work == null) return null;
        foreach (string currentAlias in (IEnumerable<string>)Access.Call(cache, "WorkAliasPaths", request)!)
        foreach (string alias in new[]{currentAlias,
            Path.Combine(CachePaths.Posters,"_shared",Path.GetFileName(Path.GetDirectoryName(currentAlias)!),Path.GetFileName(currentAlias)),
            Path.Combine(CachePaths.Artwork,"_shared",Path.GetFileName(Path.GetDirectoryName(currentAlias)!),Path.GetFileName(currentAlias))}.Distinct(StringComparer.OrdinalIgnoreCase))
        {
            if (!File.Exists(alias)) continue;
            try
            {
                var info=new FileInfo(alias);if(info.Length>65536||(info.Attributes&FileAttributes.ReparsePoint)!=0)continue;
                // Legacy aliases were relative to Posters; the inherited reader
                // rejects them against Cache before our multi-root resolver runs.
                var record=JsonSerializer.Deserialize<CachedWorkAlias>(File.ReadAllText(alias));
                var work=record?.Work;var relative=record?.RelativePath;
                bool compatible = work != null && WorkMatches(request.Work,work);
                // Emby image tags are local revisions, not cross-server work
                // identities. Reuse the indexed file of a proven same work.
                if (compatible && relative != null && ResolveRelative(relative) is { } file) return file;
            }
            catch (Exception error) when (error is IOException or JsonException or UnauthorizedAccessException or ArgumentException) { }
        }
        return null;
    }
    sealed record CachedWorkAlias(ArtworkWorkIdentity? Work,string? RelativePath);
    static bool WorkMatches(ArtworkWorkIdentity requested,ArtworkWorkIdentity stored)
    {
        if(!string.Equals(requested.Type,stored.Type,StringComparison.OrdinalIgnoreCase))return false;
        if(requested.Providers is null||stored.Providers is null)return false;
        bool matched=false;
        foreach(var pair in requested.Providers)
            foreach(var other in stored.Providers.Where(p=>p.Key.Equals(pair.Key,StringComparison.OrdinalIgnoreCase)))
            {
                if(!string.Equals(pair.Value,other.Value,StringComparison.OrdinalIgnoreCase))return false;
                matched=true;
            }
        // Only a positive stable identifier establishes cross-owner reuse.
        // A matching title alone cannot establish edition/series identity.
        return matched;
    }
    public static async Task<bool> Execute(object scheduler, string serverId, PosterFetchPriority priority,
        ServerRequestCoordinator coordinator, Func<CancellationToken, Task<bool>> send, CancellationToken token,
        Func<bool>? needed, Func<PosterFetchPriority>? currentPriority)
    {
        long queued=ImageLoadDiagnostics.Start();bool started=false;
        bool result=await Scheduler.RunAsync(serverId,async t=>{
            started=true;ImageLoadDiagnostics.Record("network-queue",queued);
            return await send(t).ConfigureAwait(false);
        },needed??(()=>true),token).ConfigureAwait(false);
        if(!started)ImageLoadDiagnostics.Record("network-deferred",queued);
        return result;
    }
    public static TimeSpan Retry(object _, string serverId) => Scheduler.RetryDelay(serverId);
    public static Task Trim(object _, string path, long maximum, CancellationToken token) => Disk.Value.Trim(path, token);
    public static Task Enforce(object _, CancellationToken token) => Disk.Value.Trim(null, token, true);
    public static Task TrimCache(object _, string path, CancellationToken token) => Disk.Value.Trim(path, token);
    public static Task SetLimit(object _, long maximum, CancellationToken token) => Disk.Value.Trim(null, token, true);
    public static bool HasAny(object _) => Disk.Value.HasAnyUsableFile();
    public static PosterCacheValidationResult Validate(object _, CancellationToken token)
    { var result = Disk.Value.Validate(token); return new(result.Valid, result.Removed); }
    public static Task<PosterCacheValidationResult> ValidateAsync(object cache, CancellationToken token)
        => Task.Run(() => Validate(cache, token), token);
    public static Task Remove(object cache, string serverId, string userId, IEnumerable<string> ids, CancellationToken token)
    {
        string[] items = ids.Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
        var owners = items.Select(id => Hash($"{serverId}|{userId}|{id}")).ToHashSet(StringComparer.Ordinal);
        var directories = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (string id in items)
            foreach (int width in new[] { 360, 480, 700, 720, 960, 1280, 1920, 2560 })
                foreach (int quality in new[] { 85, 90 })
                    foreach (string type in new[] { "Primary", "Thumb", "Backdrop" })
                        foreach (var retention in new[] { PosterCacheRetention.Browse, PosterCacheRetention.Detail })
                            directories.Add(DirectoryFor(cache, new PosterCacheRequest(serverId, userId, id, type, null, width, quality, retention)));
        return Task.Run(() => Disk.Value.RemoveOwners(owners, directories, token), token);
    }
    public static async Task<bool> Download(object cache, Uri source, string destination, CancellationToken token,
        PosterFetchPriority priority, Func<bool>? needed)
    {
        if (needed?.Invoke() == false) return false;
        using var abort = CancellationTokenSource.CreateLinkedTokenSource(token);
        string temporary = destination + "." + Guid.NewGuid().ToString("N") + ".tmp";
        Task<HttpResponseMessage>? pending = null;
        HttpResponseMessage? claimed = null;
        long started=ImageLoadDiagnostics.Start();int status=0;
        try
        {
            pending = (Task<HttpResponseMessage>)Access.Call(cache, "SendWithRedirectsAsync", source, abort.Token)!;
            using var response = claimed = await pending.WaitAsync(TimeSpan.FromSeconds(12), token).ConfigureAwait(false);
            status=(int)response.StatusCode;ImageLoadDiagnostics.Record("response-headers",started,status);
            if (!response.IsSuccessStatusCode)
            {
                var error = new HttpRequestException("图片请求未成功。", null, response.StatusCode);
                if (response.StatusCode == HttpStatusCode.TooManyRequests || (int)response.StatusCode >= 500)
                {
                    var retry = response.Headers.RetryAfter;
                    double? wait = retry?.Delta?.TotalSeconds ?? (retry?.Date - DateTimeOffset.UtcNow)?.TotalSeconds;
                    if (wait is >= 0 and <= int.MaxValue) error.Data["ImageRetryAfterSeconds"] = (int)Math.Ceiling(wait.Value);
                }
                throw error;
            }
            if (response.Content.Headers.ContentLength > 4 * 1024 * 1024) throw new IOException("图片文件过大。");
            Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
            await using var sourceBody = await response.Content.ReadAsStreamAsync(abort.Token).ConfigureAwait(false);
            await using (var output = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None, 16384, true))
            {
                byte[] buffer = new byte[16384]; int count; long total = 0;
                while ((count = await sourceBody.ReadAsync(buffer, abort.Token).AsTask().WaitAsync(TimeSpan.FromSeconds(12), token).ConfigureAwait(false)) != 0)
                {
                    total += count; if (total > 4 * 1024 * 1024) throw new IOException("图片文件过大。");
                    await output.WriteAsync(buffer.AsMemory(0, count), abort.Token).ConfigureAwait(false);
                }
                if (total == 0) throw new IOException("图片内容为空。");
                await output.FlushAsync(abort.Token).ConfigureAwait(false);
            }
            token.ThrowIfCancellationRequested(); File.Move(temporary, destination, true);
            ImageLoadDiagnostics.Record("downloaded",started,status);return true;
        }
        catch(HttpRequestException){ImageLoadDiagnostics.Record("http-failed",started,status);throw;}
        catch(TimeoutException){ImageLoadDiagnostics.Record("timeout",started,status);throw;}
        catch(OperationCanceledException){ImageLoadDiagnostics.Record(token.IsCancellationRequested?"cancelled":"timeout",started,status);throw;}
        catch(IOException){ImageLoadDiagnostics.Record("io-failed",started,status);throw;}
        finally
        {
            abort.Cancel();
            if (claimed is null && pending is not null)
            { try { using var discarded = await pending.ConfigureAwait(false); } catch (Exception error) when (error is OperationCanceledException or HttpRequestException or IOException) { } }
            if (File.Exists(temporary)) File.Delete(temporary);
        }
    }
    public static async Task<PosterCacheStatistics> Statistics(object _, CancellationToken token)
    { var result = await Disk.Value.Statistics(token); return new(result.Bytes, result.Count, (long)AndroidCacheRuntime.Options.CacheGB * 1024 * 1024 * 1024, 1); }
    public static async Task<PosterCacheClearResult> ClearPosters(object _, CancellationToken token)
    { var result = await Disk.Value.Clear(false, token); return new(result.Bytes, result.Count); }
    public static Task ClearArtwork() => Disk.Value.Clear(true);
    public static void Touch(string path)
    {
        if (string.IsNullOrWhiteSpace(path) || !path.EndsWith(".image", StringComparison.OrdinalIgnoreCase)) return;
        _ = Record();
        async Task Record()
        {
            try { await Disk.Value.Touch(path).ConfigureAwait(false); }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException)
            { PlaybackTransport.Write("Warning", "Poster.Cache", "图片使用时间保存失败；保留图片。 "); }
        }
    }
    public static void Prepare(object cache)
    {
        CachePaths.PrepareLegacyPictures();
        Access.Set(cache, "_rootDirectory", CachePaths.CacheRoot);
    }
}
