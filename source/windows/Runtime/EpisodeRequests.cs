using EmbyDesktop.Core.Models;

namespace Yingyu.Update;

public static class EpisodeRequests
{
    // Metadata and poster loading remain untouched. Playback information/302
    // preparation for episodes starts only after click or actual auto-advance.
    public static bool IsEpisode(EmbyItem? item) => item != null &&
        (string.Equals(item.Type, "Episode", StringComparison.OrdinalIgnoreCase)
         || !string.IsNullOrEmpty(item.SeriesId));
}
