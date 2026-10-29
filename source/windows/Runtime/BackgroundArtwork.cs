using System.Reflection;
using EmbyDesktop.Core.Models;
using EmbyDesktop.Core.Services;
using Microsoft.UI.Xaml.Media.Imaging;

namespace Yingyu.Update;

internal static class Access
{
    const BindingFlags Flags = BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic;
    public static T Get<T>(object owner, string name) => (T)owner.GetType().GetField(name, Flags)!.GetValue(owner)!;
    public static void Set(object owner, string name, object? value) => owner.GetType().GetField(name, Flags)!.SetValue(owner, value);
    public static object? Call(object owner, string name, params object?[] args) => owner.GetType().GetMethods(Flags).Single(m => m.Name == name && m.GetParameters().Length == args.Length).Invoke(owner, args);
}

// ABI entries retained for inherited hooks. Android has no bulk initialization.
public static class BackgroundArtwork
{
    public static bool AllowNetwork(bool _) => !AndroidCacheImages.Scheduler.Paused;
    public static bool IsRunning(object _) => false;
    public static void Configure(object page) => AndroidCacheRuntime.Configure(page);
    public static void Begin(object _) { }
    public static void End(object _) { }
    public static bool BlockPlayback(object _) => false;
    public static bool BlockInitialization(object _) => true;
    public static void UpdatePlaybackButton(object _) { }
    public static async Task<BitmapImage?> CachedPosterAsync(object page, EmbyItem item, string imageType, int width,
        CancellationToken token, string? imageItemId, string? imageTag, PosterCacheRetention retention)
    {
        var session = Access.Get<EmbySession?>(page, "_session");
        if (session == null) return null;
        string? tag = imageTag;
        if (imageType.Equals("Backdrop", StringComparison.OrdinalIgnoreCase)) tag ??= item.BackdropImageTags.FirstOrDefault();
        else if (tag == null) item.ImageTags.TryGetValue(imageType, out tag);
        if (string.IsNullOrWhiteSpace(tag)) return null;
        string id = imageItemId ?? item.Id;
        var matched = id == item.Id ? item : (Access.Call(page, "FindCachedItems", id) as IEnumerable<EmbyItem>)?.FirstOrDefault();
        var request = new PosterCacheRequest(session.ServerId, session.UserId, id, imageType, tag, width, 85, retention, ArtworkWorkIdentity.FromItem(matched));
        var cache = Access.Get<PosterCacheService>(page, "_posterCache");
        var local = await Task.Run(() => AndroidCacheImages.TryCached(cache,request), token);
        if (local == null) return null;
        token.ThrowIfCancellationRequested();
        if (!ReferenceEquals(session, Access.Get<EmbySession?>(page, "_session"))) return null;
        return await (Task<BitmapImage?>)Access.Call(page, "LoadBitmapFromFileAsync", local.FilePath, token)!;
    }
}
