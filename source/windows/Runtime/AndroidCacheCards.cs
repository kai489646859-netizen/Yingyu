using System.Reflection;
using System.Runtime.CompilerServices;
using EmbyDesktop.Core.Models;
using EmbyDesktop.Core.Services;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.UI.Xaml.Media;
using Windows.Foundation;

namespace Yingyu.Update;

public static class AndroidCacheCards
{
    sealed class Identity { public string? Key, Source; public int Retries; public bool Hidden, RequeueOnFinish, CacheOnly; public List<WeakReference<ViewportEntry>> Views = new(); public WeakReference<object>? Page; public CancellationToken NextGeneration; public CancellationTokenSource? RetryCancellation; }
    static readonly ConditionalWeakTable<object, Identity> Identities = new();
    static readonly ConditionalWeakTable<FrameworkElement, ViewportEntry> Viewports = new();
    static readonly System.Collections.Concurrent.ConcurrentDictionary<string,int> traces=new();
    static void Trace(string stage)
    {try{if(traces.AddOrUpdate(stage,1,(_,count)=>count+1)<=6)PlaybackTransport.Write("Info","Poster.Load",stage);}catch(Exception){}}
    sealed class ViewportEntry
    {
        readonly FrameworkElement element;
        WeakReference<object>? owner;
        Rect viewport;
        bool known;
        bool measuredViewport;
        bool deferred;
        bool visibleNow;
        bool presenting;
        bool refreshQueued;
        bool motionCachePrepared;
        object? previous;
        readonly List<(UIElement Element,long Token)> visibility = new();
        internal ViewportEntry(FrameworkElement element)
        {
            this.element=element;
            // EffectiveViewportChanged can precede Loaded. Retain that real
            // geometry and consume it when the template actually becomes ready.
            element.Loaded+=(_,_)=>{Watch();QueueRefresh();};
            element.SizeChanged+=(_,_)=>QueueRefresh();
            element.DataContextChanged+=(_,_)=>{measuredViewport=false;motionCachePrepared=false;if(previous!=null&&!ReferenceEquals(previous,element.DataContext)){visibleNow=false;Viewport(previous,false,false);}QueueRefresh();};
            element.Unloaded+=(_,_)=>{visibleNow=false;if(previous!=null)Viewport(previous,false,false);foreach(var item in visibility){try{item.Element.UnregisterPropertyChangedCallback(UIElement.VisibilityProperty,item.Token);}catch(Exception){}}visibility.Clear();};
        }
        void Own(object page){if(owner?.TryGetTarget(out var current)!=true||!ReferenceEquals(current,page))owner=new(page);}
        void QueueRefresh()
        {
            if(refreshQueued)return;refreshQueued=true;
            if(!element.DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low,()=>{
                refreshQueued=false;
                try{Refresh();}catch(Exception error){try{PlaybackTransport.Write("Warning","Poster.Viewport","图片视图刷新未完成；"+error.GetType().Name);}catch(Exception){}}
            }))refreshQueued=false;
        }
        internal void Update(object page,Rect value){Own(page);viewport=value;known=measuredViewport=true;if(!element.IsLoaded&&!deferred){deferred=true;Trace("阶段=viewport-before-loaded；保留几何，等待控件就绪。");}if(element.IsLoaded)Watch();Refresh();}
        internal void Attach(object page){Own(page);known=true;if(element.IsLoaded)Watch();QueueRefresh();}
        internal bool VisibleFor(object card)=>visibleNow&&element.IsLoaded&&ReferenceEquals(previous,card)&&ReferenceEquals(element.DataContext,card);
        internal bool BoundFor(object card)=>element.IsLoaded&&ReferenceEquals(element.DataContext,card)&&ReferenceEquals(previous,card);
        internal bool OwnedBy(object page)=>owner?.TryGetTarget(out var current)==true&&ReferenceEquals(current,page);
        internal bool Present(object page,object card,bool cached=false)
        {
            if(presenting||!(cached?BoundFor(card):VisibleFor(card))||!ReferenceEquals(element.DataContext,card))return false;
            if(element is Microsoft.UI.Xaml.Controls.Grid grid&&DesktopCardSurface.Ready(grid,card))return true;
            if(element is Microsoft.UI.Xaml.Controls.Grid existing&&DesktopCardSurface.PaintPoster(existing,card))return DesktopCardSurface.Ready(existing,card);
            if(!cached&&!MeasureVisible())return false;
            presenting=true;
            try{DesktopTheme.Card(page,element);}
            finally{presenting=false;}
            return element is Microsoft.UI.Xaml.Controls.Grid surface&&DesktopCardSurface.Ready(surface,card);
        }
        bool MeasureVisible()
        {
            if(!element.IsLoaded||element.ActualWidth<=0||element.ActualHeight<=0)return false;
            if(visibility.Any(item=>item.Element.Visibility!=Visibility.Visible))return false;
            // The framework has already intersected all clipping ancestors.
            // Consume its measured element-local rectangle once, instead of
            // walking/translating every ancestor on each scrolling callback.
            if(measuredViewport)return viewport.Width>0&&viewport.Height>0&&viewport.Right>0&&viewport.Bottom>0&&viewport.Left<element.ActualWidth&&viewport.Top<element.ActualHeight;
            if(element.XamlRoot?.Content is not FrameworkElement host)return false;
            var screen=element.TransformToVisual(host).TransformBounds(new Rect(0,0,element.ActualWidth,element.ActualHeight));
            if(screen.Right<=0||screen.Left>=host.ActualWidth||screen.Bottom<=0||screen.Top>=host.ActualHeight)return false;
            bool scroll=false;
            for(DependencyObject? node=element;node!=null;node=VisualTreeHelper.GetParent(node)){
                if(node is UIElement{Visibility:not Visibility.Visible})return false;
                if(node is Microsoft.UI.Xaml.Controls.ScrollViewer viewer){
                    scroll=true;
                    var bounds=element.TransformToVisual(viewer).TransformBounds(new Rect(0,0,element.ActualWidth,element.ActualHeight));
                    if(bounds.Right<=0||bounds.Left>=viewer.ActualWidth||bounds.Bottom<=0||bounds.Top>=viewer.ActualHeight)return false;
                }
            }
            return scroll;
        }
        internal void Reconcile(object page)
        {
            if(owner?.TryGetTarget(out var current)==true&&ReferenceEquals(page,current))Refresh();
        }
        void Watch()
        {
            if(visibility.Count!=0)return;
            for(DependencyObject? node=element;node!=null;node=VisualTreeHelper.GetParent(node))
                if(node is UIElement ui)
                {
                    long token=ui.RegisterPropertyChangedCallback(UIElement.VisibilityProperty,(_,_)=>{
                        if(ui.Visibility!=Visibility.Visible){visibleNow=false;if(previous!=null)Viewport(previous,false,false);}
                        QueueRefresh();
                    });
                    visibility.Add((ui,token));
                }
        }
        void Refresh()
        {
            if(!known||owner?.TryGetTarget(out var page)!=true||page==null||element.DataContext is not {} card)return;
            if(previous!=null&&!ReferenceEquals(previous,card)){visibleNow=false;Viewport(previous,false,false);}
            if(!ReferenceEquals(previous,card)){
                var views=Identities.GetOrCreateValue(card).Views;
                views.RemoveAll(v=>!v.TryGetTarget(out var view)||!ReferenceEquals(view.previous,card));
                views.Add(new(this));CachedArtwork.Enqueue(page,new[]{card},true);
            }
            previous=card;
            // A recycled template can retain the old EffectiveViewport rect.
            // Use its current position in the realized scroll containers.
            if(DesktopScroll.IsAnimating(page))
            {
                // Cached pixels are allowed during the transition. Only new
                // server downloads wait for its final viewport.
                visibleNow=MeasureVisible();Viewport(card,visibleNow,visibleNow);
                if(visibleNow&&!AndroidCacheRuntime.IsPaused)
                {
                    if(element is Microsoft.UI.Xaml.Controls.Grid painted&&DesktopCardSurface.Ready(painted,card))return;
                    if(Get<BitmapImage?>(card,"Poster") is {PixelWidth:>0,PixelHeight:>0})Present(page,card,true);
                    else if(!motionCachePrepared){motionCachePrepared=true;CachedArtwork.Enqueue(page,new[]{card},true);}
                }
                return;
            }
            motionCachePrepared=false;
            bool visible=MeasureVisible();
            visibleNow=visible;
            Viewport(card,visible,visible);
            if(visible&&!AndroidCacheRuntime.IsPaused)
            {
                if(deferred){deferred=false;Trace("阶段=loaded-visible；接续屏幕内海报加载。");}
                // Movement alone does not invalidate an already painted bitmap.
                // Real image changes clear the model/source and fail this check.
                if(element is Microsoft.UI.Xaml.Controls.Grid grid&&DesktopCardSurface.Ready(grid,card))return;
                _=Load(page,card,Access.Get<CancellationTokenSource?>(page,"_posterLoadCts")?.Token??CancellationToken.None);
            }
        }
    }
    const BindingFlags Flags = BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic;
    static readonly System.Collections.Concurrent.ConcurrentDictionary<(Type Type,string Name),PropertyInfo> Properties=new();
    static PropertyInfo Property(object card,string name)=>Properties.GetOrAdd((card.GetType(),name),key=>key.Type.GetProperty(key.Name,Flags)??throw new MissingMemberException(key.Type.FullName,key.Name));
    static T Get<T>(object card, string name) => (T)Property(card,name).GetValue(card)!;
    static void Set(object card, string name, object? value) => Property(card,name).SetValue(card, value);
    static string SourceKey(EmbyItem item) => string.Join('|', item.Id, item.SeriesId, item.SeriesPrimaryImageTag,
        string.Join(';', item.ImageTags.OrderBy(pair => pair.Key).Select(pair => pair.Key + ":" + pair.Value)),
        string.Join(';', item.BackdropImageTags), item.ParentThumbItemId, item.ParentThumbImageTag,
        item.ParentBackdropItemId, string.Join(';', item.ParentBackdropImageTags));
    public static void ArtworkChanged(object card)
    {
        var identity = Identities.GetOrCreateValue(card);
        string current = SourceKey(Get<EmbyItem>(card, "Item"));
        if (identity.Source == null || identity.Source == current) { identity.Source = current; return; }
        identity.Source = current;
        // Server detail enrichment must not invalidate unchanged card artwork.
        // Compare only the actual request chain used by this card layout.
        object? page = identity.Page?.TryGetTarget(out var target) == true ? target : null;
        string? nextKey = page == null ? null : ArtworkKey(page, card);
        if (identity.Key != null && identity.Key == nextKey) return;
        identity.Key = null; identity.Retries = 0;
        identity.RetryCancellation?.Cancel();
        Get<CancellationTokenSource?>(card, "PosterCancellation")?.Cancel();
        Set(card, "Poster", new BitmapImage()); Set(card, "PosterLoadState", PosterLoadAttemptState.NotStarted);
        if (identity.Page?.TryGetTarget(out var owner) == true && owner is FrameworkElement element)
            element.DispatcherQueue.TryEnqueue(() =>
            {
                if (!element.IsLoaded) return;
                CachedArtwork.Enqueue(owner,new[]{card});
                if(Get<bool>(card,"IsInViewport"))_ = Load(owner, card, Access.Get<CancellationTokenSource?>(owner, "_posterLoadCts")?.Token ?? CancellationToken.None);
            });
    }
    public static void Viewport(object card, bool visible, bool near)
    {
        var identity = Identities.GetOrCreateValue(card);
        // An outgoing/recycled template cannot hide another live instance.
        if(!visible&&identity.Views.Any(v=>v.TryGetTarget(out var view)&&view.VisibleFor(card)))visible=true;
        if (visible && identity.Hidden && Get<PosterLoadAttemptState>(card, "PosterLoadState") == PosterLoadAttemptState.InProgress)
            identity.RequeueOnFinish = true;
        identity.Hidden = !visible;
        Set(card, "IsInViewport", visible); Set(card, "IsNearViewport", visible);
        if (!visible)
        {
            if(!identity.CacheOnly)Get<CancellationTokenSource?>(card, "PosterCancellation")?.Cancel();
            identity.RetryCancellation?.Cancel();
            identity.RequeueOnFinish = false;
        }
    }
    static void Present(object page,object card,bool cached=false)
    {
        bool presented=false;
        foreach(var view in Identities.GetOrCreateValue(card).Views.ToArray())
            if(view.TryGetTarget(out var entry))presented|=entry.Present(page,card,cached);
        if(presented)return;
        // GridView can realize/rebind a template without another effective
        // viewport event. Recover that exact container, never scan library data.
        if(page is FrameworkElement element&&element.FindName("LatestGrid") is Microsoft.UI.Xaml.Controls.GridView grid
            &&grid.ContainerFromItem(card) is FrameworkElement container)
            foreach(var root in UiElements.Descendants(container).OfType<FrameworkElement>().Where(e=>e.Name=="PosterCardRoot"&&ReferenceEquals(e.DataContext,card)))
            {
                if(root.IsLoaded&&(cached||Get<bool>(card,"IsInViewport"))&&root is Microsoft.UI.Xaml.Controls.Grid surface&&!DesktopCardSurface.Ready(surface,card))DesktopTheme.Card(page,root);
            }
    }
    public static void Attach(object page,object? sender)
    {if(sender is FrameworkElement element)Viewports.GetValue(element,e=>new ViewportEntry(e)).Attach(page);}
    public static void PresentVisible(object page,object card)
    {if(Get<bool>(card,"IsInViewport")&&Get<BitmapImage?>(card,"Poster") is {PixelWidth:>0})Present(page,card);}
    internal static void PresentCached(object page,object card)=>Present(page,card,true);
    internal static bool HasBoundView(object card)=>Identities.TryGetValue(card,out var state)&&state.Views.Any(v=>v.TryGetTarget(out var view)&&view.BoundFor(card));
    internal static void WarmBound(object page)
    {
        foreach(var pair in Identities)
            if(pair.Value.Views.Any(v=>v.TryGetTarget(out var view)&&view.BoundFor(pair.Key)))
                foreach(var entry in pair.Value.Views)
                    if(entry.TryGetTarget(out var view)&&view.OwnedBy(page)){CachedArtwork.Enqueue(page,new[]{pair.Key},true);break;}
    }
    internal static void SuspendNetwork(object page)
    {
        foreach(var pair in Identities)
            if(pair.Value.Page?.TryGetTarget(out var owner)==true&&ReferenceEquals(page,owner))
            {
                pair.Value.RetryCancellation?.Cancel();pair.Value.RequeueOnFinish=false;
                if(!pair.Value.CacheOnly)Get<CancellationTokenSource?>(pair.Key,"PosterCancellation")?.Cancel();
            }
    }
    public static void Reconcile(object page)
    {
        foreach(var pair in Viewports)pair.Value.Reconcile(page);
    }
    public static void EffectiveViewport(object page, FrameworkElement sender, EffectiveViewportChangedEventArgs args)
    {
        Viewports.GetValue(sender,element=>new ViewportEntry(element)).Update(page,args.EffectiveViewport);
    }
    internal static string CacheIdentity(object page,object card)=>ArtworkKey(page,card);
    // Only the bounded destination viewport is retained. This path never
    // admits a network request or mutates another loader's cancellation slot.
    internal static async Task PrepareJumpCached(object page,object card,CancellationToken token)
    {
        if(token.IsCancellationRequested)return;
        if(Get<BitmapImage?>(card,"Poster") is {PixelWidth:>0,PixelHeight:>0}){Present(page,card,true);return;}
        var session=Access.Get<EmbySession?>(page,"_session");var generation=Access.Get<CancellationTokenSource?>(page,"_posterLoadCts");
        var item=Get<EmbyItem>(card,"Item");string identity=ArtworkKey(page,card);bool landscape=Get<bool>(card,"PreferLandscapeArtwork");
        var choices=new List<(string Id,string Type,string? Tag,int Width,PosterCacheRetention Retention)>();
        if(landscape)choices.AddRange(Landscape(item,page).Select(c=>(c.ItemId,c.ImageType,(string?)c.ImageTag,1280,PosterCacheRetention.Detail)));
        else
        {
            bool series=item.Type is "Episode" or "Season"&&!string.IsNullOrWhiteSpace(item.SeriesId);
            string id=series?item.SeriesId!:item.Id;string? tag=series?item.SeriesPrimaryImageTag:item.ImageTags.GetValueOrDefault("Primary");
            if(series||!string.IsNullOrWhiteSpace(tag))choices.Add((id,"Primary",tag,360,PosterCacheRetention.Browse));
            if(series&&item.ImageTags.TryGetValue("Primary",out var own)&&!string.IsNullOrWhiteSpace(own))choices.Add((item.Id,"Primary",own,360,PosterCacheRetention.Browse));
        }
        foreach(var choice in choices)
        {
            token.ThrowIfCancellationRequested();
            var image=await BitmapCore(page,item,choice.Type,choice.Width,token,choice.Id,choice.Tag,PosterFetchPriority.Visible,choice.Retention,null,null,true,true);
            if(image==null||landscape&&!ResumeArtwork.IsLandscape(image.PixelWidth,image.PixelHeight))continue;
            if(token.IsCancellationRequested||!ReferenceEquals(session,Access.Get<EmbySession?>(page,"_session"))
                ||!ReferenceEquals(generation,Access.Get<CancellationTokenSource?>(page,"_posterLoadCts"))||identity!=ArtworkKey(page,card))return;
            // Keep decoded cache LRU bounded; realize cached pixels outside
            // the screen too, without pinning a whole catalogue in memory.
            bool bound=Get<bool>(card,"IsInViewport")||Identities.GetOrCreateValue(card).Views.Any(v=>v.TryGetTarget(out var view)&&view.BoundFor(card));
            if(!bound)return;
            if(Get<BitmapImage?>(card,"Poster") is not {PixelWidth:>0,PixelHeight:>0})Set(card,"Poster",image);
            if(!landscape)Access.Call(card,"SetContainedPoster",false);
            Trace("阶段=cache-delivered；本地命中绕过网络限流与重试。");
            Present(page,card,true);return;
        }
    }
    internal static Task LoadCached(object page,object card,CancellationToken generation)=>PrepareJumpCached(page,card,generation);
    public static Task Load(object page,object card,CancellationToken generation)=>LoadCore(page,card,generation,false);
    static async Task LoadCore(object page, object card, CancellationToken generation,bool localOnly)
    {
        if(generation.IsCancellationRequested || AndroidCacheRuntime.IsPaused || !localOnly&&!Get<bool>(card,"IsInViewport"))return;
        var ownerSession=Access.Get<EmbySession?>(page,"_session");
        var ownerGeneration=Access.Get<CancellationTokenSource?>(page,"_posterLoadCts");
        var queued=Identities.GetOrCreateValue(card);queued.NextGeneration=generation;
        if(Get<PosterLoadAttemptState>(card,"PosterLoadState")==PosterLoadAttemptState.InProgress)
        {
            if (Get<CancellationTokenSource?>(card,"PosterCancellation")?.IsCancellationRequested == true || queued.CacheOnly && !DesktopScroll.IsAnimating(page))
                queued.RequeueOnFinish=true;
            return;
        }
        // An existing delayed retry owns this demand. Repeated layout events
        // must not bypass its backoff or create duplicate image attempts.
        if (queued.RetryCancellation is { IsCancellationRequested: false }) return;
        var bitmap = Get<BitmapImage?>(card, "Poster");
        var item = Get<EmbyItem>(card, "Item");
        string demandSource=SourceKey(item);
        bool series = item.Type.Equals("Episode", StringComparison.OrdinalIgnoreCase) || item.Type.Equals("Season", StringComparison.OrdinalIgnoreCase);
        bool landscape = Get<bool>(card, "PreferLandscapeArtwork");
        Set(card, "PreferSeriesArtwork", !landscape && series);
        var candidates = landscape ? Landscape(item, page) : Array.Empty<MediaArtworkCandidate>();
        string identity = ArtworkKey(page, card);
        var remembered = Identities.GetOrCreateValue(card);
        remembered.Page = new(page); remembered.Source = SourceKey(item);
        bool changedIdentity = remembered.Key != null && remembered.Key != identity;
        remembered.Key = identity;
        if (changedIdentity)
        {
            // A fresh Emby tag or episode artwork owner replaces only pixels.
            Set(card, "Poster", new BitmapImage());
            Access.Call(card, "SetContainedPoster", false);
            Access.Call(card, "NotifyResumeLayoutChanged");
            bitmap = null;
        }
        if (bitmap is { PixelWidth: > 0, PixelHeight: > 0 }) { Present(page,card); return; }
        remembered.CacheOnly=true;
        Set(card, "PosterLoadState", PosterLoadAttemptState.InProgress);
        using var cancellation = CancellationTokenSource.CreateLinkedTokenSource(generation);
        Set(card, "PosterCancellation", cancellation);
        try
        {
            BitmapImage? image = null;bool fromCache=false;
            // Examine every CURRENT candidate on disk before admitting any
            // network work. A missing preferred image cannot block a valid
            // cached alternative behind the download queue or a slow server.
            var choices = new List<(string Id,string Type,string? Tag,int Width,PosterCacheRetention Retention)>();
            if (landscape)
                choices.AddRange(candidates.Select(c => (c.ItemId,c.ImageType,(string?)c.ImageTag,1280,PosterCacheRetention.Detail)));
            else
            {
                string id = series && !string.IsNullOrWhiteSpace(item.SeriesId) ? item.SeriesId : item.Id;
                string? tag = id != item.Id ? item.SeriesPrimaryImageTag : item.ImageTags.GetValueOrDefault("Primary");
                if (id != item.Id || !string.IsNullOrWhiteSpace(tag)) choices.Add((id,"Primary",tag,360,PosterCacheRetention.Browse));
                if (id != item.Id && item.ImageTags.TryGetValue("Primary",out var ownTag) && !string.IsNullOrWhiteSpace(ownTag))
                    choices.Add((item.Id,"Primary",ownTag,360,PosterCacheRetention.Browse));
            }
            foreach (bool cacheOnly in localOnly?new[]{true}:new[] { true, false })
            {
                if(!cacheOnly&&(!Get<bool>(card,"IsInViewport")||AndroidCacheRuntime.IsPaused||DesktopScroll.IsAnimating(page)))break;
                remembered.CacheOnly=cacheOnly||DesktopScroll.IsAnimating(page);
                foreach (var choice in choices)
                {
                    image = await BitmapCore(page,item,choice.Type,choice.Width,cancellation.Token,choice.Id,choice.Tag,
                        PosterFetchPriority.Visible,choice.Retention,
                        () => Get<bool>(card,"IsInViewport") && !generation.IsCancellationRequested,() => PosterFetchPriority.Visible,true,cacheOnly);
                    if (image != null && (!landscape || ResumeArtwork.IsLandscape(image.PixelWidth,image.PixelHeight))){fromCache=cacheOnly;break;}
                    image = null;
                    if (cancellation.IsCancellationRequested || (!cacheOnly && (!Get<bool>(card,"IsInViewport")||AndroidCacheRuntime.IsPaused))) break;
                }
                if (image != null || cancellation.IsCancellationRequested || !Get<bool>(card,"IsInViewport") || AndroidCacheRuntime.IsPaused) break;
            }
            if (!localOnly&&landscape && image == null && !generation.IsCancellationRequested && Get<bool>(card,"IsInViewport") && !AndroidCacheRuntime.IsPaused)
                PlaybackTransport.Write("Info", "Poster.Resume", candidates.Count == 0 ? "Emby 未提供可用横图标识，保留横向图片占位。" : "本轮 Emby 横图未加载成功，保留横向图片占位并按既有限额重试。");
            if (image == null || cancellation.IsCancellationRequested || !fromCache&&!Get<bool>(card,"IsInViewport")
                || page is not FrameworkElement{IsLoaded:true}
                ||!ReferenceEquals(ownerSession,Access.Get<EmbySession?>(page,"_session"))
                ||!ReferenceEquals(ownerGeneration,Access.Get<CancellationTokenSource?>(page,"_posterLoadCts"))
                || SourceKey(Get<EmbyItem>(card,"Item")) != demandSource) return;
            // Unrealized offscreen cards warm the existing bounded decoder LRU.
            // Do not pin a bitmap in every model of a large catalogue.
            if(fromCache&&!Get<bool>(card,"IsInViewport")&&!remembered.Views.Any(v=>v.TryGetTarget(out var view)&&view.BoundFor(card)))return;
            Set(card, "Poster", image);
            Present(page,card,fromCache);
            Trace("阶段=card-applied；图片已交给当前卡片。");
            remembered.Retries = 0;
            if (!landscape) Access.Call(card, "SetContainedPoster", false);
        }
        catch (OperationCanceledException) { }
        catch (Exception error)
        { PlaybackTransport.Write("Warning", "Poster", "海报读取失败：" + error.GetType().Name + "；代码="+error.HResult.ToString("X8")+"；可在当前页面重试。 "); }
        finally
        {
            if (ReferenceEquals(Get<CancellationTokenSource?>(card, "PosterCancellation"), cancellation))
            {
                Set(card, "PosterCancellation", null);
                Set(card, "PosterLoadState", Get<BitmapImage?>(card, "Poster") is { PixelWidth: > 0 }
                    ? PosterLoadAttemptState.Completed : PosterLoadAttemptState.NotStarted);
                bool requeue = remembered.RequeueOnFinish && !DesktopScroll.IsAnimating(page) && !remembered.NextGeneration.IsCancellationRequested && !AndroidCacheRuntime.IsPaused
                    && Get<bool>(card, "IsInViewport") && page is FrameworkElement { IsLoaded: true };
                remembered.RequeueOnFinish = false;
                if (requeue && page is FrameworkElement element)
                    element.DispatcherQueue.TryEnqueue(() => _ = Load(page, card, remembered.NextGeneration));
                else if (!localOnly&&!generation.IsCancellationRequested && !DesktopScroll.IsAnimating(page) && !AndroidCacheRuntime.IsPaused && Get<bool>(card, "IsInViewport")
                    && Get<PosterLoadAttemptState>(card, "PosterLoadState") == PosterLoadAttemptState.NotStarted
                    && page is FrameworkElement { IsLoaded: true }
                    && (landscape ? candidates.Count > 0 : series || item.ImageTags.TryGetValue("Primary", out var retryTag) && !string.IsNullOrWhiteSpace(retryTag))
                    && remembered.RetryCancellation is not { IsCancellationRequested: false })
                    _ = Retry();
            }
        }
        async Task Retry()
        {
            using var retry = CancellationTokenSource.CreateLinkedTokenSource(generation);
            remembered.RetryCancellation = retry;
            int delay = Math.Min(30000, 3000 * (1 << Math.Min(remembered.Retries++, 4)));
            try
            {
                await Task.Delay(delay, retry.Token);
                if (!retry.IsCancellationRequested && !DesktopScroll.IsAnimating(page) && Get<bool>(card, "IsInViewport") && !AndroidCacheRuntime.IsPaused
                    && page is FrameworkElement { IsLoaded: true } && SourceKey(Get<EmbyItem>(card, "Item")) == demandSource)
                {
                    if (ReferenceEquals(remembered.RetryCancellation, retry)) remembered.RetryCancellation = null;
                    await Load(page, card, generation);
                }
            }
            catch (OperationCanceledException) { }
            finally { if (ReferenceEquals(remembered.RetryCancellation, retry)) remembered.RetryCancellation = null; }
        }
    }
    static string ArtworkKey(object page, object card)
    {
        var item = Get<EmbyItem>(card, "Item");
        if (Get<bool>(card, "PreferLandscapeArtwork"))
            return "landscape:" + string.Join('|', Landscape(item, page).Select(c => $"{c.ItemId}:{c.ImageType}:{c.ImageTag}"));
        bool series = (item.Type.Equals("Episode", StringComparison.OrdinalIgnoreCase) || item.Type.Equals("Season", StringComparison.OrdinalIgnoreCase)) && !string.IsNullOrWhiteSpace(item.SeriesId);
        return series ? $"portrait:{item.SeriesId}:{item.SeriesPrimaryImageTag}:{item.Id}:{item.ImageTags.GetValueOrDefault("Primary")}" : $"portrait:{item.Id}:{item.ImageTags.GetValueOrDefault("Primary")}";
    }
    static IReadOnlyList<MediaArtworkCandidate> Landscape(EmbyItem item, object page)
    {
        var candidates = ResumeArtwork.Expand(item, id => (IEnumerable<EmbyItem>)Access.Call(page, "FindCachedItems", id)!);
        return candidates.Where(c => c.ImageType is "Thumb" or "Backdrop").ToArray();
    }
    internal static async Task<BitmapImage?> CachedDetailPoster(object page,EmbyItem item,CancellationToken token)
    {
        bool parent=item.Type is "Episode" or "Season"&&!string.IsNullOrWhiteSpace(item.SeriesId);
        var choices=new List<(string Id,string? Tag)>();
        if(parent)choices.Add((item.SeriesId!,item.SeriesPrimaryImageTag));
        if(item.ImageTags.TryGetValue("Primary",out var own)&&!string.IsNullOrWhiteSpace(own))choices.Add((item.Id,own));
        foreach(var choice in choices)
        {
            var image=await BitmapCore(page,item,"Primary",360,token,choice.Id,choice.Tag,PosterFetchPriority.Interactive,PosterCacheRetention.Browse,null,null,false,true);
            if(image is {PixelWidth:>0,PixelHeight:>0})return image;
        }
        return null;
    }
    internal static Task<BitmapImage?> CachedDetailBackground(object page,EmbyItem item,CancellationToken token)
        =>BitmapCore(page,item,"Backdrop",1280,token,item.Id,item.BackdropImageTags.FirstOrDefault(),PosterFetchPriority.Interactive,PosterCacheRetention.Detail,null,null,false,true);
    public static Task<BitmapImage?> Bitmap(object page, EmbyItem item, string imageType, int width, CancellationToken token,
        string? imageItemId, string? imageTag, PosterFetchPriority priority, PosterCacheRetention retention,
        Func<bool>? isStillNeeded, Func<PosterFetchPriority>? currentPriority)
        =>BitmapCore(page,item,imageType,width,token,imageItemId,imageTag,priority,retention,isStillNeeded,currentPriority,false);
    static async Task<BitmapImage?> BitmapCore(object page, EmbyItem item, string imageType, int width, CancellationToken token,
        string? imageItemId, string? imageTag, PosterFetchPriority priority, PosterCacheRetention retention,
        Func<bool>? isStillNeeded, Func<PosterFetchPriority>? currentPriority,bool card,bool cacheOnly=false)
    {
        var session = Access.Get<EmbySession?>(page, "_session");
        var client = Access.Get<EmbyApiClient?>(page, "_client");
        if (session == null) return null;
        string id = imageItemId ?? item.Id;
        string? tag = imageTag;
        if (tag == null && id == item.Id)
            tag = imageType == "Backdrop" ? item.BackdropImageTags.FirstOrDefault() : item.ImageTags.GetValueOrDefault(imageType);
        if (imageType == "Backdrop" && string.IsNullOrWhiteSpace(tag)) return null;
        width = imageType == "Backdrop" || retention == PosterCacheRetention.Detail && width >= 960 ? 1280 : 360;
        var owner = id == item.Id ? item : (Access.Call(page, "FindCachedItems", id) as IEnumerable<EmbyItem>)?.FirstOrDefault();
        var request = new PosterCacheRequest(session.ServerId, session.UserId, id, imageType, tag, width, 85, retention, ArtworkWorkIdentity.FromItem(owner));
        var cache = Access.Get<PosterCacheService>(page, "_posterCache");
        long lookupStarted=ImageLoadDiagnostics.Start();
        var local = await Task.Run(() => AndroidCacheImages.TryCached(cache,request), token);
        ImageLoadDiagnostics.Record(local==null?"cache-miss":"cache-hit",lookupStarted);
        Trace(local==null?"阶段=cache-miss；当前图片需要下载。":"阶段=cache-hit；读取当前图片缓存。");
        if (local == null && cacheOnly) return null;
        if (local == null)
        {
            bool Needed() => (!card||!DesktopScroll.IsAnimating(page)) && (isStillNeeded?.Invoke() ?? true) && !token.IsCancellationRequested;
            if (client==null||!Needed() || AndroidCacheRuntime.IsPaused || !ReferenceEquals(session, Access.Get<EmbySession?>(page, "_session"))) return null;
            local = await cache.GetOrDownloadAsync(request, client.BuildImageUri(id, tag, width, imageType), token,
                priority, false, Needed, currentPriority);
        }
        // A stale fallback belongs to an older Emby image tag. It must not
        // complete the current demand or suppress the bounded visible retry.
        if (local == null || local.IsStale || token.IsCancellationRequested || !ReferenceEquals(session, Access.Get<EmbySession?>(page, "_session"))) return null;
        long decodeStarted=ImageLoadDiagnostics.Start();BitmapImage? decoded;
        try{decoded=await (Task<BitmapImage?>)Access.Call(page, "LoadBitmapFromFileAsync", local.FilePath, token)!;}
        catch(OperationCanceledException){throw;}
        catch{ImageLoadDiagnostics.Record("decode-failed",decodeStarted);throw;}
        ImageLoadDiagnostics.Record(decoded is {PixelWidth:>0,PixelHeight:>0}?"decoded":"decode-failed",decodeStarted);
        if(token.IsCancellationRequested||!ReferenceEquals(session,Access.Get<EmbySession?>(page,"_session"))
            ||!ReferenceEquals(client,Access.Get<EmbyApiClient?>(page,"_client")))return null;
        Trace(decoded is {PixelWidth:>0,PixelHeight:>0}?"阶段=decoded；图片已完成解码。":"阶段=decode-empty；保留重试入口。");
        return decoded;
    }
}
