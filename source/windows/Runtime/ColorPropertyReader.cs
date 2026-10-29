using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using Microsoft.UI.Dispatching;
using Richasy.MpvKernel;
using Richasy.MpvKernel.Core;

namespace Yingyu.Update;

// Asynchronous reads only: no synchronous MPV queries on the UI thread.
internal static class ColorPropertyReader
{
    internal readonly record struct Result(int Status,string Value);
    sealed class State { internal readonly object Gate=new();internal readonly Dictionary<ulong,TaskCompletionSource<Result>> Pending=new(); }
    static readonly ConditionalWeakTable<MpvClient,State> States=new();
    const ulong OwnerPrefix=0x5959434400000000ul;
    static long next;
    internal static async Task<Dictionary<string,Result>> Read(MpvClient client,DispatcherQueue? dispatcher,IEnumerable<string> properties,Func<bool> current)
    {
        var state=States.GetValue(client,_=>new());
        var requests=properties.Distinct(StringComparer.Ordinal).ToDictionary(p=>p,p=>(Id:OwnerPrefix|((ulong)Interlocked.Increment(ref next)&uint.MaxValue),Done:new TaskCompletionSource<Result>(TaskCreationOptions.RunContinuationsAsynchronously)));
        bool retired=false;
        void Fail(int status){foreach(var r in requests.Values)r.Done.TrySetResult(new(status,""));}
        if(dispatcher is null||!dispatcher.TryEnqueue(()=>
        {
            try
            {
                if(!current()||client.IsDisposed){Fail(-10);return;}
                lock(state.Gate)
                {
                    if(retired){Fail(-10);return;}
                    if(state.Pending.Count+requests.Count>256){Fail(-10002);return;}
                    foreach(var pair in requests)
                    {
                        state.Pending.Add(pair.Value.Id,pair.Value.Done);
                        int result=(int)MpvNative.GetPropertyAsync(client.Handle,pair.Value.Id,pair.Key,MpvFormat.String);
                        if(result<0){state.Pending.Remove(pair.Value.Id);pair.Value.Done.TrySetResult(new(result,""));}
                    }
                }
            }
            catch(Exception){Fail(-10002);}
        }))Fail(-10);
        try
        {
            try{await Task.WhenAll(requests.Values.Select(r=>r.Done.Task)).WaitAsync(TimeSpan.FromSeconds(3)).ConfigureAwait(false);}
            catch(TimeoutException){Fail(-10001);}
            return requests.ToDictionary(p=>p.Key,p=>p.Value.Done.Task.Result);
        }
        finally{lock(state.Gate){retired=true;foreach(var r in requests.Values)state.Pending.Remove(r.Id);}}
    }
    static bool OwnsReply(MpvEvent value)=>value.EventId==MpvEventId.GetPropertyReply&&(value.UserData&0xFFFFFFFF00000000ul)==OwnerPrefix;
    internal static bool Notify(MpvClient client,MpvEvent value)
    {
        bool owned=OwnsReply(value);
        // Ownership is independent of Pending: expired/late diagnostic replies
        // must never leak into the host's generic playback-error dispatcher.
        if(!States.TryGetValue(client,out var state))return owned;
        if(value.EventId is MpvEventId.StartFile or MpvEventId.EndFile or MpvEventId.Shutdown or MpvEventId.QueueOverflow)
        {lock(state.Gate){foreach(var p in state.Pending.Values)p.TrySetResult(new(-10,""));state.Pending.Clear();}return false;}
        if(!owned)return false;
        CompleteReply(state,value);
        return true;
    }
    static void CompleteReply(State state,MpvEvent value)
    {
        TaskCompletionSource<Result>? pending;
        lock(state.Gate){if(!state.Pending.Remove(value.UserData,out pending))return;}
        if(value.Error!=MpvError.Success){pending.TrySetResult(new((int)value.Error,""));return;}
        try
        {
            var property=value.GetData<MpvEventProperty>();
            if(property.Format!=MpvFormat.String||property.DataPtr==IntPtr.Zero){pending.TrySetResult(new(-10,""));return;}
            // MPV_FORMAT_STRING data points to a char* variable. Copy before
            // wait_event releases the event; never retain or free its memory.
            var pointer=Marshal.ReadIntPtr(property.DataPtr);
            if(pointer==IntPtr.Zero){pending.TrySetResult(new(0,""));return;}
            int length=0;while(length<8192&&Marshal.ReadByte(pointer,length)!=0)length++;
            pending.TrySetResult(length>=8192?new(-10003,""):new(0,Marshal.PtrToStringUTF8(pointer,length)??""));
        }
        catch(Exception){pending.TrySetResult(new(-10002,""));}
    }
}
