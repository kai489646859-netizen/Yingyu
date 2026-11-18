using System.Net;
using System.Net.Http;
using System.Text.Json;
using EmbyDesktop.Core.Models;
using EmbyDesktop.Core.Services;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.Storage;

namespace Yingyu.Update;

internal static class OnlineSubtitles
{
    static readonly HttpClient Http=new(new HttpClientHandler{AllowAutoRedirect=false})
    {Timeout=Timeout.InfiniteTimeSpan};
    static readonly JsonSerializerOptions Json=new(){PropertyNameCaseInsensitive=true};
    internal sealed record Result(string Id,string? Name,string? ProviderName,string? Format,string? Language,bool IsHashMatch);

    internal static Uri SearchUri(string root,string item,string source,string language)
        =>new(root.TrimEnd('/')+"/Items/"+Uri.EscapeDataString(item)+"/RemoteSearch/Subtitles/"
            +Uri.EscapeDataString(language)+"?MediaSourceId="+Uri.EscapeDataString(source));

    internal static async Task<byte[]> ReadBounded(HttpContent content,int limit,CancellationToken token)
    {
        if(content.Headers.ContentLength>limit)throw new IOException("响应超出大小限制。");
        await using var input=await content.ReadAsStreamAsync(token).ConfigureAwait(false);
        using var output=new MemoryStream();
        byte[] buffer=new byte[16*1024];
        for(int read;(read=await input.ReadAsync(buffer,token).ConfigureAwait(false))>0;)
        {
            if(output.Length+read>limit)throw new IOException("响应超出大小限制。");
            output.Write(buffer,0,read);
        }
        return output.ToArray();
    }

    internal static async Task<byte[]> Get(Uri uri,string token,int limit,CancellationToken cancellationToken)
    {
        using var request=new HttpRequestMessage(HttpMethod.Get,uri);
        request.Headers.Add("X-Emby-Token",token);
        using var response=await Http.SendAsync(request,HttpCompletionOption.ResponseHeadersRead,cancellationToken);
        if(response.StatusCode is HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden)
            throw new InvalidOperationException("Emby 未授权在线字幕，请检查账号权限。");
        if(!response.IsSuccessStatusCode)
            throw new InvalidOperationException("Emby 在线字幕服务暂不可用，请检查服务器字幕提供商设置。");
        return await ReadBounded(response.Content,limit,cancellationToken);
    }

    internal static Result[] Parse(byte[] data)
        =>(JsonSerializer.Deserialize<Result[]>(data,Json)??[]).Where(r=>r is not null
            && r.Id is {Length:>0 and <=1024} && r.Id is not ("." or "..") && !r.Id.Any(char.IsControl)
            && Extension(r.Format)!="")
            .OrderByDescending(r=>r.IsHashMatch).DistinctBy(r=>r.Id).Take(50).ToArray();

    static string Extension(string? format)
    {
        string extension=OfflineViewing.Extension(format);
        return extension is ".srt" or ".ass" or ".ssa" or ".vtt"?extension:"";
    }

