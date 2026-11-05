using System.Collections.Concurrent;
using System.Net;
using System.Net.Http;
using System.Text;
using System.Text.Json;

namespace Yingyu.Update;

internal static class DanmakuSources
{
    static readonly HttpClient Http=new(new SocketsHttpHandler{AutomaticDecompression=DecompressionMethods.All,UseCookies=false,AllowAutoRedirect=false,ConnectTimeout=TimeSpan.FromSeconds(5),MaxConnectionsPerServer=2}){Timeout=Timeout.InfiniteTimeSpan};
    static readonly ConcurrentDictionary<string,(DateTimeOffset At,JsonElement[] Rows)> Searches=new();
    static readonly ConcurrentDictionary<string,(DateTimeOffset At,JsonElement Value)> Details=new();
    internal static bool ValidCid(string? cid)=>cid is {Length:>0 and <=20}&&ulong.TryParse(cid,out var value)&&value>0;
    internal static void Trace(string source,string stage,string reason,int count=0,int http=0)
    {
        // All tokens are fixed call-site literals. No titles, IDs, addresses,
        // response bodies or exception messages enter playback diagnostics.
        PlaybackTransport.Write("Info","Playback.Danmaku",$"版本=1.2.2; source={source}; stage={stage}; result={reason}; count={count}; http={http}");
    }
    internal static async Task Find(DanmakuIdentity id,DanmakuOptions options,Action<DanmakuTrack> publish,CancellationToken token,bool refresh=false,Action<IReadOnlyList<DanmakuCandidate>>? choices=null,string? query=null)
    {
        if(refresh){Searches.Clear();Details.Clear();PublicDanmaku.ClearSearches();}
        async Task Run(string name,string? cacheSlot,Func<CancellationToken,Task<DanmakuTrack?>> fetch)
        {
            using var budget=CancellationTokenSource.CreateLinkedTokenSource(token);
            budget.CancelAfter(TimeSpan.FromSeconds(30));
            try
            {
                if(!refresh&&cacheSlot is not null)
                {
                    var cached=await DanmakuStorage.Read(id,budget.Token,cacheSlot).ConfigureAwait(false);
                    if(cached is not null&&((name=="bilibili")==ValidCid(cached.StreamCid)))
                    {
                        publish(cached);Trace(name,"cache","hit",cached.Comments.Length);return;
                    }
                }
                var track=await fetch(budget.Token).ConfigureAwait(false);
                token.ThrowIfCancellationRequested();
                if(track is null){Trace(name,"match","no-confirmed-match");return;}
                publish(track);
                if(cacheSlot is not null)
                    await DanmakuStorage.Write(track with{Comments=track.StreamCid is null?track.Comments:[]},budget.Token,cacheSlot).ConfigureAwait(false);
            }
            catch(Exception e)when(IsSourceFailure(e)||e is UnauthorizedAccessException)
            {
                if(!token.IsCancellationRequested)Trace(name,"lookup",e is OperationCanceledException?"timeout":e.GetType().Name,http:(int?)((e as HttpRequestException)?.StatusCode)??0);
            }
        }
        var wanted=string.IsNullOrWhiteSpace(query)?id:id with{Title=query.Trim(),Aliases=[]};
        bool useCache=string.IsNullOrWhiteSpace(query);
        var catalogSearches=new ConcurrentDictionary<string,Lazy<Task<JsonElement[]>>>(StringComparer.Ordinal);
        async Task<DanmakuTrack?> PublicMatch(bool tencent,CancellationToken ct)
        {
            var videos=await PublicDanmaku.FindLinks(wanted,tencent?"qq":"qiyi",catalogSearches,ct).ConfigureAwait(false);
            var exact=await PublicDanmaku.Match(videos,wanted,id.Key,tencent,ct).ConfigureAwait(false);
            if(exact is not null||DanmakuProtocol.ContinuousTitle(wanted) is not {Length:>=2} continuousTitle)return exact;
            var continuous=await PublicDanmaku.FindLinks(wanted,tencent?"qq":"qiyi",catalogSearches,ct,continuousTitle).ConfigureAwait(false);
            var matched=await PublicDanmaku.Match(continuous,wanted,id.Key,tencent,ct,continuous:true).ConfigureAwait(false);
            if(matched is not null)Trace(tencent?"tencent":"iqiyi","match","continuous-episode");
            return matched;
        }
        async Task<DanmakuTrack?> BilibiliMatch(CancellationToken ct)
        {
            var direct=await MatchBilibili(wanted,id.Key,ct,choices).ConfigureAwait(false);
            if(direct is not null||wanted.Movie||wanted.Duration<=0
                ||Uri.TryCreate(wanted.Title,UriKind.Absolute,out var link)&&link.Scheme is "https" or "http")return direct;
            var ids=await PublicDanmaku.FindLinks(wanted,"bilibili1",catalogSearches,ct).ConfigureAwait(false);
            if(ids.Length==0&&DanmakuProtocol.ContinuousTitle(wanted) is {Length:>=2} continuous)
                ids=await PublicDanmaku.FindLinks(wanted,"bilibili1",catalogSearches,ct,continuous).ConfigureAwait(false);

            var candidates=new List<DanmakuCandidate>();
            foreach(var episodeId in ids)
            {
                try
                {
                    var show=await Detail("ep_id="+episodeId,ct).ConfigureAwait(false);
                    candidates.AddRange(Candidates(show,wanted,false,episodeId,requireDuration:true));
                }
                catch(Exception e)when(IsSourceFailure(e)&&!ct.IsCancellationRequested)
                {Trace("bilibili","catalog-detail",e.GetType().Name,http:(int?)((e as HttpRequestException)?.StatusCode)??0);}
            }
            var unique=candidates.DistinctBy(row=>row.Cid).Take(2).ToArray();
            if(unique.Length!=1)return null;
            Trace("bilibili","match","catalog-episode");
            return Stream(unique[0],id.Key);
        }
        await Task.WhenAll(
            Run("bilibili",useCache?"":null,BilibiliMatch),
            Run("tencent",null,ct=>PublicMatch(true,ct)),
            Run("iqiyi",null,ct=>PublicMatch(false,ct)),
            Run("compatible",useCache&&options.CompatibleApi.Length>0?"-compatible":null,ct=>Compatible(wanted,id.Key,options.CompatibleApi,query,ct))).ConfigureAwait(false);
    }

