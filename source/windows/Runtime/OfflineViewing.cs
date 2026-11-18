using System.Globalization;
using System.Text;
using System.Text.Json;
using EmbyDesktop.Core.Models;
using EmbyDesktop.Core.Services;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Richasy.MpvKernel.Core;

namespace Yingyu.Update;

public static class OfflineViewing
{
    public static async Task AddDownloads(object page)
    {
        if(!await TrySeason(page)&&!await TryVersion(page))
            await (Task)Access.Call(page,"AddSingleDownloadAsync")!;
    }
    public static EmbyItem ResumeItem(object page,EmbyItem item)
    {
        var state=Access.Get<DesktopLibraryState>(page,"_desktopState");
        var scope=(string)Access.Call(page,"get_DesktopScope")!;
        var version=ReadVersion(item.Id);
        if(version is not null&&version.Scope!=scope)
            throw new IOException("离线片源不属于当前账号。");
        var row=state.PlaybackHistory.GetValueOrDefault(scope)?.FirstOrDefault(candidate=>candidate.Id==(version?.Item??item.Id));
        if(row?.UserData is null &&version is null)return item;
        // Clone the download's metadata before replacing its transient progress.
        var copy=CopyItem(item,version?.Item??item.Id,version?.Name??item.Name);
        if(copy is null)return item;
        copy.UserData=row?.UserData??item.UserData;
        return copy;
    }
    static EmbyItem? CopyItem(EmbyItem item,string id,string name)
    {
        var node=JsonSerializer.SerializeToNode(item)?.AsObject();
        if(node is null)return null;
        node[nameof(EmbyItem.Id)]=id;node[nameof(EmbyItem.Name)]=name;
        return node.Deserialize<EmbyItem>();
    }
    const string VersionPrefix="yingyu-source-v1-";
    internal sealed record Version(string Scope,string Server,string User,string Item,string Name,string Source,string? Container);
    static string VersionPath(string key)=>Path.Combine(CachePaths.UserDataRoot,"Downloads","VersionSelections",key+".json");
    internal static string VersionKey(string scope,string item,string source)=>VersionPrefix+VideoCacheStore.Hash(scope,item,source);
    static Version? ReadVersion(string key)
    {
        if(!key.StartsWith(VersionPrefix,StringComparison.Ordinal))return null;
        var hex=key.AsSpan(VersionPrefix.Length);
        if(hex.Length!=64||!hex.ToString().All(char.IsAsciiHexDigit))throw new IOException("离线片源标识无效。");
        string path=VersionPath(key);CacheLayout.RejectLinks(path);
        if(new FileInfo(path) is not {Exists:true,Length:>0 and <=16384})throw new IOException("离线片源记录缺失。");
        var entry=JsonSerializer.Deserialize<Version>(File.ReadAllText(path));
        return entry is not null&&VersionKey(entry.Scope,entry.Item,entry.Source)==key
            ?entry:throw new IOException("离线片源记录无效。");
    }
    static void PersistVersion(string key,Version version)
    {
        string path=VersionPath(key);CacheLayout.RejectLinks(path);
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        string stage=path+"."+Guid.NewGuid().ToString("N")+".tmp";
        try{File.WriteAllText(stage,JsonSerializer.Serialize(version));File.Move(stage,path,true);}
        finally{File.Delete(stage);}
    }
    public static Uri VersionedDownloadUri(EmbyApiClient client,string key)
    {
        if(ReadVersion(key) is not {} version)return client.BuildDownloadUri(key);
        if(version.Server!=client.ServerUrl||version.User!=Access.Get<string?>(client,"_userId"))
            throw new InvalidOperationException("下载任务与当前账号不一致。");
        return client.BuildPlaybackUri(version.Item,new MediaSourceInfo
        {Id=version.Source,Container=version.Container,SupportsDirectPlay=true},false);
    }
    public static string VersionedSourceId(string key)=>ReadVersion(key)?.Source??key;

