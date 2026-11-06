using System.Collections.Concurrent;
using System.Globalization;
using System.IO.Compression;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Xml;
using System.Xml.Linq;

namespace Yingyu.Update;

// The catalog resolves public episode links. Comment data is then fetched
// directly from the platform CDNs, with no accounts or media requests.
internal static class PublicDanmaku
{
    internal sealed record Segment(double Start,double End,string Url);
    internal sealed record Feed(string Site,Segment[] Segments)
    {
        internal string? SeedUrl{get;init;}
    }
    internal static string SourceName(string site)=>site switch
        {"qq"=>"tencent","qiyi"=>"iqiyi","imgo"=>"mgtv",_=>"bilibili"};
    static readonly ConcurrentDictionary<string,(DateTimeOffset At,JsonElement[] Rows)> Catalog=new();
    static readonly Regex TencentPath=new(@"^/(?:x/cover/[a-zA-Z0-9]+/|x/page/)([a-zA-Z0-9]{6,24})\.html$",RegexOptions.None,TimeSpan.FromMilliseconds(50));
    static readonly Regex TencentCoverPath=new(@"^/x/cover/([a-zA-Z0-9]{6,24})(?:/[a-zA-Z0-9]{6,24})?\.html$",
        RegexOptions.None,TimeSpan.FromMilliseconds(50));
    static readonly Regex TencentVideo=new(@"^[a-zA-Z0-9]{6,24}$",RegexOptions.None,TimeSpan.FromMilliseconds(50));
    static readonly Regex IqiyiPath=new(@"^/v_([a-zA-Z0-9]{1,32})\.html$",RegexOptions.None,TimeSpan.FromMilliseconds(50));
    static readonly Regex MangoPath=new(@"^/b/([0-9]{1,12}/[0-9]{1,12})\.html$",RegexOptions.None,TimeSpan.FromMilliseconds(50));
    static readonly Regex BilibiliEpisodePath=new(@"^/bangumi/play/ep([0-9]{1,16})/?$",RegexOptions.None,TimeSpan.FromMilliseconds(50));
    static readonly Regex SegmentPath=new(@"^(?:t/v1/)?\d{1,9}/\d{1,9}$",RegexOptions.None,TimeSpan.FromMilliseconds(50));

    internal static void ClearSearches()=>Catalog.Clear();
    static JsonElement Field(JsonElement e,string key)=>e.ValueKind==JsonValueKind.Object&&e.TryGetProperty(key,out var v)?v:default;
    static string Text(JsonElement e,string key)=>DanmakuProtocol.String(e,key);
    static double Number(JsonElement e,string key)=>DanmakuProtocol.Numeric(e,key);
    static Task<JsonDocument> Json(string url,CancellationToken token)=>DanmakuSources.Json(url,token,redirects:false);

    internal static string? DirectSite(string? url)
        =>new[]{"qq","qiyi","imgo"}.FirstOrDefault(site=>VideoId(url,site) is not null);
    internal static bool IsDirectLink(string? url)=>DirectSite(url) is not null;
    static string? VideoId(string? url,string site,bool catalog=false)
    {
        if(!Uri.TryCreate(url,UriKind.Absolute,out var uri)||uri.Scheme!="https"&&(!catalog||uri.Scheme!="http")||!uri.IsDefaultPort
            ||uri.UserInfo.Length!=0)return null;
        Regex? path=site switch
        {
            "qq" when uri.Host=="v.qq.com"=>TencentPath,
            "qiyi" when uri.Host=="www.iqiyi.com"=>IqiyiPath,
            "imgo" when uri.Host=="www.mgtv.com"=>MangoPath,
            "bilibili1" when uri.Host is "www.bilibili.com" or "bilibili.com"=>BilibiliEpisodePath,
            _=>null
        };
        if(path is null)return null;
        var match=path.Match(uri.AbsolutePath);
        return match.Success?match.Groups[1].Value:null;
    }

    static async Task<JsonElement[]> Search(string title,CancellationToken token)
    {
        if(Catalog.TryGetValue(title,out var cached)&&DateTimeOffset.UtcNow-cached.At<TimeSpan.FromMinutes(10))return cached.Rows;
        using var json=await Json("https://api.so.360kan.com/index?force_v=1&from=&pageno=1&v_ap=1&tab=all&kw="+Uri.EscapeDataString(title),token).ConfigureAwait(false);
        var rows=Field(Field(Field(json.RootElement,"data"),"longData"),"rows");
        if(rows.ValueKind!=JsonValueKind.Array)return [];
        var result=rows.EnumerateArray().Take(40).Select(row=>row.Clone()).ToArray();
        if(result.Length>0)
        {
            if(Catalog.Count>=24)Catalog.Clear();
            Catalog[title]=(DateTimeOffset.UtcNow,result);
        }
        return result;
    }

