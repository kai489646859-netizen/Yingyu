using System.Runtime.CompilerServices;
using EmbyDesktop.Core.Models;
using EmbyDesktop.Core.Services;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Imaging;

namespace Yingyu.Update;

public static class DetailArtwork
{
    static bool Ready(Image image)=>image.Source is BitmapSource{PixelWidth:>0,PixelHeight:>0};
    static readonly ConditionalWeakTable<object,PosterSurface> Surfaces=new();
    // The old fallback lives in the original XBF tree. Do not reuse or move
    // it: the host deliberately collapses it, and Detach does not traverse a
    // ScrollViewer. Mount an owned frame directly in the known hero Grid.
    sealed class PosterSurface
    {
        readonly object page;readonly Image source;readonly Grid hero;
        internal readonly Border Frame=new(){Name="YingyuDetailPosterFrame",VerticalAlignment=VerticalAlignment.Top,IsHitTestVisible=false};
        readonly Image visible=new(){Name="YingyuDetailPosterSurface",Stretch=Microsoft.UI.Xaml.Media.Stretch.Uniform,HorizontalAlignment=HorizontalAlignment.Stretch,VerticalAlignment=VerticalAlignment.Stretch};
        bool queued,applying;string last="";int reports,generation=-1;
        internal PosterSurface(object page,Image source,Grid hero)
        {
            this.page=page;this.source=source;this.hero=hero;Frame.Child=visible;
            source.RegisterPropertyChangedCallback(Image.SourceProperty,(_,_)=>Queue());
            Access.Get<Grid>(page,"DetailView").RegisterPropertyChangedCallback(UIElement.VisibilityProperty,(_,_)=>Queue());
            Frame.Loaded+=(_,_)=>Queue();Frame.SizeChanged+=(_,_)=>Queue();
            visible.ImageOpened+=(_,_)=>Safe(()=>{if(Current()){Present();Access.Call(page,"UpdateDetailExperienceLayout");}});
            visible.ImageFailed+=(_,_)=>{if(reports++<8)PlaybackTransport.Write("Warning","Poster.Detail","详情显示图像未能解码；未记录来源或身份。");};
        }
        bool Current()=>Access.Get<Grid>(page,"DetailView").Visibility==Visibility.Visible;
        void Safe(Action action){try{action();}catch(Exception error){if(reports++<8)PlaybackTransport.Write("Warning","Poster.Detail","详情显示面回调未完成；"+error.GetType().Name);}}
        void Queue()
        {
            if(queued||!Current())return;queued=true;
            if(!hero.DispatcherQueue.TryEnqueue(()=>{queued=false;Safe(()=>{if(Current())EnsureSurface(page);});}))queued=false;
        }
        internal void Present()
        {
            if(applying||!Current())return;applying=true;
            try
            {
                int next=Access.Get<int>(page,"_detailLoadVersion");if(next!=generation){generation=next;reports=0;last="";}
                if(!hero.Children.Contains(Frame))hero.Children.Add(Frame);
                if(!ReferenceEquals(visible.Source,source.Source))visible.Source=source.Source;
                Access.Get<Border>(page,"DetailPosterFallback").Visibility=Visibility.Collapsed;
                source.Visibility=Visibility.Collapsed;
                visible.Visibility=Visibility.Visible;visible.Opacity=1;visible.Margin=new(0);visible.Clip=null;
                visible.Width=visible.Height=double.NaN;visible.MaxWidth=visible.MaxHeight=double.PositiveInfinity;
                Grid.SetRow(Frame,0);Grid.SetColumn(Frame,0);Grid.SetRowSpan(Frame,1);Grid.SetColumnSpan(Frame,1);
                Frame.Visibility=Visibility.Visible;Frame.Opacity=1;Frame.Clip=null;Frame.MinWidth=Frame.MinHeight=0;
                Frame.MaxWidth=Frame.MaxHeight=double.PositiveInfinity;Frame.BorderThickness=new(0);Frame.Padding=new(0);Frame.Background=DesktopVisuals.Brush(0);
                string signature=FormattableString.Invariant($"sourceReady={Ready(source)}; heroAttached={hero.Children.Contains(Frame)}; width={Frame.ActualWidth:0}; height={Frame.ActualHeight:0}; generation={generation}");
                if(signature!=last&&reports++<8){last=signature;PlaybackTransport.Write("Info","Poster.Detail",signature+"；仅显示状态，无来源或身份。");}
            }
            finally{applying=false;}
        }
    }
    static int surfaceWarnings;
    internal static Border? Frame(object page)
    {
        EnsureSurface(page);return Surfaces.TryGetValue(page,out var surface)?surface.Frame:null;
    }
    internal static void EnsureSurface(object page)
    {
        try
        {
            if(Access.Get<Grid>(page,"DetailView").Visibility!=Visibility.Visible)return;
            var image=Access.Get<Image>(page,"DetailPosterImage");var hero=Access.Get<Grid>(page,"DetailHeroLayout");
            Surfaces.GetValue(page,p=>new PosterSurface(p,image,hero)).Present();
        }
        catch(Exception error){if(Interlocked.Increment(ref surfaceWarnings)<=4)PlaybackTransport.Write("Warning","Poster.Detail","详情主海报显示面未完成；"+error.GetType().Name);}
    }
    internal static void Resume(object page)
    {
        if(AndroidCacheRuntime.IsPaused||Access.Get<Grid>(page,"DetailView").Visibility!=Visibility.Visible
            ||Access.Get<EmbyItem?>(page,"_currentDetailItem") is not {} item)return;
        EnsureSurface(page);if(Ready(Access.Get<Image>(page,"DetailPosterImage")))return;
        var token=Access.Get<CancellationTokenSource?>(page,"_posterLoadCts")?.Token??CancellationToken.None;
        if(token.IsCancellationRequested)return;
        // A resume/refresh replaces the shared poster CTS. Rejoin this detail
        // with the NEW token; ReloadMissingPosters otherwise skips DetailView.
        _=Load(page,item,token);
    }
    static readonly ConditionalWeakTable<object, State> States = new();
    internal static async Task WaitForPriorityImages(object page,CancellationToken token)
    {
        // Actor cache hits never call this. Only missing actor files wait for
        // the current detail's higher-priority *network* image attempts.
        if(Access.Get<Grid>(page,"DetailView").Visibility!=Visibility.Visible||!States.TryGetValue(page,out var state)
            ||state.Generation!=Access.Get<int>(page,"_detailLoadVersion")||state.Running is not {} work)return;
        await work.WaitAsync(token);
    }
    sealed class State
    {
        internal Task? Running;
        internal EmbyItem? Item;
        internal CancellationToken Token;
        internal int Generation;
        internal ArtworkSizePreference Size;
    }

