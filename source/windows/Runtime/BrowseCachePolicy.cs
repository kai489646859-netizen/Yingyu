using System.Reflection;
using System.Collections;
using System.Runtime.CompilerServices;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Input;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using EmbyDesktop.Core.Models;
using EmbyDesktop.Core.Services;

namespace Yingyu.Update;

// Display snapshots only. Fresh playback/route/progress code remains the owner
// of playback data, and clearing this store never touches DesktopLibraryStore.
public static class BrowseCachePolicy
{
    public const long MaximumBytes = 64L * 1024 * 1024;
    public const int MaximumRecords = 96;
    static readonly SemaphoreSlim StoreGate = new(1, 1);
    static readonly object PagesGate = new();
    static readonly List<WeakReference<object>> Pages = new();
    static readonly Dictionary<object, CancellationTokenSource> Refreshes = new(ReferenceEqualityComparer.Instance);
    sealed class ScopeClock { internal DateTimeOffset Checked,Full; }
    sealed class RefreshClock { internal object? Session;internal readonly Dictionary<string,ScopeClock> Scopes=new(); }
    static readonly ConditionalWeakTable<object,RefreshClock> Clocks=new();
    static bool Browsing(object page)=>DesktopScroll.IsAnimating(page)
        ||DateTimeOffset.UtcNow-Access.Get<DateTimeOffset>(page,"_lastDesktopInteraction")<TimeSpan.FromSeconds(5);
    static object? Snapshot(object page,string key)=>key=="home"?Access.Get<object?>(page,"_homeSnapshot")
        :(Access.Get<object>(page,"_librarySnapshots") as IDictionary)?[key];
    static ScopeClock Clock(object page,object session,string key,object? snapshot,DateTimeOffset now)
    {
        var owner=Clocks.GetOrCreateValue(page);
        if(!ReferenceEquals(owner.Session,session)){owner.Session=session;owner.Scopes.Clear();}
        var updated=snapshot?.GetType().GetProperty("UpdatedAt")?.GetValue(snapshot) is DateTimeOffset time?time:now;
        if(updated>now)updated=now;
        if(!owner.Scopes.TryGetValue(key,out var clock)){clock=new(){Checked=updated,Full=updated};owner.Scopes[key]=clock;}
        else if(updated>clock.Full){clock.Full=updated;if(updated>clock.Checked)clock.Checked=updated;}
        return clock;
    }
    static int _paused;
    static int _minutes;
    static readonly string[] CancellationFields = ["_localSearchIndexCts", "_browseLoadCancellation", "_searchCancellation", "_collectionCancellation"];