    internal static Func<string,CancellationToken,Task<JsonElement[]>> ShareCatalog(CancellationToken lifetime)
    {
        var requests=new ConcurrentDictionary<string,Lazy<Task<JsonElement[]>>>(StringComparer.Ordinal);
        return (title,token)=>requests.GetOrAdd(title,key=>new Lazy<Task<JsonElement[]>>(
            ()=>Search(key,lifetime))).Value.WaitAsync(token);
    }

    internal static async Task<string[]> FindLinks(DanmakuIdentity id,string site,
        Func<string,CancellationToken,Task<JsonElement[]>> search,CancellationToken token,string? continuousTitle=null)
    {
        if(Uri.TryCreate(id.Title,UriKind.Absolute,out var url)&&url.Scheme is "https" or "http")
            return VideoId(id.Title,site) is {} direct?[direct]:[];

        var videos=new HashSet<string>(StringComparer.Ordinal);
        var tried=new HashSet<string>(StringComparer.Ordinal);
        IEnumerable<string> titles=continuousTitle is null?DanmakuProtocol.SearchTitles(id):
            new[]{continuousTitle+" 年番",continuousTitle};
        foreach(var title in titles)
        {
            JsonElement[] rows;
            try
            {
                rows=await search(title,token).ConfigureAwait(false);
            }
            catch(Exception e)when(DanmakuSources.IsSourceFailure(e)&&!token.IsCancellationRequested)
            {DanmakuSources.Trace("public-catalog","search",e.GetType().Name,http:(int?)((e as HttpRequestException)?.StatusCode)??0);continue;}
            foreach(var row in rows)
            {
                string category=Text(row,"cat_name"),candidate=Text(row,"titleTxt");
                if(!id.Movie&&id.Animation&&category!="动漫")continue;
                double year=Number(row,"year");
                if(continuousTitle is null&&!id.Movie&&id.Season<=1&&id.CatalogYear>0&&year>0&&year!=id.CatalogYear)continue;
                double tmdb=Number(row,"tmdb_id");
                if(id.TmdbId>0&&tmdb>0&&tmdb!=id.TmdbId)continue;
                if(continuousTitle is null?!DanmakuProtocol.TitleMatches(id,candidate):
                    category!="动漫"||!DanmakuProtocol.ContinuousTitleMatches(continuousTitle,candidate))continue;
                var playlinks=Field(row,"playlinks");
                if(id.Movie)
                {
                    if(category!="电影"||id.Year>0&&Number(row,"year")!=id.Year)continue;
                    if(VideoId(Text(playlinks,site),site,catalog:true) is {} movie)videos.Add(movie);
                    continue;
                }
                if(playlinks.ValueKind==JsonValueKind.Object&&Field(playlinks,site).ValueKind==JsonValueKind.Undefined
                    &&Text(row,"seriesSite")!=site)continue;
                int cat=category switch{"电视剧"=>2,"动漫"=>4,_=>0};
                string entity=Text(row,"en_id");
                if(cat==0||!Regex.IsMatch(entity,@"^[A-Za-z0-9_-]{1,64}$")||tried.Count>=3||!tried.Add(entity))continue;
                if(await Episode(cat,entity,id.Episode,site,token,continuousTitle).ConfigureAwait(false) is {} episode)videos.Add(episode);
            }
            if(continuousTitle is null&&videos.Count>0)break;
        }
        DanmakuSources.Trace(SourceName(site),
            "catalog",continuousTitle is null?"exact-episode-links":"continuous-episode-links",videos.Count);
        return videos.Take(4).ToArray();
    }

    // A catalog landing link is only a way into the platform's official
    // season metadata. Its episode number is never used as the selection.
    internal static async Task<string[]> BilibiliShowSeeds(DanmakuIdentity id,
        Func<string,CancellationToken,Task<JsonElement[]>> search,CancellationToken token)
    {
        var seeds=new HashSet<string>(StringComparer.Ordinal);
        foreach(string query in DanmakuProtocol.SearchTitles(id))
        {
            try
            {
                var rows=await search(query,token).ConfigureAwait(false);
                foreach(var row in rows)
                {
                    string category=Text(row,"cat_name"),title=Text(row,"titleTxt");
                    double year=Number(row,"year");
                    if(id.Movie?category!="电影"||id.Year>0&&year>0&&year!=id.Year
                        :category is not ("动漫" or "电视剧")||id.Animation&&category!="动漫")continue;
                    if(!DanmakuProtocol.SeriesTitleMatches(id,title)
                        &&!DanmakuProtocol.SeasonNameMatches(id,title))continue;
                    if(VideoId(Text(Field(row,"playlinks"),"bilibili1"),"bilibili1",catalog:true) is {} episode)
                        seeds.Add(episode);
                    if(seeds.Count>=4)return seeds.ToArray();
                }
            }
            catch(Exception e)when(DanmakuSources.IsSourceFailure(e)&&!token.IsCancellationRequested)
            {DanmakuSources.Trace("bilibili","catalog-family",e.GetType().Name);}
        }
        return seeds.ToArray();
    }

