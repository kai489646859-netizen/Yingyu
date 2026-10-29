using System.Collections;
using System.Reflection;
using EmbyDesktop.Core.Models;
using EmbyDesktop.Core.Services;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media.Imaging;

namespace Yingyu.Update;

public static class WallPosterReusePolicy
{
    public const long MaximumDecodedBytes = 128L * 1024 * 1024;
    public const int MaximumDecodedCount = 128;

    // This is the original DecodedPosterCache identity, including file revision.
    public static string FileKey(FileInfo file) => $"{file.FullName}|{file.Length}|{file.LastWriteTimeUtc.Ticks}";
}

public static class WallPosterReuse
{
    const BindingFlags Flags = BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic;
    static int _warnings;

    static T Value<T>(object owner, string name) => (T)(owner.GetType().GetProperty(name, Flags)
        ?? throw new MissingMemberException(name)).GetValue(owner)!;
    static void SetValue(object owner, string name, object value) => (owner.GetType().GetProperty(name, Flags)
        ?? throw new MissingMemberException(name)).SetValue(owner, value);

    static bool Eligible(object card) => Value<bool>(card, "UsesBrowseViewport") && Value<bool>(card, "IsInViewport")
        && !Value<bool>(card, "PreferLandscapeArtwork")
        && Value<PosterLoadAttemptState>(card, "PosterLoadState") == PosterLoadAttemptState.NotStarted
        && Value<CancellationTokenSource?>(card, "PosterCancellation") == null
        && Value<BitmapImage?>(card, "Poster") is not { PixelWidth: > 0 }
        && Value<BitmapImage?>(card, "Poster") is not { PixelHeight: > 0 };

    // Runs synchronously on the existing UI loader entry. It only borrows the
    // existing bounded LRU's Bitmap; it does not retain another image pool.
    public static bool TryReuse(object page, object card, CancellationToken token)
    {
        try
        {
            if (page is not FrameworkElement { IsLoaded: true } element || !element.DispatcherQueue.HasThreadAccess
                || token.IsCancellationRequested || !Eligible(card)) return false;
            var generation = Access.Get<CancellationTokenSource?>(page, "_posterLoadCts");
            if ((generation?.Token ?? CancellationToken.None) != token) return false;
            var session = Access.Get<EmbySession?>(page, "_session");
            if (session == null) return false;
            var item = Value<EmbyItem>(card, "Item");
            string id = item.Id;
            item.ImageTags.TryGetValue("Primary", out var tag);
            if (Value<bool>(card, "PreferSeriesArtwork") && string.Equals(item.Type, "Episode", StringComparison.OrdinalIgnoreCase)
                && !string.IsNullOrWhiteSpace(item.SeriesId))
            {
                // Preserve the original series-first chain. An ambiguous or
                // missing series tag must use the original cache/fallback path.
                if (string.IsNullOrWhiteSpace(item.SeriesPrimaryImageTag)) return false;
                id = item.SeriesId;
                tag = item.SeriesPrimaryImageTag;
            }
            if (string.IsNullOrWhiteSpace(id) || string.IsNullOrWhiteSpace(tag)) return false;
            int width = ArtworkRequestSizePolicy.Resolve(Access.Get<UserPreferences>(page, "_preferences").ArtworkSize).CardWidth;
            var matched = id == item.Id ? item : (Access.Call(page, "FindCachedItems", id) as IEnumerable<EmbyItem>)?.FirstOrDefault();
            var request = new PosterCacheRequest(session.ServerId, session.UserId, id, "Primary", tag, width, 90,
                PosterCacheRetention.Browse, ArtworkWorkIdentity.FromItem(matched));
            var cache = Access.Get<PosterCacheService>(page, "_posterCache");
            // First prove an exact decoded hit. Stale and shared/work-only
            // candidates retain the original asynchronous loading/refresh chain.
            var path = (string)Access.Call(cache, "BuildExactPath", request)!;
            var file = new FileInfo(path);
            if (!file.Exists || file.Length <= 0) return false;
            var decoded = Access.Get<object>(page, "_decodedPosters");
            int decodedGeneration = Access.Get<int>(decoded, "_generation");
            var images = (IDictionary)Access.Get<object>(decoded, "_images");
            string key = WallPosterReusePolicy.FileKey(file);
            var node = images[key];
            if (node == null) return false;
            var entry = Value<object>(node, "Value");
            if (Value<BitmapImage?>(entry, "Bitmap") is not { PixelWidth: > 0, PixelHeight: > 0 } bitmap) return false;
            var recent = Access.Get<object>(decoded, "_recent");
            var remove = recent.GetType().GetMethod("Remove", Flags, null, [node.GetType()], null)
                ?? throw new MissingMethodException("Remove");
            var addLast = recent.GetType().GetMethod("AddLast", Flags, null, [node.GetType()], null)
                ?? throw new MissingMethodException("AddLast");
            // Preserve the original cache hit's owner/work indexes, use time
            // and cooldown clearing. This lookup never downloads. A competing
            // file revision or fallback result cannot become a reuse hit.
            var hit = cache.TryGetCached(request, allowStale: false);
            if (hit == null || hit.IsStale || !string.Equals(Path.GetFullPath(hit.FilePath), file.FullName, StringComparison.OrdinalIgnoreCase)) return false;
            file.Refresh();
            if (!file.Exists || file.Length <= 0 || WallPosterReusePolicy.FileKey(file) != key
                || !ReferenceEquals(images[key], node) || !ReferenceEquals(Value<object>(node, "Value"), entry)
                || !ReferenceEquals(Value<BitmapImage?>(entry, "Bitmap"), bitmap)) return false;
            if (token.IsCancellationRequested || !ReferenceEquals(generation, Access.Get<CancellationTokenSource?>(page, "_posterLoadCts"))
                || !ReferenceEquals(session, Access.Get<EmbySession?>(page, "_session"))
                || !ReferenceEquals(item, Value<EmbyItem>(card, "Item")) || !Eligible(card)
                || decodedGeneration != Access.Get<int>(decoded, "_generation")) return false;
            remove.Invoke(recent, [node]);
            addLast.Invoke(recent, [node]);
            SetValue(card, "Poster", bitmap);
            Access.Call(card, "SetContainedPoster", false);
            SetValue(card, "PosterLoadState", PosterLoadAttemptState.Completed);
            return true;
        }
        catch (OperationCanceledException) { return false; }
        catch (ObjectDisposedException) { return false; }
        catch (Exception error)
        {
            if (Interlocked.Increment(ref _warnings) <= 3)
                PlaybackTransport.Write("Warning", "Poster.Reuse", "已解码海报复用未完成：" + error.GetType().Name + "；继续原加载入口。");
            return false;
        }
    }
}
