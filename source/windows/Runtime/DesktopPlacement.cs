using System.Runtime.CompilerServices;
using EmbyDesktop.Core.Services;
using Microsoft.UI.Xaml;
using Microsoft.UI.Windowing;
using Windows.Graphics;
namespace Yingyu.Update;
public static class DesktopPlacement
{
    static readonly ConditionalWeakTable<Window,Watch> Watches=new();
    public static WindowPlacement Restore(WindowPlacement? saved,WindowWorkArea fallback)
    {
        var primary=new RectInt32(fallback.X,fallback.Y,fallback.Width,fallback.Height);
        var area=Choose(saved,CurrentAreas(primary),primary);
        return saved==null?WindowPlacementPolicy.Restore(null,new(area.X,area.Y,area.Width,area.Height)) with {IsMaximized=true}:Fit(saved,area);
    }
    static RectInt32[] CurrentAreas(RectInt32 fallback)
    {
        try
        {
            // IVectorView's indexer works on systems where its IIterable
            // projection fails. Do not use LINQ/foreach on this WinRT list.
            var displays=DisplayArea.FindAll();
            var areas=new RectInt32[displays.Count];
            for(int i=0;i<areas.Length;i++)areas[i]=displays[i].WorkArea;
            return areas.Length==0?[fallback]:areas;
        }
        catch(Exception e)
        {
            PlaybackTransport.Write("Warning","Window.Placement","显示器列表读取失败，使用当前有效工作区；"+e.GetType().Name);
            return [fallback];
        }
    }
    internal static RectInt32 Choose(WindowPlacement? p,RectInt32[] areas,RectInt32 fallback)
    {
        if(p==null||areas.Length==0)return fallback;
        long Overlap(RectInt32 a)=>Math.Max(0,Math.Min((long)p.X+p.Width,(long)a.X+a.Width)-Math.Max(p.X,a.X))*Math.Max(0,Math.Min((long)p.Y+p.Height,(long)a.Y+a.Height)-Math.Max(p.Y,a.Y));
        var best=areas.OrderByDescending(Overlap).First();return Overlap(best)>0?best:fallback;
    }
    internal static WindowPlacement Fit(WindowPlacement p,RectInt32 area)
    {
        int width=Math.Min(Math.Max(320,p.Width),Math.Max(1,area.Width)),height=Math.Min(Math.Max(240,p.Height),Math.Max(1,area.Height));
        return new(Math.Clamp(p.X,area.X,area.X+area.Width-width),Math.Clamp(p.Y,area.Y,area.Y+area.Height-height),width,height,p.IsMaximized);
    }
    public static void Attach(object owner){try{if(owner is Window window)Watches.GetValue(window,w=>new Watch(w));}catch(Exception e){PlaybackTransport.Write("Warning","Window.Placement","显示器监听未能启动；"+e.GetType().Name);}}
    sealed class Watch
    {
        readonly Window window;readonly DisplayAreaWatcher watcher;bool closed,queued;
        internal Watch(Window window)
        {
            this.window=window;watcher=DisplayArea.CreateWatcher();watcher.Removed+=Changed;watcher.Updated+=Changed;
            window.Closed+=(_,_)=>{closed=true;watcher.Removed-=Changed;watcher.Updated-=Changed;watcher.Stop();};watcher.Start();
        }
        void Changed(DisplayAreaWatcher sender,DisplayArea area)
        {
            if(closed||queued)return;queued=true;
            window.DispatcherQueue.TryEnqueue(()=>{queued=false;if(closed)return;try{
                var app=window.AppWindow;if(app.Presenter is not OverlappedPresenter {State:OverlappedPresenterState.Restored})return;
                var old=new WindowPlacement(app.Position.X,app.Position.Y,app.Size.Width,app.Size.Height,false);
                var primary=DisplayArea.GetFromWindowId(app.Id,DisplayAreaFallback.Primary).WorkArea;
                var target=Fit(old,Choose(old,CurrentAreas(primary),primary));
                if(target!=old)app.MoveAndResize(new(target.X,target.Y,target.Width,target.Height));
            }catch(Exception e){PlaybackTransport.Write("Warning","Window.Placement","显示器变化后窗口位置恢复未完成；"+e.GetType().Name);}});
        }
    }
}