    internal static async Task Show(object session,XamlRoot root,Func<bool> current,
        Func<StorageFile,Task> load,CancellationToken lifetime)
    {
        var client=Access.Get<EmbyApiClient>(session,"_embyClient");
        bool SameClient()=>current()&&ReferenceEquals(client,Access.Get<EmbyApiClient>(session,"_embyClient"));
        var item=Access.Get<EmbyItem>(session,"_item");
        var source=Access.Get<MediaSourceInfo>(session,"_source");
        string? address=Access.Get<string?>(client,"_apiBaseUrl");
        string? token=Access.Get<string?>(client,"_accessToken");
        if(!Uri.TryCreate(address,UriKind.Absolute,out var server)||server.Scheme is not ("https" or "http")
            || server.UserInfo.Length>0 || server.Query.Length>0 || server.Fragment.Length>0
            ||string.IsNullOrWhiteSpace(token)||string.IsNullOrWhiteSpace(source.Id)
            ||Access.Get<Uri>(session,"_playbackUri").IsFile)
            throw new InvalidOperationException("在线字幕需要已登录的 Emby 片源。");

        using var searchLifetime=CancellationTokenSource.CreateLinkedTokenSource(lifetime);
        string[] codes=["zho","eng","jpn","kor","spa","fra","deu"];
        var language=new ComboBox{Header="字幕语言",SelectedIndex=-1};
        foreach(string label in new[]{"中文","英语","日语","韩语","西语","法语","德语"})language.Items.Add(label);
        language.SelectedIndex=0;
        var rows=new ListView{MaxHeight=260,SelectionMode=ListViewSelectionMode.Single};
        var status=new TextBlock{Text="使用当前 Emby 服务器配置的字幕提供商。",TextWrapping=TextWrapping.Wrap};
        var search=new Button{Content="搜索"};
        var body=new StackPanel{Spacing=10};body.Children.Add(language);body.Children.Add(search);
        body.Children.Add(status);body.Children.Add(rows);
        var dialog=new ContentDialog{XamlRoot=root,Title="在线字幕",PrimaryButtonText="下载并加载",
            CloseButtonText="关闭",IsPrimaryButtonEnabled=false,Content=body};
        rows.SelectionChanged+=(_,_)=>dialog.IsPrimaryButtonEnabled=rows.SelectedItem is ListViewItem;
        search.Click+=async(_,_) =>
        {
            if(!SameClient()||language.SelectedIndex<0)return;
            search.IsEnabled=language.IsEnabled=false;rows.Items.Clear();status.Text="正在搜索…";
            try
            {
                using var timeout=CancellationTokenSource.CreateLinkedTokenSource(searchLifetime.Token);
                timeout.CancelAfter(TimeSpan.FromSeconds(15));
                var data=await Get(SearchUri(address!,item.Id,source.Id,codes[language.SelectedIndex]),token,512*1024,timeout.Token);
                if(!SameClient()||searchLifetime.IsCancellationRequested)return;
                foreach(var result in Parse(data))
                {
                    string label=result.Name??result.Format??"字幕";
                    if(label.Length>150)label=label[..150];
                    string provider=result.ProviderName??"";
                    if(provider.Length>40)provider=provider[..40];
                    rows.Items.Add(new ListViewItem{Tag=result,Content=label+" · "+provider
                        +(result.IsHashMatch?" · 片源匹配":"")});
                }
                status.Text=rows.Items.Count==0?"未找到可用字幕。可换语言重试。":"请选择字幕。已确认的片源匹配排在前面。";
                if(rows.Items.Count>0)rows.SelectedIndex=0;
            }
            catch(OperationCanceledException){if(SameClient()&&!searchLifetime.IsCancellationRequested)status.Text="字幕搜索超时。";}
            catch(Exception error){if(SameClient()&&!searchLifetime.IsCancellationRequested)status.Text=error is InvalidOperationException?error.Message:"读取字幕结果失败。";}
            finally{if(SameClient()&&!searchLifetime.IsCancellationRequested)search.IsEnabled=language.IsEnabled=true;}
        };
        var choice=await ModalProtection.Show(dialog);
        searchLifetime.Cancel();
        if(choice!=ContentDialogResult.Primary||rows.SelectedItem is not ListViewItem{Tag:Result selected}||!SameClient())return;
        using var download=CancellationTokenSource.CreateLinkedTokenSource(lifetime);
        download.CancelAfter(TimeSpan.FromSeconds(20));
        var bytes=await Get(new Uri(address!.TrimEnd('/')+"/Providers/Subtitles/Subtitles/"+Uri.EscapeDataString(selected.Id)),
            token,8*1024*1024,download.Token);
        if(!SameClient())return;
        if(bytes.Length==0)throw new InvalidOperationException("字幕提供商返回了空文件。");
        string folder=Path.Combine(CachePaths.Temporary,"OnlineSubtitles");Directory.CreateDirectory(folder);
        string path=Path.Combine(folder,Guid.NewGuid().ToString("N")+Extension(selected.Format));
        await File.WriteAllBytesAsync(path,bytes,download.Token);
        if(SameClient())await load(await StorageFile.GetFileFromPathAsync(path));
    }
}
