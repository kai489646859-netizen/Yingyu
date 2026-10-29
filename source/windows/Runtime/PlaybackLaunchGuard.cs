using System.Reflection;
namespace Yingyu.Update;

// Ordinary card/detail launches must not replace an existing player. The
// original gate still owns concurrent preparation; intentional episode
// transitions (waitForTurn=true) retain the original close/switch sequence.
public static class PlaybackLaunchGuard
{
    public static Task<bool>? Repeated(object page,bool waitForTurn)
    {
        if(waitForTurn)return null;
        const BindingFlags flags=BindingFlags.Instance|BindingFlags.Public|BindingFlags.NonPublic;
        bool active=page.GetType().GetField("_playbackSession",flags)?.GetValue(page) is not null;
        return active?Task.FromResult(false):null;
    }
}