    static async Task<string?> Episode(int cat,string entity,int episode,string site,CancellationToken token,string? continuousTitle)
    {
        try
        {
            string number=episode.ToString(CultureInfo.InvariantCulture);
            using var json=await Json($"https://api.web.360kan.com/v1/detail?cat={cat}&id={entity}&site={site}&start={number}&end={number}",token).ConfigureAwait(false);
            var data=Field(json.RootElement,"data");
            if(continuousTitle is not null&&(!DanmakuProtocol.ContinuousTitleMatches(continuousTitle,Text(data,"title"))
                ||Number(Field(data,"allupinfo"),site)<DanmakuProtocol.ContinuousEpisodeFloor))return null;
            var rows=Field(Field(data,"allepidetail"),site);
            if(rows.ValueKind!=JsonValueKind.Array)return null;
            foreach(var row in rows.EnumerateArray().Take(2500))
                if(Number(row,"playlink_num")==episode&&VideoId(Text(row,"url"),site,catalog:true) is {} video)return video;
        }
        catch(Exception e)when(DanmakuSources.IsSourceFailure(e)&&!token.IsCancellationRequested)
        {DanmakuSources.Trace("public-catalog","episode",e.GetType().Name,http:(int?)((e as HttpRequestException)?.StatusCode)??0);}
        return null;
    }

    internal sealed record TencentEpisode(string Video,double Duration);

    internal static async Task<TencentEpisode?> FindTencentEpisode(DanmakuIdentity id,
        Func<string,CancellationToken,Task<JsonElement[]>> search,string? continuousTitle,CancellationToken token)
    {
        if(id.Movie||id.Duration<=0)return null;
        var covers=new HashSet<string>(StringComparer.Ordinal);
        using(var direct=CancellationTokenSource.CreateLinkedTokenSource(token))
        {
            direct.CancelAfter(TimeSpan.FromSeconds(4));
            try
            {
                var queries=continuousTitle is null
                    ? DanmakuProtocol.SearchTitles(id)
                    : id.AnnualEdition?new[]{continuousTitle+"年番",continuousTitle}
                    :new[]{continuousTitle,continuousTitle+"年番"};
                foreach(string query in queries.Take(2))
                {
                    var entries=await SearchTencent(query,direct.Token).ConfigureAwait(false);
                    DanmakuSources.Trace("tencent","official-search","catalog-rows",entries.Length);
                    foreach(var entry in entries)
                    {
                        string cover=Text(Field(entry,"doc"),"id");
                        var info=Field(entry,"videoInfo");
                        string name=DanmakuProtocol.Clean(Text(info,"title"));
                        int type=(int)Number(info,"videoType");
                        double year=Number(info,"year");
                        if(type is not (2 or 3)||id.Animation&&type!=3||year<=0
                            ||!TencentVideo.IsMatch(cover)
                            ||id.AnnualEdition&&!name.EndsWith("年番",StringComparison.Ordinal))continue;
                        bool exact=DanmakuProtocol.TitleMatches(id,name)
                            &&(id.Season>1||id.CatalogYear<=0||year==id.CatalogYear);
                        bool continuous=type==3&&continuousTitle is not null
                            &&DanmakuProtocol.ContinuousTitleMatches(continuousTitle,name);
                        if((!exact&&!continuous)||!covers.Add(cover))continue;
                        var found=PickTencentSearchEpisode(info,cover,id,exact)
                            ??await TencentCoverEpisode(cover,null,id,exact,continuousTitle,direct.Token)
                                .ConfigureAwait(false);
                        if(found is not null){DanmakuSources.Trace("tencent","official-search","verified-episode",1);return found;}
                        if(covers.Count>=2)break;
                    }
                    if(covers.Count>=2)break;
                }
            }
            catch(Exception e)when(DanmakuSources.IsSourceFailure(e)&&!token.IsCancellationRequested)
            {DanmakuSources.Trace("tencent","official-search",e is OperationCanceledException?"timeout":e.GetType().Name,http:(int?)((e as HttpRequestException)?.StatusCode)??0);}
        }
        covers.Clear();
        var titles=DanmakuProtocol.SearchTitles(id);
        if(continuousTitle is {Length:>=2})
            titles=titles.Concat(new[]{continuousTitle+" 年番",continuousTitle});
        foreach(var title in titles.Distinct(StringComparer.OrdinalIgnoreCase))
        {
            try
            {
                var rows=await search(title,token).ConfigureAwait(false);
                foreach(var row in rows)
                {
                    string category=Text(row,"cat_name"),name=Text(row,"titleTxt");
                    if(category is not ("动漫" or "电视剧")||id.Animation&&category!="动漫")continue;
                    double year=Number(row,"year"),tmdb=Number(row,"tmdb_id");
                    if(id.TmdbId>0&&tmdb>0&&tmdb!=id.TmdbId)continue;
                    if(id.AnnualEdition&&!name.TrimEnd().EndsWith("年番",StringComparison.Ordinal))continue;
                    bool exact=DanmakuProtocol.TitleMatches(id,name)
                        &&(id.Season>1||id.CatalogYear<=0||year<=0||year==id.CatalogYear);
                    bool continuous=category=="动漫"&&continuousTitle is {Length:>=2}
                        &&DanmakuProtocol.ContinuousTitleMatches(continuousTitle,name);
                    if(!exact&&!continuous)continue;
                    string address=Text(Field(row,"playlinks"),"qq");
                    if(!Uri.TryCreate(address,UriKind.Absolute,out var uri)||uri.Host!="v.qq.com"
                        ||uri.Scheme is not ("http" or "https")||!uri.IsDefaultPort||uri.UserInfo.Length!=0)continue;
                    var match=TencentCoverPath.Match(uri.AbsolutePath);
                    if(!match.Success||!covers.Add(match.Groups[1].Value))continue;
                    var candidate=await TencentCoverEpisode(match.Groups[1].Value,VideoId(address,"qq",catalog:true),
                        id,exact,continuousTitle,token).ConfigureAwait(false);
                    if(candidate is not null)return candidate;
                    if(covers.Count>=3)return null;
                }
            }
            catch(Exception e)when(DanmakuSources.IsSourceFailure(e)&&!token.IsCancellationRequested)
            {DanmakuSources.Trace("tencent","official-episode",e.GetType().Name,http:(int?)((e as HttpRequestException)?.StatusCode)??0);}
        }
        DanmakuSources.Trace("tencent","official-episode","no-exact-episode");
        return null;
    }

