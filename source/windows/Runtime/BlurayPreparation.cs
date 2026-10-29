using System.Reflection;
using EmbyDesktop.Core.Models;

namespace Yingyu.Update;

// Called only at the original StartAsync load boundary, after the actual
// MpvPlayerWindow.Show. Keep the original awaiter, loadfile and resume options.
public static class BlurayPreparation
{
    public static async Task PlayWhenPrepared(object session, Task<MediaUriResolution> resolution, int? expectedGeneration)
    {
        int generation = expectedGeneration ?? Access.Get<int>(session, "_mediaGeneration");
        if (NetworkBluray.PendingPreparation(session) is { } preparation)
        {
            // The actual window can now close before MPV has emitted any
            // position. Preserve its existing resume point for the original
            // stop/local-save path; do not manufacture a playback-start event.
            if (!Access.Get<bool>(session, "_hasStartedPlayback") && Access.Get<double>(session, "_position") <= 0)
            {
                long ticks = Access.Get<EmbyItem>(session, "_item").UserData?.PlaybackPositionTicks ?? 0;
                if (ticks > 0) Access.Set(session, "_position", ticks / 10000000.0);
            }
            if (Access.Get<object?>(session, "_overlay") is { } overlay)
                Access.Call(overlay, "ShowPlaybackLoading", "正在读取原盘目录…");
            try { await preparation; }
            catch (OperationCanceledException) when (Closing(session) || generation != Access.Get<int>(session, "_mediaGeneration")) { return; }
            if (Closing(session) || generation != Access.Get<int>(session, "_mediaGeneration")) return;
        }
        await (Task)Access.Call(session, "PlayCurrentItemAsync", resolution, expectedGeneration)!;
    }

    // Called after BeginClose succeeds, before stop reporting. Stop this disc's
    // preparation or active reads while leaving reports and cleanup intact.
    public static void Cancel(object session) => NetworkBluray.CancelSessionReading(session);

    static bool Closing(object session) => (bool)session.GetType().GetProperty("_isClosing",
        BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic)!.GetValue(session)!;
}