    static async Task<bool> TryVersion(object page)
    {
        if(page is not FrameworkElement {XamlRoot:{} root}
            ||Access.Get<EmbyItem?>(page,"_detailPlayableItem") is not {} item
            ||Access.Get<EmbyApiClient?>(page,"_client") is not {} client
            ||Access.Call(page,"get_IsPlaybackActive") is true)return false;
        string scope=(string)Access.Call(page,"get_DesktopScope")!;
        bool Current()=>ReferenceEquals(client,Access.Get<EmbyApiClient?>(page,"_client"))
            &&Access.Get<EmbyItem?>(page,"_detailPlayableItem")?.Id==item.Id
            &&Access.Call(page,"get_IsPlaybackActive") is not true;
        using var timeout=new CancellationTokenSource(TimeSpan.FromSeconds(12));
        try
        {
            var playback=await client.GetDirectPlaybackInfoAsync(item.Id,TimeSpan.FromSeconds(10),timeout.Token,null);
            if(!Current())return true;
            var sources=playback.MediaSources.Where(source=>!string.IsNullOrWhiteSpace(source.Id)
                &&(source.SupportsDirectPlay||source.SupportsDirectStream)&&source.RequiresOpening!=true
                &&source.IsInfiniteStream!=true).DistinctBy(source=>source.Id).ToArray();
            if(playback.MediaSources.Count<=1)return false;
            if(sources.Length==0)throw new InvalidOperationException("这个条目没有可离线保存的原始版本。");
            var list=new ListView{MaxHeight=300,SelectionMode=ListViewSelectionMode.Single};
            string? saved=Access.Get<DesktopLibraryState>(page,"_desktopState").Versions.GetValueOrDefault(scope+"|"+item.Id);
            foreach(var source in sources)
                list.Items.Add(new ListViewItem{Content=source.Name??source.Container??"原始版本",Tag=source});
            list.SelectedIndex=Math.Max(0,Array.FindIndex(sources,source=>source.Id==saved));
            var dialog=new ContentDialog{XamlRoot=root,Title="选择下载版本",PrimaryButtonText="下载",
                CloseButtonText="取消",Content=list};
            if(await ModalProtection.Show(dialog)!=ContentDialogResult.Primary||!Current()
                ||list.SelectedItem is not ListViewItem{Tag:MediaSourceInfo sourceChoice})return true;
            string key=VersionKey(scope,item.Id,sourceChoice.Id);
            var copy=CopyItem(item,key,item.Name+" · "+(sourceChoice.Name??sourceChoice.Container??"指定版本"));
            if(copy is null)throw new IOException("保存版本信息失败。");
            var version=new Version(scope,client.ServerUrl,Access.Get<string>(client,"_userId"),item.Id,item.Name,
                sourceChoice.Id,sourceChoice.Container);
            PersistVersion(key,version);
            var downloads=(OfflineDownloadManager)Access.Call(page,"get_Downloads")!;
            var job=await downloads.AddAsync(scope,copy);
            if(Current()&&job.State!="已完成")await (Task)Access.Call(page,"StartDownloadAsync",job)!;
            else if(Current())Access.Call(page,"ShowLibraryStatus","该版本已下载，可在离线下载中播放。","下载任务",InfoBarSeverity.Success,false);
            return true;
        }
        catch(Exception error)
        {
            if(Current())
                await (Task)Access.Call(page,"ShowErrorDialogAsync","离线下载",error is InvalidOperationException?error.Message:"无法确认下载版本，请稍后重试。")!;
            return true;
        }
    }
    internal static async Task OpenSaved(object page)
    {
        if(page is not FrameworkElement { XamlRoot: {} root })return;
        if(Access.Get<EmbyApiClient?>(page,"_client") is not null
            && Access.Get<EmbySession?>(page,"_session") is not null)
        { await (Task)Access.Call(page,"ShowDownloadsAsync")!;return; }
        var downloads=(OfflineDownloadManager)Access.Call(page,"get_Downloads")!;
        var profiles=await Access.Get<ServerProfileStore>(page,"_serverProfileStore").LoadAsync(CancellationToken.None);
        var owners=profiles.GroupBy(p=>DesktopLibraryStore.Scope(p.Session)).ToDictionary(g=>g.Key,g=>g.First().Session);
        var jobs=(await downloads.ListAsync()).Where(job=>job.State=="已完成"&&owners.ContainsKey(job.Scope)).ToArray();
        if(jobs.Length==0)
        {
            await (Task)Access.Call(page,"ShowErrorDialogAsync","离线下载","已保存的账号没有可离线播放的影片。")!;
            return;
        }
        var list=new ListView{MaxHeight=350,SelectionMode=ListViewSelectionMode.Single};
        foreach(var job in jobs)
        {
            var owner=owners[job.Scope];
            list.Items.Add(new ListViewItem{Content=$"{job.Item.Name} · {owner.UserName}",Tag=job});
        }
        list.SelectedIndex=0;
        var dialog=new ContentDialog{XamlRoot=root,Title="离线下载",Content=list,
            PrimaryButtonText="播放",CloseButtonText="关闭",DefaultButton=ContentDialogButton.Primary};
        if(await ModalProtection.Show(dialog)!=ContentDialogResult.Primary
            || list.SelectedItem is not ListViewItem {Tag:OfflineDownload selected}
            || Access.Get<EmbyApiClient?>(page,"_client") is not null)return;
        var identity=owners[selected.Scope];
        var store=(DesktopLibraryStore)Access.Call(page,"get_DesktopStore")!;
        var local=await store.ReadAsync();
        if(Access.Get<EmbyApiClient?>(page,"_client") is not null)return;
        Access.Set(page,"_desktopState",local);
        var client=(EmbyApiClient)Access.Call(page,"CreateClient",identity.ServerUrl)!;
        client.RestoreSession(identity.UserId,identity.AccessToken);
        var previous=Access.Get<EmbySession?>(page,"_session");
        var previousPlayer=Access.Get<object?>(page,"_playbackSession");
        Access.Set(page,"_client",client);
        Access.Set(page,"_session",identity);
        try
        {
            DurablePlaybackSync.Bind(page);
            await (Task)Access.Call(page,"PlayDownloadAsync",selected)!;
        }
        finally
        {
            if(ReferenceEquals(client,Access.Get<EmbyApiClient?>(page,"_client")))
            {
                Access.Set(page,"_client",null);
                Access.Set(page,"_session",previous);
            }
            if(ReferenceEquals(previousPlayer,Access.Get<object?>(page,"_playbackSession")))
                client.Dispose();
        }
    }
    internal static async Task<bool> TrySeason(object page)
    {
        if(Access.Get<EmbyItem?>(page,"_detailPlayableItem") is not {Type:"Episode",SeriesId.Length:>0,SeasonId.Length:>0} item
            || Access.Get<EmbyApiClient?>(page,"_client") is not {} api
            || page is not FrameworkElement { XamlRoot: {} root })return false;
        if(Access.Call(page,"get_IsPlaybackActive") is true)return false;
        var select=new ContentDialog{XamlRoot=root,Title="下载剧集",Content="下载本集，或将当前季全部加入离线下载队列。",
            PrimaryButtonText="下载整季",SecondaryButtonText="下载本集",CloseButtonText="取消",DefaultButton=ContentDialogButton.Secondary};
        var selection=await ModalProtection.Show(select);
        if(selection==ContentDialogResult.Secondary)return false;
        if(selection!=ContentDialogResult.Primary)return true;
        try
        {
            using var timeout=new CancellationTokenSource(TimeSpan.FromSeconds(30));
            var season=await api.GetEpisodesAsync(item.SeriesId,item.SeasonId,timeout.Token);
            if(!ReferenceEquals(api,Access.Get<EmbyApiClient?>(page,"_client")))return true;
            var rows=SeasonEpisodes(season.Items,item.SeriesId,item.SeasonId);
            if(rows.Length==0)throw new InvalidOperationException("没有可下载的分集。");
            var list=(OfflineDownloadManager)Access.Call(page,"get_Downloads")!;
            var scope=(string)Access.Call(page,"get_DesktopScope")!;
            int count=0;
            foreach(var episode in rows)
            {
                if(!ReferenceEquals(api,Access.Get<EmbyApiClient?>(page,"_client"))||Access.Call(page,"get_IsPlaybackActive") is true)break;
                var job=await list.AddAsync(scope,episode);
                if(job.State=="已完成")continue;
                await (Task)Access.Call(page,"StartDownloadAsync",job)!;
                count++;
            }
            Access.Call(page,"ShowLibraryStatus",$"本季已加入 {count} 集，可在离线下载管理。","下载任务",InfoBarSeverity.Success,false);
        }
        catch(Exception error)
        {
            PlaybackTransport.Write("Warning","Downloads.Season","整季下载排队未完成："+error.GetType().Name);
            await (Task)Access.Call(page,"ShowErrorDialogAsync","下载整季","部分任务可能已排队，请检查网络和离线下载列表。")!;
        }
        return true;
    }
    internal static EmbyItem[] SeasonEpisodes(IEnumerable<EmbyItem> items,string series,string season)
        =>items.Where(e=>e.Type=="Episode"&&!string.IsNullOrWhiteSpace(e.Id)
            && (string.IsNullOrEmpty(e.SeriesId)||e.SeriesId==series) && (string.IsNullOrEmpty(e.SeasonId)||e.SeasonId==season))
            .DistinctBy(e=>e.Id).OrderBy(e=>e.IndexNumber??int.MaxValue).ToArray();