    public static int RefreshMinutes
    {
        get
        {
            if (Volatile.Read(ref _minutes) != 0) return _minutes;
            try { _minutes = int.Parse(File.ReadAllText(Path.Combine(CachePaths.UserDataRoot, "browse-refresh.txt"))); }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException or FormatException) { _minutes = 15; }
            if (_minutes is not (5 or 15 or 30)) _minutes = 15;
            return _minutes;
        }
        set
        {
            if (value is not (5 or 15 or 30)) return;
            Directory.CreateDirectory(CachePaths.UserDataRoot);
            var path = Path.Combine(CachePaths.UserDataRoot, "browse-refresh.txt");
            File.WriteAllText(path + ".tmp", value.ToString(System.Globalization.CultureInfo.InvariantCulture));
            File.Move(path + ".tmp", path, true);
            Volatile.Write(ref _minutes, value);
        }
    }

    static readonly ConditionalWeakTable<FrameworkElement,object> InteractionHooks=new();
    static void CancelOptional(object page)
    {
        lock(PagesGate)if(Refreshes.TryGetValue(page,out var source))try{source.Cancel();}catch(ObjectDisposedException){}
    }
    public static void Configure(object page)
    {
        if(page is FrameworkElement element)InteractionHooks.GetValue(element,owner=>{
            owner.AddHandler(UIElement.PointerWheelChangedEvent,new PointerEventHandler((_,_)=>CancelOptional(owner)),true);
            owner.AddHandler(UIElement.PointerPressedEvent,new PointerEventHandler((_,_)=>CancelOptional(owner)),true);
            owner.Unloaded+=(_,_)=>CancelOptional(owner);return new object();
        });
        lock (PagesGate)
        {
            if (!Pages.Any(p => p.TryGetTarget(out var target) && ReferenceEquals(target, page))) Pages.Add(new(page));
            Pages.RemoveAll(p => !p.TryGetTarget(out _));
        }
    }

    public static void Pause(bool paused)
    {
        if (Interlocked.Exchange(ref _paused, paused ? 1 : 0) == (paused ? 1 : 0) || !paused) return;
        LocalMetadata.Pause();
        CancellationTokenSource[] abort;
        object[] pages;
        lock (PagesGate)
        {
            abort = Refreshes.Values.ToArray();
            pages = Pages.Select(entry => entry.TryGetTarget(out var target) ? target : null).OfType<object>().ToArray();
        }
        foreach (var source in abort) try { source.Cancel(); } catch (ObjectDisposedException) { }
        foreach (var page in pages)
            foreach (var field in CancellationFields)
                try { Access.Get<CancellationTokenSource?>(page, field)?.Cancel(); }
                catch (Exception e) when (e is ObjectDisposedException or NullReferenceException) { }
    }

    static readonly BindingFlags Flags = BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic;
    static bool Flag(object page, string name) => page.GetType().GetField(name, Flags)?.GetValue(page) is true;
    static bool ForegroundRefresh(object page)=>Flag(page,"_manualRefreshInProgress")||Flag(page,"_globalRefreshInProgress")||Flag(page,"_libraryLoadInProgress")||Flag(page,"_profileSwitchInProgress");
    static bool Playback(object page) => page.GetType().GetProperty("IsPlaybackActive", Flags)?.GetValue(page) is true;

    public static async Task RefreshAsync(object page)
    {
        Configure(page);
        if (page is not FrameworkElement{IsLoaded:true} element||Browsing(page)
            ||Volatile.Read(ref _paused) != 0 || Playback(page) || Flag(page, "_automaticCacheSyncInProgress") ||
            Flag(page, "_profileSwitchInProgress") || Flag(page, "_libraryLoadInProgress") ||
            Flag(page, "_manualRefreshInProgress") || Flag(page, "_globalRefreshInProgress") ||
            Flag(page, "_localSearchIndexRefreshInProgress") || Flag(page, "_authenticationNeedsAttention") ||
            Access.Get<object?>(page, "_launchCancellation") != null) return;
        var session = Access.Get<EmbySession?>(page, "_session");
        var client = Access.Get<EmbyApiClient?>(page, "_client");
        if (session == null || client == null) return;
        if (Access.Get<object?>(page, "_connectionFailure") != null)
        {
            if (DateTimeOffset.UtcNow >= Access.Get<DateTimeOffset>(page, "_nextRecoveryAt"))
                await (Task)Access.Call(page, "CheckConnectionRecoveryAsync")!;
            return;
        }
        var now = DateTimeOffset.UtcNow;
        var active = Access.Get<string?>(page, "_activeSnapshotKey");
        var library = Access.Get<string?>(page, "_activeLibraryId");
        // Android refreshes home/current library; an idle global catalogue sweep
        // is not used as a timer. Its existing optional search warmup is retained.
        if (active != "home" && string.IsNullOrEmpty(library)||active==null) return;
        // Hidden settings/detail/search views do not trigger catalogue reads.
        if(page.GetType().GetField("LibraryView",Flags)?.GetValue(page) is not UIElement{Visibility:Visibility.Visible}
            ||page.GetType().GetField("SettingsView",Flags)?.GetValue(page) is UIElement{Visibility:Visibility.Visible}
            ||page.GetType().GetField("SearchResultsPanel",Flags)?.GetValue(page) is UIElement{Visibility:Visibility.Visible}
            ||!string.IsNullOrWhiteSpace(Access.Get<string?>(page,"_lastSearchTerm")))return;
        var original=Snapshot(page,active);if(original==null)return; // Normal foreground load owns a missing snapshot.
        var clock=Clock(page,session,active,original,now);
        if(now-clock.Checked<TimeSpan.FromMinutes(RefreshMinutes))return;
        using var cancellation = new CancellationTokenSource();
        lock (PagesGate)
        {
            if (Volatile.Read(ref _paused) != 0 || Refreshes.ContainsKey(page)) return;
            Refreshes[page] = cancellation;
        }
        clock.Checked=now; // Failure also observes the interval; never retry every timer tick.
        Access.Set(page, "_automaticCacheSyncInProgress", true);
        try
        {
            if (active == "home")
            {
                var task = (Task)Access.Call(page, "FetchHomeSnapshotAsync", client, cancellation.Token)!;
                await task;
                cancellation.Token.ThrowIfCancellationRequested();
                if (!ReferenceEquals(session, Access.Get<EmbySession?>(page, "_session"))||!ReferenceEquals(client,Access.Get<EmbyApiClient?>(page,"_client"))
                    ||Playback(page)||ForegroundRefresh(page)||Browsing(page)||!ReferenceEquals(original,Snapshot(page,active))) return;
                var snapshot = task.GetType().GetProperty("Result")!.GetValue(task);
                Access.Set(page, "_homeSnapshot", snapshot);
                if (Access.Get<string?>(page, "_activeSnapshotKey") == "home") Access.Call(page, "ShowHomeSnapshot", snapshot);
            }
            else
            {
                var views=Access.Get<List<EmbyItem>>(page,"_libraryViews");
                var view=views.FirstOrDefault(item=>item.Id==library);if(view==null)return;
                string type=view.CollectionType?.ToLowerInvariant() switch{"movies"=>"Movie","tvshows"=>"Series","music"=>"Audio","books"=>"Book",_=>"Movie,Series,Video,Audio"};
                var probe=await client.GetItemsAsync(library,1,type,false,0,cancellation.Token,ServerRequestPriority.Background);
                cancellation.Token.ThrowIfCancellationRequested();
                if(Browsing(page)||Playback(page)||ForegroundRefresh(page)||!ReferenceEquals(session,Access.Get<EmbySession?>(page,"_session"))
                    ||!ReferenceEquals(client,Access.Get<EmbyApiClient?>(page,"_client")))return;
                int count=((IEnumerable)original.GetType().GetProperty("Items")!.GetValue(original)!).Cast<object>().Count();
                // A count is only an inexpensive change signal, not proof that
                // all metadata is unchanged. An idle full check remains at most
                // one hour (or the user's longer four-interval window) apart.
                if(probe.TotalRecordCount==count&&now-clock.Full<TimeSpan.FromMinutes(Math.Max(60,4*RefreshMinutes)))return;
                var entries=await LibraryCacheSync.ReadCompleteLibraryAsync(library!,
                    (start,token)=>client.GetItemsAsync(library,200,type,false,start,token,ServerRequestPriority.Background),cancellation.Token);
                cancellation.Token.ThrowIfCancellationRequested();
                if(!ReferenceEquals(session,Access.Get<EmbySession?>(page,"_session"))||!ReferenceEquals(client,Access.Get<EmbyApiClient?>(page,"_client"))
                    ||Playback(page)||ForegroundRefresh(page)||Browsing(page)||!ReferenceEquals(original,Snapshot(page,active)))return;
                var updated=Activator.CreateInstance(original.GetType(),BindingFlags.Instance|BindingFlags.Public|BindingFlags.NonPublic,null,
                    new object[]{entries.Select(entry=>entry.Item).ToList(),DateTimeOffset.UtcNow},null)!;
                ((IDictionary)Access.Get<object>(page,"_librarySnapshots"))[active]=updated;
                if(Access.Get<string?>(page,"_activeSnapshotKey")==active)Access.Call(page,"ShowLibrarySnapshot",updated,view.Name,true,true);
            }
            clock.Full=DateTimeOffset.UtcNow;
        }
        catch (Exception error) when (error is OperationCanceledException or EmbyApiException or HttpRequestException or TargetInvocationException or InvalidDataException)
        {
            // Keep usable display snapshots; foreground retry retains its own error.
        }
        finally
        {
            Access.Set(page, "_automaticCacheSyncInProgress", false);
            lock (PagesGate) Refreshes.Remove(page);
        }
    }

    static bool IsBrowseRecord(string path) => Path.GetFileNameWithoutExtension(path) is var name && name.Length == 64 && name.All(Uri.IsHexDigit);
    static string PathFor(string server, string user) => Path.Combine(CachePaths.Metadata,
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(JsonSerializer.Serialize(new[] { server, user })))).ToLowerInvariant() + ".json");

    public static async Task<LocalSearchIndexSnapshot?> LoadAsync(object store, string server, string user, CancellationToken token)
    {
        await StoreGate.WaitAsync(token).ConfigureAwait(false);
        try
        {
            return await Task.Run(async () =>
            {
                var path = PathFor(server, user);
                if (!File.Exists(path) || new FileInfo(path).Length > MaximumBytes) return null;
                var snapshot = JsonSerializer.Deserialize<LocalSearchIndexSnapshot>(await File.ReadAllBytesAsync(path, token).ConfigureAwait(false));
                if (snapshot?.ServerId != server || snapshot.UserId != user || snapshot.LibraryFiles != null) return null;
                File.SetLastWriteTimeUtc(path, DateTime.UtcNow);
                return Sanitize(snapshot);
            }, token).ConfigureAwait(false);
        }
        catch (Exception error) when (error is IOException or JsonException or UnauthorizedAccessException) { return null; }
        finally { StoreGate.Release(); }
    }

    public static async Task SaveAsync(object store, LocalSearchIndexSnapshot snapshot, CancellationToken token)
    {
        var bytes = await Task.Run(() => JsonSerializer.SerializeToUtf8Bytes(Sanitize(snapshot)), token).ConfigureAwait(false);
        await StoreGate.WaitAsync(token).ConfigureAwait(false);
        string? temporary = null;
        try
        {
            Directory.CreateDirectory(CachePaths.Metadata);
            var path = PathFor(snapshot.ServerId, snapshot.UserId);
            // An oversized optional record must not displace the rest of the cache.
            if (bytes.LongLength > MaximumBytes) return;
            temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
            await File.WriteAllBytesAsync(temporary, bytes, token).ConfigureAwait(false);
            token.ThrowIfCancellationRequested();
            File.Move(temporary, path, true); temporary = null;
            var files = new DirectoryInfo(CachePaths.Metadata).GetFiles("*.json").Where(f => IsBrowseRecord(f.Name)).OrderBy(f => f.LastWriteTimeUtc).ToList();
            long length = files.Sum(f => f.Length);
            while (files.Count > MaximumRecords || length > MaximumBytes)
            {
                var first = files[0]; files.RemoveAt(0); length -= first.Length; first.Delete();
            }
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { /* Optional cache is not an account or playback write. */ }
        finally
        {
            if (temporary != null) try { File.Delete(temporary); } catch (IOException) { }
            StoreGate.Release();
        }
    }

    public static async Task ClearAsync()
    {
        await LocalMetadata.Clear();
        await StoreGate.WaitAsync().ConfigureAwait(false);
        try
        {
            if (Directory.Exists(CachePaths.Metadata))
                foreach (var path in Directory.EnumerateFiles(CachePaths.Metadata, "*.json").Where(IsBrowseRecord)) File.Delete(path);
        }
        finally { StoreGate.Release(); }
    }

    static readonly HashSet<string> ItemFields = new(StringComparer.OrdinalIgnoreCase)
    {
        "Id","Name","SortName","OriginalTitle","Type","IsFolder","MediaType","CollectionType","Overview","ProductionYear",
        "CommunityRating","OfficialRating","Genres","RunTimeTicks","DateCreated","PremiereDate","ParentId","SeriesId","SeriesName",
        "SeasonId","IndexNumber","ParentIndexNumber","RecursiveItemCount","ImageTags","BackdropImageTags","ParentBackdropItemId",
        "ParentBackdropImageTags","ParentThumbItemId","ParentThumbImageTag","SeriesPrimaryImageTag","ProviderIds","UserData","MediaSources","MediaStreams"
    };
    static readonly HashSet<string> UserFields = new(StringComparer.OrdinalIgnoreCase)
        { "PlaybackPositionTicks","Played","LastPlayedDate","PlayCount","IsFavorite","Likes","Rating" };
    static readonly HashSet<string> SourceFields = new(StringComparer.OrdinalIgnoreCase)
        { "Id","Name","Container","VideoType","Bitrate","MediaStreams" };
    static readonly HashSet<string> VideoFields = new(StringComparer.OrdinalIgnoreCase)
        { "Type","Width","Height","Codec","VideoRange","VideoRangeType","BitRate","Profile","DolbyVisionProfile" };
    static void Keep(JsonObject value, HashSet<string> fields)
    { foreach (var key in value.Select(kv => kv.Key).ToArray()) if (!fields.Contains(key)) value.Remove(key); }
    static void Streams(JsonArray? array)
    {
        if (array == null) return;
        foreach (var node in array.ToArray())
            if (node is not JsonObject stream || stream["Type"]?.GetValue<string>() != "Video") array.Remove(node);
            else Keep(stream, VideoFields);
    }
    static EmbyItem Item(EmbyItem item)
    {
        var json = JsonSerializer.SerializeToNode(item)!.AsObject(); Keep(json, ItemFields);
        if (json["UserData"] is JsonObject user) Keep(user, UserFields);
        if (json["ProviderIds"] is JsonObject providers)
            foreach (var key in providers.Select(kv => kv.Key).ToArray())
                if (!key.Equals("tmdb", StringComparison.OrdinalIgnoreCase) || providers[key]?.ToString().All(char.IsAsciiDigit) != true) providers.Remove(key);
        if (json["MediaSources"] is JsonArray sources)
            foreach (var source in sources.OfType<JsonObject>()) { Keep(source, SourceFields); Streams(source["MediaStreams"] as JsonArray); }
        Streams(json["MediaStreams"] as JsonArray);
        return json.Deserialize<EmbyItem>()!;
    }
    public static LocalSearchIndexSnapshot Sanitize(LocalSearchIndexSnapshot value) => value with
    {
        Entries = value.Entries.Select(entry => entry with { Item = Item(entry.Item) }).ToArray(),
        Libraries = value.Libraries?.Select(Item).ToArray(), ResumeItems = value.ResumeItems?.Select(Item).ToArray(),
        HomeSections = value.HomeSections?.Select(section => section with { Items = section.Items.Select(Item).ToArray() }).ToArray(),
        LibraryFiles = null
    };
}
