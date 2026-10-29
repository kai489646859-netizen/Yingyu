using System.Diagnostics;
using System.Runtime.CompilerServices;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
namespace Yingyu.Update;

// Continuous movement of the real ScrollViewer. No snapshot, opacity swap,
// target pre-position or compositor cover substitutes for the scroll path.
internal static class DesktopJumpPresentation
{
    sealed class State
    {
        internal int Epoch;internal bool Active,Browse,Settling,PrefetchRunning,PrefetchQueued;
        internal double Target,StartOffset,LastFrame=-20,LastPrepare=-100;internal TimeSpan Duration;
        internal readonly Stopwatch Clock=new();internal ScrollViewer? Scroll;internal GridView? Grid;
        internal int Columns,WantedFirst,WantedCount;internal double RowHeight;internal int? Index;internal string? Letter;
        internal CancellationTokenSource? Cancellation,OwnerGeneration;internal object? Session;internal string? Scope;
        internal Task? Preparing;internal DispatcherTimer? Deadline;internal EventHandler<object>? Rendering;
        internal Microsoft.UI.Xaml.Input.PointerEventHandler? Wheel,Press;internal RoutedEventHandler? Unloaded;internal SizeChangedEventHandler? Resized;
        internal CancellationTokenRegistration GenerationEnd;
    }
    static readonly ConditionalWeakTable<object,State> States=new();
    static double Ease(double p)=>p*p*(3-2*p);
    internal static async void Start(object page,ScrollViewer scroll,double target,int? index=null,string? letter=null)
    {
        State? state=null;int epoch=0;
        try
        {
            Cancel(page,false);
            if(page is not FrameworkElement{IsLoaded:true} element||!scroll.IsLoaded||scroll.ViewportHeight<=0||!double.IsFinite(target))return;
            state=States.GetOrCreateValue(page);state.Active=true;epoch=++state.Epoch;state.Scroll=scroll;
            state.Target=Math.Clamp(target,0,Math.Max(0,scroll.ScrollableHeight));state.StartOffset=scroll.VerticalOffset;
            state.Duration=DesktopScroll.Duration(state.Target-state.StartOffset,scroll.ViewportHeight);state.LastFrame=-20;state.LastPrepare=-100;
            state.Settling=state.PrefetchRunning=state.PrefetchQueued=false;state.Index=index;state.Letter=letter;
            state.Browse=ReferenceEquals(scroll,Access.Get<ScrollViewer?>(page,"_browseResultsScrollViewer"));
            state.OwnerGeneration=Access.Get<CancellationTokenSource?>(page,"_posterLoadCts");
            state.Cancellation=CancellationTokenSource.CreateLinkedTokenSource(state.OwnerGeneration?.Token??CancellationToken.None);var token=state.Cancellation.Token;
            state.Session=Access.Get<object?>(page,"_session");state.Scope=Access.Get<string?>(page,"_activeSnapshotKey");
            if(state.Browse){state.Grid=DesktopNavigation.BrowseGrid(page);var metrics=DesktopNavigation.Metrics(page);state.Columns=metrics.Columns;state.RowHeight=metrics.Height;}
            else state.Grid=null;
            Access.Set(page,"_browseRestoreVersion",Access.Get<int>(page,"_browseRestoreVersion")+1);Access.Set(page,"_restoringBrowseOffset",false);
            Access.Set(page,"_alphabetScrollViewer",scroll);Access.Set(page,"_alphabetScrollInProgress",true);AndroidCacheCards.SuspendNetwork(page);
            state.Wheel=(_,_)=>Cancel(page,true);state.Press=(_,_)=>Cancel(page,true);state.Unloaded=(_,_)=>Cancel(page,false);
            state.Resized=(_,args)=>{if(Math.Abs(args.NewSize.Width-args.PreviousSize.Width)>.5||Math.Abs(args.NewSize.Height-args.PreviousSize.Height)>.5)Cancel(page,true);};
            scroll.AddHandler(UIElement.PointerWheelChangedEvent,state.Wheel,true);scroll.AddHandler(UIElement.PointerPressedEvent,state.Press,true);scroll.Unloaded+=state.Unloaded;
            scroll.SizeChanged+=state.Resized;
            state.GenerationEnd=token.Register(()=>{try{element.DispatcherQueue.TryEnqueue(()=>{if(state.Epoch==epoch)Finish(page,state,false);});}catch(Exception error){Warn(error);}});
            state.Deadline=new DispatcherTimer{Interval=state.Duration+TimeSpan.FromSeconds(3)};
            // A stalled/cancelled scroll stops where it is; the deadline must
            // never hide a skipped path by teleporting to the destination.
            state.Deadline.Tick+=(_,_)=>{if(state.Epoch==epoch){Warn(new TimeoutException());Finish(page,state,true);}};state.Deadline.Start();
            bool reduced=DesktopTheme.Options.ReducedMotion||Access.Get<EmbyDesktop.Core.Services.UserPreferences>(page,"_preferences").Experience?.ReducedMotion==true
                ||!Access.Get<Windows.UI.ViewManagement.UISettings>(page,"_uiSettings").AnimationsEnabled;
            if(reduced||Math.Abs(state.Target-state.StartOffset)<1){await Settle(page,state,epoch);return;}
            UpdateWindow(state,state.StartOffset,Position(state,.18));
            state.Preparing=PrepareWindow(page,state,epoch,token);
            await Task.WhenAny(state.Preparing,Task.Delay(120,token));
            if(!Current(page,state,epoch)){if(state.Epoch==epoch)Finish(page,state,false);return;}
            state.Rendering=(_,_)=>Frame(page,state,epoch);state.Clock.Restart();CompositionTarget.Rendering+=state.Rendering;
        }
        catch(OperationCanceledException){if(state?.Epoch==epoch)Finish(page,state,false);}
        catch(Exception error){Warn(error);if(state?.Epoch==epoch)Finish(page,state,true);}
    }
    static bool Current(object page,State state,int epoch)=>state.Active&&state.Epoch==epoch&&state.Cancellation?.IsCancellationRequested==false
        &&page is FrameworkElement{IsLoaded:true}&&!AndroidCacheRuntime.IsPaused&&state.Scroll is {IsLoaded:true}
        &&ReferenceEquals(state.OwnerGeneration,Access.Get<CancellationTokenSource?>(page,"_posterLoadCts"))
        &&ReferenceEquals(state.Session,Access.Get<object?>(page,"_session"))&&state.Scope==Access.Get<string?>(page,"_activeSnapshotKey");
    static double Position(State state,double progress)=>state.StartOffset+(state.Target-state.StartOffset)*Ease(Math.Clamp(progress,0,1));
    static void Frame(object page,State state,int epoch)
    {
        try
        {
            if(!Current(page,state,epoch)){if(state.Epoch==epoch)Finish(page,state,false);return;}
            double elapsed=state.Clock.Elapsed.TotalMilliseconds,progress=Math.Clamp(elapsed/state.Duration.TotalMilliseconds,0,1);
            if(progress<1&&elapsed-state.LastFrame<15)return;state.LastFrame=elapsed;
            if(progress>=1){if(!state.Settling)_=Settle(page,state,epoch);return;}
            var scroll=state.Scroll!;double offset=Math.Clamp(Position(state,progress),0,Math.Max(0,scroll.ScrollableHeight));
            if(Math.Abs(scroll.VerticalOffset-offset)>.25)scroll.ChangeView(null,offset,null,true);
            // Only update a bounded prediction window at most every 75ms.
            // Native ViewChanged is guarded, so there is no per-frame save,
            // global card scan, navigation repaint or responsive grid rebuild.
            if(state.Browse&&elapsed-state.LastPrepare>=75)
            {
                state.LastPrepare=elapsed;UpdateWindow(state,offset,Position(state,progress+180/state.Duration.TotalMilliseconds));
                QueueWindow(page,state,epoch);
            }
        }
        catch(Exception error){Warn(error);if(state.Epoch==epoch)Finish(page,state,true);}
    }
    static void UpdateWindow(State state,double offset,double predicted)
    {
        if(state.Grid==null||state.Scroll==null)return;
        int first=Math.Max(0,(int)Math.Floor(Math.Min(offset,predicted)/state.RowHeight)-1)*state.Columns;
        int last=((int)Math.Floor((Math.Max(offset,predicted)+state.Scroll.ViewportHeight)/state.RowHeight)+2)*state.Columns;
        state.WantedFirst=Math.Min(first,state.Grid.Items.Count);state.WantedCount=Math.Min(128,Math.Max(0,Math.Min(last,state.Grid.Items.Count)-state.WantedFirst));
    }
    static void QueueWindow(object page,State state,int epoch)
    {
        if(state.PrefetchRunning||state.PrefetchQueued||page is not FrameworkElement element)return;
        state.PrefetchQueued=true;
        if(!element.DispatcherQueue.TryEnqueue(DispatcherQueuePriority.Low,()=>{
            if(state.Epoch!=epoch)return;state.PrefetchQueued=false;
            if(Current(page,state,epoch)&&!state.PrefetchRunning)state.Preparing=PrepareWindow(page,state,epoch,state.Cancellation!.Token);
        }))state.PrefetchQueued=false;
    }
    static async Task PrepareWindow(object page,State state,int epoch,CancellationToken token)
    {
        if(!state.Browse||state.Grid==null||!Current(page,state,epoch))return;
        state.PrefetchRunning=true;var grid=state.Grid;int first=state.WantedFirst,count=state.WantedCount,cursor=0;
        async Task Worker()
        {
            while(!token.IsCancellationRequested&&Current(page,state,epoch))
            {
                int index=first+cursor++;if(index>=first+count||index>=grid.Items.Count)return;
                if(index<state.WantedFirst||index>=state.WantedFirst+state.WantedCount)continue;
                try{await AndroidCacheCards.PrepareJumpCached(page,grid.Items[index],token);}
                catch(OperationCanceledException){return;}catch(Exception error){Warn(error);}
            }
        }
        try{await Task.WhenAll(Worker(),Worker());}
        catch(Exception error){if(error is not OperationCanceledException)Warn(error);}
        finally{if(state.Epoch==epoch)state.PrefetchRunning=false;}
    }
    static async Task Settle(object page,State state,int epoch)
    {
        if(state.Settling)return;state.Settling=true;
        try
        {
            if(state.Rendering!=null)CompositionTarget.Rendering-=state.Rendering;state.Rendering=null;state.Clock.Stop();
            if(!Current(page,state,epoch)){if(state.Epoch==epoch)Finish(page,state,false);return;}
            var scroll=state.Scroll!;double target=Math.Clamp(state.Target,0,Math.Max(0,scroll.ScrollableHeight));
            scroll.ChangeView(null,target,null,true);scroll.UpdateLayout();
            if(state.Browse&&state.Index is {} requested)
            {
                state.Grid!.UpdateLayout();target=Math.Clamp(DesktopNavigation.RowOffset(page,scroll,requested),0,Math.Max(0,scroll.ScrollableHeight));
                if(Math.Abs(scroll.VerticalOffset-target)>.75){scroll.ChangeView(null,target,null,true);scroll.UpdateLayout();}
            }
            if(state.Browse)
            {
                UpdateWindow(state,target,target);
                if(!state.PrefetchRunning)state.Preparing=PrepareWindow(page,state,epoch,state.Cancellation!.Token);
                if(state.Preparing!=null)await Task.WhenAny(state.Preparing,Task.Delay(120,state.Cancellation!.Token));
            }
            if(!Current(page,state,epoch)){if(state.Epoch==epoch)Finish(page,state,false);return;}
            if(state.Browse&&state.Index is {} finalIndex)
            {
                // Recycling/image layout can adjust the ScrollViewer anchor
                // after the first ChangeView. Re-measure the actual target row
                // after layout, and ease any remaining correction continuously.
                for(int pass=0;pass<2;pass++)
                {
                    await Task.Delay(34,state.Cancellation!.Token);
                    if(!Current(page,state,epoch)){if(state.Epoch==epoch)Finish(page,state,false);return;}
                    scroll.UpdateLayout();
                    double corrected=Math.Clamp(DesktopNavigation.RowOffset(page,scroll,finalIndex),0,Math.Max(0,scroll.ScrollableHeight));
                    double from=scroll.VerticalOffset;target=corrected;
                    if(Math.Abs(from-corrected)<=.75)break;
                    for(int step=1;step<=8;step++)
                    {
                        if(!Current(page,state,epoch)){if(state.Epoch==epoch)Finish(page,state,false);return;}
                        scroll.ChangeView(null,from+(corrected-from)*Ease(step/8d),null,true);
                        await Task.Delay(16,state.Cancellation.Token);
                    }
                }
            }
            AndroidCacheCards.Reconcile(page);
            if(Math.Abs(scroll.VerticalOffset-target)<=2)DesktopNavigation.Commit(page,state.Letter,state.Index??0,scroll.VerticalOffset);
            Finish(page,state,true);
        }
        catch(OperationCanceledException){if(state.Epoch==epoch)Finish(page,state,false);}
        catch(Exception error){Warn(error);if(state.Epoch==epoch)Finish(page,state,true);}
    }
    internal static void Cancel(object page,bool resume)
    {try{if(States.TryGetValue(page,out var state)&&state.Active)Finish(page,state,resume);}catch(Exception error){Warn(error);}}
    static void Finish(object page,State state,bool resume)
    {
        if(!state.Active)return;state.Active=false;int epoch=++state.Epoch;
        void Clean(Action action){try{action();}catch(Exception error){Warn(error);}}
        state.Clock.Stop();if(state.Rendering!=null)Clean(()=>CompositionTarget.Rendering-=state.Rendering);state.Rendering=null;
        Clean(()=>state.Deadline?.Stop());state.Deadline=null;
        Clean(()=>state.Cancellation?.Cancel());Clean(()=>state.Cancellation?.Dispose());state.Cancellation=null;Clean(()=>state.GenerationEnd.Dispose());
        if(state.Scroll is {} scroll)
        {if(state.Wheel!=null)Clean(()=>scroll.RemoveHandler(UIElement.PointerWheelChangedEvent,state.Wheel));if(state.Press!=null)Clean(()=>scroll.RemoveHandler(UIElement.PointerPressedEvent,state.Press));if(state.Unloaded!=null)Clean(()=>scroll.Unloaded-=state.Unloaded);if(state.Resized!=null)Clean(()=>scroll.SizeChanged-=state.Resized);}
        state.Wheel=state.Press=null;state.Unloaded=null;state.Resized=null;state.Scroll=null;state.Grid=null;
        Clean(()=>Access.Set(page,"_alphabetScrollInProgress",false));Clean(()=>Access.Set(page,"_alphabetScrollViewer",null));Clean(()=>Access.Set(page,"_browseLayoutRefreshQueued",false));
        if(resume&&page is FrameworkElement{IsLoaded:true} element&&state.OwnerGeneration?.IsCancellationRequested!=true)
            Clean(()=>element.DispatcherQueue.TryEnqueue(DispatcherQueuePriority.Low,()=>{
                try
                {
                    if(state.Epoch!=epoch||!element.IsLoaded||DesktopScroll.IsAnimating(page)||AndroidCacheRuntime.IsPaused||state.OwnerGeneration?.IsCancellationRequested==true
                        ||!ReferenceEquals(state.Session,Access.Get<object?>(page,"_session"))||state.Scope!=Access.Get<string?>(page,"_activeSnapshotKey"))return;
                    if(state.Browse){Access.Call(page,"LatestGrid_LayoutUpdated",null!,EventArgs.Empty);Access.Call(page,"RememberBrowseOffset");}
                    AndroidCacheCards.Reconcile(page);DesktopCardSurface.RefreshAfterScroll(page);DesktopNavigation.Update(page);Access.Call(page,"UpdateBackToTopButtonVisibility");
                }
                catch(Exception error){Warn(error);}
            }));
    }
    static void Warn(Exception error){try{PlaybackTransport.Write("Warning","Navigation.Jump","连续滚动或本地图片准备未完成；"+error.GetType().Name);}catch(Exception){}}
}
