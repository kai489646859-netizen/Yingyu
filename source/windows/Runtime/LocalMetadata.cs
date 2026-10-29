using System.Collections.Concurrent;
using System.Net.Http.Json;
using System.Runtime.CompilerServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using EmbyDesktop.Core.Models;
using EmbyDesktop.Core.Services;
using Microsoft.UI.Xaml;

namespace Yingyu.Update;

// Text/relationships only. This store never supplies PlaybackInfo, routes,
// credentials, availability probes, or server checkpoints used for uploads.
public static class LocalMetadata
{
    const long MaximumBytes=64L*1024*1024;
    const int PageSize=200;
    static readonly JsonSerializerOptions Json=new(){PropertyNameCaseInsensitive=true};
    static readonly ConcurrentDictionary<string,WeakReference<State>> Stores=new();
    sealed class ClientState {public State? Current;}
    static readonly ConditionalWeakTable<EmbyApiClient,ClientState> Clients=new();
    static readonly object StoreGate=new();
    static readonly ConditionalWeakTable<object,Warmup> Warmups=new();
    static readonly ConditionalWeakTable<EmbyItem,object> CachedItems=new();
    static readonly object CacheMarker=new();
    static readonly SemaphoreSlim Computations=new(1,1);
    static int generation;
    public sealed record Record(EmbyItem Item,EmbyPerson[] People);
    public sealed record Library(DateTimeOffset At,Record[] Items);
    public sealed record CastRecord(DateTimeOffset At,EmbyPerson[] People);
    public sealed record Document(int Version,string Scope,Dictionary<string,Library> Libraries,Dictionary<string,CastRecord> Cast);
    public sealed record Display(DateTimeOffset At,EmbyItemsResponse Result);
    sealed class Batch { public int Total;public readonly List<Record> Items=new(); }
    sealed class State(string scope)
    {
        public readonly string Scope=scope;
        public readonly SemaphoreSlim Gate=new(1,1);
        public readonly SemaphoreSlim DisplayGate=new(1,1);
        public readonly SemaphoreSlim CastGate=new(1,1);
        public Document Data=new(1,scope,new(StringComparer.OrdinalIgnoreCase),new(StringComparer.OrdinalIgnoreCase));
        public readonly Dictionary<string,Batch> Batches=new(StringComparer.OrdinalIgnoreCase);
        public bool Loaded;
        public DateTimeOffset Invalidated;
        public string Directory=>Path.Combine(CachePaths.Metadata,"LocalMetadata-v1",Scope);
        public string File=>Path.Combine(Directory,"catalogue.json");
        public async Task Load(CancellationToken token)
        {
            if(Loaded)return;
            await Gate.WaitAsync(token).ConfigureAwait(false);
            try{
                if(Loaded)return;
                var saved=await Read<Document>(File,token).ConfigureAwait(false);
                if(saved is {Version:1}&&saved.Scope==Scope&&saved.Libraries!=null&&saved.Cast!=null
                    &&saved.Libraries.Values.All(l=>l!=null&&l.Items!=null&&l.Items.All(i=>i!=null&&i.Item!=null&&!string.IsNullOrEmpty(i.Item.Id)&&i.People!=null&&i.People.All(p=>p!=null&&!string.IsNullOrEmpty(p.Id)&&!string.IsNullOrEmpty(p.Name))))
                    &&saved.Cast.Values.All(c=>c!=null&&c.People!=null&&c.People.All(p=>p!=null&&!string.IsNullOrEmpty(p.Id)&&!string.IsNullOrEmpty(p.Name))))Data=saved;
                Loaded=true;
            }finally{Gate.Release();}
        }
        public Task Save(CancellationToken token)=>Write(File,Data,token);
    }
    sealed class Warmup
    {
        public readonly object Gate=new();
        public Task? Work;
        public string Scope="";
        public CancellationTokenSource? Cancellation;
        public bool Hooked;
        public DateTimeOffset RetryAt;
    }
    static string Hash(string text)=>Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(text)));
    static string User(EmbyApiClient client)=>Access.Get<string?>(client,"_userId")??"";
    static State Store(EmbyApiClient client)
    {
        string user=User(client);if(user.Length==0)throw new InvalidOperationException("尚未选择账户。");
        string scope=Hash(JsonSerializer.Serialize(new[]{client.ServerUrl,user}));
        lock(StoreGate){
            var owner=Clients.GetOrCreateValue(client);if(owner.Current?.Scope==scope)return owner.Current;
            if(!Stores.TryGetValue(scope,out var weak)||!weak.TryGetTarget(out var state)){state=new(scope);Stores[scope]=new(state);}
            owner.Current=state;
            if(Stores.Count>96)foreach(var pair in Stores)if(!pair.Value.TryGetTarget(out _))Stores.TryRemove(pair.Key,out _);
            return state;
        }
    }
    static async Task<T?> Read<T>(string path,CancellationToken token)
    {
        try{CacheLayout.RejectLinks(path);if(!System.IO.File.Exists(path)||new FileInfo(path).Length>MaximumBytes)return default;
            var bytes=await System.IO.File.ReadAllBytesAsync(path,token).ConfigureAwait(false);
            return await Task.Run(()=>JsonSerializer.Deserialize<T>(bytes,Json),token).ConfigureAwait(false);
        }catch(Exception e)when(e is IOException or UnauthorizedAccessException or JsonException or NotSupportedException){return default;}
    }
    static async Task Write<T>(string path,T data,CancellationToken token)
    {
        string? temporary=null;
        try{
            byte[] bytes=await Task.Run(()=>JsonSerializer.SerializeToUtf8Bytes(data,Json),token).ConfigureAwait(false);if(bytes.LongLength>MaximumBytes)return;
            CacheLayout.RejectLinks(Path.GetDirectoryName(path)!);System.IO.Directory.CreateDirectory(Path.GetDirectoryName(path)!);temporary=path+"."+Guid.NewGuid().ToString("N")+".tmp";
            await System.IO.File.WriteAllBytesAsync(temporary,bytes,token).ConfigureAwait(false);token.ThrowIfCancellationRequested();
            System.IO.File.Move(temporary,path,true);temporary=null;
        }catch(Exception e)when(e is IOException or UnauthorizedAccessException){/* Optional cache never fails a successful API read. */}
        finally{if(temporary!=null)try{System.IO.File.Delete(temporary);}catch(IOException){}catch(UnauthorizedAccessException){}}
    }
    static readonly HashSet<string> StableFields=new(StringComparer.OrdinalIgnoreCase){
        "Id","Name","SortName","OriginalTitle","Type","IsFolder","MediaType","CollectionType","Overview","ProductionYear",
        "CommunityRating","OfficialRating","Genres","Taglines","Container","Chapters","ProviderIds","PrimaryImageAspectRatio","RunTimeTicks","DateCreated","PremiereDate","ParentId","SeriesId","SeriesName",
        "SeasonId","IndexNumber","ParentIndexNumber","RecursiveItemCount","ImageTags","BackdropImageTags","ParentBackdropItemId",
        "ParentBackdropImageTags","ParentThumbItemId","ParentThumbImageTag","SeriesPrimaryImageTag","UserData"};
    static EmbyItem Stable(EmbyItem item,bool userData=false)
    {
        var node=JsonSerializer.SerializeToNode(item,Json)!.AsObject();
        foreach(var key in node.Select(p=>p.Key).ToArray())if(!StableFields.Contains(key)||key=="UserData"&&!userData)node.Remove(key);
        if(node["ProviderIds"] is JsonObject providers)foreach(var key in providers.Select(p=>p.Key).ToArray()){
            string value=providers[key]?.ToString()??"";
            bool numeric=(key.Equals("tmdb",StringComparison.OrdinalIgnoreCase)||key.Equals("tvdb",StringComparison.OrdinalIgnoreCase))&&value.Length>0&&value.All(char.IsAsciiDigit);
            bool imdb=key.Equals("imdb",StringComparison.OrdinalIgnoreCase)&&value.StartsWith("tt",StringComparison.OrdinalIgnoreCase)&&value.Length>2&&value.AsSpan(2).ToArray().All(char.IsAsciiDigit);
            if(!numeric&&!imdb)providers.Remove(key);
        }
        return node.Deserialize<EmbyItem>(Json)!;
    }
    static string PersonName(string name)=>name.Normalize(NormalizationForm.FormKC).Trim().ToUpperInvariant();
    static bool NamedOnly(EmbyPerson person)=>person.Id.StartsWith("local-name-",StringComparison.Ordinal);
    static EmbyPerson[] Cast(JsonElement item)=>item.TryGetProperty("People",out var people)&&people.ValueKind==JsonValueKind.Array
        ?people.EnumerateArray().Where(p=>EmbyPeopleApi.Text(p,"Type").Equals("Actor",StringComparison.OrdinalIgnoreCase))
            .Select(EmbyPeopleApi.Person).Where(p=>p.Name.Length>0)
            .Select(p=>p.Id.Length>0?p:p with{Id="local-name-"+Hash(PersonName(p.Name)),ImageTag=""})
            .DistinctBy(p=>(p.Id,p.Name)).ToArray():[];
    static async Task<T> Compute<T>(Func<T> work,CancellationToken token)
    {
        await Computations.WaitAsync(token).ConfigureAwait(false);
        try{return await Task.Run(work,token).ConfigureAwait(false);}finally{Computations.Release();}
    }
    static Dictionary<string,EmbyPerson> KnownPeople(IEnumerable<Record> records,CancellationToken token)=>records.SelectMany(r=>r.People)
        .Select(p=>{token.ThrowIfCancellationRequested();return p;}).Where(p=>!NamedOnly(p))
        .GroupBy(p=>PersonName(p.Name),StringComparer.Ordinal).Where(g=>g.Select(p=>p.Id).Distinct(StringComparer.OrdinalIgnoreCase).Count()==1)
        .ToDictionary(g=>g.Key,g=>g.First(),StringComparer.Ordinal);
    static EmbyPerson Identity(EmbyPerson person,Dictionary<string,EmbyPerson> known)
        =>NamedOnly(person)&&known.TryGetValue(PersonName(person.Name),out var actual)?person with{Id=actual.Id,ImageTag=actual.ImageTag}:person;
    static Dictionary<string,string> Query(Uri uri)=>uri.Query.TrimStart('?').Split('&',StringSplitOptions.RemoveEmptyEntries)
        .Select(p=>p.Split('=',2)).GroupBy(p=>Uri.UnescapeDataString(p[0]),StringComparer.OrdinalIgnoreCase)
        .ToDictionary(g=>g.Key,g=>Uri.UnescapeDataString(g.Last().ElementAtOrDefault(1)??""),StringComparer.OrdinalIgnoreCase);
    public static string CatalogueFields(string fields,string? parent,int limit,bool favorites,ServerRequestPriority priority)
        =>!string.IsNullOrEmpty(parent)&&limit==PageSize&&!favorites&&priority==ServerRequestPriority.Background?fields+",People":fields;

    // The original client still owns queueing, authentication, retries, response
    // disposal, JSON options, cancellation, and errors. Only catalogue pages join here.
    public static async Task<T?> ReadJsonAsync<T>(HttpContent content,JsonSerializerOptions? options,CancellationToken token,EmbyApiClient client,HttpRequestMessage request)
    {
        var uri=request.RequestUri;string user=User(client);var args=uri==null?new Dictionary<string,string>():Query(uri);
        int epoch=Volatile.Read(ref generation);
        bool catalogue=typeof(T)==typeof(EmbyItemsResponse)&&uri!=null
            &&Uri.UnescapeDataString(uri.AbsolutePath).EndsWith("/Users/"+user+"/Items",StringComparison.OrdinalIgnoreCase)
            &&args.GetValueOrDefault("Fields","").Split(',').Contains("People",StringComparer.OrdinalIgnoreCase)
            &&args.GetValueOrDefault("ParentId","").Length>0&&!args.ContainsKey("Filters")
            &&args.GetValueOrDefault("Limit")==PageSize.ToString();
        if(!catalogue)return await content.ReadFromJsonAsync<T>(options,token).ConfigureAwait(false);
        return await Task.Run(async()=>{
        var raw=await content.ReadFromJsonAsync<JsonElement>(options,token).ConfigureAwait(false);
        var result=raw.Deserialize<T>(options);
        if(result is EmbyItemsResponse page&&User(client)==user&&epoch==Volatile.Read(ref generation)&&raw.TryGetProperty("Items",out var values)&&values.ValueKind==JsonValueKind.Array){
            var state=Store(client);await state.Load(token).ConfigureAwait(false);
            var records=values.EnumerateArray().Select(p=>new Record(Stable(p.Deserialize<EmbyItem>(Json)!,true),Cast(p))).ToArray();
            int start=int.TryParse(args.GetValueOrDefault("StartIndex"),out int value)?Math.Max(0,value):0;
            await state.Gate.WaitAsync(token).ConfigureAwait(false);
            try{
                if(epoch!=Volatile.Read(ref generation))return result;
                string library=args["ParentId"];
                if(start==0)state.Batches[library]=new(){Total=page.TotalRecordCount};
                if(state.Batches.TryGetValue(library,out var batch)){
                    if(start!=batch.Items.Count||page.TotalRecordCount!=batch.Total||records.Any(r=>r.Item.Id.Length==0)
                        ||batch.Items.Concat(records).Select(r=>r.Item.Id).Distinct(StringComparer.OrdinalIgnoreCase).Count()!=batch.Items.Count+records.Length)
                        state.Batches.Remove(library);
                    else{
                        batch.Items.AddRange(records);
                        bool complete=batch.Total>=0?batch.Items.Count==batch.Total:records.Length<PageSize;
                        if(complete){state.Data.Libraries[library]=new(DateTimeOffset.UtcNow,batch.Items.ToArray());state.Batches.Remove(library);await state.Save(token).ConfigureAwait(false);}
                        else if(records.Length==0||batch.Total>=0&&batch.Items.Count>batch.Total)state.Batches.Remove(library);
                    }
                }
            }finally{state.Gate.Release();}
        }
        return result;
        },token).ConfigureAwait(false);
    }
    static string[] Libraries(object page)
    {
        var preferences=Access.Get<UserPreferences>(page,"_preferences");string scope=(string)Access.Call(page,"get_HomeScope")!;
        var hidden=preferences.Experience?.HiddenHomeSections?.GetValueOrDefault(scope)??[];
        return Access.Get<List<EmbyItem>>(page,"_libraryViews").Where(l=>!hidden.Contains(l.Id)).Select(l=>l.Id).ToArray();
    }
    static async Task Ensure(object page,EmbyApiClient client,CancellationToken token)
    {
        // Read page-owned fields only on the UI caller before asynchronous work.
        var state=Store(client);
        var session=Access.Get<EmbySession?>(page,"_session");
        if(session==null||session.UserId!=User(client)||!ReferenceEquals(client,Access.Get<EmbyApiClient?>(page,"_client")))throw new OperationCanceledException("账户正在切换。");
        var libraries=Libraries(page);var views=Access.Get<List<EmbyItem>>(page,"_libraryViews").ToArray();
        var refreshGate=Access.Get<SemaphoreSlim>(page,"_localSearchIndexRefreshGate");var warmup=Warmups.GetOrCreateValue(page);
        if(!warmup.Hooked&&page is FrameworkElement root){warmup.Hooked=true;root.Unloaded+=(_,_)=>{lock(warmup.Gate)warmup.Cancellation?.Cancel();};}
        await state.Load(token).ConfigureAwait(false);
        await state.Gate.WaitAsync(token).ConfigureAwait(false);bool ready;
        try{ready=libraries.All(state.Data.Libraries.ContainsKey);}finally{state.Gate.Release();}
        if(ready)return;
        Task work;
        lock(warmup.Gate){
            if(warmup.Scope!=state.Scope||warmup.Work==null||warmup.Work.IsCanceled||warmup.Work.IsCompleted&&DateTimeOffset.UtcNow>=warmup.RetryAt){
                warmup.Cancellation?.Cancel();warmup.Cancellation?.Dispose();warmup.Cancellation=new();warmup.Scope=state.Scope;
                var ownerToken=warmup.Cancellation.Token;
                warmup.Work=Build(client,state,views,libraries,refreshGate,()=>ReferenceEquals(client,Access.Get<EmbyApiClient?>(page,"_client"))&&ReferenceEquals(session,Access.Get<EmbySession?>(page,"_session")),ownerToken);
                warmup.RetryAt=DateTimeOffset.UtcNow.AddSeconds(30);
                _=warmup.Work.ContinueWith(t=>{_=t.Exception;},CancellationToken.None,TaskContinuationOptions.OnlyOnFaulted,TaskScheduler.Default);
            }
            work=warmup.Work;
        }
        await work.WaitAsync(token).ConfigureAwait(false);
    }
    static async Task Build(EmbyApiClient client,State state,EmbyItem[] views,string[] libraries,SemaphoreSlim refreshGate,Func<bool> current,CancellationToken token)
    {
        await refreshGate.WaitAsync(token).ConfigureAwait(false);
        try{
            foreach(string library in libraries){
                await state.Gate.WaitAsync(token).ConfigureAwait(false);bool exists;
                try{exists=state.Data.Libraries.ContainsKey(library);}finally{state.Gate.Release();}
                if(exists)continue;
                string? type=views.First(v=>v.Id==library).CollectionType?.ToLowerInvariant() switch{"movies"=>"Movie","tvshows"=>"Series",_=>"Movie,Series,Video,Audio"};
                int start=0;var seen=new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                while(true){
                    token.ThrowIfCancellationRequested();if(!current()||AndroidCacheRuntime.IsPaused||Store(client).Scope!=state.Scope)throw new OperationCanceledException(token);
                    var result=await client.GetItemsAsync(library,PageSize,type,false,start,token,ServerRequestPriority.Background).ConfigureAwait(false);
                    if(result.Items.Any(i=>!seen.Add(i.Id)))throw new InvalidDataException("演员索引收到重复分页，保留原索引。");
                    start+=result.Items.Count;
                    if(result.TotalRecordCount>=0&&start>=result.TotalRecordCount||result.TotalRecordCount<0&&result.Items.Count<PageSize)break;
                    if(result.Items.Count==0)throw new InvalidDataException("演员索引分页不完整，保留原索引。");
                }
                await state.Gate.WaitAsync(token).ConfigureAwait(false);
                try{if(!state.Data.Libraries.ContainsKey(library))throw new InvalidDataException("演员索引尚未完整同步。");}finally{state.Gate.Release();}
            }
        }finally{refreshGate.Release();}
    }
    static async Task<Record[]> Records(object page,EmbyApiClient client,CancellationToken token)
    {
        string[] libraries=Libraries(page);await Ensure(page,client,token).ConfigureAwait(false);var state=Store(client);
        await state.Gate.WaitAsync(token).ConfigureAwait(false);
        try{return libraries.SelectMany(l=>state.Data.Libraries.GetValueOrDefault(l)?.Items??[]).ToArray();}finally{state.Gate.Release();}
    }
    public static async Task<PeoplePage> Search(object page,EmbyApiClient client,string term,int start,CancellationToken token)
    {
        token.ThrowIfCancellationRequested();if(SearchMatching.Normalize(term).Length==0)return new([],0,Math.Max(0,start));
        var records=await Records(page,client,token).ConfigureAwait(false);token.ThrowIfCancellationRequested();
        var people=await Compute(()=>{
            var known=KnownPeople(records,token);
            return records.SelectMany(r=>r.People).Select(p=>Identity(p,known))
                .Select(p=>{token.ThrowIfCancellationRequested();return(Person:p,Score:SearchMatching.Score(p.Name,term));}).Where(p=>p.Score>0)
                .GroupBy(p=>p.Person.Id,StringComparer.OrdinalIgnoreCase).Select(g=>g.OrderByDescending(p=>p.Score).First())
                .OrderByDescending(p=>p.Score).ThenBy(p=>p.Person.Name,StringComparer.CurrentCultureIgnoreCase).Select(p=>p.Person).ToArray();
        },token).ConfigureAwait(false);
        int offset=Math.Max(0,start);var result=people.Skip(offset).Take(24).ToArray();return new(result,people.Length,offset+result.Length);
    }
    public static async Task<PersonFilms> Films(object page,EmbyApiClient client,string person,string library,int start,bool favorites,CancellationToken token)
    {
        // Current local item observations retain favorite/progress authority.
        var snapshot=(LocalSearchIndexSnapshot?)Access.Call(page,"get__localSearchIndex");
        var session=Access.Get<EmbySession?>(page,"_session");
        var liveEntries=snapshot?.ServerId==session?.ServerId&&snapshot?.UserId==session?.UserId?snapshot?.Entries??[]:[];
        await Ensure(page,client,token).ConfigureAwait(false);var state=Store(client);await state.Gate.WaitAsync(token).ConfigureAwait(false);
        Record[] records,identities;try{records=state.Data.Libraries.GetValueOrDefault(library)?.Items??[];identities=state.Data.Libraries.Values.SelectMany(l=>l.Items).ToArray();}finally{state.Gate.Release();}
        token.ThrowIfCancellationRequested();var items=await Compute(()=>{
            var live=liveEntries.Where(e=>e.LibraryId==library).Select(e=>e.Item).GroupBy(i=>i.Id,StringComparer.OrdinalIgnoreCase).ToDictionary(g=>g.Key,g=>g.First(),StringComparer.OrdinalIgnoreCase);
            var known=KnownPeople(identities,token);var requested=identities.SelectMany(r=>r.People).FirstOrDefault(p=>p.Id.Equals(person,StringComparison.OrdinalIgnoreCase));
            string id=requested==null?person:Identity(requested,known).Id;
            return records.Select(r=>{token.ThrowIfCancellationRequested();return r;}).Where(r=>r.People.Any(p=>Identity(p,known).Id.Equals(id,StringComparison.OrdinalIgnoreCase)))
            .Select(r=>live.GetValueOrDefault(r.Item.Id)??Stable(r.Item,true)).Where(i=>!favorites||i.UserData?.IsFavorite==true)
            .DistinctBy(i=>i.Id,StringComparer.OrdinalIgnoreCase).OrderBy(i=>i.SortName??i.Name,StringComparer.CurrentCultureIgnoreCase).ToArray();
        },token).ConfigureAwait(false);
        return new(items.Skip(Math.Max(0,start)).Take(48).ToArray(),items.Length);
    }
    public static async Task<IReadOnlyList<EmbyItem>> SupplementTitles(object page,EmbyApiClient client,string term,CancellationToken token)
    {
        string? library=Access.Get<string?>(page,"_lastSearchLibraryId");bool favorites=Access.Get<bool>(page,"_lastSearchFavoritesOnly");
        var allowed=Access.Get<List<EmbyItem>>(page,"_libraryViews").Select(l=>l.Id).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var unavailable=Access.Get<HashSet<string>>(page,"_unavailableMediaKeys").ToHashSet(StringComparer.OrdinalIgnoreCase);
        var snapshot=(LocalSearchIndexSnapshot?)Access.Call(page,"get__localSearchIndex");
        var state=Store(client);await state.Load(token).ConfigureAwait(false);await state.Gate.WaitAsync(token).ConfigureAwait(false);
        LocalSearchIndexEntry[] entries;
        try{entries=state.Data.Libraries.Where(l=>allowed.Contains(l.Key)&&(library==null||l.Key.Equals(library,StringComparison.OrdinalIgnoreCase)))
            .SelectMany(l=>l.Value.Items.Select(r=>new LocalSearchIndexEntry(l.Key,r.Item))).ToArray();}finally{state.Gate.Release();}
        return await Compute(()=>{
            var live=(snapshot?.UserId==User(client)?snapshot.Entries:[]).Select(e=>e.Item).GroupBy(i=>i.Id,StringComparer.OrdinalIgnoreCase).ToDictionary(g=>g.Key,g=>g.First(),StringComparer.OrdinalIgnoreCase);
            var found=SearchMatching.Search(entries,term,library,int.MaxValue,false,0,token).Select(i=>{var item=Stable(i,true);if(live.TryGetValue(i.Id,out var latest))item.UserData=latest.UserData;CachedItems.GetValue(item,_=>CacheMarker);return item;})
                .Where(i=>!favorites||i.UserData?.IsFavorite==true);
            return UnavailableMediaItemPolicy.Exclude(found,unavailable);
        },token).ConfigureAwait(false);
    }
    public static async Task<IReadOnlyList<EmbyPerson>> Detail(EmbyApiClient client,string user,string item,CancellationToken token)
    {
        var state=Store(client);await state.Load(token).ConfigureAwait(false);await state.CastGate.WaitAsync(token).ConfigureAwait(false);
        try{
        await state.Gate.WaitAsync(token).ConfigureAwait(false);
        try{
            var known=state.Data.Libraries.Values.SelectMany(l=>l.Items).FirstOrDefault(r=>r.Item.Id.Equals(item,StringComparison.OrdinalIgnoreCase));
            if(known!=null)return known.People;
            if(state.Data.Cast.TryGetValue(item,out var saved)&&saved.At>=state.Invalidated)return saved.People;
        }finally{state.Gate.Release();}
        var raw=await new EmbyPeopleApi(client,user).Get($"Users/{Uri.EscapeDataString(user)}/Items/{Uri.EscapeDataString(item)}?Fields=People",token).ConfigureAwait(false);
        var result=Cast(raw);token.ThrowIfCancellationRequested();
        if(Store(client).Scope==state.Scope){await state.Gate.WaitAsync(token).ConfigureAwait(false);try{state.Data.Cast[item]=new(DateTimeOffset.UtcNow,result);await state.Save(token).ConfigureAwait(false);}finally{state.Gate.Release();}}
        return result;
        }finally{state.CastGate.Release();}
    }

    // Only display-list call sites use these wrappers. The original APIs used by
    // playback, route selection, refresh observations, and progress remain live.
    public static Task<EmbyItemsResponse> Seasons(EmbyApiClient client,string series,CancellationToken token)
        =>DisplayList(client,"seasons",series,token,()=>client.GetSeasonsAsync(series,token));
    public static Task<EmbyItemsResponse> Episodes(EmbyApiClient client,string series,string? season,CancellationToken token)
        =>DisplayList(client,"episodes",JsonSerializer.Serialize(new[]{series,season}),token,()=>client.GetEpisodesAsync(series,season,token));
    public static async Task<EmbyItem> DisplayItem(EmbyApiClient client,string item,CancellationToken token)
    {
        var state=Store(client);await state.Load(token).ConfigureAwait(false);await state.Gate.WaitAsync(token).ConfigureAwait(false);
        try{
            var saved=state.Data.Libraries.Values.SelectMany(l=>l.Items).FirstOrDefault(r=>r.Item.Id.Equals(item,StringComparison.OrdinalIgnoreCase));
            if(saved!=null){var value=Stable(saved.Item,true);CachedItems.GetValue(value,_=>CacheMarker);return value;}
        }finally{state.Gate.Release();}
        var result=await DisplayList(client,"detail",item,token,async()=>new(){Items=[await client.GetItemAsync(item,token).ConfigureAwait(false)],TotalRecordCount=1}).ConfigureAwait(false);
        return result.Items.Single();
    }
    static async Task<EmbyItemsResponse> DisplayList(EmbyApiClient client,string kind,string id,CancellationToken token,Func<Task<EmbyItemsResponse>> fetch)
    {
        var state=Store(client);await state.Load(token).ConfigureAwait(false);await state.DisplayGate.WaitAsync(token).ConfigureAwait(false);
        int epoch=Volatile.Read(ref generation);
        try{
            string path=Path.Combine(state.Directory,kind+"-"+Hash(id)+".json");var saved=await Read<Display>(path,token).ConfigureAwait(false);
            if(saved?.Result?.Items!=null&&saved.At>=state.Invalidated&&DateTimeOffset.UtcNow-saved.At<TimeSpan.FromMinutes(BrowseCachePolicy.RefreshMinutes))return Clone(saved.Result,true);
            try{
                var result=await fetch().ConfigureAwait(false);token.ThrowIfCancellationRequested();
                if(Store(client).Scope==state.Scope&&epoch==Volatile.Read(ref generation)){await Write(path,new Display(DateTimeOffset.UtcNow,new(){Items=result.Items.Select(i=>Stable(i,true)).ToList(),TotalRecordCount=result.TotalRecordCount}),token).ConfigureAwait(false);TrimDisplay(state);}
                return result;
            }catch(Exception e)when(saved?.Result?.Items!=null&&(e is HttpRequestException||e is EmbyApiException api&&(api.IsTimeout||api.StatusCode==null))){token.ThrowIfCancellationRequested();return Clone(saved.Result,true);}
        }finally{state.DisplayGate.Release();}
    }
    static EmbyItemsResponse Clone(EmbyItemsResponse source,bool cached)
    {
        var result=JsonSerializer.Deserialize<EmbyItemsResponse>(JsonSerializer.SerializeToUtf8Bytes(source,Json),Json)!;
        if(cached)foreach(var item in result.Items)CachedItems.GetValue(item,_=>CacheMarker);return result;
    }
    public static bool IsCached(EmbyItem item)=>CachedItems.TryGetValue(item,out _);
    public static void Refresh(object page)
    {
        if(Access.Get<EmbyApiClient?>(page,"_client") is {} client&&User(client).Length>0)Store(client).Invalidated=DateTimeOffset.UtcNow;
        if(Warmups.TryGetValue(page,out var warmup))lock(warmup.Gate){warmup.Cancellation?.Cancel();warmup.RetryAt=default;}
    }
    static void TrimDisplay(State state)
    {
        try{
            var files=new DirectoryInfo(state.Directory).GetFiles("*.json").Where(f=>f.Name!="catalogue.json").OrderByDescending(f=>f.LastWriteTimeUtc).ToArray();
            long bytes=0;for(int i=0;i<files.Length;i++){bytes+=files[i].Length;if(i>=512||bytes>MaximumBytes)files[i].Delete();}
        }catch(Exception e)when(e is IOException or UnauthorizedAccessException){}
    }
    public static void Pause()
    {
        foreach(var pair in Warmups)lock(pair.Value.Gate)pair.Value.Cancellation?.Cancel();
    }
    public static async Task Clear()
    {
        Interlocked.Increment(ref generation);Pause();
        foreach(var weak in Stores.Values){if(!weak.TryGetTarget(out var state))continue;await state.Gate.WaitAsync().ConfigureAwait(false);try{state.Data=new(1,state.Scope,new(),new());state.Batches.Clear();state.Loaded=true;}finally{state.Gate.Release();}}
        var path=Path.GetFullPath(Path.Combine(CachePaths.Metadata,"LocalMetadata-v1"));
        if(!CacheLayout.IsWithin(CachePaths.Metadata,path))throw new IOException("文字缓存清理范围无效。");
        CacheLayout.RejectLinks(path);if(System.IO.Directory.Exists(path))await Task.Run(()=>System.IO.Directory.Delete(path,true));
    }
}