    // Called on the same UI thread as the original method. Keep its cache,
    // decoder, image-size preference, retry policy and layout updates.
    public static Task Load(object page, EmbyItem item, CancellationToken token)
    {
        var state = States.GetValue(page, _ => new());
        EnsureSurface(page);
        int generation = Access.Get<int>(page, "_detailLoadVersion");
        var size = Access.Get<UserPreferences>(page, "_preferences").ArtworkSize;
        if (state.Running is { IsCompleted: false } existing && ReferenceEquals(state.Item, item)
            && state.Token == token && state.Generation == generation && state.Size == size)
            return existing;
        state.Item = item; state.Token = token; state.Generation = generation; state.Size = size;
        state.Running = LoadCore(page, item, token, generation, size);
        return state.Running;
    }

    static async Task LoadCore(object page, EmbyItem item, CancellationToken token, int generation, ArtworkSizePreference size)
    {
        var owner=Access.Get<EmbySession?>(page,"_session");var client=Access.Get<EmbyApiClient?>(page,"_client");
        bool Current() => ReferenceEquals(owner,Access.Get<EmbySession?>(page,"_session"))&&ReferenceEquals(client,Access.Get<EmbyApiClient?>(page,"_client"))&&!token.IsCancellationRequested && ReferenceEquals(Access.Get<EmbyItem?>(page, "_currentDetailItem"), item)
            && Access.Get<int>(page, "_detailLoadVersion") == generation
            && Access.Get<Grid>(page,"DetailView").Visibility==Visibility.Visible;
        Task<BitmapImage?> Picture(string type, int width) => (Task<BitmapImage?>)Access.Call(page,
            "LoadPosterBitmapAsync", item, type, width, token, null, null,
            PosterFetchPriority.Interactive, PosterCacheRetention.Detail, (Func<bool>)Current, null)!;
        try
        {
            if (!Current() || Access.Get<Grid>(page, "DetailView").Visibility != Visibility.Visible) return;
            var sizes = ArtworkRequestSizePolicy.Resolve(size);
            var poster = Access.Get<Image>(page, "DetailPosterImage");
            var backdrop = Access.Get<Image>(page, "DetailBackdropImage");
            // The current presentation intentionally hides the large backdrop.
            // Keep its loader/cache for a later design, but do not download a
            // large image that the current view will not show.
            bool backgroundRequested=ReferenceAppearance.WantsDetailBackground((FrameworkElement)page)&&item.BackdropImageTags.Count>0;
            async Task LoadPrimary()
            {
                try
                {
                    var cached=await AndroidCacheCards.CachedDetailPoster(page,item,token);
                    if(!Current())return;
                    if(cached!=null){poster.Source=cached;EnsureSurface(page);Access.Call(page,"UpdateDetailExperienceLayout");}
                }
                catch(OperationCanceledException){}
                catch(Exception error){PlaybackTransport.Write("Warning","Poster.Detail","详情主海报缓存读取未完成，保留正常加载；"+error.GetType().Name);}
                if(!Current()||Ready(poster))return;
                try{var image=await Picture("Primary",sizes.DetailPosterWidth);if(!Current())return;poster.Source=image??poster.Source;EnsureSurface(page);Access.Call(page,"UpdateDetailExperienceLayout");}
                catch(OperationCanceledException){}
                catch(Exception error){PlaybackTransport.Write("Warning","Poster.Detail","详情主海报加载未完成；"+error.GetType().Name);}
            }
            var primary=LoadPrimary();
            async Task LoadBackground()
            {
                if(!backgroundRequested||!Current()||Ready(backdrop))return;
                try
                {
                    // Cache reads run beside primary reads/downloads. Only a
                    // background *miss* waits for the primary network attempt.
                    var cached=await AndroidCacheCards.CachedDetailBackground(page,item,token);
                    if(!Current())return;
                    if(cached!=null){backdrop.Source=cached;return;}
                    await primary;if(!Current())return;
                    var image=await Picture("Backdrop",sizes.DetailBackdropWidth);if(Current())backdrop.Source=image??backdrop.Source;
                }
                catch(OperationCanceledException){}
                catch(Exception error){PlaybackTransport.Write("Warning","Poster.Detail","详情背景独立加载未完成；"+error.GetType().Name);}
            }
            await Task.WhenAll(primary,LoadBackground());
            if (!Current()) return;
            Access.Set(page, "_detailBackdropUnavailable", backgroundRequested&&!Ready(backdrop));
            EnsureSurface(page);
            Access.Call(page, "UpdateDetailExperienceLayout");
            if ((Ready(poster) || !item.ImageTags.ContainsKey("Primary"))
                && (!backgroundRequested || Ready(backdrop)))
                Access.Call(page, "ClearDetailArtworkFeedback");
        }
        catch (OperationCanceledException) { }
        catch (Exception error)
        {
            PlaybackTransport.Write("Warning", "Poster.Detail", "详情图片加载异常：" + error.GetType().Name + "；地址及身份已隐藏。");
        }
        finally
        {
            var session = Access.Get<EmbySession?>(page, "_session");
            if (session != null && Current())
            {
                var cache = Access.Get<PosterCacheService>(page, "_posterCache");
                TimeSpan delay = cache.GetServerRetryDelay(session.ServerId);
                if (delay > TimeSpan.Zero) Access.Call(page, "ScheduleVisiblePosterRetry", delay, token, false);
                else
                {
                    var status = Access.Get<InfoBar>(page, "LibraryStatusInfoBar");
                    if (status.Title == "海报加载暂停") status.IsOpen = false;
                }
            }
        }
    }
}
