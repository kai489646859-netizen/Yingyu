using System.Runtime.CompilerServices;
using System.Text.Json;
using EmbyDesktop.Core.Models;
using EmbyDesktop.Core.Services;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.Foundation;

namespace Yingyu.Update;

public static class DetailResourceBadges
{
    static readonly ConditionalWeakTable<object,State> States=new();
    // Playback selection is authoritative. A separate detail-only metadata read
    // covers episodes, local ISO/STRM and suppressed playback prefetch.
    public static MediaSourceInfo? Capture(MediaSourceInfo? selected,object page,EmbyItem item,EmbyApiClient client,List<MediaSourceInfo> sources)
    {
        var element=(FrameworkElement)page;
        element.DispatcherQueue.TryEnqueue(()=>
        {
            if(!ReferenceEquals(client,Access.Get<EmbyApiClient?>(page,"_client"))||Access.Get<EmbyItem?>(page,"_detailPlayableItem")?.Id!=item.Id)return;
            var state=States.GetValue(page,p=>new State((FrameworkElement)p));
            state.Item=item.Id;state.Client=client;state.Sources=sources.ToArray();state.Selected=selected;state.Refresh();
        });
        return selected;
    }
    public static void Refresh(object page){if(Access.Get<TextBlock?>(page,"DetailMetadataText") is null)return;States.GetValue(page,p=>new State((FrameworkElement)p)).Refresh();}
    public static Task<ContentDialogResult> ShowVersions(ContentDialog dialog)
    {
        if(dialog.Content is ListView list)
        {
            list.FontSize=13;list.MaxHeight=280;
            var style=new Style(typeof(ListViewItem));
            style.Setters.Add(new Setter(FrameworkElement.MinHeightProperty,32d));
            style.Setters.Add(new Setter(Control.PaddingProperty,new Thickness(8,4,8,4)));
            list.ItemContainerStyle=style;
        }
        return ModalProtection.Show(dialog);
    }
    sealed class State
    {
        readonly FrameworkElement page;
        readonly StackPanel root=new(){Name="DetailResourceBadges",Spacing=6,Margin=new(0,8,0,6),IsHitTestVisible=false};
        readonly TextBlock caption=new(){Text="资源信息",FontSize=12,Opacity=.72};
        readonly StackPanel rows=new(){Spacing=6};
        readonly List<Border> badges=new();
        internal string? Item; internal EmbyApiClient? Client;
        internal MediaSourceInfo[] Sources=[];internal MediaSourceInfo? Selected;
        EmbyApiClient? metadataClient;string? metadataItem;EmbySession? metadataSession;
        CancellationTokenSource? pending;
        MediaSourceInfo[] metadata=[];
        bool metadataFailed;
        internal State(FrameworkElement page)
        {
            this.page=page;root.Children.Add(caption);root.Children.Add(rows);
            root.SizeChanged+=(_,_)=>Arrange();
            page.Unloaded+=(_,_)=>{pending?.Cancel();pending=null;metadata=[];metadataItem=null;metadataClient=null;metadataSession=null;Sources=[];Selected=null;Item=null;Client=null;root.Visibility=Visibility.Collapsed;};
            if(Access.Get<Grid?>(page,"DetailView") is {} detail)detail.RegisterPropertyChangedCallback(UIElement.VisibilityProperty,(_,_)=>Refresh());
        }
        internal void Refresh()
        {
            var item=Access.Get<EmbyItem?>(page,"_detailPlayableItem");
            var client=Access.Get<EmbyApiClient?>(page,"_client");
            var session=Access.Get<EmbySession?>(page,"_session");
            bool visible=Access.Get<Grid?>(page,"DetailView")?.Visibility==Visibility.Visible;
            if(!visible||item?.Id!=metadataItem||!ReferenceEquals(client,metadataClient)||!ReferenceEquals(session,metadataSession))
            {
                pending?.Cancel();pending=null;metadata=[];metadataItem=null;metadataClient=null;metadataSession=null;metadataFailed=false;
                if(visible&&item!=null&&client!=null&&session!=null)
                {
                    metadataItem=item.Id;metadataClient=client;metadataSession=session;
                    pending=new();pending.CancelAfter(TimeSpan.FromSeconds(10));
                    _=LoadMetadata(client,session,item.Id,pending);
                }
            }
            var meta=Access.Get<TextBlock>(page,"DetailMetadataText");
            var actions=Access.Get<FrameworkElement?>(page,"DetailAllActions");
            if(actions?.Parent is StackPanel host)
            {
                if(root.Parent is Panel previous && !ReferenceEquals(previous,host))previous.Children.Remove(root);
                int current=host.Children.IndexOf(root),at=host.Children.IndexOf(actions);
                if(current!=at-1 || current<0){if(current>=0)host.Children.Remove(root);host.Children.Insert(host.Children.IndexOf(actions),root);}
            }
            badges.Clear();rows.Children.Clear();
            root.Visibility=item==null||!visible?Visibility.Collapsed:Visibility.Visible;
            if(item==null)return;
            MediaSourceInfo? source=null;
            if(item.Id==Item&&ReferenceEquals(Client,Access.Get<EmbyApiClient?>(page,"_client")))
            {
                var state=Access.Get<DesktopLibraryState>(page,"_desktopState");
                var scope=page.GetType().GetProperty("DesktopScope",System.Reflection.BindingFlags.Instance|System.Reflection.BindingFlags.NonPublic|System.Reflection.BindingFlags.Public)?.GetValue(page)?.ToString();
                source=scope!=null&&state.Versions.TryGetValue(scope+"|"+item.Id,out var id)?Sources.FirstOrDefault(s=>s.Id==id):Selected;
            }
            var libraryState=Access.Get<DesktopLibraryState>(page,"_desktopState");
            var desktopScope=page.GetType().GetProperty("DesktopScope",System.Reflection.BindingFlags.Instance|System.Reflection.BindingFlags.NonPublic|System.Reflection.BindingFlags.Public)?.GetValue(page)?.ToString();
            bool saved=desktopScope!=null&&libraryState.Versions.TryGetValue(desktopScope+"|"+item.Id,out _);
            string? wanted=saved?libraryState.Versions[desktopScope+"|"+item.Id]:source?.Id;
            var supplement=wanted!=null?metadata.FirstOrDefault(s=>s.Id==wanted):metadata.Length==1?metadata[0]:PlaybackSourcePolicy.SelectBestOriginal(metadata.Where(s=>s.MediaStreams!=null&&s.MediaStreams.All(v=>v!=null)));
            // Never borrow metadata from another edition when a particular ID was selected.
            if(source==null)source=supplement;
            var video=source==null?null:ResourceSourceInfo.Video(source);
            var extra=supplement==null?null:ResourceSourceInfo.Video(supplement);
            caption.Text=Sources.Length>1&&source!=null?"当前选用资源 · 服务器资料":"资源信息 · 服务器资料";
            if(source!=null)
            {
                var dimensions=video;
                string resolution=ResourceSourceInfo.Resolution(dimensions?.Width,dimensions?.Height);
                if(resolution=="分辨率未知"&&extra!=null)
                {
                    dimensions=extra;
                    resolution=ResourceSourceInfo.Resolution(extra.Width,extra.Height);
                }
                if(resolution=="1440p" && dimensions is {Width:>0,Height:>0}
                    && (dimensions.Width!=2560 || dimensions.Height!=1440))
                    resolution=$"{dimensions.Width}×{dimensions.Height}";
                string format=ResourceSourceInfo.ServerFormat(source);
                if(format=="格式未知"&&supplement!=null)format=ResourceSourceInfo.ServerFormat(supplement);
                if(resolution!="分辨率未知")Add("分辨率",resolution,0xFF19719B);
                if(format!="格式未知")Add("格式",format,format=="杜比视界"?0xFF6850A4u:0xFF178066u);
                string? codec=video?.Codec??extra?.Codec;
                if(!string.IsNullOrWhiteSpace(codec))Add("编码",codec.ToUpperInvariant(),0xFF526372);
            }
            if(badges.Count==0)rows.Children.Add(new TextBlock{Text=pending!=null?"正在读取资源资料…":metadataFailed?"资源资料暂不可用":"服务器未提供资源规格",FontSize=12,Opacity=.7});
            else Arrange();
        }
        async Task LoadMetadata(EmbyApiClient client,EmbySession session,string item,CancellationTokenSource cancellation)
        {
            try
            {
                var json=await new EmbyPeopleApi(client,session.UserId).Get($"Users/{Uri.EscapeDataString(session.UserId)}/Items/{Uri.EscapeDataString(item)}?Fields=MediaSources,MediaStreams",cancellation.Token);
                if(cancellation.IsCancellationRequested||!ReferenceEquals(pending,cancellation))return;
                var options=new JsonSerializerOptions{PropertyNameCaseInsensitive=true};
                var sources=json.TryGetProperty("MediaSources",out var list)&&list.ValueKind==JsonValueKind.Array
                    ?list.Deserialize<List<MediaSourceInfo>>(options)?.Where(s=>s!=null).ToArray()??[]:Array.Empty<MediaSourceInfo>();
                // Item-level streams can supplement only a sole source, never multiple editions.
                if(json.TryGetProperty("MediaStreams",out var streams)&&streams.ValueKind==JsonValueKind.Array)
                {
                    var tracks=streams.Deserialize<List<MediaStreamInfo>>(options)??[];
                    if(sources.Length==0)sources=[new MediaSourceInfo{Id=item,MediaStreams=tracks}];
                    else if(sources.Length==1&&(sources[0].MediaStreams==null||sources[0].MediaStreams.Count==0))sources[0]=new MediaSourceInfo{Id=sources[0].Id,MediaStreams=tracks};
                }
                if(ReferenceEquals(pending,cancellation))metadata=sources;
            }
            catch(OperationCanceledException)when(cancellation.IsCancellationRequested){if(ReferenceEquals(pending,cancellation))metadataFailed=true;}
            catch(Exception){if(ReferenceEquals(pending,cancellation))metadataFailed=true;/* Optional display data never fails playback. */}
            finally
            {
                if(ReferenceEquals(pending,cancellation)){pending=null;Refresh();}
                cancellation.Dispose();
            }
        }
        void Add(string label,string value,uint color)
        {
            var contents=new StackPanel{Orientation=Orientation.Horizontal};
            TextBlock Text(string text)=>new(){Text=text,FontSize=12,FontWeight=Microsoft.UI.Text.FontWeights.SemiBold,Foreground=DesktopVisuals.Brush(0xFFFFFFFF)};
            contents.Children.Add(new Border{Background=DesktopVisuals.Brush(0xFF454B54),CornerRadius=new(6,0,0,6),Padding=new(8,4,8,4),Child=Text(label)});
            contents.Children.Add(new Border{Background=DesktopVisuals.Brush(color),CornerRadius=new(0,6,6,0),Padding=new(8,4,8,4),Child=Text(value)});
            badges.Add(new Border{CornerRadius=new(6),Child=contents});
        }
        bool arranging;
        void Arrange()
        {
            if(arranging||badges.Count==0)return;arranging=true;
            try
            {
                foreach(var row in rows.Children.OfType<StackPanel>())row.Children.Clear();rows.Children.Clear();
                double width=root.ActualWidth>0?root.ActualWidth:360,used=0;StackPanel? current=null;
                foreach(var badge in badges)
                {
                    badge.Measure(new Size(double.PositiveInfinity,double.PositiveInfinity));double next=badge.DesiredSize.Width;
                    if(current==null||used+6+next>width){current=new(){Orientation=Orientation.Horizontal,Spacing=6};rows.Children.Add(current);used=0;}
                    current.Children.Add(badge);used+=next+(used>0?6:0);
                }
            }
            finally{arranging=false;}
        }
    }
}