    internal static bool IsSourceFailure(Exception e)=>e is HttpRequestException or IOException or JsonException
        or OperationCanceledException or FormatException or System.Xml.XmlException or OverflowException or InvalidOperationException;

    internal static async Task<byte[]> Bytes(Uri uri,int limit,CancellationToken token,bool redirects=true)
    {
        for(int hop=0;hop<4;hop++)
        {
            if(uri.Scheme!="https"||uri.UserInfo.Length>0)throw new InvalidDataException("Invalid source scheme");
            using var deadline=CancellationTokenSource.CreateLinkedTokenSource(token);deadline.CancelAfter(TimeSpan.FromSeconds(10));
            using var request=new HttpRequestMessage(HttpMethod.Get,uri);
            // Use a normal public client UA; server rate limits still apply.
            request.Headers.UserAgent.ParseAdd("Mozilla/5.0");
            if(uri.Host.EndsWith(".bilibili.com",StringComparison.OrdinalIgnoreCase))request.Headers.Referrer=new Uri("https://www.bilibili.com/");
            using var response=await Http.SendAsync(request,HttpCompletionOption.ResponseHeadersRead,deadline.Token).ConfigureAwait(false);
            if(redirects&&((int)response.StatusCode is 301 or 302 or 303 or 307 or 308)){var location=response.Headers.Location??throw new InvalidDataException("Missing redirect");uri=location.IsAbsoluteUri?location:new Uri(uri,location);continue;}
            response.EnsureSuccessStatusCode();if(response.Content.Headers.ContentLength>limit)throw new InvalidDataException("Body too large");
            using var body=await response.Content.ReadAsStreamAsync(deadline.Token).ConfigureAwait(false);using var output=new MemoryStream();var buffer=new byte[16384];int count;
            while((count=await body.ReadAsync(buffer,deadline.Token).ConfigureAwait(false))>0){if(output.Length+count>limit)throw new InvalidDataException("Body too large");output.Write(buffer,0,count);}return output.ToArray();
        }
        throw new InvalidDataException("Too many redirects");
    }
    internal static async Task<JsonDocument> Json(string url,CancellationToken token,bool redirects=true)=>JsonDocument.Parse(await Bytes(new Uri(url),8*1024*1024,token,redirects).ConfigureAwait(false),new JsonDocumentOptions{MaxDepth=48});
    static async Task<JsonElement[]> Search(string title,string category,CancellationToken token)
    {
        string key=category+"|"+title;
        if(Searches.TryGetValue(key,out var entry)&&DateTimeOffset.UtcNow-entry.At<TimeSpan.FromMinutes(30))return entry.Rows;
        using var json=await Json("https://api.bilibili.com/x/web-interface/search/type?search_type="+category+"&keyword="+Uri.EscapeDataString(title),token).ConfigureAwait(false);
        if(DanmakuProtocol.Numeric(json.RootElement,"code")!=0){Trace("bilibili","search","api-refused");return [];}
        if(!json.RootElement.TryGetProperty("data",out var data)||!data.TryGetProperty("result",out var rows)||rows.ValueKind!=JsonValueKind.Array)return [];
        var results=rows.EnumerateArray().Take(40).Select(r=>r.Clone()).ToArray();if(Searches.Count>=32)Searches.Clear();if(results.Length>0)Searches[key]=(DateTimeOffset.UtcNow,results);Trace("bilibili","search","received",results.Length);return results;
    }
    static async Task<JsonElement> Detail(string key,CancellationToken token)
    {
        if(Details.TryGetValue(key,out var entry)&&DateTimeOffset.UtcNow-entry.At<TimeSpan.FromMinutes(2))return entry.Value;
        JsonElement show=default;
        try{
            using var json=await Json("https://api.bilibili.com/pgc/view/web/season?"+key,token).ConfigureAwait(false);
            if(DanmakuProtocol.Numeric(json.RootElement,"code")==0&&json.RootElement.TryGetProperty("result",out var value))show=value.Clone();
        }catch(HttpRequestException e){Trace("bilibili","detail","view-unavailable",http:(int?)e.StatusCode??0);}
        bool HasEpisodes(JsonElement value)=>value.ValueKind==JsonValueKind.Object&&value.TryGetProperty("episodes",out var eps)&&eps.ValueKind==JsonValueKind.Array&&eps.GetArrayLength()>0;
        if(!HasEpisodes(show))
        {
            using var section=await Json("https://api.bilibili.com/pgc/web/season/section?"+key,token).ConfigureAwait(false);
            if(DanmakuProtocol.Numeric(section.RootElement,"code")!=0||!section.RootElement.TryGetProperty("result",out var data)||!data.TryGetProperty("main_section",out var main)||!main.TryGetProperty("episodes",out var eps)||eps.ValueKind!=JsonValueKind.Array)throw new InvalidDataException("Missing episode metadata");
            var node=show.ValueKind==JsonValueKind.Object?System.Text.Json.Nodes.JsonNode.Parse(show.GetRawText())!.AsObject():new System.Text.Json.Nodes.JsonObject();
            node["episodes"]=System.Text.Json.Nodes.JsonNode.Parse(eps.GetRawText());show=JsonSerializer.SerializeToElement(node);
        }
        var result=show.Clone();if(Details.Count>=24)Details.Clear();Details[key]=(DateTimeOffset.UtcNow,result);return result;
    }
    static int Confidence(DanmakuIdentity id,double duration)=>duration>0&&id.Duration>0?100-(int)Math.Min(12,Math.Abs(duration-id.Duration)/10):85;
    static DanmakuTrack Stream(DanmakuCandidate choice,string identity)=>new("哔哩哔哩公开弹幕",identity,choice.Duration,[],choice.Confidence){StreamCid=choice.Cid,Partial=true};
    internal static DanmakuTrack Select(DanmakuCandidate choice,DanmakuIdentity id)=>Stream(choice,id.Key);
    static async Task<DanmakuTrack?> MatchBilibili(DanmakuIdentity id,string identity,CancellationToken token,Action<IReadOnlyList<DanmakuCandidate>>? choices)
    {
        // Explicit public links avoid repeating a failed keyword search. They
        // resolve public episode metadata; access checks remain server-owned.
        if(Uri.TryCreate(id.Title,UriKind.Absolute,out var uri)&&uri.Scheme=="https"&&uri.Host is "www.bilibili.com" or "bilibili.com")
        {
            var match=System.Text.RegularExpressions.Regex.Match(uri.AbsolutePath,@"^/bangumi/play/(ep|ss)([0-9]{1,16})/?$",System.Text.RegularExpressions.RegexOptions.None,TimeSpan.FromMilliseconds(50));
            if(!match.Success)return null;string key=(match.Groups[1].Value=="ep"?"ep_id=":"season_id=")+match.Groups[2].Value;
            var show=await Detail(key,token).ConfigureAwait(false);var result=Candidates(show,id,false,match.Groups[1].Value=="ep"?match.Groups[2].Value:null);
            if(result.Count==1)return Stream(result[0],identity);if(result.Count>1)choices?.Invoke(result);return null;
        }
        if(Uri.TryCreate(id.Title,UriKind.Absolute,out var link)&&link.Scheme is "http" or "https")return null;
        var triedSeasons=new HashSet<string>(StringComparer.Ordinal);
        foreach(string title in DanmakuProtocol.SearchTitles(id))
        {
            var results=new List<JsonElement>();
            foreach(string category in id.Movie?new[]{"media_ft"}:new[]{"media_bangumi","media_ft"})
            {
                try{results.AddRange(await Search(title,category,token).ConfigureAwait(false));}
                catch(Exception e)when(e is HttpRequestException or IOException or OperationCanceledException)
                {token.ThrowIfCancellationRequested();Trace("bilibili","search",e is OperationCanceledException?"timeout":e.GetType().Name,http:(int?)((e as HttpRequestException)?.StatusCode)??0);}
            }
            var candidates=new List<DanmakuCandidate>();
            foreach(var row in results.Where(r=>DanmakuProtocol.TitleMatches(id,DanmakuProtocol.String(r,"title"))))
            {
                string sid=DanmakuProtocol.String(row,"season_id");
                if(!ValidCid(sid)||!triedSeasons.Add(sid))continue;
                try
                {
                    var detail=await Detail("season_id="+sid,token).ConfigureAwait(false);
                    candidates.AddRange(Candidates(detail,id,true,titleFallback:DanmakuProtocol.String(row,"title")));
                }
                catch(Exception e)when(e is HttpRequestException or IOException or OperationCanceledException)
                {token.ThrowIfCancellationRequested();Trace("bilibili","detail",e.GetType().Name,http:(int?)((e as HttpRequestException)?.StatusCode)??0);}
                if(triedSeasons.Count>=6)break;
            }
            var ranked=candidates.GroupBy(c=>c.Cid).Select(g=>g.First()).OrderByDescending(c=>c.Confidence).Take(8).ToArray();
            if(ranked.Length>1&&ranked[0].Confidence-ranked[1].Confidence<4)
            {choices?.Invoke(ranked);Trace("bilibili","candidate","selection-required",ranked.Length);return null;}
            if(ranked.Length>0)return Stream(ranked[0],identity);
            if(triedSeasons.Count>=6)break;
        }
        return null;
    }
    static List<DanmakuCandidate> Candidates(JsonElement show,DanmakuIdentity id,bool strict,string? exactEpisode=null,string? titleFallback=null,bool requireDuration=false)
    {
        var output=new List<DanmakuCandidate>();string title=DanmakuProtocol.String(show,"title");if(string.IsNullOrWhiteSpace(title))title=titleFallback??"公开番剧";if(strict&&!DanmakuProtocol.TitleMatches(id,title))return output;
        JsonElement episodes;if(!show.TryGetProperty("episodes",out episodes)&&!(show.TryGetProperty("main_section",out var main)&&main.TryGetProperty("episodes",out episodes)))return output;
        if(episodes.ValueKind!=JsonValueKind.Array)return output;
        if(strict&&id.Movie){if(DanmakuProtocol.Numeric(show,"type")!=2||episodes.GetArrayLength()!=1)return output;if(id.Year>0&&show.TryGetProperty("publish",out var pub)&&int.TryParse(DanmakuProtocol.String(pub,"pub_time").Split('-')[0],out int year)&&year!=id.Year)return output;}
        foreach(var ep in episodes.EnumerateArray().Take(2000))
        {
            if(exactEpisode is not null?DanmakuProtocol.String(ep,"id")!=exactEpisode:!id.Movie&&!DanmakuProtocol.EpisodeMatches(DanmakuProtocol.String(ep,"title"),id.Episode))continue;
            string cid=DanmakuProtocol.String(ep,"cid");double duration=DanmakuProtocol.Numeric(ep,"duration")/1000;
            if(!ValidCid(cid)||requireDuration&&duration<=0||(strict||requireDuration)&&!DanmakuProtocol.DurationMatches(id.Duration,duration))continue;
            output.Add(new(DanmakuProtocol.Clean(title)+" · "+DanmakuProtocol.String(ep,"title")+" · "+DanmakuProtocol.String(ep,"long_title"),cid,duration>0?duration:id.Duration,Confidence(id,duration)));
        }
        return output;
    }
    internal static bool IsPlatformLink(string? query)
        => Uri.TryCreate(query?.Trim(),UriKind.Absolute,out var uri)&&uri.Scheme=="https"&&uri.UserInfo.Length==0
            && uri.IsDefaultPort && uri.Host is "v.qq.com" or "www.iqiyi.com" or "v.youku.com" or "www.mgtv.com";

