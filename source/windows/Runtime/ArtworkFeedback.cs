using System.Collections.Concurrent;
using System.Net;
using System.Diagnostics;
using System.Runtime.CompilerServices;
using EmbyDesktop.Core.Models;
using EmbyDesktop.Core.Services;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Yingyu.Update;

public static class ArtworkFeedback
{
    static readonly ConditionalWeakTable<object, ConcurrentDictionary<string, Failure>> Failures = new();
    static readonly TimeSpan Lifetime = TimeSpan.FromMinutes(2);
    static readonly ConditionalWeakTable<object, LargeImageState> LargeImages = new();
    sealed class LargeImageState
    {
        internal readonly SemaphoreSlim Gate = new(1, 1);
        internal long LastStarted;
    }
    sealed record Failure(bool Missing, bool Cancelled, DateTimeOffset Time);

    // The page/cache may live for days. Expiry-on-lookup alone retains every
    // failed address that is never visited again. Bound writes as well.
    static void Remember(ConcurrentDictionary<string,Failure> states,string path,Failure failure)
    {
        lock(states)
        {
            if(states.Count>=1024)
            {
                var now=DateTimeOffset.UtcNow;
                foreach(var pair in states)if(now-pair.Value.Time>Lifetime)states.TryRemove(pair.Key,out _);
                if(states.Count>=1024)
                    foreach(var pair in states.OrderBy(p=>p.Value.Time).Take(states.Count-767))states.TryRemove(pair.Key,out _);
            }
            states[path]=failure;
        }
    }
    public static async Task<bool> Download(object cache, Uri source, string destination,
        CancellationToken token, PosterFetchPriority priority, Func<bool>? isStillNeeded)
    {
        var states = Failures.GetValue(cache, _ => new());
        LargeImageState? large = null;
        bool acquired = false;
        long started = 0;
        try
        {
            // Keep the selected resolution. Limit only actual large network
            // downloads; existing local/cache hits do not pass this delegate.
            if (LargeWidth(source) >= 960)
            {
                large = LargeImages.GetValue(cache, _ => new());
                await large.Gate.WaitAsync(token).ConfigureAwait(false);
                acquired = true;
                TimeSpan gap = large.LastStarted == 0 ? TimeSpan.Zero : TimeSpan.FromSeconds(1) - Stopwatch.GetElapsedTime(large.LastStarted);
                if (gap > TimeSpan.Zero) await Task.Delay(gap, token).ConfigureAwait(false);
                token.ThrowIfCancellationRequested();
                if (isStillNeeded != null && !isStillNeeded()) return false;
                started = large.LastStarted = Stopwatch.GetTimestamp();
            }
            bool result = await (Task<bool>)Access.Call(cache, "DownloadAtomicallyAsync",
                source, destination, token, priority, isStillNeeded)!;
            if (result) states.TryRemove(destination, out _);
            else Remember(states,destination,new(false, true, DateTimeOffset.UtcNow));
            return result;
        }
        catch (HttpRequestException error)
        {
            bool missing = error.StatusCode is HttpStatusCode.NotFound or HttpStatusCode.Gone;
            Remember(states,destination,new(missing, false, DateTimeOffset.UtcNow));
            if (missing) PlaybackTransport.Write("Info", "Poster.Detail", "图片来源返回不存在，保留现有封面或占位，不将其提示为下载故障。 ");
            throw;
        }
        catch (OperationCanceledException)
        {
            Remember(states,destination,new(false, token.IsCancellationRequested, DateTimeOffset.UtcNow));
            throw;
        }
        catch
        {
            Remember(states,destination,new(false, false, DateTimeOffset.UtcNow));
            throw;
        }
        finally
        {
            if (acquired) large!.Gate.Release();
            if (started != 0) PlaybackTransport.Write("Info", "Poster.Large", $"大图片请求结束，耗时={Stopwatch.GetElapsedTime(started).TotalMilliseconds:0}ms；保留所选尺寸，单路请求；来源及身份已隐藏。 ");
        }
    }
    static int LargeWidth(Uri source)
    {
        foreach (string part in source.Query.TrimStart('?').Split('&'))
        {
            int split = part.IndexOf('=');
            if (split > 0 && part[..split].Equals("maxWidth", StringComparison.OrdinalIgnoreCase)
                && int.TryParse(part[(split + 1)..], out int width)) return width;
        }
        return 0;
    }
    public static TimeSpan RetryDelay(TimeSpan original, object cache, PosterCacheRequest request)
    {
        // Do not queue a failure retry for an image that the source says is absent.
        return Find(cache, request) is { Missing: true } ? TimeSpan.Zero : original;
    }
    static Failure? Find(object cache, PosterCacheRequest request)
    {
        if (!Failures.TryGetValue(cache, out var states)) return null;
        string path = (string)Access.Call(cache, "BuildExactPath", request)!;
        if (!states.TryGetValue(path, out var result)) return null;
        if (DateTimeOffset.UtcNow - result.Time > Lifetime) { states.TryRemove(path, out _); return null; }
        return result;
    }

    public static bool Suppress(object page, string message)
    {
        bool retry = message == "部分详情图片暂时未加载成功，将稍后自动重试。";
        if (!retry && message != "部分详情图片仍未加载成功，请返回媒体库后重新进入重试。") return false;
        try
        {
            bool report = NeedsWarning(page);
            // First transient failure retries quietly. Persistent failures remain visible.
            if (report && (!retry || Access.Get<Dictionary<string, int>>(page, "_detailArtworkRetries").Values.Any(n => n >= 2))) return false;
            var bar = Access.Get<InfoBar>(page, "OperationFeedbackInfoBar");
            if (bar.Message is "部分详情图片暂时未加载成功，将稍后自动重试。" or "部分详情图片仍未加载成功，请返回媒体库后重新进入重试。") bar.IsOpen = false;
            return true;
        }
        catch { return false; } // Preserve genuine errors when classification is unavailable.
    }
    static bool NeedsWarning(object page)
    {
        var item = Access.Get<EmbyItem?>(page, "_currentDetailItem");
        var session = Access.Get<EmbySession?>(page, "_session");
        if (item == null || session == null || BackgroundArtwork.IsRunning(page)
            || Access.Get<Grid>(page, "DetailView").Visibility != Visibility.Visible) return false;
        var cache = Access.Get<PosterCacheService>(page, "_posterCache");
        var sizes = ArtworkRequestSizePolicy.Resolve(Access.Get<UserPreferences>(page, "_preferences").ArtworkSize);
        foreach (var (type, tag, width, control) in new[]
        {
            ("Primary", item.ImageTags.GetValueOrDefault("Primary"), sizes.DetailPosterWidth, "DetailPosterImage"),
            ("Backdrop", item.BackdropImageTags.FirstOrDefault(), sizes.DetailBackdropWidth, "DetailBackdropImage")
        })
        {
            if(type=="Backdrop"&&!ReferenceAppearance.WantsDetailBackground((FrameworkElement)page))continue;
            if (string.IsNullOrWhiteSpace(tag) || Access.Get<Image>(page, control).Source != null) continue;
            var request = new PosterCacheRequest(session.ServerId, session.UserId, item.Id,
                type, tag, width, 90, PosterCacheRetention.Detail, ArtworkWorkIdentity.FromItem(item));
            var failure = Find(cache, request);
            if (failure is not { Missing: true } and not { Cancelled: true }) return true;
        }
        return false;
    }
}
