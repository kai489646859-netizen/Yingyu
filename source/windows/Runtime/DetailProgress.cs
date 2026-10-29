using EmbyDesktop.Core.Models;
using EmbyDesktop.Core.Services;

namespace Yingyu.Update;

public static class DetailProgress
{
    // The original episode-only handler ran before the movie/resume update.
    // Apply this event to every cached copy first; never merge an older, larger
    // position over a deliberate backwards seek from the just-closed session.
    public static void Apply(object page, object activity)
    {
        string id = (string)activity.GetType().GetProperty("ItemId")!.GetValue(activity)!;
        double position = (double)activity.GetType().GetProperty("PositionSeconds")!.GetValue(activity)!;
        double duration = (double)activity.GetType().GetProperty("DurationSeconds")!.GetValue(activity)!;
        var reason = (PlaybackStopReason?)activity.GetType().GetProperty("StopReason")!.GetValue(activity);
        var items = (IEnumerable<EmbyItem>)Access.Call(page, "FindCachedItems", id)!;
        foreach (var item in items.Distinct<EmbyItem>(ReferenceEqualityComparer.Instance))
            item.UserData = PlaybackUserDataUpdatePolicy.Apply(item.UserData, position, duration, reason);
    }

    public static void SetContained(object card, bool portrait)
    {
        var image = (Microsoft.UI.Xaml.Media.Imaging.BitmapImage)card.GetType().GetProperty("Poster")!.GetValue(card)!;
        // Metadata can omit aspect ratio even though the decoded Primary image
        // is a valid landscape still. Use real dimensions when available.
        if (portrait && image.PixelWidth > 0 && image.PixelHeight > 0)
            portrait = (double)image.PixelWidth / image.PixelHeight < 1.35;
        Access.Call(card, "SetContainedPoster", portrait);
    }

    public static bool CanReuse(string source, string target, bool fromLandscape, bool toLandscape, bool usable, object? previous)
    {
        if (previous != null)
            source = ((EmbyItem)previous.GetType().GetProperty("Item")!.GetValue(previous)!).Id;
        return ArtworkReusePolicy.CanReuse(source, target, fromLandscape, toLandscape, usable);
    }
}