    static async Task<DanmakuTrack?> Compatible(DanmakuIdentity id,string identity,string api,string? query,CancellationToken token)
    {
        if(string.IsNullOrEmpty(api)||new Uri(api).Host.Equals("api.dandanplay.net",StringComparison.OrdinalIgnoreCase))return null;
        async Task<DanmakuTrack?> ReadComments(string path)
        {
            try
            {
                using var json=await Json(api+path,token).ConfigureAwait(false);
                double duration=DanmakuProtocol.Numeric(json.RootElement,"videoDuration");
                if(!DanmakuProtocol.DurationMatches(id.Duration,duration))return null;
                var comments=DanmakuProtocol.JsonComments(json.RootElement);
                return comments.Length>0?new("兼容弹幕服务",identity,duration,comments,Confidence(id,duration)):null;
            }
            catch(HttpRequestException e){Trace("compatible","comments","http-failed",http:(int?)e.StatusCode??0);return null;}
        }
        if(IsPlatformLink(query))
            return await ReadComments("comment?format=json&duration=true&url="+Uri.EscapeDataString(new Uri(query!.Trim()).GetLeftPart(UriPartial.Path))).ConfigureAwait(false);
        if(Uri.TryCreate(id.Title,UriKind.Absolute,out var link)&&link.Scheme is "http" or "https")return null;
        var tried=new HashSet<string>(StringComparer.Ordinal);
        foreach(string title in DanmakuProtocol.SearchTitles(id))
        {
            using var search=await Json(api+"search/episodes?anime="+Uri.EscapeDataString(title)+"&episode="+id.Episode,token).ConfigureAwait(false);
            if(!search.RootElement.TryGetProperty("animes",out var shows)||shows.ValueKind!=JsonValueKind.Array)continue;
            foreach(var show in shows.EnumerateArray().Take(40))
            {
                string name=DanmakuProtocol.String(show,"animeTitle");
                if(!DanmakuProtocol.TitleMatches(id,name)&&!DanmakuProtocol.TitleMatches(id,DanmakuProtocol.StripPlatformLabel(name)))continue;
                string type=DanmakuProtocol.String(show,"typeDescription");
                if(id.Movie&&!type.Contains("电影")&&!type.Contains("剧场")&&!type.Contains("Movie",StringComparison.OrdinalIgnoreCase))continue;
                if(!show.TryGetProperty("episodes",out var episodes)||episodes.ValueKind!=JsonValueKind.Array)continue;
                foreach(var ep in episodes.EnumerateArray().Take(2000))
                {
                    if(!(id.Movie?episodes.GetArrayLength()==1:DanmakuProtocol.EpisodeMatches(DanmakuProtocol.String(ep,"episodeTitle"),id.Episode)))continue;
                    string key=DanmakuProtocol.String(ep,"episodeId");
                    if(key.Length is not (>0 and <160)||!tried.Add(key))continue;
                    var found=await ReadComments("comment/"+Uri.EscapeDataString(key)+"?format=json&duration=true&withRelated=true").ConfigureAwait(false);
                    if(found is not null)return found;
                    if(tried.Count>=6)return null;
                }
            }
        }
        return null;
    }
    internal static async Task Watch(DanmakuTrack selection,Func<double> position,Action<DanmakuTrack> publish,Action<string> state,CancellationToken token)
    {
        if(selection.PublicFeed is not null)
        {
            await PublicDanmaku.Watch(selection,position,publish,token).ConfigureAwait(false);return;
        }
        if(!ValidCid(selection.StreamCid))return;string cid=selection.StreamCid!;
        var segments=new Dictionary<int,DanmakuComment[]>();var retries=new Dictionary<int,(int Count,DateTimeOffset At)>();
        int window=-1;bool xmlTried=false;DanmakuComment[] xmlFallback=[];var lastState="";
        void Status(string value){if(lastState==value)return;lastState=value;state(value);}
        void Snapshot()=>publish(selection with{Comments=segments.Values.SelectMany(v=>v).Concat(xmlFallback.Where(c=>c.Time>=Math.Max(0,window-2)*360&&c.Time<(window+2)*360)).GroupBy(c=>((long)Math.Round(c.Time*5),c.Text,c.Mode)).Select(g=>g.First()).OrderBy(c=>c.Time).Take(80000).ToArray(),Partial=true});
        while(!token.IsCancellationRequested)
        {
            double current=position();if(!double.IsFinite(current)||current<0)current=0;
            int target=Math.Clamp((int)(current/360)+1,1,240);int last=selection.Duration>0?Math.Clamp((int)Math.Ceiling(selection.Duration/360),1,240):240;
            if(target!=window){window=target;foreach(var key in segments.Keys.Where(k=>k<target-1||k>target+2).ToArray())segments.Remove(key);foreach(var key in retries.Keys.Where(k=>Math.Abs(k-target)>3).ToArray())retries.Remove(key);if(segments.Count>0||xmlFallback.Length>0)Snapshot();}
            bool changed=false;
            foreach(int index in Enumerable.Range(Math.Max(1,target-1),Math.Max(0,Math.Min(last,target+2)-Math.Max(1,target-1)+1)).OrderBy(i=>Math.Abs(i-target)))
            {
                token.ThrowIfCancellationRequested();if(segments.ContainsKey(index)||retries.TryGetValue(index,out var retry)&&retry.At>DateTimeOffset.UtcNow)continue;
                if(Math.Clamp((int)(Math.Max(0,position())/360)+1,1,240)!=target)break;
                using var read=CancellationTokenSource.CreateLinkedTokenSource(token);
                var fetch=Segment(cid,index,read.Token);
                // Seek cancels the previous position's bounded network read.
                while(!fetch.IsCompleted){await Task.WhenAny(fetch,Task.Delay(250,token)).ConfigureAwait(false);if(token.IsCancellationRequested||Math.Clamp((int)(Math.Max(0,position())/360)+1,1,240)!=target){read.Cancel();break;}}
                try{
                    var rows=await fetch.ConfigureAwait(false);if(token.IsCancellationRequested)break;
                    segments[index]=rows;retries.Remove(index);changed=true;Snapshot();Status("按当前进度持续加载 · 已就绪 "+segments.Count+" 段");
                }catch(Exception e)when(e is HttpRequestException or IOException or OperationCanceledException or OverflowException or JsonException)
                {
                    token.ThrowIfCancellationRequested();int attempts=retries.TryGetValue(index,out var old)?old.Count+1:1;retries[index]=(attempts,DateTimeOffset.UtcNow.AddSeconds(Math.Min(120,Math.Pow(2,Math.Min(6,attempts))*3)));
                    Trace("bilibili","segment",e is OperationCanceledException?"read-cancelled":e.GetType().Name,attempts,(int?)((e as HttpRequestException)?.StatusCode)??0);
                    Status("部分分段暂不可用，保留已加载弹幕并稍后重试");
                    if(!xmlTried&&segments.Count==0)
                    {
                        xmlTried=true;
                        try{var bytes=await Bytes(new Uri("https://comment.bilibili.com/"+cid+".xml"),8*1024*1024,token).ConfigureAwait(false);var rows=DanmakuProtocol.Xml(bytes);if(rows.Length>0){xmlFallback=rows;Snapshot();Status("已加载公开 XML 弹幕，分段继续后台补齐");}}
                        catch(Exception error)when(error is HttpRequestException or IOException or OperationCanceledException or System.Xml.XmlException){token.ThrowIfCancellationRequested();Trace("bilibili","xml",error.GetType().Name,http:(int?)((error as HttpRequestException)?.StatusCode)??0);}
                    }
                }
                if(Math.Clamp((int)(Math.Max(0,position())/360)+1,1,240)!=target)break;
            }
            if(changed)Trace("bilibili","window","ready",segments.Count);
            await Task.Delay(1000,token).ConfigureAwait(false);
        }
    }
    static async Task<DanmakuComment[]> Segment(string cid,int index,CancellationToken token)
    {
        var cached=await DanmakuStorage.ReadSegment(cid,index,token).ConfigureAwait(false);if(cached is not null)return cached;
        var bytes=await Bytes(new Uri("https://api.bilibili.com/x/v2/dm/web/seg.so?type=1&oid="+cid+"&segment_index="+index),2*1024*1024,token).ConfigureAwait(false);
        var rows=DanmakuProtocol.Normalize(ParseSegment(bytes)).Where(c=>c.Time>=(index-1)*360&&c.Time<index*360).ToArray();
        try{await DanmakuStorage.WriteSegment(cid,index,rows,token).ConfigureAwait(false);}catch(Exception e)when(e is IOException or UnauthorizedAccessException){Trace("cache","segment","write-unavailable");}return rows;
    }
    // DmSegMobileReply.elems=1; DanmakuElem progress=2, mode=3,
    // color=5, content=7. Unknown protobuf fields are skipped by wire type.
    internal static DanmakuComment[] ParseSegment(byte[] bytes)
    {
        var output=new List<DanmakuComment>();int at=0;
        while(at<bytes.Length)
        {
            ulong tag=Varint(bytes,ref at);int field=(int)(tag>>3),wire=(int)(tag&7);if(field==0)throw new InvalidDataException("Invalid protobuf field");
            if(field==1&&wire==2)
            {
                int length=Length(bytes,ref at),end=checked(at+length);double time=0;int mode=1;uint color=0xffffff;string text="";
                while(at<end){ulong key=Varint(bytes,ref at);int f=(int)(key>>3),w=(int)(key&7);if(f==0)throw new InvalidDataException("Invalid protobuf field");
                    if(w==0){ulong value=Varint(bytes,ref at);if(f==2)time=value/1000d;else if(f==3)mode=checked((int)value);else if(f==5)color=checked((uint)value);}
                    else if(f==7&&w==2){int n=Length(bytes,ref at);if(n>2048||at+n>end)throw new InvalidDataException("Invalid comment text");text=Encoding.UTF8.GetString(bytes,at,n);at+=n;}
                    else Skip(bytes,ref at,w);
                    if(at>end)throw new InvalidDataException("Invalid comment boundary");
                }
                output.Add(new(time,mode,color,text));if(output.Count>=20000)break;
            }else Skip(bytes,ref at,wire);
        }
        return output.ToArray();
    }
    internal static ulong Varint(byte[] bytes,ref int at){ulong value=0;for(int shift=0;shift<64;shift+=7){if(at>=bytes.Length)throw new InvalidDataException("Truncated protobuf");byte b=bytes[at++];if(shift==63&&b>1)throw new InvalidDataException("Protobuf overflow");value|=(ulong)(b&127)<<shift;if(b<128)return value;}throw new InvalidDataException("Invalid protobuf integer");}
    internal static int Length(byte[] bytes,ref int at){int n=checked((int)Varint(bytes,ref at));if(n<0||n>bytes.Length-at)throw new InvalidDataException("Invalid protobuf length");return n;}
    internal static void Skip(byte[] bytes,ref int at,int wire){int n=wire switch{0=>0,1=>8,2=>Length(bytes,ref at),5=>4,_=>throw new InvalidDataException("Invalid protobuf wire type")};if(wire==0)Varint(bytes,ref at);else{if(n>bytes.Length-at)throw new InvalidDataException("Invalid protobuf boundary");at+=n;}}
}