    static async Task<JsonElement[]> SearchTencent(string title,CancellationToken token)
    {
        const string endpoint="https://pbaccess.video.qq.com/trpc.videosearch.mobile_search.MultiTerminalSearch/MbSearch?vplatform=2";
        var body=JsonSerializer.Serialize(new Dictionary<string,object>
        {
            ["version"]="25071701",["clientType"]=1,["query"]=title,["pagenum"]=0,["pagesize"]=20,["isneedQc"]=true,
            ["extraInfo"]=new Dictionary<string,string>{["multi_terminal_pc"]="1",["themeType"]="1",["sugRelatedIds"]="{}"}
        });
        using var json=JsonDocument.Parse(await DanmakuSources.Bytes(new Uri(endpoint),2*1024*1024,token,
            redirects:false,jsonBody:body,tencentQuery:title).ConfigureAwait(false),new JsonDocumentOptions{MaxDepth=48});
        if(Number(json.RootElement,"ret")!=0)return [];
        var data=Field(json.RootElement,"data");
        var boxes=Field(data,"areaBoxList");
        IEnumerable<JsonElement> Rows(JsonElement box)
        {
            var items=Field(box,"itemList");
            return items.ValueKind==JsonValueKind.Array?items.EnumerateArray().Take(24):[];
        }
        var normal=Rows(Field(data,"normalList"));
        var other=boxes.ValueKind==JsonValueKind.Array?boxes.EnumerateArray().Take(6).SelectMany(Rows):[];
        return normal.Concat(other).Select(row=>row.Clone()).ToArray();
    }

    static TencentEpisode? PickTencentSearchEpisode(JsonElement info,string cover,DanmakuIdentity id,bool exact)
    {
        var sites=Field(info,"episodeSites");
        if(sites.ValueKind!=JsonValueKind.Array)return null;
        var matches=new Dictionary<string,double>(StringComparer.Ordinal);
        foreach(var site in sites.EnumerateArray().Take(8))
        {
            if(Text(site,"enName")!="qq"||!exact&&Number(site,"totalEpisode")<DanmakuProtocol.ContinuousEpisodeFloor)continue;
            var list=Field(site,"episodeInfoList");
            if(list.ValueKind!=JsonValueKind.Array)continue;
            foreach(var row in list.EnumerateArray().Take(200))
            {
                string video=Text(row,"id"),address=Text(row,"url");
                double duration=Number(row,"duration");
                if(Number(row,"title")!=id.Episode||duration is <=90 or >86400
                    ||!DanmakuProtocol.DurationMatches(id.Duration,duration)||!TencentVideo.IsMatch(video)
                    ||VideoId(address,"qq",catalog:true)!=video||!Uri.TryCreate(address,UriKind.Absolute,out var url)
                    ||TencentCoverPath.Match(url.AbsolutePath).Groups[1].Value!=cover)continue;
                matches.TryAdd(video,duration);
            }
        }
        if(matches.Count!=1)return null;
        var match=matches.Single();
        DanmakuSources.Trace("tencent","official-episode","verified-search-episode",1);
        return new(match.Key,match.Value);
    }

