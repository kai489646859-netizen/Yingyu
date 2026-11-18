using System.Globalization;
using EmbyDesktop.Core.Models;
using EmbyDesktop.Core.Services;

namespace Yingyu.Update;

public static class ForwardPlaybackCache
{
    // MPV's largest accepted duration leaves the byte budget as the effective limit.
    static readonly string UnlimitedSeconds = double.MaxValue.ToString("R", CultureInfo.InvariantCulture);

    public static IReadOnlyDictionary<string, string> ForMedia(object session,
        IReadOnlyDictionary<string, string> options)
    {
        if (!options.ContainsKey("cache-secs")) return options;
        var address = Access.Get<Uri?>(session, "_playbackUri");
        if (address is not { IsAbsoluteUri: true }) return options;

        var source = Access.Get<MediaSourceInfo>(session, "_source");
        bool eligible = address.Scheme == "yingyu-bd" ||
            (address.Scheme is "http" or "https" && source.IsInfiniteStream != true
                && Access.Get<string?>(session, "_nativeDiscPath") == null
                && !NetworkIsoMount.IsRemoteIso(source));
        if (!eligible) return options;

        // MPV's demux thread keeps prefetching while the presentation is paused.
        // Leave the startup and rebuffer thresholds in the existing disc options.
        return new Dictionary<string, string>(options, StringComparer.Ordinal)
        {
            // The user-visible 5 GiB capacity is implemented by the private
            // Cache/Video store. This MPV option is compressed packet RAM and
            // therefore has a separate, bounded process-memory budget.
            ["demuxer-max-bytes"] = PlaybackCachePolicy.PacketMemoryLimit,
            ["cache-secs"] = UnlimitedSeconds,
            ["demuxer-readahead-secs"] = UnlimitedSeconds
        };
    }
}
