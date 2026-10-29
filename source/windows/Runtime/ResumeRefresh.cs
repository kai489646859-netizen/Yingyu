using System.Reflection;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Yingyu.Update;

// Same read-side lifecycle as Android HomeDashboard: entry, foreground return,
// and a bounded foreground refresh. Reuse the existing authenticated reader.
public static class ResumeRefresh
{
    static readonly ConditionalWeakTable<FrameworkElement,State> States=new();
    public static void Home(object page)
    {
        if(page is FrameworkElement element)States.GetValue(element,e=>new State(e)).Start();
    }
    sealed class State
    {
        const BindingFlags Flags=BindingFlags.Instance|BindingFlags.Public|BindingFlags.NonPublic;
        readonly FrameworkElement page;
        readonly Microsoft.UI.Dispatching.DispatcherQueueTimer timer;
        object? session,client;
        bool running,wasVisible,force,reported;
        DateTimeOffset attempted=DateTimeOffset.MinValue;
        [DllImport("user32.dll")]static extern IntPtr GetForegroundWindow();
        internal State(FrameworkElement page)
        {
            this.page=page;timer=page.DispatcherQueue.CreateTimer();timer.Interval=TimeSpan.FromSeconds(2);
            timer.Tick+=(_,_)=>Check();page.Loaded+=(_,_)=>Start();page.Unloaded+=(_,_)=>{timer.Stop();wasVisible=false;};
        }
        bool Foreground()=>page.XamlRoot is {} root&&GetForegroundWindow()==Microsoft.UI.Win32Interop.GetWindowFromWindowId(root.ContentIslandEnvironment.AppWindowId);
        bool Flag(string name)=>page.GetType().GetField(name,Flags)?.GetValue(page) is true;
        bool Visible()=>page.IsLoaded&&Access.Get<string?>(page,"_activeSnapshotKey")=="home"
            &&Access.Get<Grid>(page,"LibraryView").Visibility==Visibility.Visible
            &&Access.Get<Grid>(page,"SettingsView").Visibility!=Visibility.Visible
            &&page.GetType().GetProperty("IsPlaybackActive",Flags)?.GetValue(page) is not true
            &&!Flag("_profileSwitchInProgress")&&!Flag("_libraryLoadInProgress")&&!Flag("_authenticationNeedsAttention");
        internal void Start(){if(page.IsLoaded){timer.Start();Check();}}
        void Check(){try{Pulse(Foreground());}catch(Exception e){timer.Stop();if(!reported){reported=true;PlaybackTransport.Write("Warning","Library.Resume","窗口状态核对暂不可用，保留继续观看与原界面；"+e.GetType().Name);}}}
        internal void Pulse(bool foreground)
        {
            var currentSession=Access.Get<object?>(page,"_session");var currentClient=Access.Get<object?>(page,"_client");
            if(!ReferenceEquals(session,currentSession)||!ReferenceEquals(client,currentClient)){session=currentSession;client=currentClient;force=true;attempted=DateTimeOffset.MinValue;}
            bool visible=foreground&&Visible()&&session!=null&&client!=null;
            if(visible&&!wasVisible)force=true;wasVisible=visible;
            if(!visible||running||Flag("_resumeRefreshInProgress"))return;
            var now=DateTimeOffset.UtcNow;
            if(now-attempted<TimeSpan.FromSeconds(15))return;
            if(!force&&now-Access.Get<DateTimeOffset>(page,"_lastResumeRefreshAt")<TimeSpan.FromMinutes(1))return;
            if(now<Access.Get<DateTimeOffset>(page,"_playbackControlPlaneRecoveryUntil"))return;
            bool fresh=force;force=false;attempted=now;running=true;Run(fresh);
        }
        async void Run(bool fresh)
        {
            var expectedSession=Access.Get<object?>(page,"_session");var expectedClient=Access.Get<object?>(page,"_client");
            try{
                await (Task)Access.Call(page,"RefreshResumeItemsAsync",fresh)!;
                if(ReferenceEquals(expectedSession,Access.Get<object?>(page,"_session"))&&ReferenceEquals(expectedClient,Access.Get<object?>(page,"_client"))&&Flag("_playbackSyncRequested"))await ResumeDeviceSync.Drain(page);
            }
            catch(OperationCanceledException){}
            catch(Exception e){PlaybackTransport.Write("Warning","Library.Resume","继续观看自动核对未完成，保留当前内容；"+e.GetType().Name);}
            finally{running=false;}
        }
    }
}