    static async Task<TencentEpisode?> TencentCoverEpisode(string cover,string? video,DanmakuIdentity id,
        bool exact,string? continuousTitle,CancellationToken token)
    {
        async Task<JsonDocument> Page(string? context=null)
        {
            var parameters=new Dictionary<string,string>(StringComparer.Ordinal)
                {["req_from"]="web_vsite",["cid"]=cover,["vid"]=video??""};
            if(context is not null)
            {
                foreach(string field in context.Split('&'))
                {
                    int equals=field.IndexOf('=');
                    if(equals>0&&!parameters.ContainsKey(field[..equals]))
                        parameters.Add(field[..equals],field[(equals+1)..]);
                }
            }
            const string endpoint="https://pbaccess.video.qq.com/trpc.vector_layout.page_view.PageService/getPage?video_appid=3000010&vversion_platform=2";
            var bypass=new Dictionary<string,object>
            {
                ["scene"]="desk_detail",
                ["params"]=new Dictionary<string,string>{["caller_id"]="3000010",["platform_id"]="2"}
            };
            var body=JsonSerializer.Serialize(new Dictionary<string,object>
            {
                ["page_params"]=parameters,
                ["page_bypass_params"]=bypass,
                ["page_context"]=new Dictionary<string,string>()
            });
            return JsonDocument.Parse(await DanmakuSources.Bytes(new Uri(endpoint),4*1024*1024,token,
                redirects:false,jsonBody:body).ConfigureAwait(false),new JsonDocumentOptions{MaxDepth=48});
        }

        using var page=await Page().ConfigureAwait(false);
        var introduction=TencentCard(page,"pc_introduction");
        var info=TencentRows(introduction).FirstOrDefault();
        var title=Text(info,"title");
        bool exactTitle=exact&&DanmakuProtocol.TitleMatches(id,title);
        if(!exactTitle&&(continuousTitle is null||Number(info,"type")!=3
            ||Number(info,"episode_all")<DanmakuProtocol.ContinuousEpisodeFloor
            ||!DanmakuProtocol.ContinuousTitleMatches(continuousTitle,title)))return null;
        double year=Number(info,"year");
        if(exactTitle&&id.Season<=1&&id.CatalogYear>0&&year>0&&year!=id.CatalogYear)return null;

        var card=TencentCard(page,"pc_web_episode_list");
        TencentEpisode? Pick(JsonElement list)
        {
            var candidates=TencentRows(list).Where(row=>Text(row,"cid")==cover&&Number(row,"title")==id.Episode
                    &&TencentVideo.IsMatch(Text(row,"vid"))&&Number(row,"duration") is >90 and <=86400
                    &&DanmakuProtocol.DurationMatches(id.Duration,Number(row,"duration")))
                .Select(row=>new TencentEpisode(Text(row,"vid"),Number(row,"duration")))
                .DistinctBy(row=>row.Video).Take(2).ToArray();
            return candidates.Length==1?candidates[0]:null;
        }
        if(card.ValueKind!=JsonValueKind.Object)
        {DanmakuSources.Trace("tencent","official-episode","missing-episode-card");return null;}
        var episode=Pick(card);
        string tabs=Text(Field(card,"params"),"tabs");
        if(episode is null&&tabs.Length is >0 and <=65536)
        {
            using var ranges=JsonDocument.Parse(tabs);
            if(ranges.RootElement.ValueKind!=JsonValueKind.Array)return null;
            var range=ranges.RootElement.EnumerateArray().Take(200).FirstOrDefault(row=>
                Number(row,"begin")<=id.Episode&&Number(row,"end")>=id.Episode);
            string context=Text(range,"page_context");
            if(context.Length is >0 and <=4096&&context.Split('&').Contains("cid="+cover))
            {
                using var next=await Page(context).ConfigureAwait(false);
                episode=Pick(TencentCard(next,"pc_web_episode_list"));
            }
        }
        if(episode is not null)DanmakuSources.Trace("tencent","official-episode","exact-episode",1);
        return episode;
    }

    static JsonElement TencentCard(JsonDocument page,string type)
    {
        var cards=Field(Field(page.RootElement,"data"),"CardList");
        return cards.ValueKind==JsonValueKind.Array
            ?cards.EnumerateArray().Take(40).FirstOrDefault(card=>Text(card,"type")==type):default;
    }

    static IEnumerable<JsonElement> TencentRows(JsonElement card)
    {
        var children=Field(card,"children_list");
        if(children.ValueKind!=JsonValueKind.Object)yield break;
        foreach(var child in children.EnumerateObject().Take(200))
        {
            var rows=Field(child.Value,"cards");
            if(rows.ValueKind==JsonValueKind.Array)
                foreach(var row in rows.EnumerateArray().Take(12))yield return Field(row,"params");
        }
    }

