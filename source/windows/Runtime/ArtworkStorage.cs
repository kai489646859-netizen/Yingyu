using EmbyDesktop.Core.Services;

namespace Yingyu.Update;

public static class ArtworkStorage
{
    public static string? Alias(string? path, object cache, PosterCacheRequest request)
    {
        if (path == null) return null;
        string root = request.Retention == PosterCacheRetention.Detail ? CachePaths.Artwork : CachePaths.Posters;
        string marker = Path.DirectorySeparatorChar + "_shared" + Path.DirectorySeparatorChar;
        int offset = path.LastIndexOf(marker, StringComparison.OrdinalIgnoreCase);
        return offset < 0 ? path : Path.Combine(root, "_shared", path[(offset + marker.Length)..]);
    }
    public static IEnumerable<string> WorkAliases(IEnumerable<string> paths, object cache, PosterCacheRequest request)
        => paths.Select(path => Alias(path, cache, request)!);
    public static void PrepareBrowse(object cache, PosterCacheRequest request)
    {
        if (request.Retention == PosterCacheRetention.Detail) return;
        string exact = (string)Access.Call(cache, "BuildExactPath", request)!;
        if (File.Exists(exact)) return;
        string? shared = AndroidCacheImages.ResolveWork(cache, request)
            ?? AndroidCacheImages.ResolveShared(cache, (string?)Access.Call(cache, "BuildSharedAliasPath", request));
        if (shared == null || !shared.StartsWith(CachePaths.Artwork + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)) return;
        Directory.CreateDirectory(Path.GetDirectoryName(exact)!);
        string temporary = exact + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try { File.Copy(shared, temporary); try { File.Move(temporary, exact, false); } catch (IOException) when (File.Exists(exact)) { } }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
    public static void Configure(object page) => AndroidCacheRuntime.Configure(page);
}
