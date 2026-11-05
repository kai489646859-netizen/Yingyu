using System.Reflection;
using System.Runtime.CompilerServices;
using EmbyDesktop.Core.Models;
using EmbyDesktop.Core.Services;
using Microsoft.UI.Dispatching;

namespace Yingyu.Update;

// Invoked only by the natural-end handler, after the unchanged stop/progress path.
// No timer, hover, startup, PlaybackInfo, image or media request is introduced.
public static class CrossSeasonContinuation
{
    const BindingFlags Flags = BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic;
    sealed class State { public int Epoch; public CancellationTokenSource? Pending; }
    static readonly ConditionalWeakTable<object, State> States = new();
    static bool Closing(object s) => (bool)s.GetType().GetProperty("_isClosing", Flags)!.GetValue(s)!;
    static bool Auto(object s) => PlayerSkipCountdown.AllowsNext(s)&&(bool)Access.Get<object>(s, "_experience").GetType().GetProperty("AutoNext")!.GetValue(Access.Get<object>(s, "_experience"))!;
    static IReadOnlyList<EmbyItem> Queue(object s) => Access.Get<IReadOnlyList<EmbyItem>>(s, "_playlist");
    static bool IdleEnd(object s) => !Closing(s) && !Access.Get<bool>(s, "_switching") && !Access.Get<bool>(s, "_manualSwitchPending")
        && Access.Get<bool>(s, "_hasStartedPlayback") && Access.Get<bool>(s, "_acceptPlaybackEvents")
        && !Access.Get<bool>(s, "_sleepAfterEpisode") && Auto(s);
    static bool Same(string? a, string? b) => string.Equals(a, b, StringComparison.OrdinalIgnoreCase);
    static bool Known(EmbyItem i) => string.Equals(i.Type, "Episode", StringComparison.OrdinalIgnoreCase)
        && !string.IsNullOrWhiteSpace(i.SeriesId) && !string.IsNullOrWhiteSpace(i.SeasonId)
        && i.ParentIndexNumber is > 0 && i.IndexNumber is > 0;

    // Also called at cancellation, seek, manual selection, retry and disposal entry.
    public static void Cancel(object session)
    {
        KeepOpenCompletion.Cancel(session);
        if (!States.TryGetValue(session, out var state)) return;
        lock (state) { state.Epoch++; state.Pending?.Cancel(); }
    }

