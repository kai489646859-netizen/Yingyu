using System.Globalization;
using System.Runtime.CompilerServices;
using EmbyDesktop.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Richasy.MpvKernel.Core;

namespace Yingyu.Update;

// File-local output policy; decode, RPU and FEL processing remain unchanged.
internal static class DolbyHdrFallback
{
    static readonly ConditionalWeakTable<object,State> States=new();
    static readonly AsyncLocal<State?> Loading=new();
    static readonly (string Key,string Value)[] Common=[("tone-mapping","bt.2390"),("tone-mapping-param","0.5"),("inverse-tone-mapping","no"),("target-colorspace-hint-strict","yes"),("gamut-mapping-mode","perceptual"),("dscale","mitchell"),("correct-downscaling","yes")];
    // 203 nit is mpv/libplacebo's SDR reference white, not measured display peak.
    // Do not inherit a 1000+ nit HDR display peak when selecting an SDR curve.
    static readonly (string Key,string Value)[] Sdr=[("target-prim","bt.709"),("target-trc","srgb"),("target-peak","203"),("target-colorspace-hint","yes"),("target-colorspace-hint-mode","target"),("hdr-contrast-recovery","0.30")];
    static readonly (string Key,string Value)[] Hdr=[("target-prim","auto"),("target-trc","auto"),("target-colorspace-hint","yes"),("target-colorspace-hint-mode","source")];
    static readonly (string Key,string Value)[] Target=[("target-prim","bt.2020"),("target-trc","pq"),("target-colorspace-hint","yes"),("target-colorspace-hint-mode","source"),("tone-mapping","bt.2390"),("tone-mapping-param","0.5"),("inverse-tone-mapping","no")];
    internal static bool IsFailed(object session)=>States.TryGetValue(session,out var state)&&state.Generation==Access.Get<int>(session,"_mediaGeneration")&&state.Failed;
    internal static string Policy(object session)=>States.TryGetValue(session,out var state)&&state.Generation==Access.Get<int>(session,"_mediaGeneration")?(state.Hdr?"hdr-test":"sdr"):"pending";
    sealed class State(int generation,bool hdr,bool dolby)
    {
        internal readonly int Generation=generation;
        internal readonly bool Hdr=hdr;
        internal bool Dolby=dolby,Failed;
        internal long Last,FirstMismatch;
        internal int Samples;
    }
    static IEnumerable<(string Key,string Value)> Options(State? state)
        =>Common.Concat(state is {Hdr:true,Dolby:true}?Target:state is {Hdr:true}?Hdr:Sdr);
    internal static async Task Play(object session,Func<Task> play)
    {
        var source=Access.Get<MediaSourceInfo>(session,"_source");
        var videos=source.MediaStreams.Where(s=>s.Type=="Video").ToArray();
        string mark=videos.Length==1?((videos[0].VideoRange??"")+" "+(videos[0].VideoRangeType??"")).ToLowerInvariant():"";
        bool dolby=mark.Contains("dolbyvision")||mark.Contains("dolby vision")||mark.Contains("dovi");
        var state=new State(Access.Get<int>(session,"_mediaGeneration"),DesktopTheme.Options.HdrExperimental,dolby);
        States.Remove(session);States.Add(session,state);
        PlaybackFeatureLog.Write(session,"output-policy",state.Hdr?"hdr-test-file-local":"sdr-file-local");
        var previous=Loading.Value;Loading.Value=state;
        try{await play();}finally{Loading.Value=previous;}
    }
    internal static void Append(List<string> options)
    {
        // Missing load context is conservative SDR.
        foreach(var (key,value) in Options(Loading.Value))options.Add(key+"="+value);
    }
    internal static void Observe(object session)
    {
        if(!States.TryGetValue(session,out var state)||state.Generation!=Access.Get<int>(session,"_mediaGeneration")||state.Failed)return;
        NativeDolby.Sample(session);
        var native=NativeDolby.Read(session);
        var client=Access.Get<MpvClient?>(session,"_mpvClient");if(client is null||client.IsDisposed)return;
        if(native.Fatal){Fail(session,state,client,"杜比播放已暂停："+NativeDolby.Why(native.Reason)+"。请导出日志用于修复。");return;}
        long now=Environment.TickCount64;if(now-state.Last<500)return;state.Last=now;
        if(!Access.Get<bool>(session,"_hasStartedPlayback")||!Access.Get<bool>(session,"_acceptPlaybackEvents"))return;
        if(PlaybackTransport.Get(client,"seeking")=="yes"){Reset(state);return;}
        string source=MediaNotice.SourceFormat(session);
        if(state.Hdr&&!state.Dolby&&source.StartsWith("杜比视界",StringComparison.Ordinal))
        {
            foreach(var (key,value) in Target)
                if(PlaybackTransport.Set(client,"file-local-options/"+key,value)<0||!Matches(PlaybackTransport.Get(client,key),value))
                {Fail(session,state,client,"杜比转 HDR10 设置未被确认；已暂停，避免错误色彩输出。");return;}
            state.Dolby=true;Reset(state);
            PlaybackFeatureLog.Write(session,"dolby-route","hdr10-decoded-source-confirmed");return;
        }
        string transfer=PlaybackTransport.Get(client,"video-target-params/gamma").ToLowerInvariant();
        string primaries=PlaybackTransport.Get(client,"video-target-params/primaries").ToLowerInvariant();
        if(transfer.Length==0||primaries.Length==0)return;
        bool isSdr=transfer is "srgb" or "bt.1886" or "bt.709" or "gamma2.2" or "gamma2.4";
        bool pq=(transfer is "pq" or "smpte2084")&&primaries=="bt.2020";
        bool hlg=(transfer is "hlg" or "arib-std-b67")&&primaries=="bt.2020";
        bool needsHdr=state.Dolby||source.StartsWith("HDR",StringComparison.Ordinal)||source.StartsWith("HLG",StringComparison.Ordinal);
        bool confirmed=state.Hdr?(!needsHdr||pq||(!state.Dolby&&hlg)):isSdr&&primaries=="bt.709";
        if(confirmed){Reset(state);return;}
        if(state.FirstMismatch==0)state.FirstMismatch=now;
        if(++state.Samples>=3&&now-state.FirstMismatch>=2000)
            Fail(session,state,client,state.Hdr?"HDR 输出未被确认；已暂停。请检查系统 HDR 状态，或关闭 HDR（测试）后重新播放。":"SDR 色彩输出未被确认；已暂停，避免以错误色彩播放。请导出日志。");
    }
    static void Reset(State state){state.FirstMismatch=0;state.Samples=0;}
    static bool Matches(string actual,string expected)
        =>actual==expected||double.TryParse(actual,NumberStyles.Float,CultureInfo.InvariantCulture,out var a)
            &&double.TryParse(expected,NumberStyles.Float,CultureInfo.InvariantCulture,out var b)&&Math.Abs(a-b)<1e-6;
    static void Fail(object session,State state,MpvClient client,string message)
    {
        state.Failed=true;PlaybackFeatureLog.Write(session,"hdr-route","output-unconfirmed-blocked",null,"OutputNotConfirmed");PlaybackFeatureLog.Output(session,"output-rejected");
        if(Access.Get<object?>(session,"_overlay") is not FrameworkElement overlay)return;
        overlay.DispatcherQueue.TryEnqueue(()=>
        {
            if(!States.TryGetValue(session,out var current)||!ReferenceEquals(current,state)||state.Generation!=Access.Get<int>(session,"_mediaGeneration")||!ReferenceEquals(client,Access.Get<MpvClient?>(session,"_mpvClient"))||client.IsDisposed||!Access.Get<bool>(session,"_acceptPlaybackEvents"))return;
            int result=PlaybackTransport.Set(client,"pause","yes");
            Access.Get<ProgressRing>(overlay,"PlaybackStatusRing").IsActive=false;
            Access.Get<TextBlock>(overlay,"PlaybackStatusText").Text=message+(result<0?" 暂停请求未被接受，请退出播放。":"");
            Access.Get<Border>(overlay,"PlaybackStatusPanel").Visibility=Visibility.Visible;
            PlaybackTransport.Write("Warning","Playback.DolbyVision",message);
        });
    }
}
