using System.Runtime.CompilerServices;
using System.Text.Json;
using EmbyDesktop.Core.Models;
using EmbyDesktop.Core.Services;
namespace Yingyu.Update;

// Read-side projection only. Never reports playback, writes UserData, changes
// completion, or turns ordinary cached observations into pending edits.
internal static class ResumeServerHistory
{
    sealed class State
    {
        internal EmbySession? Session;internal EmbyApiClient? Client;internal DateTimeOffset At;
        internal Task<IReadOnlyList<EmbyItem>>? Reading;
    }
    static readonly ConditionalWeakTable<object,State> States=new();
    internal static bool Rewatch(EmbyItem item)=>item.UserData is {Played:true,PlaybackPositionTicks:>0} data
        &&(item.RunTimeTicks is not >0||data.PlaybackPositionTicks<item.RunTimeTicks.Value);
    internal static bool Show(EmbyItem item)=>item.UserData?.Played!=true||Rewatch(item);
    static string Key(EmbyItem item)=>item.Type.Equals("Episode",StringComparison.OrdinalIgnoreCase)&&!string.IsNullOrWhiteSpace(item.SeriesId)?"series:"+item.SeriesId:"item:"+item.Id;
    internal static async Task<IReadOnlyList<EmbyItem>> Read(object page,EmbySession session,EmbyApiClient client,IReadOnlyList<EmbyItem> resume)
    {
        var state=States.GetOrCreateValue(page);var now=DateTimeOffset.UtcNow;
        if(!ReferenceEquals(state.Session,session)||!ReferenceEquals(state.Client,client))
        {state.Session=session;state.Client=client;state.Reading=null;state.At=default;}
        // Coalesce only overlapping/near-identical homepage reads. Foreground
        // resume refresh is already rate-limited; there is no new timer/poller.
        if(state.Reading==null||state.Reading.IsCompleted&&now-state.At>TimeSpan.FromSeconds(5))
        {state.At=now;state.Reading=Fetch(session,client);}
        IReadOnlyList<EmbyItem> recent;var reading=state.Reading;
        try{recent=await reading;}
        catch(Exception error)
        {
            if(ReferenceEquals(state.Reading,reading))state.Reading=null;
            try{PlaybackTransport.Write("Warning","Library.Resume","服务端重看记录核对未完成，保留原继续观看读取；"+error.GetType().Name);}catch(Exception){}
            return resume;
        }
        if(!ReferenceEquals(session,Access.Get<EmbySession?>(page,"_session"))||!ReferenceEquals(client,Access.Get<EmbyApiClient?>(page,"_client")))throw new OperationCanceledException();
        return Merge(resume,recent);
    }
    static async Task<IReadOnlyList<EmbyItem>> Fetch(EmbySession session,EmbyApiClient client)
    {
        using var timeout=new CancellationTokenSource(TimeSpan.FromSeconds(8));
        string path=$"Users/{Uri.EscapeDataString(session.UserId)}/Items?Limit=36&Recursive=true&IncludeItemTypes=Movie,Episode&MediaTypes=Video&SortBy=DatePlayed&SortOrder=Descending&Filters=IsPlayed&EnableUserData=true&EnableImages=true&ImageTypeLimit=1&EnableImageTypes=Primary,Thumb,Backdrop&Fields=ProviderIds,Overview,RunTimeTicks,PrimaryImageAspectRatio,SeriesPrimaryImageTag,ParentThumbItemId,ParentThumbImageTag,ParentBackdropItemId,ParentBackdropImageTags,Genres,OfficialRating,ProductionYear,CommunityRating";
        var json=await new EmbyPeopleApi(client,session.UserId).Get(path,timeout.Token);
        if(!json.TryGetProperty("Items",out var values)||values.ValueKind!=JsonValueKind.Array)throw new InvalidDataException("Missing recent history rows");
        var options=new JsonSerializerOptions{PropertyNameCaseInsensitive=true};
        return values.EnumerateArray().Take(36).Select(v=>JsonSerializer.Deserialize<EmbyItem>(v.GetRawText(),options)).OfType<EmbyItem>().Where(i=>!string.IsNullOrWhiteSpace(i.Id)).ToArray();
    }
    static IReadOnlyList<EmbyItem> Merge(IReadOnlyList<EmbyItem> resume,IReadOnlyList<EmbyItem> history)
    {
        var result=resume.ToList();var seen=new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach(var candidate in history)
        {
            // Consume the newest title observation before filtering progress:
            // a latest completed-zero row must suppress older partial episodes.
            string key=Key(candidate);if(!seen.Add(key)||!Rewatch(candidate))continue;
            var current=result.FirstOrDefault(i=>Key(i).Equals(key,StringComparison.OrdinalIgnoreCase));
            var at=candidate.UserData?.LastPlayedDate;var before=current?.UserData?.LastPlayedDate;
            if(current!=null)
            {
                bool same=current.Id.Equals(candidate.Id,StringComparison.OrdinalIgnoreCase);
                if(same&&!(at.HasValue&&before.HasValue&&at.Value>before.Value))continue;
                if(!same&&current.UserData?.PlaybackPositionTicks>0&&!(at.HasValue&&before.HasValue&&at.Value>before.Value))continue;
                if(!same&&at.HasValue&&before.HasValue&&at.Value<before.Value)continue;
                result.Remove(current);
            }
            // Preserve the Resume endpoint's own relative order. Only insert
            // fresh history where explicit server dates establish its recency.
            int index=at.HasValue?result.FindIndex(i=>i.UserData?.LastPlayedDate is {} other&&at.Value>other):-1;
            if(index<0)result.Add(candidate);else result.Insert(index,candidate);
        }
        return ResumeSeriesMergePolicy.Collapse(result.Where(Show),18);
    }
    internal static string Caption(EmbyItem item,string fallback)
    {
        if(!Rewatch(item))return fallback;
        string Stamp(long ticks){var time=TimeSpan.FromTicks(Math.Max(0,ticks));return time.TotalHours>=1?$"{(int)time.TotalHours}:{time.Minutes:00}:{time.Seconds:00}":$"{(int)time.TotalMinutes}:{time.Seconds:00}";}
        string episode=item.Type=="Episode"&&item.IndexNumber is {} number?(item.ParentIndexNumber is {} season?$"第 {season} 季 · 第 {number} 集 · ":$"第 {number} 集 · "):"";
        return episode+"已看完 · 重看至 "+Stamp(item.UserData!.PlaybackPositionTicks)+(item.RunTimeTicks is >0?" / "+Stamp(item.RunTimeTicks.Value):"");
    }
}
