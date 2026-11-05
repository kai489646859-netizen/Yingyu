using System.Globalization;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Xml;
using EmbyDesktop.Core.Models;

namespace Yingyu.Update;

// Public metadata only: no source URI, file reads, Emby credentials or media hash.
internal sealed record DanmakuIdentity(string Title,int Season,int Episode,int Year,bool Movie,double Duration)
{
    public string[] Aliases{get;init;}=[];
    internal bool ContinuousNumbering{get;init;}
    internal bool Animation{get;init;}
    internal string Key => Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(JsonSerializer.Serialize(new object[]{Title,Season,Episode,Year,Movie,Math.Round(Duration)}))));
    internal static DanmakuIdentity? From(EmbyItem item,double duration)
    {
        bool movie=item.Type.Equals("Movie",StringComparison.OrdinalIgnoreCase);
        if(!movie&&!item.Type.Equals("Episode",StringComparison.OrdinalIgnoreCase))return null;
        string title=(movie?item.Name:item.SeriesName)?.Trim()??"";
        if(title.Length is <2 or >160||!movie&&(item.IndexNumber is not >0||item.ParentIndexNumber==0))return null;
        // Episode production year can differ from the series premiere year.
        return new(title,item.ParentIndexNumber??1,movie?1:item.IndexNumber!.Value,movie?item.ProductionYear??0:0,movie,duration)
        {
            Aliases=movie&&!string.IsNullOrWhiteSpace(item.OriginalTitle)?[item.OriginalTitle]:[],
            Animation=item.Genres?.Any(g=>g is "动画" or "動畫" or "动漫" or "動漫" or "国漫" or "國漫"
                ||string.Equals(g,"Animation",StringComparison.OrdinalIgnoreCase))==true
        };
    }
}
internal sealed record DanmakuComment(double Time,int Mode,uint Color,string Text);
internal sealed record DanmakuTrack(string Source,string Identity,double Duration,DanmakuComment[] Comments,int Confidence)
{
    public string? StreamCid{get;init;}
    public bool Partial{get;init;}
    [System.Text.Json.Serialization.JsonIgnore]
    internal PublicDanmaku.Feed? PublicFeed{get;init;}
}
internal sealed record DanmakuCandidate(string Label,string Cid,double Duration,int Confidence);
internal sealed class DanmakuOptions
{
    public bool Enabled{get;set;}=true;
    public bool Automatic{get;set;}=true;
    public double Opacity{get;set;}=.8;
    public double FontSize{get;set;}=24;
    public bool AdaptiveSize{get;set;}=true;
    public bool Background{get;set;}=false;
    public bool Featured{get;set;}=false;
    public double Area{get;set;}=.5;
    public double TravelSeconds{get;set;}=9;
    public double Delay{get;set;}
    public bool Scroll{get;set;}=true;
    public bool Top{get;set;}=true;
    public bool Bottom{get;set;}=true;
    public string CompatibleApi{get;set;}="";
    internal void Normalize()
    {
        double Bound(double x,double min,double max,double fallback)=>double.IsFinite(x)?Math.Clamp(x,min,max):fallback;
        Opacity=Bound(Opacity,.15,1,.8);FontSize=Bound(FontSize,14,40,24);Area=Bound(Area,.2,1,.5);
        TravelSeconds=Bound(TravelSeconds,4,20,9);Delay=Bound(Delay,-3600,3600,0);
        CompatibleApi=CompatibleApi?.Trim()??"";
        // This was the unverified built-in default, not a user-supplied source.
        if(CompatibleApi.TrimEnd('/').Equals("https://api.danmu.icu/api/v2",StringComparison.OrdinalIgnoreCase))CompatibleApi="";
        if(CompatibleApi.Length>512||!Uri.TryCreate(CompatibleApi,UriKind.Absolute,out var uri)||uri.Scheme!="https"||uri.UserInfo.Length>0||uri.Query.Length>0||uri.Fragment.Length>0)CompatibleApi="";
        else CompatibleApi=CompatibleApi.TrimEnd('/')+(uri.AbsolutePath.TrimEnd('/').EndsWith("/api/v2",StringComparison.OrdinalIgnoreCase)?"/":"/api/v2/");
    }
}
internal static class DanmakuStorage
{
    static readonly SemaphoreSlim Gate=new(1,1);
    static string Settings=>Path.Combine(CachePaths.UserDataRoot,"danmaku-settings.json");
    static string Cache=>Path.Combine(CachePaths.CacheRoot,"Danmaku-v2");
    static readonly JsonSerializerOptions Json=new(){PropertyNameCaseInsensitive=true,Encoder=System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping};
    internal static async Task<DanmakuOptions> ReadOptions(CancellationToken token)
    {
        try{if(new FileInfo(Settings) is {Exists:true,Length:<=16384}){var o=JsonSerializer.Deserialize<DanmakuOptions>(await File.ReadAllTextAsync(Settings,token),Json)??new();o.Normalize();return o;}}
        catch(Exception e)when(e is IOException or UnauthorizedAccessException or JsonException){}
        return new();
    }
    internal static async Task Save(DanmakuOptions options)
    {
        string data=JsonSerializer.Serialize(options,Json);await Gate.WaitAsync().ConfigureAwait(false);
        try{await Atomic(Settings,data,CancellationToken.None).ConfigureAwait(false);}finally{Gate.Release();}
    }
    static async Task Atomic(string path,string data,CancellationToken token)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);string temp=path+"."+Guid.NewGuid().ToString("N")+".tmp";
        try{await File.WriteAllTextAsync(temp,data,token).ConfigureAwait(false);token.ThrowIfCancellationRequested();File.Move(temp,path,true);}
        finally{try{if(File.Exists(temp))File.Delete(temp);}catch(IOException){}}
    }
    internal static async Task<DanmakuTrack?> Read(DanmakuIdentity id,CancellationToken token,string suffix="")
    {
        try{
            var file=new FileInfo(Path.Combine(Cache,id.Key+suffix+".json"));
            if(!file.Exists||file.Length>12*1024*1024||DateTime.UtcNow-file.LastWriteTimeUtc>TimeSpan.FromDays(7))return null;
            var track=JsonSerializer.Deserialize<DanmakuTrack>(await File.ReadAllTextAsync(file.FullName,token),Json);
            if(track?.Identity!=id.Key||track.Comments==null||track.Source is not {Length:<=64})return null;
            var normalized=DanmakuProtocol.Normalize(track.Comments);
            return normalized.Length>0||DanmakuSources.ValidCid(track.StreamCid)?track with{Comments=normalized}:null;
        }catch(Exception e)when(e is IOException or UnauthorizedAccessException or JsonException){return null;}
    }
    internal static async Task Write(DanmakuTrack track,CancellationToken token,string suffix="")
    {
        await Gate.WaitAsync(token).ConfigureAwait(false);
        try{
            string json=JsonSerializer.Serialize(track,Json);if(Encoding.UTF8.GetByteCount(json)>12*1024*1024)return;
            await Atomic(Path.Combine(Cache,track.Identity+suffix+".json"),json,token).ConfigureAwait(false);
            long total=0;
            int count=0;foreach(var file in new DirectoryInfo(Cache).GetFiles("*.json").OrderByDescending(f=>f.LastWriteTimeUtc))
            {total+=file.Length;if(++count>512||total>64L*1024*1024||DateTime.UtcNow-file.LastWriteTimeUtc>TimeSpan.FromDays(7))file.Delete();}
        }finally{Gate.Release();}
    }
    internal static async Task Clear()
    {
        await Gate.WaitAsync().ConfigureAwait(false);
        try{if(Directory.Exists(Cache))foreach(var file in new DirectoryInfo(Cache).GetFiles("*.json"))file.Delete();}finally{Gate.Release();}
    }
    internal static async Task<DanmakuComment[]?> ReadSegment(string cid,int index,CancellationToken token)
    {
        if(!DanmakuSources.ValidCid(cid)||index is <1 or >240)return null;
        try{
            var file=new FileInfo(Path.Combine(Cache,$"segment-{cid}-{index}.json"));
            if(!file.Exists||file.Length>4*1024*1024||DateTime.UtcNow-file.LastWriteTimeUtc>TimeSpan.FromDays(7))return null;
            return DanmakuProtocol.Normalize(JsonSerializer.Deserialize<DanmakuComment[]>(await File.ReadAllTextAsync(file.FullName,token),Json)??[]);
        }catch(Exception e)when(e is IOException or UnauthorizedAccessException or JsonException){return null;}
    }
    internal static async Task WriteSegment(string cid,int index,DanmakuComment[] rows,CancellationToken token)
    {
        if(!DanmakuSources.ValidCid(cid)||index is <1 or >240)return;
        await Gate.WaitAsync(token).ConfigureAwait(false);
        try{
            string json=JsonSerializer.Serialize(rows,Json);if(Encoding.UTF8.GetByteCount(json)>4*1024*1024)return;
            await Atomic(Path.Combine(Cache,$"segment-{cid}-{index}.json"),json,token).ConfigureAwait(false);
            long total=0;int count=0;foreach(var file in new DirectoryInfo(Cache).GetFiles("*.json").OrderByDescending(f=>f.LastWriteTimeUtc)){total+=file.Length;if(++count>512||total>64L*1024*1024)file.Delete();}
        }finally{Gate.Release();}
    }
}
internal static class DanmakuProtocol
{
    internal static string Clean(string title)=>WebUtility.HtmlDecode(Regex.Replace(title,"<[^>]{0,100}>","",RegexOptions.None,TimeSpan.FromMilliseconds(50))).Normalize(NormalizationForm.FormKC).Trim();
    [System.Runtime.InteropServices.DllImport("kernel32.dll",CharSet=System.Runtime.InteropServices.CharSet.Unicode)]
    static extern int LCMapStringEx(string locale,uint flags,string source,int sourceCount,StringBuilder destination,int destinationCount,IntPtr version,IntPtr reserved,nint sort);
    static string Compact(string value)
    {
        try{var buffer=new StringBuilder(value.Length*2+8);int count=LCMapStringEx("zh-CN",0x02000000,value,value.Length,buffer,buffer.Capacity,IntPtr.Zero,IntPtr.Zero,0);if(count>0)value=buffer.ToString();}
        catch(Exception e)when(e is DllNotFoundException or EntryPointNotFoundException){}
        value=Regex.Replace(value,@"[（(]\s*(?:国语|國語|日语|日語|英语|英語|普通话|普通話|粤语|粵語|中配|原声|原聲|字幕版|配音版|\d{4})\s*[）)]","",RegexOptions.IgnoreCase,TimeSpan.FromMilliseconds(50));
        return Regex.Replace(value.ToLowerInvariant(),@"[\s\p{P}\p{S}]","",RegexOptions.None,TimeSpan.FromMilliseconds(50));
    }
    static readonly Regex SeasonPattern=new(@"(?:第\s*(?<n>[0-9一二三四五六七八九十]+)\s*[季期]|\bseason\s*(?<n>\d+)\b|\bs(?<n>\d{1,2})\b)",RegexOptions.IgnoreCase,TimeSpan.FromMilliseconds(50));
    static int Number(string value)
    {
        if(int.TryParse(value,out int n))return n;
        const string digits="零一二三四五六七八九";if(value.Length==1)return value=="十"?10:digits.IndexOf(value[0]);
        int total=0,current=0;foreach(char ch in value){int digit=digits.IndexOf(ch);if(digit>=0){current=digit;continue;}int unit=ch switch{'十'=>10,'百'=>100,'千'=>1000,_=>0};if(unit==0)return -1;total+=(current==0?1:current)*unit;current=0;}return total+current;
    }
    internal static IEnumerable<string> SearchTitles(DanmakuIdentity id)
    {
        string baseTitle=SeasonPattern.Replace(id.Title,"").Trim();
        string alternate=!id.Movie&&id.Season>1&&baseTitle==id.Title
            ? $"{id.Title} 第{id.Season}季" : baseTitle;
        return new[]{id.Title,alternate}.Concat(id.Aliases)
            .Where(t=>t.Length>=2).Distinct(StringComparer.OrdinalIgnoreCase).Take(3);
    }

