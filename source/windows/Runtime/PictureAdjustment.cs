using System.Globalization;
using System.Reflection;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using Microsoft.UI.Dispatching;
using Richasy.MpvKernel;
using Richasy.MpvKernel.Core;

namespace Yingyu.Update;

// Only the explicit gamma menu uses this queue. Native requests are submitted
// on the session dispatcher; completion is read from the existing event pump.
// No synchronous MPV getter/setter or product worker is used here.
internal static class PictureAdjustment
{
    static readonly ConditionalWeakTable<MpvClient,State> States=new();
    static long next;
    sealed class Pending(MpvEventId kind)
    {
        internal readonly MpvEventId Kind=kind;
        internal readonly TaskCompletionSource<double?> Completion=new(TaskCreationOptions.RunContinuationsAsynchronously);
    }
    sealed class State
    {
        internal readonly object Sync=new();
        internal readonly Dictionary<ulong,Pending> Pending=new();
        internal int Busy,Revision;
        internal volatile bool Closed;
    }
    internal static async Task Apply(object session,double target)
    {
        if(target is not (0 or 5 or 10 or 15))throw new InvalidOperationException("画面明暗选项无效。");
        var client=Access.Get<MpvClient>(session,"_mpvClient");
        var dispatcher=Access.Get<DispatcherQueue>(session,"_dispatcher");
        int generation=Access.Get<int>(session,"_mediaGeneration");
        var state=States.GetValue(client,_=>new());int revision=Volatile.Read(ref state.Revision);
        bool Current()=>!state.Closed&&!client.IsDisposed&&revision==Volatile.Read(ref state.Revision)
            &&generation==Access.Get<int>(session,"_mediaGeneration")&&ReferenceEquals(client,Access.Get<MpvClient?>(session,"_mpvClient"))
            &&session.GetType().GetProperty("_isClosing",BindingFlags.Instance|BindingFlags.Public|BindingFlags.NonPublic)?.GetValue(session) is not true;
        if(!Current())throw new InvalidOperationException("播放会话已变化，请重新打开菜单。");
        if(Interlocked.CompareExchange(ref state.Busy,1,0)!=0)throw new InvalidOperationException("画面明暗正在应用，请稍候。");
        long began=Environment.TickCount64;
        try
        {
            double before=await Read("read-before").ConfigureAwait(false);
            if(Math.Abs(before-target)<.0001){PlaybackFeatureLog.Write(session,"picture-write","unchanged",target);return;}
            bool acknowledged=false;
            try
            {
                await Send(MpvEventId.CommandReply,id=>MpvNative.SetCommandAsync(client.Handle,id,["set","file-local-options/gamma",target.ToString(CultureInfo.InvariantCulture)]),"set-ack").ConfigureAwait(false);
                acknowledged=true;
                double actual=await Read("read-after").ConfigureAwait(false);
                if(Math.Abs(actual-target)>.0001)throw new InvalidOperationException("播放器未确认画面明暗设置。");
                PlaybackFeatureLog.Write(session,"set-gamma","readback-confirmed",actual);
            }
            catch
            {
                if(acknowledged&&Current())
                {
                    await Send(MpvEventId.CommandReply,id=>MpvNative.SetCommandAsync(client.Handle,id,["set","file-local-options/gamma",before.ToString(CultureInfo.InvariantCulture)]),"restore-ack").ConfigureAwait(false);
                    double restored=await Read("restore-read").ConfigureAwait(false);
                    if(Math.Abs(restored-before)>.0001)throw new InvalidOperationException("画面设置恢复未被确认，请退出本次播放后重试。");
                }
                throw;
            }
        }
        finally{Interlocked.Exchange(ref state.Busy,0);PlaybackFeatureLog.Write(session,"picture-transaction","finished",Environment.TickCount64-began);}

        async Task<double> Read(string phase)
        {
            var value=await Send(MpvEventId.GetPropertyReply,id=>MpvNative.GetPropertyAsync(client.Handle,id,"gamma",MpvFormat.Double),phase).ConfigureAwait(false);
            if(value is not {} number||!double.IsFinite(number))throw new InvalidOperationException("画面明暗回读无效。");
            return number;
        }
        async Task<double?> Send(MpvEventId kind,Func<ulong,MpvError> submit,string phase)
        {
            var pending=new Pending(kind);ulong id=0x5959504900000000ul|((ulong)Interlocked.Increment(ref next)&uint.MaxValue);
            long started=Environment.TickCount64;
            if(!dispatcher.TryEnqueue(()=>{
                if(!Current()){pending.Completion.TrySetException(new InvalidOperationException("播放会话已变化，旧画面调整已停止。"));return;}
                lock(state.Sync)
                {
                    if(!Current()){pending.Completion.TrySetException(new InvalidOperationException("播放会话已变化，旧画面调整已停止。"));return;}
                    state.Pending.Add(id,pending);
                    try{var result=submit(id);if(result!=MpvError.Success){state.Pending.Remove(id);pending.Completion.TrySetException(new InvalidOperationException("播放器未接受画面明暗请求。"));}}
                    catch(Exception error){state.Pending.Remove(id);pending.Completion.TrySetException(error);}
                }
            }))throw new InvalidOperationException("播放器界面已退出，未发送画面设置。");
            try{return await pending.Completion.Task.ConfigureAwait(false);}
            finally{PlaybackFeatureLog.Write(session,"picture-"+phase,"settled",Environment.TickCount64-started);}
        }
    }
    internal static void Notify(MpvClient client,MpvEvent value)
    {
        if(!States.TryGetValue(client,out var state))return;
        if(value.EventId is MpvEventId.StartFile or MpvEventId.EndFile or MpvEventId.Shutdown or MpvEventId.QueueOverflow){Cancel(client,value.EventId==MpvEventId.Shutdown);return;}
        Pending? pending;
        lock(state.Sync){if(!state.Pending.TryGetValue(value.UserData,out pending)||pending.Kind!=value.EventId)return;state.Pending.Remove(value.UserData);}
        if(value.Error!=MpvError.Success){pending.Completion.TrySetException(new InvalidOperationException("画面明暗请求执行失败。"));return;}
        if(value.EventId==MpvEventId.GetPropertyReply)
        {
            // Copy before returning: MPV owns the memory until next wait_event.
            if(value.DataPtr==IntPtr.Zero){pending.Completion.TrySetException(new InvalidOperationException("画面明暗回读为空。"));return;}
            var property=value.GetData<MpvEventProperty>();
            if(property.Format!=MpvFormat.Double||property.DataPtr==IntPtr.Zero){pending.Completion.TrySetException(new InvalidOperationException("画面明暗回读类型无效。"));return;}
            pending.Completion.TrySetResult(BitConverter.Int64BitsToDouble(Marshal.ReadInt64(property.DataPtr)));
        }
        else pending.Completion.TrySetResult(null);
    }
    internal static void Cancel(MpvClient client,bool close=true)
    {
        if(!States.TryGetValue(client,out var state))return;
        Pending[] pending;
        lock(state.Sync){if(close)state.Closed=true;Interlocked.Increment(ref state.Revision);pending=state.Pending.Values.ToArray();state.Pending.Clear();}
        foreach(var item in pending)item.Completion.TrySetException(new InvalidOperationException("播放会话已结束或变化，旧画面调整已停止。"));
    }
}
