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
// directly from the two platform CDNs, with no accounts or media requests.
internal static class PublicDanmaku
{
    internal sealed record Segment(double Start,double End,string Url);
    internal sealed record Feed(string Name,bool Tencent,Segment[] Segments);
    static readonly ConcurrentDictionary<string,(DateTimeOffset At,JsonElement[] Rows)> Catalog=new();
    static readonly Regex TencentPath=new(@"^/(?:x/cover/[a-zA-Z0-9]+/|x/page/)([a-zA-Z0-9]{6,24})\.html$",RegexOptions.None,TimeSpan.FromMilliseconds(50));
    static readonly Regex IqiyiPath=new(@"^/v_([a-zA-Z0-9]{1,32})\.html$",RegexOptions.None,TimeSpan.FromMilliseconds(50));
    static readonly Regex BilibiliEpisodePath=new(@"^/bangumi/play/ep([0-9]{1,16})/?$",RegexOptions.None,TimeSpan.FromMilliseconds(50));
    static readonly Regex SegmentPath=new(@"^(?:t/v1/)?\d{1,9}/\d{1,9}$",RegexOptions.None,TimeSpan.FromMilliseconds(50));

    internal static void ClearSearches()=>Catalog.Clear();
    static JsonElement Field(JsonElement e,string key)=>e.ValueKind==JsonValueKind.Object&&e.TryGetProperty(key,out var v)?v:default;
    static string Text(JsonElement e,string key)=>DanmakuProtocol.String(e,key);
    static double Number(JsonElement e,string key)=>DanmakuProtocol.Numeric(e,key);
    static Task<JsonDocument> Json(string url,CancellationToken token)=>DanmakuSources.Json(url,token,redirects:false);

    internal static bool IsDirectLink(string? url)=>VideoId(url,"qq") is not null||VideoId(url,"qiyi") is not null;
    static string? VideoId(string? url,string site)
    {
        if(!Uri.TryCreate(url,UriKind.Absolute,out var uri)||uri.Scheme!="https"||!uri.IsDefaultPort
            ||uri.UserInfo.Length!=0)return null;
        Regex? path=site switch
        {
            "qq" when uri.Host=="v.qq.com"=>TencentPath,
            "qiyi" when uri.Host=="www.iqiyi.com"=>IqiyiPath,
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
        if(Catalog.Count>=24)Catalog.Clear();
        if(result.Length>0)Catalog[title]=(DateTimeOffset.UtcNow,result);
        return result;
    }

    internal static async Task<string[]> FindLinks(DanmakuIdentity id,string site,
        ConcurrentDictionary<string,Lazy<Task<JsonElement[]>>> searches,CancellationToken token,string? continuousTitle=null)
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
                var pending=searches.GetOrAdd(title,key=>new Lazy<Task<JsonElement[]>>(()=>Search(key,token)));
                rows=await pending.Value.WaitAsync(token).ConfigureAwait(false);
            }
            catch(Exception e)when(DanmakuSources.IsSourceFailure(e)&&!token.IsCancellationRequested)
            {DanmakuSources.Trace("public-catalog","search",e.GetType().Name,http:(int?)((e as HttpRequestException)?.StatusCode)??0);continue;}
            foreach(var row in rows)
            {
                string category=Text(row,"cat_name"),candidate=Text(row,"titleTxt");
                if(!id.Movie&&id.Animation&&category!="动漫")continue;
                if(continuousTitle is null?!DanmakuProtocol.TitleMatches(id,candidate):
                    category!="动漫"||!DanmakuProtocol.ContinuousTitleMatches(continuousTitle,candidate))continue;
                var playlinks=Field(row,"playlinks");
                if(id.Movie)
                {
                    if(category!="电影"||id.Year>0&&Number(row,"year")!=id.Year)continue;
                    if(VideoId(Text(playlinks,site),site) is {} movie)videos.Add(movie);
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
        DanmakuSources.Trace(site switch{"qq"=>"tencent","qiyi"=>"iqiyi",_=>"bilibili"},
            "catalog",continuousTitle is null?"exact-episode-links":"continuous-episode-links",videos.Count);
        return videos.Take(4).ToArray();
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
            foreach(var row in rows.EnumerateArray().Take(12))
                if(Number(row,"playlink_num")==episode&&VideoId(Text(row,"url"),site) is {} video)return video;
        }
        catch(Exception e)when(DanmakuSources.IsSourceFailure(e)&&!token.IsCancellationRequested)
        {DanmakuSources.Trace("public-catalog","episode",e.GetType().Name,http:(int?)((e as HttpRequestException)?.StatusCode)??0);}
        return null;
    }

    internal static async Task<DanmakuTrack?> Match(string[] videos,DanmakuIdentity wanted,string identity,bool tencent,CancellationToken token,bool continuous=false)
    {
        string name=tencent?"tencent":"iqiyi";
        DanmakuTrack? matched=null;
        foreach(var video in videos)
        {
            try
            {
                var (duration,segments)=tencent
                    ?await TencentSegments(video,token).ConfigureAwait(false)
                    :await IqiyiSegments(video,token).ConfigureAwait(false);
                if(segments.Length==0){DanmakuSources.Trace(name,"match","no-segments");continue;}
                if(continuous&&(wanted.Duration<=0||duration<=0)||!DanmakuProtocol.DurationMatches(wanted.Duration,duration))
                {DanmakuSources.Trace(name,"match","duration-mismatch");continue;}
                if(matched is not null){DanmakuSources.Trace(name,"match","ambiguous-edition");return null;}
                matched=new(tencent?"腾讯视频":"爱奇艺",identity,duration,[],85)
                    {PublicFeed=new(name,tencent,segments),Partial=true};
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

    internal static async Task Watch(DanmakuTrack selection,Func<double> position,Action<DanmakuTrack> publish,CancellationToken token)
    {
        var feed=selection.PublicFeed!;
        var loaded=new Dictionary<string,DanmakuComment[]>(StringComparer.Ordinal);
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
                    DanmakuSources.Trace(feed.Name,"segment","ready",rows.Length);
                    Publish();
                }
                catch(HttpRequestException e)when(e.StatusCode==System.Net.HttpStatusCode.NotFound)
                {loaded[segment.Url]=[];DanmakuSources.Trace(feed.Name,"segment","missing",http:404);}
                catch(Exception e)when(DanmakuSources.IsSourceFailure(e)&&!token.IsCancellationRequested)
                {
                    if(read.IsCancellationRequested)break;
                    retry[segment.Url]=DateTimeOffset.UtcNow.AddSeconds(30);
                    DanmakuSources.Trace(feed.Name,"segment",e.GetType().Name,http:(int?)((e as HttpRequestException)?.StatusCode)??0);
                }
            }
            await Task.Delay(1000,token).ConfigureAwait(false);
        }
    }

    static async Task<DanmakuComment[]> ReadSegment(Feed feed,Segment segment,CancellationToken token)
    {
        var bytes=await DanmakuSources.Bytes(new Uri(segment.Url),2*1024*1024,token,redirects:false).ConfigureAwait(false);
        IEnumerable<DanmakuComment> rows;
        if(feed.Tencent)
        {
            using var json=JsonDocument.Parse(bytes);
            var list=Field(json.RootElement,"barrage_list");
            if(list.ValueKind!=JsonValueKind.Array)return [];
            rows=list.EnumerateArray().Take(5000).Select(TencentComment).ToArray();
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
        return DanmakuProtocol.Normalize(rows.Where(c=>c.Time>=segment.Start&&(c.Time<segment.End||!feed.Tencent&&c.Time==segment.End)));
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