    internal const int ContinuousEpisodeFloor=75;
    internal static string? ContinuousTitle(DanmakuIdentity id)
    {
        if(id.Movie||(Uri.TryCreate(id.Title,UriKind.Absolute,out var uri)&&uri.Scheme is "https" or "http")||id.Season<=0)return null;
        string title=SeasonPattern.Replace(Clean(id.Title),"").Trim();
        bool annual=title.EndsWith("年番",StringComparison.Ordinal);
        if(!annual&&!id.ContinuousNumbering&&id.Episode<ContinuousEpisodeFloor)return null;
        return annual?title[..^2].TrimEnd():title;
    }

    internal static bool ContinuousTitleMatches(string title,string candidate)
    {
        string key=Compact(title),other=Compact(Clean(candidate));
        return key.Length>=2&&(other==key||other==key+"年番");
    }

    internal static string StripPlatformLabel(string title)
        => Regex.Replace(Clean(title),@"\s*(?:[（(\[【]\s*(?:腾讯视频|爱奇艺|優酷|优酷|芒果TV|哔哩哔哩|B站)\s*[）)\]】]|[·|｜-]\s*(?:腾讯视频|爱奇艺|優酷|优酷|芒果TV|哔哩哔哩|B站))\s*$",
            "",RegexOptions.IgnoreCase,TimeSpan.FromMilliseconds(50));