    internal static async Task<DanmakuTrack?> Match(string[] videos,DanmakuIdentity wanted,string identity,string site,CancellationToken token,bool continuous=false,double confirmedDuration=0)
    {
        string name=SourceName(site);
        DanmakuTrack? matched=null;
        foreach(var video in videos)
        {
            try
            {
                var (duration,segments)=site switch
                {
                    "qq"=>await TencentSegments(video,token).ConfigureAwait(false),
                    "qiyi"=>await IqiyiSegments(video,token).ConfigureAwait(false),
                    _=>MangoSegments(video,wanted.Duration)
                };
                if(confirmedDuration>0)duration=confirmedDuration;
                if(segments.Length==0){DanmakuSources.Trace(name,"match","no-segments");continue;}
                if(continuous&&(wanted.Duration<=0||duration<=0)||!DanmakuProtocol.DurationMatches(wanted.Duration,duration))
                {DanmakuSources.Trace(name,"match","duration-mismatch");continue;}
                if(matched is not null){DanmakuSources.Trace(name,"match","ambiguous-edition");return null;}
                string label=site switch{"qq"=>"腾讯视频","qiyi"=>"爱奇艺",_=>"芒果 TV"};
                matched=new(label,identity,duration,[],85)
                    {PublicFeed=new(site,segments),Partial=true};
            }
            catch(Exception e)when(DanmakuSources.IsSourceFailure(e)&&!token.IsCancellationRequested)
            {DanmakuSources.Trace(name,"detail",e.GetType().Name,http:(int?)((e as HttpRequestException)?.StatusCode)??0);}
        }
        return matched;
    }

    static async Task<(double,Segment[])> TencentSegments(string video,CancellationToken token)
    {
        using var json=await Json("https://dm.video.qq.com/barrage/base/"+video,token).ConfigureAwait(false);
        var index=Field(json.RootElement,"segment_index");
        IEnumerable<JsonElement> items=index.ValueKind switch
        {
            JsonValueKind.Object=>index.EnumerateObject().Select(p=>p.Value),
            JsonValueKind.Array=>index.EnumerateArray(),
            _=>[]
        };
        var segments=new List<Segment>();
        foreach(var item in items.Take(3000))
        {
            string path=Text(item,"segment_name");
            if(!SegmentPath.IsMatch(path))continue;
            double start=Number(item,"segment_start")/1000;
            double end=double.Parse(path.AsSpan(path.LastIndexOf('/')+1),CultureInfo.InvariantCulture)/1000;
            if(start<0||end<=start||end>86460)continue;
            segments.Add(new(start,end,"https://dm.video.qq.com/barrage/segment/"+video+"/"+path));
        }
        if(segments.Count==0)return (0,[]);
        // The final 30-second bucket is an estimate, not the true video length.
        return (segments.Max(s=>s.End),segments.OrderBy(s=>s.Start).ToArray());
    }

    static async Task<(double,Segment[])> IqiyiSegments(string video,CancellationToken token)
    {
        string tvId=video;
        if(!DanmakuSources.ValidCid(tvId))
        {
            using var decoded=await Json("https://pcw-api.iq.com/api/decode/"+video+"?platformId=3&modeCode=intl&langCode=sg",token).ConfigureAwait(false);
            tvId=Text(decoded.RootElement,"data");
        }
        if(!DanmakuSources.ValidCid(tvId))return (0,[]);
        using var info=await Json("https://pcw-api.iqiyi.com/video/video/baseinfo/"+tvId,token).ConfigureAwait(false);
        var data=Field(info.RootElement,"data");
        double duration=Number(data,"durationSec");
        if(duration<=0||duration>86400||Field(data,"displayBarrage").ValueKind==JsonValueKind.False)return (0,[]);
        string tail=tvId.PadLeft(4,'0')[^4..];
        var segments=new Segment[(int)Math.Ceiling(duration/60)];
        for(int i=0;i<segments.Length;i++)
        {
            string key=FormattableString.Invariant($"{tvId}_60_{i+1}");
            string hash=Convert.ToHexStringLower(MD5.HashData(Encoding.ASCII.GetBytes(key+"cbzuw1259a")))[^8..];
            segments[i]=new(i*60,(i+1)*60,$"https://cmts.iqiyi.com/bullet/{tail[..2]}/{tail[2..]}/{key}_{hash}.br");
        }
        return (duration,segments);
    }

    static (double,Segment[]) MangoSegments(string key,double duration)
    {
        // The catalog identifies the exact episode. Local duration only bounds reads.
        if(duration<=0||duration>86400)return (0,[]);
        string[] ids=key.Split('/');
        var segments=new Segment[(int)Math.Ceiling(duration/60)];
        for(int i=0;i<segments.Length;i++)
        {
            string url=FormattableString.Invariant($"https://galaxy.bz.mgtv.com/rdbarrage?version=2.0.0&vid={ids[1]}&cid={ids[0]}&time={i*60000}&abroad=0&platform=0");
            segments[i]=new(i*60,(i+1)*60,url);
        }
        return (0,segments);
    }

