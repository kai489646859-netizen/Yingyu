using System.Collections;
using System.Reflection;
using System.Runtime.CompilerServices;
using EmbyDesktop.Core.Models;
using EmbyDesktop.Core.Services;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.UI.Dispatching;

namespace Yingyu.Update;

public static class BrowseArtwork
{
    // A successful same-library refresh can keep its cards, after the fetch
    // canceled the previous poster generation. Renew that generation before
    // resuming the currently realized viewport, regardless of library identity.
    public static void SnapshotReady(object page)
    {
        try
        {
            if (page is not FrameworkElement element) return;
            if (Access.Get<CancellationTokenSource?>(page, "_posterLoadCts")?.IsCancellationRequested == true)
                Access.Call(page, "ResetPosterLoads");
            var generation = Access.Get<CancellationTokenSource?>(page, "_posterLoadCts");
            element.DispatcherQueue.TryEnqueue(DispatcherQueuePriority.Low, () =>
            {
                try
                {
                    if (!element.IsLoaded || generation?.IsCancellationRequested == true
                        || !ReferenceEquals(generation, Access.Get<CancellationTokenSource?>(page, "_posterLoadCts"))) return;
                    CachedArtwork.WarmCurrent(page);
                    AndroidCacheCards.Reconcile(page);
                    Access.Call(page, "RefreshBrowsePosterViewport");
                }
                catch (Exception error) { Warn(error); }
            });
        }
        catch (Exception error) { Warn(error); }
    }
    const BindingFlags Flags = BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic;
    sealed class Attempt(CancellationToken generation) : IDisposable
    {
        internal readonly CancellationToken Generation = generation;
        internal readonly CancellationTokenSource Cancellation = CancellationTokenSource.CreateLinkedTokenSource(generation);
        internal bool Running = true;
        internal bool Cancelled;
        public void Dispose() { Running = false; Cancellation.Dispose(); }
    }
    static readonly ConditionalWeakTable<object, Attempt> Pending = new();
    static int _warnings;
    static T Value<T>(object owner, string name)
    {
        var property = owner.GetType().GetProperty(name, Flags) ?? throw new MissingMemberException(name);
        return (T)property.GetValue(owner)!;
    }
    static bool Visible(object card) => Value<bool>(card, "IsInViewport");
    static bool Decoded(object card) => Value<BitmapImage?>(card, "Poster") is { } poster && (poster.PixelWidth > 0 || poster.PixelHeight > 0);
    static void Warn(Exception error)
    {
        if (Interlocked.Increment(ref _warnings) <= 3)
            PlaybackTransport.Write("Warning", "Poster.Local", "屏幕内海报本地读取未完成：" + error.GetType().Name + "；保留原加载和重试入口。");
    }
    // The caller passes measured containers after the original loader. This
    // path never downloads and never scans LatestItems or a whole library.
    public static void LoadVisible(object page, IEnumerable realizedCards)
    {
        try
        {
            if (page is not FrameworkElement { IsLoaded: true }) return;
            var generation = Access.Get<CancellationTokenSource?>(page, "_posterLoadCts")?.Token ?? CancellationToken.None;
            if (generation.IsCancellationRequested) return;
            foreach (object card in realizedCards.Cast<object>().ToArray())
            {
                if (!Visible(card)) continue;
                if(Decoded(card)){AndroidCacheCards.PresentVisible(page,card);continue;}
                if(Value<bool>(card,"PreferLandscapeArtwork")||Value<PosterLoadAttemptState>(card,"PosterLoadState")==PosterLoadAttemptState.InProgress)continue;
                if (Pending.TryGetValue(card, out var previous) && (previous.Running || (previous.Generation == generation && !previous.Cancelled))) continue;
                if (WallPosterReuse.TryReuse(page, card, generation)) continue;
                Pending.Remove(card);
                var attempt = new Attempt(generation);
                Pending.Add(card, attempt);
                _ = Load(page, card, attempt);
            }
        }
        catch (OperationCanceledException) { }
        catch (ObjectDisposedException) { }
        catch (Exception error) { Warn(error); }
    }
    public static void CancelIfHidden(object card, bool visible)
    {
        if (visible || !Pending.TryGetValue(card, out var attempt) || !attempt.Running) return;
        attempt.Cancelled = true;
        attempt.Cancellation.Cancel();
    }
    static async Task Load(object page, object card, Attempt attempt)
    {
        try
        {
            var token = attempt.Cancellation.Token;
            token.ThrowIfCancellationRequested();
            if (!Visible(card)) return;
            var item = Value<EmbyItem>(card, "Item");
            int width = ArtworkRequestSizePolicy.Resolve(Access.Get<UserPreferences>(page, "_preferences").ArtworkSize).CardWidth;
            BitmapImage? local = null;
            if (Value<bool>(card, "PreferSeriesArtwork") && string.Equals(item.Type, "Episode", StringComparison.OrdinalIgnoreCase) && !string.IsNullOrWhiteSpace(item.SeriesId))
                local = await BackgroundArtwork.CachedPosterAsync(page, item, "Primary", width, token, item.SeriesId, item.SeriesPrimaryImageTag, PosterCacheRetention.Browse);
            token.ThrowIfCancellationRequested();
            if (!Visible(card)) return;
            local ??= await BackgroundArtwork.CachedPosterAsync(page, item, "Primary", width, token, null, null, PosterCacheRetention.Browse);
            token.ThrowIfCancellationRequested();
            if (local == null || !Visible(card) || page is not FrameworkElement { IsLoaded: true } || Decoded(card)) return;
            var property = card.GetType().GetProperty("Poster", Flags) ?? throw new MissingMemberException("Poster");
            property.SetValue(card, local);
            Access.Call(card, "SetContainedPoster", false);
        }
        catch (OperationCanceledException) { attempt.Cancelled = true; }
        catch (Exception error) { Warn(error); }
        finally { attempt.Dispose(); }
    }
}
