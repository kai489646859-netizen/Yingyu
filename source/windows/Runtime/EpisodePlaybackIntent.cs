using System.Reflection;
using EmbyDesktop.Core.Models;

namespace Yingyu.Update;

// A new episode starts playing as part of loadfile itself. Never resume the
// outgoing file or send a late ResumeAsync that could override a user's pause.
internal static class EpisodePlaybackIntent
{
    sealed record Intent(object Session, int Generation, EmbyItem Item, object? Client);
    static readonly AsyncLocal<Intent?> Loading = new();
    static bool Closing(object session) => (bool)session.GetType().GetProperty("_isClosing", BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic)!.GetValue(session)!;
    internal static async Task Play(object session, Func<Task> play)
    {
        var previous = Loading.Value;
        var item = Access.Get<EmbyItem>(session, "_item");
        bool start = EpisodeRequests.IsEpisode(item) && !Closing(session) && !Access.Get<bool>(session, "_isPaused")
            && (Access.Get<bool>(session, "_switching") || !Access.Get<bool>(session, "_hasStartedPlayback"));
        Loading.Value = start ? new(session, Access.Get<int>(session, "_mediaGeneration"), item, Access.Get<object?>(session, "_mpvClient")) : null;
        try { await play(); }
        finally { Loading.Value = previous; }
    }
    internal static void Append(List<string> options)
    {
        if (Loading.Value is not { } intent) return;
        var session = intent.Session;
        if (Closing(session) || Access.Get<int>(session, "_mediaGeneration") != intent.Generation
            || !ReferenceEquals(Access.Get<EmbyItem>(session, "_item"), intent.Item)
            || !ReferenceEquals(Access.Get<object?>(session, "_mpvClient"), intent.Client)
            || Access.Get<bool>(session, "_isPaused")) return;
        options.RemoveAll(value => value.StartsWith("pause=", StringComparison.Ordinal));
        options.Add("pause=no");
    }
}