    internal static async Task<DanmakuTrack?> Confirm(DanmakuTrack track,double position,
        Func<DanmakuComment,bool> usable,CancellationToken token)
    {
        var feed=track.PublicFeed!;
        // Introductions can be quiet. Probe a later opening segment as well
        // before rejecting a feed that returned a valid but empty response.
        var candidates=feed.Segments.OrderBy(s=>s.Start<=position&&s.End>position?0:1)
            .ThenBy(s=>Math.Abs(s.Start-position)).Take(2)
            .Append(feed.Segments[0]).Append(feed.Segments.FirstOrDefault(s=>s.Start>=60)??feed.Segments[0])
            .DistinctBy(s=>s.Url);
        foreach(var segment in candidates)
        {
            try
            {
                var rows=await ReadSegment(feed,segment,token).ConfigureAwait(false);
                if(rows.Any(usable))return track with{Comments=rows,PublicFeed=feed with{SeedUrl=segment.Url}};
            }
            catch(Exception e)when(DanmakuSources.IsSourceFailure(e)&&!token.IsCancellationRequested){}
        }
        return null;
    }

    internal static async Task Watch(DanmakuTrack selection,Func<double> position,Action<DanmakuTrack> publish,CancellationToken token)
    {
        var feed=selection.PublicFeed!;
        var loaded=new Dictionary<string,DanmakuComment[]>(StringComparer.Ordinal);
        if(feed.SeedUrl is {} seed)loaded[seed]=selection.Comments;
        var retry=new Dictionary<string,DateTimeOffset>(StringComparer.Ordinal);
        while(true)
        {
            token.ThrowIfCancellationRequested();
            double now=position();
            var wanted=feed.Segments.Where(s=>s.End>now-35&&s.Start<now+95)
                .OrderBy(s=>s.Start<=now&&s.End>now?0:s.Start>now?1:2).ThenBy(s=>Math.Abs(s.Start-now)).Take(6).ToArray();
            var urls=wanted.Select(s=>s.Url).ToHashSet(StringComparer.Ordinal);
            bool changed=false;
            foreach(var key in loaded.Keys.Where(key=>!urls.Contains(key)).ToArray())changed|=loaded.Remove(key);
            foreach(var key in retry.Keys.Where(key=>!urls.Contains(key)).ToArray())retry.Remove(key);
            void Publish()=>publish(selection with{Comments=DanmakuProtocol.Normalize(loaded.Values.SelectMany(v=>v))});
            if(changed)Publish();
            foreach(var segment in wanted)
            {
                if(Math.Abs(position()-now)>25)break;
                if(loaded.ContainsKey(segment.Url)||retry.TryGetValue(segment.Url,out var next)&&next>DateTimeOffset.UtcNow)continue;
                using var read=CancellationTokenSource.CreateLinkedTokenSource(token);
                var fetch=ReadSegment(feed,segment,read.Token);
                while(!fetch.IsCompleted)
                {
                    await Task.WhenAny(fetch,Task.Delay(250,token)).ConfigureAwait(false);
                    if(token.IsCancellationRequested||Math.Abs(position()-now)>25){read.Cancel();break;}
                }
                try
                {
                    var rows=await fetch.ConfigureAwait(false);
                    token.ThrowIfCancellationRequested();
                    if(read.IsCancellationRequested)break;
                    retry.Remove(segment.Url);loaded[segment.Url]=rows;
                    DanmakuSources.Trace(SourceName(feed.Site),"segment","ready",rows.Length);
                    Publish();
                }
                catch(HttpRequestException e)when(e.StatusCode==System.Net.HttpStatusCode.NotFound)
                {loaded[segment.Url]=[];DanmakuSources.Trace(SourceName(feed.Site),"segment","missing",http:404);}
                catch(Exception e)when(DanmakuSources.IsSourceFailure(e)&&!token.IsCancellationRequested)
                {
                    if(read.IsCancellationRequested)break;
                    retry[segment.Url]=DateTimeOffset.UtcNow.AddSeconds(30);
                    DanmakuSources.Trace(SourceName(feed.Site),"segment",e.GetType().Name,http:(int?)((e as HttpRequestException)?.StatusCode)??0);
                }
            }
            await Task.Delay(1000,token).ConfigureAwait(false);
        }
    }