    static string DirectoryFor(string media)
    {
        string target=media+".subtitles";
        CacheLayout.RejectLinks(target);
        return target;
    }
    internal static string Extension(string? codec)=>codec?.ToLowerInvariant() switch
    { "srt" or "subrip"=>".srt","ass"=>".ass","ssa"=>".ssa","webvtt" or "vtt"=>".vtt","pgs" or "hdmv_pgs_subtitle" or "sup"=>".sup",_=>"" };

    public static async Task CaptureSubtitles(Task transfer,object page,OfflineDownload job)
    {
        var client=Access.Get<EmbyApiClient?>(page,"_client");
        string scope=(string)Access.Call(page,"get_DesktopScope")!;
        var downloads=(OfflineDownloadManager)Access.Call(page,"get_Downloads")!;
        await transfer;
        if(client is null || job.Scope!=scope || !ReferenceEquals(client,Access.Get<EmbyApiClient?>(page,"_client")))return;
        try
        {
            var saved=(await downloads.ListAsync()).FirstOrDefault(d=>d.Id==job.Id&&d.State=="已完成");
            if(saved is null)return;
            string media=downloads.FilePath(job.Id,false);
            if(!File.Exists(media))return;
            using var timeout=new CancellationTokenSource(TimeSpan.FromSeconds(50));
            var version=ReadVersion(job.Item.Id);
            string item=version?.Item??job.Item.Id;
            var metadata=await client.GetDirectPlaybackInfoAsync(item,TimeSpan.FromSeconds(10),timeout.Token,null);
            if(!ReferenceEquals(client,Access.Get<EmbyApiClient?>(page,"_client")))return;
            // The download endpoint supplies the default source. Only use
            // external tracks that can be associated with that same edition.
            var source=version is not null&&version.Scope==scope
                ?metadata.MediaSources.SingleOrDefault(s=>s.Id==version.Source)
                :metadata.MediaSources.Count==1?metadata.MediaSources[0]:null;
            if(source is null || string.IsNullOrWhiteSpace(source.Id))return;
            var tracks=source.MediaStreams.Where(s=>s.Type=="Subtitle"&&s.IsExternal&&s.Index>=0&&Extension(s.Codec)!="")
                .DistinctBy(s=>s.Index).Take(8).ToArray();
            string root=DirectoryFor(media);
            foreach(var track in tracks)
            {
                timeout.Token.ThrowIfCancellationRequested();
                if(!ReferenceEquals(client,Access.Get<EmbyApiClient?>(page,"_client"))||!File.Exists(media))break;
                try
                {
                    string label=string.Concat((track.Language??"und").Take(15).Where(c=>char.IsAsciiLetterOrDigit(c)||c=='-'));
                    string file=Path.Combine(root,track.Index.ToString("0000",CultureInfo.InvariantCulture)+"-"+label+Extension(track.Codec));
                    CacheLayout.RejectLinks(file);
                    if(File.Exists(file))continue;
                    byte[] bytes=await client.GetExternalSubtitleAsync(item,source.Id,track,timeout.Token);
                    if(bytes.Length is 0 or >8*1024*1024 || !File.Exists(media)
                        || !ReferenceEquals(client,Access.Get<EmbyApiClient?>(page,"_client")))continue;
                    Directory.CreateDirectory(root);
                    string stage=Path.Combine(root,Guid.NewGuid().ToString("N")+".part");
                    try { await File.WriteAllBytesAsync(stage,bytes,timeout.Token);File.Move(stage,file,true); }
                    finally { File.Delete(stage); }
                }
                catch(Exception error) when(error is IOException or UnauthorizedAccessException or HttpRequestException or EmbyApiException)
                { PlaybackTransport.Write("Warning","Downloads.Subtitles","外挂字幕暂不可用："+error.GetType().Name); }
            }
        }
        catch(Exception error)
        { PlaybackTransport.Write("Warning","Downloads.Subtitles","外挂字幕下载未完成："+error.GetType().Name); }
    }

    internal static void Append(List<string> options,string media,string? dataRoot=null)
    {
        if(Uri.TryCreate(media,UriKind.Absolute,out var uri)&&uri.IsFile)media=uri.LocalPath;
        if(!Path.IsPathFullyQualified(media))return;
        try
        {
            if(!CacheLayout.IsWithin(Path.Combine(dataRoot??CachePaths.UserDataRoot,"Downloads"),media))return;
            string root=DirectoryFor(media);
            if(!Directory.Exists(root))return;
            string list=string.Join(';',Directory.EnumerateFiles(root).Where(path=>!path.Contains(';')
                && DesktopSubtitles.Supported(path)&&new FileInfo(path) is {Length:>0 and <=8*1024*1024}
                && (File.GetAttributes(path)&FileAttributes.ReparsePoint)==0).Order(StringComparer.OrdinalIgnoreCase).Take(8));
            if(list.Length>0)options.Add(FormattableString.Invariant($"sub-files=%{Encoding.UTF8.GetByteCount(list)}%{list}"));
        }
        catch(Exception error) when(error is IOException or UnauthorizedAccessException)
        { PlaybackTransport.Write("Warning","Downloads.Subtitles","本机字幕读取失败："+error.GetType().Name); }
    }
}