    public static async Task Handle(object session, Func<Task> original)
    {
        var item = Access.Get<EmbyItem>(session, "_item");
        bool eligible = Known(item) && IdleEnd(session) && !Access.Get<bool>(session, "_endReached")
            && Access.Get<int>(session, "_fileEndHandling") == 0
            && DateTimeOffset.UtcNow >= Access.Get<DateTimeOffset>(session, "_fileEndSuppressionUntil")
            && Queue(session).Any(i => Same(i.Id, item.Id))
            && EpisodeNavigationPolicy.FindAdjacent(Queue(session), item.Id).Next == null;
        var client = Access.Get<EmbyApiClient>(session, "_embyClient");
        int generation = Access.Get<int>(session, "_mediaGeneration");
        string? user = client == null ? null : Access.Get<string?>(client, "_userId");
        string? credential = client == null ? null : Access.Get<string?>(client, "_accessToken");
        var state = States.GetOrCreateValue(session);
        int epoch;
        lock (state) epoch = state.Epoch;
        await original();
        bool Current() => state.Epoch == epoch && ReferenceEquals(item, Access.Get<EmbyItem>(session, "_item"))
            && ReferenceEquals(client, Access.Get<EmbyApiClient>(session, "_embyClient"))
            && (client == null || (user == Access.Get<string?>(client, "_userId") && credential == Access.Get<string?>(client, "_accessToken")))
            && generation == Access.Get<int>(session, "_mediaGeneration") && IdleEnd(session)
            && Access.Get<bool>(session, "_endReached")
            && EpisodeNavigationPolicy.FindAdjacent(Queue(session), item.Id).Next == null;
        if (!eligible || client==null || !Current()) return;
        var closing = (CancellationToken)session.GetType().GetProperty("ClosingToken")!.GetValue(session)!;
        using var cancellation = CancellationTokenSource.CreateLinkedTokenSource(closing);
        cancellation.CancelAfter(TimeSpan.FromSeconds(15));
        lock (state)
        {
            if (!Current() || state.Pending != null) return;
            state.Pending = cancellation;
        }
        try
        {
            var following = await Resolve(client, item, cancellation.Token, Current);
            if (!Current() || cancellation.IsCancellationRequested || following.Count == 0) return;
            Access.Get<DispatcherQueue>(session, "_dispatcher").TryEnqueue(() =>
            {
                // The HTTP operation may have finished before a user cancel/seek/close.
                if (!Current() || cancellation.IsCancellationRequested) return;
                var merged = Queue(session).Concat(following).DistinctBy(i => i.Id, StringComparer.OrdinalIgnoreCase).ToList();
                Access.Set(session, "_playlist", merged);
                // Existing five-second countdown owns the eventual EpisodeRequested.
                // Do not change the visible selected-season list while waiting.
                Access.Call(session, "StartNextEpisodeCountdown", following[0].Id);
            });
        }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested) { }
        catch (Exception)
        {
            // Metadata failure never fails or restarts the already completed media.
            PlaybackTransport.Write("Warning", "Playback.Queue", "跨季分集资料暂不可用，已停止自动连播；可返回详情页选集。");
        }
        finally
        {
            lock (state) { if (ReferenceEquals(state.Pending, cancellation)) state.Pending = null; }
        }
    }

    internal static async Task<IReadOnlyList<EmbyItem>> Resolve(EmbyApiClient client, EmbyItem current, CancellationToken token, Func<bool> stillCurrent)
    {
        if (!Known(current)) return Array.Empty<EmbyItem>();
        // Recheck the current season only after EOF: a partial local queue must not
        // turn an arbitrary episode into a season finale. Existing API budgets,
        // pagination and response-integrity checks remain in force.
        string? user = Access.Get<string?>(client, "_userId");
        string? credential = Access.Get<string?>(client, "_accessToken");
        void CheckAccount()
        {
            token.ThrowIfCancellationRequested();
            if (user != Access.Get<string?>(client, "_userId") || credential != Access.Get<string?>(client, "_accessToken"))
                throw new OperationCanceledException("Account changed during episode lookup.");
        }
        var present = await client.GetEpisodesAsync(current.SeriesId!, current.SeasonId, token);
        CheckAccount();
        if (!stillCurrent()) return Array.Empty<EmbyItem>();
        var ordered = Validate(present.Items, current.SeriesId!, current.SeasonId!, current.ParentIndexNumber!.Value);
        if (ordered.Count == 0 || !Same(ordered[^1].Id, current.Id)) return Array.Empty<EmbyItem>();
        var seasons = await client.GetSeasonsAsync(current.SeriesId!, token);
        CheckAccount();
        if (!stillCurrent()) return Array.Empty<EmbyItem>();
        if (seasons.TotalRecordCount > seasons.Items.Count) return Array.Empty<EmbyItem>();
        var next = seasons.Items.Where(i => i.IndexNumber == current.ParentIndexNumber + 1
            && string.Equals(i.Type, "Season", StringComparison.OrdinalIgnoreCase)
            && (string.IsNullOrWhiteSpace(i.SeriesId) || Same(i.SeriesId, current.SeriesId))).ToList();
        if (next.Count != 1 || string.IsNullOrWhiteSpace(next[0].Id) || Same(next[0].Id, current.SeasonId)) return Array.Empty<EmbyItem>();
        var episodes = await client.GetEpisodesAsync(current.SeriesId!, next[0].Id, token);
        CheckAccount();
        if (!stillCurrent()) return Array.Empty<EmbyItem>();
        var result = Validate(episodes.Items, current.SeriesId!, next[0].Id, next[0].IndexNumber!.Value);
        return result.Count > 0 && result.Select((i, n) => i.IndexNumber == n + 1).All(ok => ok)
            && !result.Any(i => ordered.Any(old => Same(old.Id, i.Id))) ? result : Array.Empty<EmbyItem>();
    }

    static IReadOnlyList<EmbyItem> Validate(IEnumerable<EmbyItem> items, string series, string season, int number)
    {
        var list = items.ToList();
        if (list.Any(i => !string.Equals(i.Type, "Episode", StringComparison.OrdinalIgnoreCase)
            || string.IsNullOrWhiteSpace(i.Id) || i.IndexNumber is not > 0 || i.ParentIndexNumber != number
            || (!string.IsNullOrWhiteSpace(i.SeriesId) && !Same(i.SeriesId, series))
            || (!string.IsNullOrWhiteSpace(i.SeasonId) && !Same(i.SeasonId, season)))
            || list.Select(i => i.Id).Distinct(StringComparer.OrdinalIgnoreCase).Count() != list.Count
            || list.Select(i => i.IndexNumber).Distinct().Count() != list.Count) return Array.Empty<EmbyItem>();
        return list.OrderBy(i => i.IndexNumber).ToArray();
    }
}
