using System.Collections;
using System.Reflection;
using EmbyDesktop.Core.Models;

namespace Yingyu.Update;

public static class NetworkEpisodes
{
    const BindingFlags Flags = BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Instance;
    public static void Configure(object player, object page)
    {
        var item = Access.Get<EmbyItem>(player, "_item");
        if (!EpisodeRequests.IsEpisode(item)) return;
        var rows = page.GetType().GetProperty("DetailEpisodes")!.GetValue(page) as IEnumerable;
        var playlist = rows?.Cast<object>().Select(row => (EmbyItem)row.GetType().GetProperty("Item", Flags)!.GetValue(row)!)
            .OrderBy(value => value.ParentIndexNumber ?? int.MaxValue).ThenBy(value => value.IndexNumber ?? int.MaxValue).ToList() ?? new();
        bool SameSeries(EmbyItem value) => value.Id == item.Id || (!string.IsNullOrWhiteSpace(item.SeriesId) && value.SeriesId == item.SeriesId);
        playlist = playlist.Where(SameSeries).ToList();
        if (!playlist.Any(value => value.Id == item.Id) && Access.Get<object?>(page, "_playbackSession") is { } previous)
        {
            var prior = previous.GetType().GetProperty("Playlist")!.GetValue(previous) as IEnumerable<EmbyItem>;
            if (prior?.Any(value => value.Id == item.Id) == true) playlist = prior.Where(SameSeries).ToList();
        }
        bool loadAfterStart = !playlist.Any(value => value.Id == item.Id) && !string.IsNullOrWhiteSpace(item.SeriesId);
        if (loadAfterStart) playlist = new() { item };
        Access.Set(player, "_playlist", playlist);
        Access.Set(player, "_loadPlaylistAfterStart", loadAfterStart);
        foreach (string eventName in new[] { "EpisodeRequested", "EpisodePreviewRequested" })
        {
            var raised = player.GetType().GetEvent(eventName)!;
            var handler = page.GetType().GetMethod("PlaybackSession_" + eventName, Flags)!;
            raised.AddEventHandler(player, Delegate.CreateDelegate(raised.EventHandlerType!, page, handler));
        }
    }
    public static bool CanSwitch(object player) => Access.Get<object?>(player, "_networkIsoMount") == null &&
        (bool)player.GetType().GetProperty("CanSwitch")!.GetValue(player)!;
    public static string CurrentId(object previous, object page) => CurrentItem(previous, page).Id;
    public static EmbyItem CurrentItem(object previous, object page) =>
        Access.Get<EmbyItem>(Access.Get<object?>(page, "_playbackSession") ?? previous, "_item");
}
