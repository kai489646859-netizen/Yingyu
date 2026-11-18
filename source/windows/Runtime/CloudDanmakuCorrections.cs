using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Yingyu.Update;

internal static class CloudDanmakuCorrections
{
    static readonly HttpClient Http=new(new HttpClientHandler{AllowAutoRedirect=false})
    {Timeout=Timeout.InfiniteTimeSpan};
    static string Settings=>Path.Combine(CachePaths.UserDataRoot,"danmaku-cloud.json");
    sealed record Configuration(string Directory,string User,string Secret);
    internal sealed record Entry(int Schema,double Duration,DanmakuCorrection Correction);

    internal static Uri? Resolve(string directory,string key)
    {
        if(key.Length!=64||!key.All(char.IsAsciiHexDigit)
            ||!Uri.TryCreate(directory.Trim(),UriKind.Absolute,out var root)
            ||root.Scheme!="https" && (root.Scheme!="http"||!root.IsLoopback)
            ||root.UserInfo.Length!=0||root.Query.Length!=0||root.Fragment.Length!=0)return null;
        return new Uri(root.AbsoluteUri.TrimEnd('/')+"/yingyu-correction-v1-"+key+".json");
    }

    internal static string? SharedKey(DanmakuIdentity id)
    {
        if(id.TmdbId<=0||id.Episode<=0||!double.IsFinite(id.Duration)||id.Duration<=0)return null;
        string key=FormattableString.Invariant($"yingyu-v1/{(id.Movie?"movie":"tv")}/{id.TmdbId}/{id.Season}/{id.Episode}");
        return Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(key)));
    }

    internal static bool Matches(Entry? entry,double duration)
        =>entry is {Schema:1, Correction.IsValid:true}&&double.IsFinite(entry.Duration)
            &&double.IsFinite(duration)&&duration>0&&Math.Abs(entry.Duration-duration)<=2;

    static async Task<(Entry? Record,EntityTagHeaderValue? ETag)> Read(Uri uri,string user,string password,CancellationToken token)
    {
        using var request=Request(HttpMethod.Get,uri,user,password);
        using var response=await Http.SendAsync(request,HttpCompletionOption.ResponseHeadersRead,token);
        if(response.StatusCode==HttpStatusCode.NotFound)return (null,null);
        CheckResponse(response);
        var data=await OnlineSubtitles.ReadBounded(response.Content,4096,token);
        var record=JsonSerializer.Deserialize<Entry>(data);
        return (record??throw new IOException("云端记录格式无效。"),response.Headers.ETag);
    }

    static HttpRequestMessage Request(HttpMethod method,Uri uri,string user,string password)
    {
        var request=new HttpRequestMessage(method,uri);
        if(user.Length>0)request.Headers.Authorization=new AuthenticationHeaderValue("Basic",
            Convert.ToBase64String(Encoding.UTF8.GetBytes(user+":"+password)));
        return request;
    }
    static void CheckResponse(HttpResponseMessage response)
    {
        if(response.StatusCode is HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden)
            throw new InvalidOperationException("WebDAV 拒绝访问，请检查账号权限。");
        if(!response.IsSuccessStatusCode)
            throw new InvalidOperationException("共享目录暂不可用，请检查地址和 WebDAV 服务。");
    }

    static async Task Upload(Uri uri,string user,string secret,Entry value,CancellationToken token)
    {
        var (previous,etag)=await Read(uri,user,secret,token);
        if(previous is not null && (!Matches(previous,value.Duration)||etag is not {IsWeak:false}))
            throw new InvalidOperationException("云端已有其他片源的记录，或服务器未提供并发保护。");
        using var request=Request(HttpMethod.Put,uri,user,secret);
        if(previous is null)request.Headers.IfNoneMatch.Add(EntityTagHeaderValue.Any);
        else request.Headers.IfMatch.Add(etag!);
        request.Content=new StringContent(JsonSerializer.Serialize(value),Encoding.UTF8,"application/json");
        using var response=await Http.SendAsync(request,HttpCompletionOption.ResponseHeadersRead,token);
        if(response.StatusCode==HttpStatusCode.PreconditionFailed)
            throw new InvalidOperationException("云端记录刚被更新，请先读取后再分享。");
        CheckResponse(response);
    }

    static Configuration? Restore()
    {
        try
        {
            CacheLayout.RejectLinks(Settings);
            return new FileInfo(Settings) is {Exists:true,Length:>0 and <=16384}
                ?JsonSerializer.Deserialize<Configuration>(File.ReadAllText(Settings)):null;
        }
        catch(Exception error)when(error is IOException or UnauthorizedAccessException or JsonException){return null;}
    }

    static void Save(string directory,string user,string password)
    {
        string encrypted=Convert.ToBase64String(ProtectedData.Protect(Encoding.UTF8.GetBytes(password),null,DataProtectionScope.CurrentUser));
        string path=Settings;CacheLayout.RejectLinks(path);
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        string stage=path+"."+Guid.NewGuid().ToString("N")+".tmp";
        try{File.WriteAllText(stage,JsonSerializer.Serialize(new Configuration(directory,user,encrypted)));File.Move(stage,path,true);}
        finally{File.Delete(stage);}
    }

    internal static async Task Show(XamlRoot root,DanmakuIdentity id,DanmakuCorrection? local,
        Func<bool> current,Func<DanmakuCorrection,Task> apply)
    {
        string key=SharedKey(id)??throw new InvalidOperationException("云端纠错需要已知的 TMDB 编号、季集和片长。");
        var saved=Restore();
        string password="";
        if(saved is not null)
            try{password=Encoding.UTF8.GetString(ProtectedData.Unprotect(Convert.FromBase64String(saved.Secret),null,DataProtectionScope.CurrentUser));}
            catch(Exception error)when(error is CryptographicException or FormatException){}
        var directory=new TextBox{Header="共享 WebDAV 目录",Text=saved?.Directory??"",MaxLength=700};
        var user=new TextBox{Header="用户名",Text=saved?.User??"",MaxLength=150};
        var secret=new PasswordBox{Header="密码",Password=password,MaxLength=512};
        var detail=new TextBlock{Text="读取将验证来源并保存到本机。分享会向此目录写入已验证的弹幕来源和片长。",TextWrapping=TextWrapping.Wrap};
        var body=new StackPanel{Spacing=8};body.Children.Add(directory);body.Children.Add(user);body.Children.Add(secret);body.Children.Add(detail);
        var dialog=new ContentDialog{XamlRoot=root,Title="云端弹幕纠错",Content=body,CloseButtonText="关闭",
            PrimaryButtonText="读取并应用",SecondaryButtonText="分享本机纠错",IsSecondaryButtonEnabled=local is {IsValid:true}};
        async Task Run(bool share)
        {
            if(!current())return;
            try
            {
                var endpoint=Resolve(directory.Text,key)??throw new InvalidOperationException("请输入 HTTPS WebDAV 目录地址。");
                detail.Text=share?"正在分享…":"正在读取…";
                using var deadline=new CancellationTokenSource(TimeSpan.FromSeconds(10));
                if(share&&local is {IsValid:true})
                {
                    await Upload(endpoint,user.Text,secret.Password,new Entry(1,id.Duration,local),deadline.Token);
                    detail.Text="已分享本机纠错。";
                }
                else
                {
                    var (entry,_)=await Read(endpoint,user.Text,secret.Password,deadline.Token);
                    if(!current())return;
                    if(!Matches(entry,id.Duration))
                    {
                        detail.Text="未找到与当前集和片长匹配的记录。";
                        return;
                    }
                    detail.Text="已取得云端记录，正在验证来源。结果见弹幕状态。";
                    await apply(entry!.Correction);
                }
                if(current())Save(directory.Text.Trim(),user.Text,secret.Password);
            }
            catch(Exception error)
            {if(current())detail.Text=error is InvalidOperationException?error.Message:"云端纠错操作未完成。";}
        }
        async void Action(object sender,ContentDialogButtonClickEventArgs args,bool share)
        {
            args.Cancel=true;
            var pause=args.GetDeferral();
            dialog.IsPrimaryButtonEnabled=dialog.IsSecondaryButtonEnabled=false;
            try{await Run(share);}
            finally{dialog.IsPrimaryButtonEnabled=true;dialog.IsSecondaryButtonEnabled=local is {IsValid:true};pause.Complete();}
        }
        dialog.PrimaryButtonClick+=(sender,args)=>Action(sender,args,false);
        dialog.SecondaryButtonClick+=(sender,args)=>Action(sender,args,true);
        await ModalProtection.Show(dialog);
    }
}