    static async Task<DanmakuComment[]> ReadSegment(Feed feed,Segment segment,CancellationToken token)
    {
        var bytes=await DanmakuSources.Bytes(new Uri(segment.Url),2*1024*1024,token,redirects:false).ConfigureAwait(false);
        IEnumerable<DanmakuComment> rows;
        if(feed.Site=="qq")
        {
            using var json=JsonDocument.Parse(bytes);
            var list=Field(json.RootElement,"barrage_list");
            if(list.ValueKind!=JsonValueKind.Array)return [];
            rows=list.EnumerateArray().Take(5000).Select(TencentComment).ToArray();
        }
        else if(feed.Site=="imgo")
        {
            using var json=JsonDocument.Parse(bytes);
            var list=Field(Field(json.RootElement,"data"),"items");
            if(list.ValueKind!=JsonValueKind.Array)return [];
            rows=list.EnumerateArray().Take(5000)
                .Where(row=>Text(row,"time").Length>0)
                .Select(row=>new DanmakuComment(Number(row,"time")/1000,1,0xffffff,Text(row,"content"))).ToArray();
        }
        else
        {
            using var input=new MemoryStream(bytes);
            using var brotli=new BrotliStream(input,CompressionMode.Decompress);
            using var decoded=new MemoryStream();
            var buffer=new byte[16384];int count;
            while((count=await brotli.ReadAsync(buffer,token).ConfigureAwait(false))>0)
            {
                if(decoded.Length+count>4*1024*1024)throw new InvalidDataException("Comment segment too large");
                decoded.Write(buffer,0,count);
            }
            byte[] body=decoded.ToArray();
            if((body.Length>0&&body[0]==(byte)'<')||(body.Length>=3&&body[0]==0xef&&body[1]==0xbb&&body[2]==0xbf))
            {
                decoded.Position=0;
                using var reader=XmlReader.Create(decoded,new XmlReaderSettings{DtdProcessing=DtdProcessing.Prohibit,XmlResolver=null,MaxCharactersInDocument=4*1024*1024});
                var xml=XDocument.Load(reader);
                rows=xml.Descendants("content").Take(5000).Select(e=>IqiyiComment(e.Value,e.Parent?.Element("showTime")?.Value,e.Parent?.Element("color")?.Value));
            }
            else rows=IqiyiProto(body).Take(5000);
        }
        return DanmakuProtocol.Normalize(rows.Where(c=>c.Time>=segment.Start&&(c.Time<segment.End||feed.Site=="qiyi"&&c.Time==segment.End)));
    }

    static DanmakuComment TencentComment(JsonElement row)
    {
        int mode=1;uint color=0xffffff;
        string style=Text(row,"content_style");
        if(style.Length is >0 and <=2048)
        {
            try
            {
                using var json=JsonDocument.Parse(style);
                mode=Number(json.RootElement,"position") switch{2=>5,3=>4,_=>1};
                color=Color(Text(json.RootElement,"color"));
            }
            catch(JsonException){}
        }
        return new(Number(row,"time_offset")/1000,mode,color,Text(row,"content"));
    }
    static uint Color(string? value)=>uint.TryParse(value?.TrimStart('#'),NumberStyles.HexNumber,CultureInfo.InvariantCulture,out uint color)?color:0xffffff;
    static DanmakuComment IqiyiComment(string text,string? time,string? color)=>
        new(double.TryParse(time,NumberStyles.Float,CultureInfo.InvariantCulture,out var point)?point:-1,1,Color(color),text);

    static IEnumerable<DanmakuComment> IqiyiProto(byte[] bytes)
    {
        string Get(Dictionary<int,ArraySegment<byte>[]> fields,int key)
            =>fields.TryGetValue(key,out var values)?Encoding.UTF8.GetString(values[0].AsSpan()):"";
        foreach(var block in ProtoFields(new(bytes)).GetValueOrDefault(6)??[])
        {
            var fields=ProtoFields(block);
            foreach(var item in fields.GetValueOrDefault(2)??[])
            {
                var values=ProtoFields(item);
                var time=Get(values,6);
                yield return IqiyiComment(Get(values,2),time.Length>0?time:Get(fields,1),Get(values,8));
            }
        }
    }

    static Dictionary<int,ArraySegment<byte>[]> ProtoFields(ArraySegment<byte> scope)
    {
        var values=new Dictionary<int,List<ArraySegment<byte>>>();
        byte[] bytes=scope.Array!;int at=scope.Offset,end=at+scope.Count;
        while(at<end)
        {
            ulong tag=DanmakuSources.Varint(bytes,ref at);
            int field=(int)(tag>>3),wire=(int)(tag&7);
            if(field<=0)throw new InvalidDataException("Invalid comment field");
            if(wire==2)
            {
                int length=DanmakuSources.Length(bytes,ref at);
                if(length>end-at)throw new InvalidDataException("Invalid comment boundary");
                if(field<=8)
                {
                    if(!values.TryGetValue(field,out var items))values[field]=items=[];
                    if(items.Count<5000)items.Add(new(bytes,at,length));
                }
                at+=length;
            }
            else DanmakuSources.Skip(bytes,ref at,wire);
            if(at>end)throw new InvalidDataException("Invalid comment boundary");
        }
        return values.ToDictionary(pair=>pair.Key,pair=>pair.Value.ToArray());
    }
}
