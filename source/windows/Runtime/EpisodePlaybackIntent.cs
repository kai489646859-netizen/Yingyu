using System.Diagnostics;
using System.Globalization;
using System.Reflection;
using System.Runtime.CompilerServices;
using EmbyDesktop.Core.Models;
using Richasy.MpvKernel.Core;

namespace Yingyu.Update;

// A new episode starts playing as part of loadfile itself. Never resume the
// outgoing file or send a late ResumeAsync that could override a user's pause.
internal static class EpisodePlaybackIntent
{
    sealed record Intent(object Session, int Generation, EmbyItem Item, MpvClient Client,
        bool Autoplay, double? Intro);
    static readonly AsyncLocal<Intent?> Loading = new();
    static readonly ConditionalWeakTable<MpvClient, Lazy<int>> Scripts = new();
    const string IntroReady = "user-data/yingyu-intro-start-ready";
    static bool Closing(object session) => (bool)session.GetType().GetProperty("_isClosing", BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic)!.GetValue(session)!;
    static bool Current(Intent intent) => !intent.Client.IsDisposed && !Closing(intent.Session)
        && Access.Get<int>(intent.Session, "_mediaGeneration") == intent.Generation
        && ReferenceEquals(Access.Get<EmbyItem>(intent.Session, "_item"), intent.Item)
        && ReferenceEquals(Access.Get<object?>(intent.Session, "_mpvClient"), intent.Client);

    internal static async Task Play(object session, MpvClient client, double? intro, Func<Task> play)
    {
        var previous = Loading.Value;
        var item = Access.Get<EmbyItem>(session, "_item");
        bool autoplay = EpisodeRequests.IsEpisode(item) && !Closing(session) && !Access.Get<bool>(session, "_isPaused")
            && (Access.Get<bool>(session, "_switching") || !Access.Get<bool>(session, "_hasStartedPlayback"));
        var intent = new Intent(session, Access.Get<int>(session, "_mediaGeneration"), item, client, autoplay, intro);
        try
        {
            if (intro.HasValue)
            {
                bool ready = await EnsureIntroHook(intent);
                if (!Current(intent)) return;
                if (!ready)
                {
                    PlayerSkipCountdown.ReleaseStart(session);
                    PlaybackFeatureLog.Write(session, "intro-start", "hook-unavailable");
                    intent = intent with { Intro = null };
                }
                else PlaybackFeatureLog.Write(session, "intro-start", "prepared", intro);
            }
            Loading.Value = intent;
            await play();
        }
        finally { Loading.Value = previous; }
    }

    static async Task<bool> EnsureIntroHook(Intent intent)
    {
        if (!Current(intent)) return false;
        var client = intent.Client;
        if (Scripts.GetValue(client, key => new Lazy<int>(() => DolbyVision.CommandAsync(key, "load-script",
                Path.Combine(AppContext.BaseDirectory, "Components", "EpisodeIntroStart.lua")))).Value < 0)
            return false;
        long began = Stopwatch.GetTimestamp();
        while (Current(intent))
        {
            if (PlaybackTransport.Get(client, IntroReady) is "ready" or "\"ready\"") return true;
            if (Stopwatch.GetElapsedTime(began).TotalMilliseconds >= 600) break;
            await Task.Delay(10);
        }
        return false;
    }

    internal static void Append(List<string> options)
    {
        if (Loading.Value is not { } intent || !Current(intent)) return;
        if (intent.Intro is double intro)
            options.Add("script-opts-append=yingyu_intro_start=" + intro.ToString(CultureInfo.InvariantCulture));
        if (!intent.Autoplay || Access.Get<bool>(intent.Session, "_isPaused")) return;
        options.RemoveAll(value => value.StartsWith("pause=", StringComparison.Ordinal));
        options.Add("pause=no");
    }
}
