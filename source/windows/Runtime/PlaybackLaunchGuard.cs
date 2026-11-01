using System.Reflection;
using System.Runtime.CompilerServices;
using System.Diagnostics;
namespace Yingyu.Update;

// Admission only. The original semaphore, request cancellation and finally cleanup remain authoritative.
public static class PlaybackLaunchGuard
{
    sealed class State{internal object? Account;internal long Accepted;}
    static readonly ConditionalWeakTable<object,State> States=new();
    public static Task<bool>? Repeated(object page,bool waitForTurn){
        if(waitForTurn)return null;
        const BindingFlags flags=BindingFlags.Instance|BindingFlags.Public|BindingFlags.NonPublic;
        object? Field(object obj,string name)=>obj.GetType().GetField(name,flags)?.GetValue(obj);
        if(Field(page,"_playbackStartGate") is SemaphoreSlim{CurrentCount:0})return Task.FromResult(false);
        var player=Field(page,"_playbackSession");
        if(player!=null){
            bool Disposed(object? value)=>value?.GetType().GetProperty("IsDisposed",flags)?.GetValue(value) is true;
            // A disposed old player must not permanently block a later launch.
            var window=Field(player,"_window");var client=Field(player,"_mpvClient");
            bool closing=Field(player,"_isClosing") is true||player.GetType().GetProperty("_isClosing",flags)?.GetValue(player) is true;
            bool fullyClosed=closing&&window==null&&client==null;
            if(!Disposed(window)&&!Disposed(client)&&!fullyClosed)return Task.FromResult(false);
        }
        var state=States.GetValue(page,_=>new());var account=Field(page,"_session");long now=Stopwatch.GetTimestamp();
        lock(state){
            if(!ReferenceEquals(state.Account,account)){state.Account=account;state.Accepted=0;}
            if(state.Accepted!=0&&Stopwatch.GetElapsedTime(state.Accepted,now)<TimeSpan.FromMilliseconds(600))return Task.FromResult(false);
            state.Accepted=now;
        }
        return null;
    }
}
