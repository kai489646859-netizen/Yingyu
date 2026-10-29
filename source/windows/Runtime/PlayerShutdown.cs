using Microsoft.UI.Dispatching;
using System.Runtime.CompilerServices;
using Microsoft.UI.Xaml.Hosting;
using Microsoft.UI.Windowing;
using Richasy.MpvKernel.Core;

namespace Yingyu.Update;

// Wrap the original cleanup delegate; keep its lifecycle once gate, progress
// report, network/disc cleanup and original asynchronous body unchanged.
public static class PlayerShutdown
{
    static int next;
    static readonly ConditionalWeakTable<object,Identity> Identities=new();
    sealed class Identity{internal readonly int Id=Interlocked.Increment(ref next);}
    public static Func<Task> Dispatch(Func<Task> cleanup,object session)
        =>()=>Run(session,async()=>{
            NativeDolby.BeginClose(session);
            // The old DisposeCore prefix synchronously releases cache readers.
            // Cancel/release them off the UI first; its preserved call is then
            // idempotent and cannot wait behind a current network read.
            LogStage(session,"cache-release-entered");
            await Task.Run(()=>VideoCache.Stop(session));
            LogStage(session,"cache-release-completed");
            await cleanup();
        },"dispose");

    public static Task Close(object session,bool destroyWindow)
        =>Run(session,()=> (Task)Access.Call(session,"CloseAsync",destroyWindow)!,"eof-close");

    // Keep both the host HWND and XAML message pump alive until the core has
    // stopped presenting and destroyed its child HWNDs. Destroying the host
    // first can synchronously enter those children during VO teardown.
    public static ValueTask DisposeWindow(object window,object session)
        =>new(Run(session,async()=>{
            Access.Get<Microsoft.UI.Dispatching.DispatcherQueueTimer?>(window,"_autoCheckTimer")?.Stop();
            await ReleaseCore(session);
            LogStage(session,"window-release-entered");
            await (ValueTask)Access.Call(window,"DisposeAsync")!;
            LogStage(session,"window-release-completed");
        },"window"));
    async static Task ReleaseCore(object session)
    {
        NativeDolby.BeginClose(session);
        var client=Access.Get<MpvClient?>(session,"_mpvClient");
        if(client is null)return;
        LogStage(session,"core-release-entered");
        Task release=client.DisposeAsync().AsTask();
        await Observe(release,session,"core-release");
        LogStage(session,"core-release-completed");
    }
    static async Task Observe(Task pending,object session,string phase)
    {
        if(await Task.WhenAny(pending,Task.Delay(8000)).ConfigureAwait(false)!=pending)
            LogStage(session,phase+"-still-pending");
        await pending.ConfigureAwait(false); // A deadline is diagnostic, never permission to free live HWNDs.
    }
    public static void DisposeXaml(DesktopWindowXamlSource source)
    {
        Trace("xaml-release-entered");source.Dispose();Trace("xaml-release-completed");
    }
    public static void DestroyHost(AppWindow window)
    {
        Trace("host-destroy-entered");window.Destroy();Trace("host-destroy-completed");
    }
    static void Trace(string stage)=>PlaybackTransport.Write("Info","Playback.Shutdown",$"版本=0.5.8; stage={stage}。");
    static void LogStage(object session,string stage)=>PlaybackTransport.Write("Info","Playback.Shutdown",$"版本=0.5.8; session={Identities.GetValue(session,_=>new()).Id}; stage={stage}。");

    static Task Run(object session,Func<Task> action,string phase)
    {
        var dispatcher=Access.Get<DispatcherQueue>(session,"_dispatcher");
        int id=Identities.GetValue(session,_=>new()).Id;
        void Log(string stage)=>PlaybackTransport.Write("Info","Playback.Shutdown",$"版本=0.5.8; session={id}; phase={phase}; stage={stage}; uiThread={dispatcher.HasThreadAccess}。");
        Log("requested");
        PlaybackFeatureLog.Write(session,"player-close",phase+"-requested");
        if(dispatcher.HasThreadAccess)return Complete();
        var completion=new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        if(!dispatcher.TryEnqueue(async()=>{
            try{await Complete();completion.TrySetResult();}
            catch(Exception error){completion.TrySetException(error);}
        }))completion.TrySetException(new InvalidOperationException("播放器界面线程已退出，未在后台线程销毁界面。"));
        return completion.Task;

        async Task Complete()
        {
            try{
                PlaybackFeatureLog.Write(session,"player-close",phase+"-ui-entered");
                Log("ui-entered");
                Task pending;
                var prior=SynchronizationContext.Current;
                try{
                    // XAML islands do not guarantee an ambient UI context.
                    // Scope a context to this invocation and its continuations.
                    SynchronizationContext.SetSynchronizationContext(new QueueContext(dispatcher));
                    pending=action();
                }finally{SynchronizationContext.SetSynchronizationContext(prior);}
                await Observe(pending,session,phase);
                PlaybackFeatureLog.Write(session,"player-close",phase+"-completed");
                Log("completed");
            }catch(Exception error){
                PlaybackTransport.Write("Warning","Playback.Shutdown",$"阶段={phase}; type={error.GetType().Name}; HRESULT=0x{error.HResult:X8}。");throw;
            }
        }
    }
    sealed class QueueContext(DispatcherQueue dispatcher):SynchronizationContext
    {
        public override SynchronizationContext CreateCopy()=>new QueueContext(dispatcher);
        public override void Post(SendOrPostCallback callback,object? state)
        {
            if(!dispatcher.TryEnqueue(()=>{
                var prior=Current;
                try{SetSynchronizationContext(this);callback(state);}
                finally{SetSynchronizationContext(prior);}
            }))throw new InvalidOperationException("播放器界面队列已退出，清理回调未能执行。");
        }
        public override void Send(SendOrPostCallback callback,object? state)
        {
            if(!dispatcher.HasThreadAccess)throw new NotSupportedException("关闭流程不允许同步等待界面线程。");
            callback(state);
        }
    }
}