    internal static bool TitleMatches(DanmakuIdentity id,string raw)
    {
        string candidate=Clean(raw);var wantedSeason=SeasonPattern.Match(id.Title);var foundSeason=SeasonPattern.Match(candidate);
        int expected=wantedSeason.Success?Number(wantedSeason.Groups["n"].Value):id.Season;
        if(!id.Movie&&((foundSeason.Success?Number(foundSeason.Groups["n"].Value):1)!=expected))return false;
        // Never strip sequels, years or subtitles to force a fuzzy match.
        return new[]{id.Title}.Concat(id.Aliases).Any(title=>Compact(SeasonPattern.Replace(candidate,""))==Compact(SeasonPattern.Replace(Clean(title),"")));
    }
    internal static bool EpisodeMatches(string title,int number)
    {
        title=Clean(title);
        var match=Regex.Match(title,@"^\s*(?:第\s*|(?:EP?|Episode)\s*)?([0-9一二三四五六七八九十零百]+)\s*(?:[话話集回]|$|[\s:：])",RegexOptions.IgnoreCase,TimeSpan.FromMilliseconds(50));
        return match.Success&&Number(match.Groups[1].Value)==number;
    }
    internal static bool DurationMatches(double local,double remote)=>remote<=0||local<=0||Math.Abs(local-remote)<=Math.Max(90,local*.05);
    internal static DanmakuComment[] Normalize(IEnumerable<DanmakuComment> input)
    {
        var seen=new HashSet<(long,string,int)>();var result=new List<DanmakuComment>();
        foreach(var c in input.Take(120000))
        {
            if(c is null||!double.IsFinite(c.Time)||c.Time<0||c.Time>86400||c.Mode is not (1 or 4 or 5)||string.IsNullOrWhiteSpace(c.Text))continue;
            string text=new(c.Text.Where(ch=>!char.IsControl(ch)&&ch is not ('\u202a' or '\u202b' or '\u202d' or '\u202e' or '\u202c')).Take(160).ToArray());
            if(text.Length>0&&seen.Add(((long)Math.Round(c.Time*5),text,c.Mode)))result.Add(c with{Text=text,Color=c.Color&0xffffff});
        }
        return result.OrderBy(c=>c.Time).ToArray();
    }
    internal static DanmakuComment[] Xml(byte[] data)
    {
        var comments=new List<DanmakuComment>();
        using var stream=new MemoryStream(data);using var xml=XmlReader.Create(stream,new XmlReaderSettings{DtdProcessing=DtdProcessing.Prohibit,XmlResolver=null,MaxCharactersInDocument=12*1024*1024});
        while(!xml.EOF&&comments.Count<120000)
        {
            if(xml.NodeType!=XmlNodeType.Element||xml.Name!="d"){xml.Read();continue;}
            string[] p=(xml.GetAttribute("p")??"").Split(',');string text=xml.ReadElementContentAsString();
            if(p.Length>=4&&double.TryParse(p[0],NumberStyles.Float,CultureInfo.InvariantCulture,out var time)&&int.TryParse(p[1],out int mode)&&uint.TryParse(p[3],out uint color))comments.Add(new(time,mode,color,text));
        }
        return Normalize(comments);
    }
    internal static DanmakuComment[] JsonComments(JsonElement root)
    {
        if(!root.TryGetProperty("comments",out var rows)||rows.ValueKind!=JsonValueKind.Array)return [];
        var comments=new List<DanmakuComment>();
        foreach(var row in rows.EnumerateArray().Take(120000))
        {
            string[] p=String(row,"p").Split(',');
            if(p.Length>=3&&double.TryParse(p[0],NumberStyles.Float,CultureInfo.InvariantCulture,out var time)&&int.TryParse(p[1],out int mode)&&uint.TryParse(p[2],out uint color))comments.Add(new(time,mode,color,String(row,"m")));
        }
        return Normalize(comments);
    }
    internal static string String(JsonElement e,string key)=>e.ValueKind==JsonValueKind.Object&&e.TryGetProperty(key,out var v)?v.ValueKind==JsonValueKind.String?v.GetString()??"":v.ValueKind==JsonValueKind.Number?v.GetRawText():"":"";
    internal static double Numeric(JsonElement e,string key)=>double.TryParse(String(e,key),NumberStyles.Float,CultureInfo.InvariantCulture,out var n)&&double.IsFinite(n)?n:0;
}
