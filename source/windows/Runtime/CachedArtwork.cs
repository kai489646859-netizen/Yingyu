using System.Collections;
using System.Reflection;
using System.Runtime.CompilerServices;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;

namespace Yingyu.Update;

// Cache-only preparation for already known items. Two low-priority workers,
// weak queue entries and the existing decoder LRU bound disk/decode pressure.
// This queue never asks Emby for metadata and cannot download an image.
internal static class CachedArtwork
{
    static readonly ConditionalWeakTable<FrameworkElement,State> Pages=new();
    static int warnings;
    const BindingFlags Flags=BindingFlags.Instance|BindingFlags.Public|BindingFlags.NonPublic;
    sealed class Stamp{internal string? Key;internal bool Completed,Bound;}
    sealed record Work(WeakReference<object> Card,string Key,int Epoch);
    internal static void Enqueue(object page,IEnumerable cards,bool bound=false)
    {
        try{if(page is FrameworkElement{IsLoaded:true} element)Pages.GetValue(element,p=>new State(p)).Add(cards,bound);}
        catch(Exception error){Warn(error);}
    }
    internal static void WarmCurrent(object page)
    {
        try
        {
            if(page is not FrameworkElement{IsLoaded:true})return;
            AndroidCacheCards.WarmBound(page);
        }
        catch(Exception error){Warn(error);}
    }
    static void Warn(Exception error){try{if(Interlocked.Increment(ref warnings)<=6)PlaybackTransport.Write("Warning","Poster.CachePrepare","本地图片准备未完成；"+error.GetType().Name+"；可继续原可见加载入口。");}catch(Exception){}}
    sealed class State
    {
        readonly FrameworkElement page;readonly Queue<Work> pending=new(),realized=new();
        ConditionalWeakTable<object,Stamp> attempts=new();CancellationToken generation;
        object? session;int epoch,active;
        internal State(FrameworkElement page)
        {
            this.page=page;
            page.Unloaded+=(_,_)=>{epoch++;pending.Clear();realized.Clear();attempts=new();session=null;};
        }
        internal void Add(IEnumerable cards,bool bound)
        {
            var next=Access.Get<CancellationTokenSource?>(page,"_posterLoadCts")?.Token??CancellationToken.None;
            var owner=Access.Get<object?>(page,"_session");
            if(next.IsCancellationRequested||owner==null)return;
            if(generation!=next||!ReferenceEquals(session,owner)){epoch++;pending.Clear();realized.Clear();attempts=new();generation=next;session=owner;}
            foreach(object card in cards)
            {
                // Virtualized models have no image surface to paint yet.
                // Their real template queues cached delivery when realized;
                // jump prediction already prepares the upcoming local window.
                if(!bound&&!AndroidCacheCards.HasBoundView(card))continue;
                if(card.GetType().GetProperty("Poster",Flags)?.GetValue(card) is Microsoft.UI.Xaml.Media.Imaging.BitmapImage{PixelWidth:>0,PixelHeight:>0}){if(bound)AndroidCacheCards.PresentCached(page,card);continue;}
                string key=AndroidCacheCards.CacheIdentity(page,card);var stamp=attempts.GetOrCreateValue(card);
                // A template realized after its model-only warm-up needs a
                // cache-only delivery pass. Scroll events do not reset this.
                if(stamp.Key==key&&(!bound||stamp.Bound&&!stamp.Completed))continue;
                stamp.Key=key;stamp.Completed=false;stamp.Bound=bound;
                // A newly realized cached card goes ahead of catalogue warm-up,
                // including when the old model-only work has not started yet.
                (bound?realized:pending).Enqueue(new(new(card),key,epoch));
            }
            Pump();
        }
        void Pump()
        {
            while(active<2&&(realized.Count>0||pending.Count>0)&&page.IsLoaded)
            {
                var work=(realized.Count>0?realized:pending).Dequeue();active++;
                if(!page.DispatcherQueue.TryEnqueue(DispatcherQueuePriority.Low,()=>_ = Run(work))){active--;break;}
            }
        }
        async Task Run(Work work)
        {
            Stamp? running=null;
            try
            {
                if(work.Epoch!=epoch||!page.IsLoaded||generation.IsCancellationRequested
                    ||!ReferenceEquals(session,Access.Get<object?>(page,"_session"))||!work.Card.TryGetTarget(out var card)
                    ||!attempts.TryGetValue(card,out var stamp)||stamp.Key!=work.Key)return;
                running=stamp;
                // Local delivery owns no network attempt, retry timer or card
                // cancellation slot. A failed download cannot block a hit.
                await AndroidCacheCards.PrepareJumpCached(page,card,generation);
            }
            catch(OperationCanceledException){}
            catch(Exception error){Warn(error);}
            finally{if(running!=null)running.Completed=true;active--;Pump();}
        }
    }
}
