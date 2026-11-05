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
        internal Task<IReadOnlyList<EmbyItem>>? Next;
        internal IReadOnlyList<EmbyItem> NextItems=[];
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
        {state.Session=session;state.Client=client;state.Reading=null;state.Next=null;state.NextItems=[];state.At=default;}
        // Coalesce only overlapping/near-identical homepage reads. Foreground
        // resume refresh is already rate-limited; there is no new timer/poller.
        if(state.Reading==null||state.Reading.IsCompleted&&now-state.At>TimeSpan.FromSeconds(5))
        {
            if(state.Next?.IsCompletedSuccessfully==true)state.NextItems=state.Next.Result;
            state.At=now;state.Reading=Fetch(session,client);state.Next=FetchNext(session,client);
        }
        IReadOnlyList<EmbyItem> recent;var reading=state.Reading;
        try{recent=await reading;}
        catch(Exception error)
        {
            if(ReferenceEquals(state.Reading,reading))state.Reading=null;
            try{PlaybackTransport.Write("Warning","Library.Resume","服务端重看记录核对未完成，保留原继续观看读取；"+error.GetType().Name);}catch(Exception){}
            return resume;
        }
        if(!ReferenceEquals(session,Access.Get<EmbySession?>(page,"_session"))||!ReferenceEquals(client,Access.Get<EmbyApiClient?>(page,"_client")))throw new OperationCanceledException();
        // A slow/unsupported NextUp endpoint must not delay the existing row.
        // Completed results are reused by the next normal foreground refresh.
        var next=state.Next?.IsCompletedSuccessfully==true?state.Next.Result:state.NextItems;
        if(!ReferenceEquals(session,Access.Get<EmbySession?>(page,"_session"))||!ReferenceEquals(client,Access.Get<EmbyApiClient?>(page,"_client")))throw new OperationCanceledException();
        var result=Merge(resume,recent).ToList();
        foreach(var item in next)
        {
            if(item.Type!="Episode"||string.IsNullOrWhiteSpace(item.SeriesId)||item.UserData is not {Played:false,PlaybackPositionTicks:0})continue;
            if(!recent.Any(i=>Key(i)==Key(item))&&item.IndexNumber is not >1&&item.ParentIndexNumber is not >1)continue;
            if(result.Any(i=>Key(i)==Key(item)))continue;
            result.Add(item);
        }
        return ResumeSeriesMergePolicy.Collapse(result,18);
    }
    static async Task<IReadOnlyList<EmbyItem>> FetchNext(EmbySession session,EmbyApiClient client)
    {
        try{
            using var timeout=new CancellationTokenSource(TimeSpan.FromSeconds(6));
            var json=await new EmbyPeopleApi(client,session.UserId).Get($"Shows/NextUp?UserId={Uri.EscapeDataString(session.UserId)}&Limit=18&EnableUserData=true&EnableImages=true&ImageTypeLimit=1&EnableImageTypes=Primary,Thumb,Backdrop&Fields=RunTimeTicks,Overview,PrimaryImageAspectRatio,SeriesPrimaryImageTag,ParentThumbItemId,ParentThumbImageTag,ParentBackdropItemId,ParentBackdropImageTags",timeout.Token);
            if(!json.TryGetProperty("Items",out var rows)||rows.ValueKind!=JsonValueKind.Array)return [];
            var options=new JsonSerializerOptions{PropertyNameCaseInsensitive=true};
            return rows.EnumerateArray().Take(18).Select(v=>JsonSerializer.Deserialize<EmbyItem>(v.GetRawText(),options)).OfType<EmbyItem>().Where(i=>!string.IsNullOrWhiteSpace(i.Id)).ToArray();
        }catch(Exception error){PlaybackTransport.Write("Info","Library.Resume","下一集资料暂不可用，保留已有继续观看；"+error.GetType().Name);return [];}
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
        if(item.Type=="Episode"&&item.IndexNumber is {} next&&item.UserData is {Played:false,PlaybackPositionTicks:0})return (item.ParentIndexNumber is {} s?$"第 {s} 季 · ":"")+$"第 {next} 集 · 待播放";
        if(!Rewatch(item))return item.Type is "Series" or "Season"?fallback.Replace("已看完","已看至当前进度"):fallback;
        string Stamp(long ticks){var time=TimeSpan.FromTicks(Math.Max(0,ticks));return time.TotalHours>=1?$"{(int)time.TotalHours}:{time.Minutes:00}:{time.Seconds:00}":$"{(int)time.TotalMinutes}:{time.Seconds:00}";}
        string episode=item.Type=="Episode"&&item.IndexNumber is {} number?(item.ParentIndexNumber is {} season?$"第 {season} 季 · 第 {number} 集 · ":$"第 {number} 集 · "):"";
        return episode+"继续 "+Stamp(item.UserData!.PlaybackPositionTicks)+(item.RunTimeTicks is >0?" / "+Stamp(item.RunTimeTicks.Value):"");
    }
}
