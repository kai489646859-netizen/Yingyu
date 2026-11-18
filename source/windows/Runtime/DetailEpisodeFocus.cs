using System.Collections;
using System.Runtime.CompilerServices;
using EmbyDesktop.Core.Models;
using EmbyDesktop.Core.Services;

namespace Yingyu.Update;

public static class DetailEpisodeFocus
{
    sealed record View(EmbyItem Series,EmbyApiClient Client,EmbySession Session,EmbyItem[] Observations);
    static readonly ConditionalWeakTable<object,View> Views=new();
    static bool Same(string? left,string? right)=>!string.IsNullOrWhiteSpace(left)
        && string.Equals(left,right,StringComparison.OrdinalIgnoreCase);

    public static async Task<EmbyItemsResponse> Seasons(EmbyApiClient client,string series,CancellationToken token,object page)
    {
        var detail=Access.Get<EmbyItem?>(page,"_currentDetailItem");
        var session=Access.Get<EmbySession?>(page,"_session");
        Views.Remove(page);
        var seasons=LocalMetadata.Seasons(client,series,token);
        if(detail is null||session is null||!Same(detail.Id,series)
            ||!string.IsNullOrWhiteSpace(Access.Get<string?>(page,"_detailFocusEpisodeId")))
            return await seasons;

        var history=(Task<IReadOnlyList<EmbyItem>>)Access.Call(page,"ReadLocalPlaybackHistoryAsync")!;
        var result=await seasons;
        var local=await history;
        token.ThrowIfCancellationRequested();
        if(!ReferenceEquals(detail,Access.Get<EmbyItem?>(page,"_currentDetailItem"))
            ||!ReferenceEquals(client,Access.Get<EmbyApiClient?>(page,"_client"))
            ||!ReferenceEquals(session,Access.Get<EmbySession?>(page,"_session")))return result;

        var cards=((IEnumerable)Access.Call(page,"get_ResumeItems")!).Cast<object>()
            .Select(card=>card.GetType().GetProperty("Item")?.GetValue(card)).OfType<EmbyItem>();
        var observations=local.Concat(cards)
            .Where(episode=>episode.Type=="Episode"&&Same(episode.SeriesId,series)&&WatchedAt(episode).HasValue)
            .OrderByDescending(WatchedAt).DistinctBy(episode=>episode.Id,StringComparer.OrdinalIgnoreCase).ToArray();
        Views.AddOrUpdate(page,new(detail,client,session,observations));
        if(InitialSeason(result.Items,observations) is {} seasonId)
            Access.Set(page,"_detailFocusSeasonId",seasonId);
        return result;
    }

    internal static string? InitialSeason(IReadOnlyList<EmbyItem> seasons,IEnumerable<EmbyItem> observations)
    {
        // Only use the most recent actual observation. An older episode with
        // better metadata should not move the page to its season instead.
        var latest=observations.Where(episode=>WatchedAt(episode).HasValue).MaxBy(WatchedAt);
        if(latest is null)return null;
        if(!string.IsNullOrWhiteSpace(latest.SeasonId))
            return seasons.FirstOrDefault(season=>Same(season.Id,latest.SeasonId))?.Id;
        if(latest.ParentIndexNumber is not int number)return null;
        var matching=seasons.Where(season=>season.IndexNumber==number).Take(2).ToArray();
        return matching.Length==1?matching[0].Id:null;
    }

    public static EmbyItem? Resolve(IReadOnlyList<EmbyItem> episodes,string? preferred,object page)
    {
        var observations=Views.TryGetValue(page,out var view)
            &&ReferenceEquals(view.Series,Access.Get<EmbyItem?>(page,"_currentDetailItem"))
            &&ReferenceEquals(view.Client,Access.Get<EmbyApiClient?>(page,"_client"))
            &&ReferenceEquals(view.Session,Access.Get<EmbySession?>(page,"_session"))?view.Observations:[];
        return Choose(episodes,preferred,observations);
    }

    internal static EmbyItem? Choose(IReadOnlyList<EmbyItem> episodes,string? preferred,IEnumerable<EmbyItem> observations)
    {
        var explicitEpisode=episodes.FirstOrDefault(episode=>Same(episode.Id,preferred));
        if(explicitEpisode is not null)return explicitEpisode;

        var observed=observations.Where(episode=>!string.IsNullOrWhiteSpace(episode.Id))
            .GroupBy(episode=>episode.Id,StringComparer.OrdinalIgnoreCase)
            .ToDictionary(group=>group.Key,group=>group.Max(WatchedAt),StringComparer.OrdinalIgnoreCase);
        DateTimeOffset? At(EmbyItem episode)
        {
            var current=WatchedAt(episode);
            var saved=observed.GetValueOrDefault(episode.Id);
            return current is null||saved>current?saved:current;
        }
        return episodes.Where(episode=>At(episode).HasValue).MaxBy(At)
            ??DetailPlaybackPrefetchPolicy.ResolvePlayableTarget(episodes,preferred);
    }

    static DateTimeOffset? WatchedAt(EmbyItem episode)
        =>episode.UserData is {LastPlayedDate:{ } at} data
            &&at>DateTimeOffset.MinValue&&(data.Played||data.PlaybackPositionTicks>0)?at:null;
}
