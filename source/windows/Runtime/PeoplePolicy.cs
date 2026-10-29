using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using EmbyDesktop.Core.Models;
using EmbyDesktop.Core.Services;

namespace Yingyu.Update;

public sealed record EmbyPerson(string Id, string Name, string Role, string ImageTag);
public sealed record PeoplePage(IReadOnlyList<EmbyPerson> People, int Total, int NextOffset = 0);
public sealed record PersonFilms(IReadOnlyList<EmbyItem> Items, int Total);
public sealed class EmbyPeopleApi(EmbyApiClient client, string userId)
{
    static readonly MethodInfo Read = typeof(EmbyApiClient).GetMethods(BindingFlags.Instance | BindingFlags.NonPublic)
        .Single(m => m.Name == "GetAsync" && m.IsGenericMethodDefinition && m.GetParameters().Length == 4);
    static readonly JsonSerializerOptions Json = new() { PropertyNameCaseInsensitive = true };
    static string Q(string text) => Uri.EscapeDataString(text);
    public async Task<JsonElement> Get(string path, CancellationToken token)
    {
        var task = (Task<JsonElement>)Read.MakeGenericMethod(typeof(JsonElement)).Invoke(client,
            [path, true, token, ServerRequestPriority.Normal])!;
        return await task.ConfigureAwait(false);
    }
    public static string Text(JsonElement value, string name) => value.ValueKind == JsonValueKind.Object && value.TryGetProperty(name, out var p) && p.ValueKind == JsonValueKind.String ? p.GetString() ?? "" : "";
    public static int Number(JsonElement value, string name, int fallback) => value.TryGetProperty(name, out var p) && p.TryGetInt32(out var n) ? Math.Max(0,n) : fallback;
    public static EmbyPerson Person(JsonElement p)
    {
        string tag = Text(p,"PrimaryImageTag");
        if (p.TryGetProperty("ImageTags",out var tags) && Text(tags,"Primary") is { Length: > 0 } primary) tag = primary;
        return new(Text(p,"Id"),Text(p,"Name"),Text(p,"Role"),tag);
    }
    public async Task<IReadOnlyList<EmbyPerson>> Detail(string itemId, CancellationToken token)
    {
        var json = await Get($"Users/{Q(userId)}/Items/{Q(itemId)}?Fields=People",token);
        return json.TryGetProperty("People",out var people) && people.ValueKind == JsonValueKind.Array
            ? people.EnumerateArray().Where(p=> Text(p,"Type").Equals("Actor",StringComparison.OrdinalIgnoreCase))
                .Select(Person).Where(p=>p.Id.Length>0 && p.Name.Length>0).DistinctBy(p=>p.Id).ToList() : [];
    }
    public async Task<PeoplePage> Search(string term, int start, CancellationToken token)
    {
        var queries=SearchMatching.Queries(term);if(queries.Length==0)return new([],0,0);
        using var gate=new SemaphoreSlim(2);
        async Task<PeoplePage> ReadPage(string value){
            await gate.WaitAsync(token);try{
                var json=await Get($"Persons?UserId={Q(userId)}&SearchTerm={Q(value)}&StartIndex={Math.Max(0,start)}&Limit=24&EnableImages=true&EnableTotalRecordCount=true",token);
                var items=json.TryGetProperty("Items",out var values)&&values.ValueKind==JsonValueKind.Array?values.EnumerateArray().Select(Person).Where(p=>p.Id.Length>0&&p.Name.Length>0).ToArray():[];
                return new(items,Number(json,"TotalRecordCount",items.Length));
            }finally{gate.Release();}
        }
        var pages=await Task.WhenAll(queries.Select(ReadPage));token.ThrowIfCancellationRequested();
        var merged=pages.SelectMany(p=>p.People).Where(p=>SearchMatching.Score(p.Name,term)>0).DistinctBy(p=>p.Id,StringComparer.OrdinalIgnoreCase).OrderByDescending(p=>SearchMatching.Score(p.Name,term)).ThenBy(p=>p.Name,StringComparer.CurrentCultureIgnoreCase).ToArray();
        int next=Math.Max(0,start)+24;bool more=pages.Any(p=>p.People.Count>0&&start+p.People.Count<p.Total);
        return new(merged,more?next+1:next,next);
    }

