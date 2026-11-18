using System.Globalization;
using System.Reflection;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Text;
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
        internal readonly TaskCompletionSource<string?> Completion=new(TaskCreationOptions.RunContinuationsAsynchronously);
    }
    sealed class State
    {
        internal readonly object Sync=new();
        internal readonly Dictionary<ulong,Pending> Pending=new();
        internal int Busy,Revision;
        internal volatile bool Closed;
    }
    internal static async Task Apply(object session,double brightness,double shadows)
    {
        if(!double.IsFinite(brightness)||brightness is < 0 or > 15
            ||!double.IsFinite(shadows)||shadows is < 0 or > 75)throw new InvalidOperationException("画面明暗选项无效。");
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
            string gamma = await Read("gamma").ConfigureAwait(false);
            string before = await Read("options/glsl-shaders").ConfigureAwait(false);
            string cache = Path.Combine(CachePaths.Shaders,"picture-shadow");
            string otherShaders = string.Join(';',before.Split(';',StringSplitOptions.RemoveEmptyEntries)
                .Where(path => !path.StartsWith(cache + Path.DirectorySeparatorChar,StringComparison.OrdinalIgnoreCase)));
            string desired = otherShaders;
            if(shadows>0)
            {
                string transfer = await Read("video-target-params/gamma").ConfigureAwait(false);
                if(transfer.Length==0)
                {
                    string renderer = await Read("current-vo").ConfigureAwait(false);
                    if(renderer=="gpu") transfer = await Read("options/target-trc").ConfigureAwait(false);
                }
                string path = await StoreShadow(cache,transfer,shadows).ConfigureAwait(false);
                desired = otherShaders.Length==0 ? path : otherShaders+";"+path;
            }
            var writes = new List<(string Name,string Property,string Before,string Value)>();
            if(!NumbersMatch(gamma,brightness))
                writes.Add(("gamma","gamma",gamma,brightness.ToString(CultureInfo.InvariantCulture)));
            if(before!=desired)
                writes.Add(("glsl-shaders","options/glsl-shaders",before,desired));
            var applied = new List<(string Name,string Property,string Before,string Value)>();
            try
            {
                foreach(var write in writes)
                {
                    await Write(write.Name,write.Value,"set-ack").ConfigureAwait(false);
                    applied.Add(write);
                    string value=await Read(write.Property).ConfigureAwait(false);
                    if(write.Name=="gamma" ? !NumbersMatch(value,brightness) : value!=write.Value)
                        throw new InvalidOperationException("播放器未确认画面明暗设置。");
                }
                if(writes.Count>0)PlaybackFeatureLog.Write(session,"picture-write","readback-confirmed",brightness);
            }
            catch
            {
                if(Current())
                    foreach(var write in applied.AsEnumerable().Reverse())
                    {
                        await Write(write.Name,write.Before,"restore-ack").ConfigureAwait(false);
                        string value=await Read(write.Property).ConfigureAwait(false);
                        if(write.Name=="gamma" ? !double.TryParse(write.Before,NumberStyles.Float,
                            CultureInfo.InvariantCulture,out double previousGamma)||!NumbersMatch(value,previousGamma)
                            : value!=write.Before)
                            throw new InvalidOperationException("画面设置恢复未被确认，请退出本次播放后重试。");
                    }
                throw;
            }
        }
        finally{Interlocked.Exchange(ref state.Busy,0);PlaybackFeatureLog.Write(session,"picture-transaction","finished",Environment.TickCount64-began);}

        async Task<string> Read(string name)
            => (await Send(MpvEventId.GetPropertyReply,id=>MpvNative.GetPropertyAsync(client.Handle,id,name,MpvFormat.String),
                "read").ConfigureAwait(false)) ?? "";

        Task<string?> Write(string name,string value,string phase)
            => Send(MpvEventId.CommandReply,id=>MpvNative.SetCommandAsync(client.Handle,id,
                ["set","file-local-options/"+name,value,null!]),phase);

        async Task<string?> Send(MpvEventId kind,Func<ulong,MpvError> submit,string phase)
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
            try{return await pending.Completion.Task.WaitAsync(TimeSpan.FromSeconds(3)).ConfigureAwait(false);}
            catch(TimeoutException)
            {
                lock(state.Sync) state.Pending.Remove(id);
                throw new InvalidOperationException("画面调整未在等待时间内得到播放器确认。");
            }
            finally{PlaybackFeatureLog.Write(session,"picture-"+phase,"settled",Environment.TickCount64-started);}
        }
    }
    static bool NumbersMatch(string value,double target)
        => double.TryParse(value,NumberStyles.Float,CultureInfo.InvariantCulture,out var actual)
            && double.IsFinite(actual) && Math.Abs(actual-target)<.0001;

    internal static string ShadowShader(string transfer,double shadows)
    {
        var (decode,encode,limit) = transfer switch
        {
            "bt.1886" or "gamma2.4" => ("pow(v,2.4)","pow(v,1.0/2.4)","0.18"),
            "gamma2.2" or "bt.709" => ("pow(v,2.2)","pow(v,1.0/2.2)","0.18"),
            "srgb" => ("v<=0.04045?v/12.92:pow((v+0.055)/1.055,2.4)",
                "v<=0.0031308?12.92*v:1.055*pow(v,1.0/2.4)-0.055","0.18"),
            "pq" or "smpte2084" => ("pow(max(pow(v,1.0/(2523.0/32.0))-3424.0/4096.0,0.0)/max(2413.0/128.0-2392.0/128.0*pow(v,1.0/(2523.0/32.0)),0.000001),1.0/(2610.0/16384.0))",
                "pow((3424.0/4096.0+2413.0/128.0*pow(v,2610.0/16384.0))/(1.0+2392.0/128.0*pow(v,2610.0/16384.0)),2523.0/32.0)","0.0064"),
            "hlg" or "arib-std-b67" => ("v<=0.5?v*v/3.0:(exp((v-0.55991073)/0.17883277)+0.28466892)/12.0",
                "v<=1.0/12.0?sqrt(3.0*v):0.17883277*log(12.0*v-0.28466892)+0.55991073","(1.0/12.0)"),
            "scrgb" => ("v","v","0.8"),
            _ => throw new InvalidOperationException("当前画面输出的传递曲线未确认，无法调整暗部。")
        };
        var gain = (shadows*.032).ToString("0.0000",CultureInfo.InvariantCulture);
        return $$"""
            //!HOOK OUTPUT
            //!BIND HOOKED
            //!DESC Yingyu live shadow enhancement
            float shadow_decode(float v) { return {{decode}}; }
            float shadow_encode(float v) { return {{encode}}; }
            vec4 hook() {
                vec4 original=HOOKED_tex(HOOKED_pos);
                float peak=max(original.r,max(original.g,original.b));
                if(original.a<0.999 || min(original.r,min(original.g,original.b))<0.0 ||
                   peak<=0.0 || peak>=shadow_encode({{limit}})) return original;
                vec3 light=vec3(shadow_decode(original.r),shadow_decode(original.g),shadow_decode(original.b));
                float weight=1.0-max(light.r,max(light.g,light.b))/{{limit}};
                light*=1.0+{{gain}}*weight*weight;
                return vec4(shadow_encode(light.r),shadow_encode(light.g),shadow_encode(light.b),original.a);
            }
            """;
    }

    static async Task<string> StoreShadow(string cache,string transfer,double shadows)
    {
        var body = ShadowShader(transfer,shadows);
        Directory.CreateDirectory(cache);
        var id = Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(Encoding.UTF8.GetBytes(body)));
        var path = Path.Combine(cache,id+".hook");
        if(!File.Exists(path))
        {
            var temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
            try
            {
                await File.WriteAllTextAsync(temporary,body).ConfigureAwait(false);
                File.Move(temporary,path,true);
            }
            finally { if(File.Exists(temporary))File.Delete(temporary); }
        }
        return path;
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
            if(property.Format!=MpvFormat.String||property.DataPtr==IntPtr.Zero)
            { pending.Completion.TrySetException(new InvalidOperationException("画面明暗回读类型无效。"));return; }
            var pointer=Marshal.ReadIntPtr(property.DataPtr);
            pending.Completion.TrySetResult(pointer==IntPtr.Zero?"":Marshal.PtrToStringUTF8(pointer));
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