    public async Task<PersonFilms> Films(string personId, string libraryId, int start, bool favorites, CancellationToken token)
    {
        if(string.IsNullOrWhiteSpace(personId)||string.IsNullOrWhiteSpace(libraryId)) return new([],0);
        var json=await Get($"Users/{Q(userId)}/Items?PersonIds={Q(personId)}&ParentId={Q(libraryId)}&Recursive=true&IncludeItemTypes=Movie,Series&StartIndex={Math.Max(0,start)}&Limit=48&EnableUserData=true&EnableTotalRecordCount=true&Fields=Overview,ProductionYear,CommunityRating,PrimaryImageAspectRatio&SortBy=SortName&SortOrder=Ascending"+(favorites?"&Filters=IsFavorite":""),token);
        var items=json.TryGetProperty("Items",out var values)&&values.ValueKind==JsonValueKind.Array
            ? values.EnumerateArray().Select(p=>JsonSerializer.Deserialize<EmbyItem>(p.GetRawText(),Json)!)
                .Where(p=>p!=null&&p.Id.Length>0).ToList() : [];
        return new(items,Number(json,"TotalRecordCount",items.Count));
    }
}

public sealed class ActorDisk(string root)
{
    readonly SemaphoreSlim gate=new(1,1);
    public static bool IsChoice(int gb)=>gb is 1 or 3 or 5;
    public static string Key(string server, string user, string person, string tag)=>Convert.ToHexStringLower(
        SHA256.HashData(Encoding.UTF8.GetBytes(JsonSerializer.Serialize(new[]{server,user,person,tag,"160x85"}))));
    public string PathFor(string key)
    {
        if(key.Length!=64 || key.Any(c=>!char.IsAsciiHexDigit(c)))throw new IOException("演员缓存身份无效。");
        CacheLayout.RejectLinks(root);Directory.CreateDirectory(root);var path=Path.Combine(root,key+".image");CacheLayout.RejectLinks(path);return path;
    }
    public async Task<string?> Get(string key,Func<string,CancellationToken,Task<bool>> download,Func<bool> needed,long limit,CancellationToken token)
    {
        // A local portrait must not wait behind the actor download gate.
        var cached=await Task.Run(()=>{
            token.ThrowIfCancellationRequested();var path=PathFor(key);
            if(!File.Exists(path)||new FileInfo(path).Length<=0)return null;
            File.SetLastAccessTimeUtc(path,DateTime.UtcNow);return path;
        },token);
        if(cached!=null)return cached;
        if(!needed())return null;
        await gate.WaitAsync(token);
        try
        {
            var path=PathFor(key);
            // Reusing an actor photo must not change its image revision: the
            // decoded bitmap cache keys include file LastWriteTime. Track use
            // separately so another film can reuse the same decoded portrait.
            if(File.Exists(path)&&new FileInfo(path).Length>0){File.SetLastAccessTimeUtc(path,DateTime.UtcNow);return path;}
            if(!needed()||!await download(path,token)||!needed())return null;
            TrimCore(limit,path);return path;
        }
        finally{gate.Release();}
    }
    public async Task Trim(long limit,CancellationToken token=default){await gate.WaitAsync(token);try{TrimCore(limit,null);}finally{gate.Release();}}
    public async Task Clear(CancellationToken token=default){await gate.WaitAsync(token);try{foreach(var f in Files())f.Delete();}finally{gate.Release();}}
    IEnumerable<FileInfo> Files()
    {
        CacheLayout.RejectLinks(root);if(!Directory.Exists(root))return [];
        return new DirectoryInfo(root).EnumerateFiles("*.image",SearchOption.TopDirectoryOnly)
            .Where(f=>(f.Attributes&FileAttributes.ReparsePoint)==0&&Path.GetFileNameWithoutExtension(f.Name).Length==64&&Path.GetFileNameWithoutExtension(f.Name).All(char.IsAsciiHexDigit)).ToArray();
    }
    void TrimCore(long limit,string? keep)
    {
        var files=Files().OrderBy(f=>f.LastAccessTimeUtc>f.LastWriteTimeUtc?f.LastAccessTimeUtc:f.LastWriteTimeUtc).ToList();long bytes=files.Sum(f=>f.Length);
        foreach(var file in files){if(bytes<=Math.Max(0,limit))break;if(file.FullName==keep)continue;long size=file.Length;file.Delete();bytes-=size;}
    }
}
