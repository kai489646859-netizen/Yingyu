using System.Globalization;
using System.Runtime.CompilerServices;
using System.Text.Json;
using Richasy.MpvKernel;
using Richasy.MpvKernel.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Dispatching;

namespace Yingyu.Update;

// Diagnostics only. Observe callbacks retain no event pointers. MPV reads stay
// on existing playback events; Windows queries run separately without MPV handles.
internal static class ColorDiagnostics
{
    static readonly ConditionalWeakTable<object,State> Sessions=new();
    static readonly ConditionalWeakTable<MpvClient,State> Clients=new();
    static readonly ConditionalWeakTable<MpvClient,object> Observed=new();
    static readonly ConditionalWeakTable<object,State> Windows=new();
    static int Faults;
    static readonly string[] Watched=["video-params/primaries","video-params/gamma","video-params/colorlevels","video-params/pixelformat","video-params/hw-pixelformat","video-target-params/primaries","video-target-params/gamma","video-target-params/colorlevels","video-target-params/pixelformat","vid","fullscreen","gamma","brightness","contrast","saturation","target-trc","target-prim","target-peak","tone-mapping","tone-mapping-param","hdr-reference-white","icc-profile-auto","icc-profile","video-output-levels"];
    sealed class State(int generation,MpvClient client,object session)
    {
        internal readonly int Generation=generation;
        internal readonly MpvClient Client=client;
        internal readonly WeakReference<object> Session=new(session);
        internal DispatcherQueue? Dispatcher;
        internal int DisplayEmitted;
        internal int Dirty=1,Busy,DisplayBusy,Emitted;
        internal long Last,DisplayAt;
        internal string Signature="",Display="displayQuery=pending; systemHdr=unknown";
        internal bool LimitReported;
    }
    internal static void Begin(object session,MpvClient client)
    {
        try{BeginCore(session,client);}
        catch(Exception error){if(Interlocked.Increment(ref Faults)<=3)PlaybackTransport.Write("Warning","Playback.Color","event=registration-failed; type="+error.GetType().Name);}
    }
    static void BeginCore(object session,MpvClient client)
    {
        var state=new State(Access.Get<int>(session,"_mediaGeneration"),client,session);
        if(Access.Get<object?>(session,"_overlay") is FrameworkElement overlay)state.Dispatcher=overlay.DispatcherQueue;
        if(Access.Get<object?>(session,"_window") is {} window){Windows.Remove(window);Windows.Add(window,state);}
        Sessions.Remove(session);Sessions.Add(session,state);Clients.Remove(client);Clients.Add(client,state);
        if(Observed.TryGetValue(client,out _))return;
        int accepted=0;
        for(int i=0;i<Watched.Length;i++)
            if((int)MpvNative.ObserveProperty(client.Handle,0x5949430000000000UL+(ulong)i,Watched[i],MpvFormat.None)>=0)accepted++;
        Observed.Add(client,new());
        PlaybackTransport.Write("Info","Playback.Color",$"版本=0.5.8; event=observation-registration; accepted={accepted}; requested={Watched.Length}; valuesCopied=false");
    }
    internal static void Property(MpvClient client,MpvEventProperty property)
    {
        if(Watched.Contains(property.Name,StringComparer.Ordinal)&&Clients.TryGetValue(client,out var state))Interlocked.Exchange(ref state.Dirty,1);
    }
    internal static void WindowChanged(object window)
    {
        try
        {
            if(!Windows.TryGetValue(window,out var state)||state.Client.IsDisposed)return;
            Interlocked.Exchange(ref state.Dirty,1);
            if(Environment.TickCount64-state.DisplayAt>=2000)QueueDisplay(state,window);
        }
        catch(Exception error){if(Interlocked.Increment(ref Faults)<=3)PlaybackTransport.Write("Warning","Playback.Color","event=window-snapshot-failed; type="+error.GetType().Name);}
    }
    static void QueueDisplay(State state,object? window)
    {
        var hwnd=window?.GetType().GetProperty("Handle")?.GetValue(window) is IntPtr h?h:IntPtr.Zero;
        if(Interlocked.CompareExchange(ref state.DisplayBusy,1,0)!=0)return;
        state.DisplayAt=Environment.TickCount64;
        _=Task.Run(()=>
        {
            try
            {
                string display=WindowsColorDiagnostics.Read(hwnd);
                if(display==Volatile.Read(ref state.Display))return;
                Volatile.Write(ref state.Display,display);Interlocked.Exchange(ref state.Dirty,1);
                state.Dispatcher?.TryEnqueue(()=>
                {
                    if(state.Session.TryGetTarget(out var session)&&Sessions.TryGetValue(session,out var current)&&ReferenceEquals(current,state)
                        &&state.Generation==Access.Get<int>(session,"_mediaGeneration")&&!state.Client.IsDisposed&&!NativeDolby.IsClosing(session)&&state.DisplayEmitted++<32)
                        PlaybackFeatureLog.Display(session,display);
                });
            }
            catch(Exception error){Volatile.Write(ref state.Display,"displayQuery=worker-failed-"+error.GetType().Name+"; systemHdr=unknown");Interlocked.Exchange(ref state.Dirty,1);}
            finally{Interlocked.Exchange(ref state.DisplayBusy,0);}
        });
    }
    static readonly string[] ReadProperties=BuildProperties();
    static string[] BuildProperties()
    {
        var properties=new List<string>(Watched);
        foreach(string path in new[]{"video-dec-params","video-params","video-target-params"})
            foreach(string key in new[]{"pixelformat","hw-pixelformat","colormatrix","primaries","gamma","colorlevels","min-luma","max-luma"})properties.Add(path+"/"+key);
        properties.AddRange(new[]{"video-params/max-cll","video-params/max-fall","video-params/max-pq-y","video-params/avg-pq-y","display-fps","estimated-vf-fps","hdr-compute-peak","hdr-peak-decay-rate","tone-mapping-max-boost","hdr-contrast-recovery","sub-hdr-peak","current-tracks/video/dolby-vision-profile","current-vo","current-gpu-context","hwdec-current","target-colorspace-hint","target-colorspace-hint-mode","target-colorspace-hint-strict","inverse-tone-mapping","gamut-mapping-mode","sdr-adjust-gamma","treat-srgb-as-power22","target-contrast","target-lut","image-lut","lut","vf","glsl-shaders","seeking"});
        properties.AddRange(new[]{"scale","dscale","cscale","correct-downscaling","sigmoid-upscaling","dither-depth","video-params/w","video-params/h","video-target-params/w","video-target-params/h"});
        return properties.Distinct(StringComparer.Ordinal).ToArray();
    }
    internal static void Capture(object session,string trigger)
    {
        if(!Sessions.TryGetValue(session,out var state)||state.Generation!=Access.Get<int>(session,"_mediaGeneration")
            ||!ReferenceEquals(state.Client,Access.Get<MpvClient?>(session,"_mpvClient"))||state.Client.IsDisposed||NativeDolby.IsClosing(session)
            ||!Access.Get<bool>(session,"_acceptPlaybackEvents")||!Access.Get<bool>(session,"_hasStartedPlayback"))return;
        long now=Environment.TickCount64;
        if(now-state.Last<2000||Interlocked.CompareExchange(ref state.Busy,1,0)!=0)return;
        state.Last=now;
        try
        {
            if(now-state.DisplayAt>=15000)
            {
                var window=Access.Get<object?>(session,"_window");
                if(window is not null){Windows.Remove(window);Windows.Add(window,state);}
                QueueDisplay(state,window);
            }
            if(Interlocked.Exchange(ref state.Dirty,0)==0&&trigger=="property-change"){Interlocked.Exchange(ref state.Busy,0);return;}
            _=CaptureAsync(session,state,trigger);
        }
        catch(Exception error){Interlocked.Exchange(ref state.Busy,0);if(Interlocked.Increment(ref Faults)<=3)PlaybackTransport.Write("Warning","Playback.Color","event=capture-queue-failed; type="+error.GetType().Name);}
    }
    static async Task CaptureAsync(object session,State state,string trigger)
    {
        long began=Environment.TickCount64;
        try
        {
            bool Current()=>Sessions.TryGetValue(session,out var current)&&ReferenceEquals(current,state)&&state.Generation==Access.Get<int>(session,"_mediaGeneration")&&ReferenceEquals(state.Client,Access.Get<MpvClient?>(session,"_mpvClient"))&&!state.Client.IsDisposed&&!NativeDolby.IsClosing(session)&&Access.Get<bool>(session,"_acceptPlaybackEvents")&&Access.Get<bool>(session,"_hasStartedPlayback");
            var readings=await ColorPropertyReader.Read(state.Client,state.Dispatcher,ReadProperties,Current).ConfigureAwait(false);
            if(!Current())return;
            ColorPropertyReader.Result Get(string property)=>readings.TryGetValue(property,out var result)?result:new(-8,"");
            if(Get("seeking").Value=="yes"){Interlocked.Exchange(ref state.Dirty,1);return;}
                var fields=new List<string>();var missing=new List<string>();var values=new Dictionary<string,string>();
                string Read(string key,string property,bool numeric=false)
                {
                    var result=Get(property);
                    string value=result.Status<0?"unknown":numeric?Number(result.Value):Token(result.Value);
                    if(value=="unknown")missing.Add(key+":"+(result.Status==-10001?"diagnostic-timeout":result.Status==-10002?"diagnostic-read-rejected":result.Status==-10003?"diagnostic-string-limit":result.Status==-8?"not-found":result.Status==-10?"unavailable":result.Status<0?"error"+result.Status.ToString(CultureInfo.InvariantCulture):"unreported-or-invalid"));
                    fields.Add(key+"="+value);values[key]=value;return value;
                }
                void Format(string prefix,string path)
                {
                    Read(prefix+"Pixel",path+"/pixelformat");Read(prefix+"HwPixel",path+"/hw-pixelformat");Read(prefix+"Matrix",path+"/colormatrix");
                    Read(prefix+"Primaries",path+"/primaries");Read(prefix+"Transfer",path+"/gamma");Read(prefix+"Levels",path+"/colorlevels");
                }
                Format("decoded","video-dec-params");Format("source","video-params");Format("output","video-target-params");
                foreach(var (key,prop) in new (string,string)[]{("sourceMin","min-luma"),("sourceMax","max-luma"),("sourceMaxCLL","max-cll"),("sourceMaxFALL","max-fall")})Read(key,"video-params/"+prop,true);
                Read("targetMin","video-target-params/min-luma",true);Read("targetMax","video-target-params/max-luma",true);
                Read("metadataSceneMaxPQ","video-params/max-pq-y",true);Read("metadataSceneAvgPQ","video-params/avg-pq-y",true);
                Read("displayFps","display-fps",true);Read("videoFps","estimated-vf-fps",true);
                foreach(string key in new[]{"scale","dscale","cscale","correct-downscaling","sigmoid-upscaling","dither-depth"})Read(key,key);
                foreach(var (key,property) in new (string,string)[]{("sourceWidth","video-params/w"),("sourceHeight","video-params/h"),("outputWidth","video-target-params/w"),("outputHeight","video-target-params/h")})Read(key,property,true);
                foreach(string key in new[]{"hdr-compute-peak","hdr-peak-decay-rate","tone-mapping-max-boost","hdr-contrast-recovery","sub-hdr-peak"})Read(key,key);
                foreach(var (key,prop) in new (string,string)[]{("profile","current-tracks/video/dolby-vision-profile"),("vo","current-vo"),("gpuContext","current-gpu-context"),("hwdec","hwdec-current"),("targetTrc","target-trc"),("targetPrim","target-prim"),("targetPeak","target-peak"),("hint","target-colorspace-hint"),("hintMode","target-colorspace-hint-mode"),("strict","target-colorspace-hint-strict"),("toneMapping","tone-mapping"),("knee","tone-mapping-param"),("inverse","inverse-tone-mapping"),("gamutMapping","gamut-mapping-mode"),("referenceWhiteRequest","hdr-reference-white"),("sdrAdjustGamma","sdr-adjust-gamma"),("srgbInterpretation","treat-srgb-as-power22"),("rangeRequest","video-output-levels"),("targetContrast","target-contrast"),("iccAutoRequest","icc-profile-auto"),("fullscreen","fullscreen")})Read(key,prop);
                foreach(string key in new[]{"gamma","brightness","contrast","saturation"})Read(key,key,true);
                // Never emit ICC/LUT/shader filenames or filter parameters.
                foreach(string key in new[]{"icc-profile","target-lut","image-lut","lut"})
                {var x=Get(key);fields.Add(key+"Configured="+(x.Status<0?"unknown":string.IsNullOrEmpty(x.Value)?"no":"yes"));}
                foreach(string key in new[]{"vf","glsl-shaders"})
                {var x=Get(key);int count=-1;try{if(x.Status>=0){using var doc=JsonDocument.Parse(x.Value);if(doc.RootElement.ValueKind==JsonValueKind.Array)count=doc.RootElement.GetArrayLength();}}catch(JsonException){}fields.Add(key+"Count="+(count<0?"unknown":count.ToString(CultureInfo.InvariantCulture)));}
                string policy=DolbyHdrFallback.Policy(session),review="none-from-current-fields";
                bool hdr=values["outputTransfer"] is "pq" or "smpte2084" or "hlg" or "arib-std-b67";
                if(policy=="sdr"&&hdr)review="sdr-policy-hdr-output";
                else if(values["rangeRequest"] is not ("auto" or "unknown"))review="manual-output-range-check-display-match";
                else if(new[]{"gamma","brightness","contrast","saturation"}.Any(k=>values[k] is not ("0" or "unknown")))review="picture-adjustment-active";
                var native=NativeDolby.Read(session);
                string integrity=native.Available?$"integrityEpoch={native.Epoch}; integrityFatal={native.Fatal}; integrityReason={native.Reason}":"integrity=unknown";
                string body=$"policy={policy}; "+string.Join("; ",fields)+"; "+Volatile.Read(ref state.Display)+$"; {integrity}; review={review}; missing={string.Join(',',missing)}; screenColorAccuracy=unmeasured; wireHdrSignal=unverified; targetBlackIsModelNotMeasurement=true";
                if(body==state.Signature)return;state.Signature=body;
                if(state.Emitted++>=32)
                {if(!state.LimitReported){state.LimitReported=true;PlaybackTransport.Write("Info","Playback.Color","event=snapshot-limit; furtherSnapshotChangesSuppressed=true; playbackFailureGuardsStillActive=true");}return;}
                PlaybackFeatureLog.Color(session,Token(trigger),$"batchElapsedMs={Environment.TickCount64-began}; snapshotAtomic=false; "+body);
        }
        catch(Exception error){if(Interlocked.Increment(ref Faults)<=3)PlaybackTransport.Write("Warning","Playback.Color","event=snapshot-failed; type="+error.GetType().Name);}
        finally{Interlocked.Exchange(ref state.Busy,0);}
    }
    static string Token(string s)=>s.Length is >0 and <=48&&s.All(c=>char.IsAsciiLetterOrDigit(c)||c is '-' or '_' or '.')?s:"unknown";
    static string Number(string s)=>double.TryParse(s,NumberStyles.Float,CultureInfo.InvariantCulture,out double n)&&double.IsFinite(n)?n.ToString("0.######",CultureInfo.InvariantCulture):"unknown";
    static readonly object ErrorGate=new();
    static readonly Dictionary<string,long> ErrorTimes=new();
    internal static void NativeMessage(string text)
    {
        string? kind=text.Contains("Failed to set color space",StringComparison.OrdinalIgnoreCase)?"swapchain-colorspace-set-failed":
            text.Contains("not supported by this swapchain",StringComparison.OrdinalIgnoreCase)?"swapchain-colorspace-unsupported":
            text.Contains("Failed to check color space support",StringComparison.OrdinalIgnoreCase)?"swapchain-color-query-failed":
            text.Contains("HDR metadata",StringComparison.OrdinalIgnoreCase)&&text.Contains("fail",StringComparison.OrdinalIgnoreCase)?"hdr-metadata-submit-failed":
            text.Contains("ICC",StringComparison.OrdinalIgnoreCase)&&(text.Contains("fail",StringComparison.OrdinalIgnoreCase)||text.Contains("invalid",StringComparison.OrdinalIgnoreCase))?"icc-profile-failed":null;
        if(kind is null)return;long now=Environment.TickCount64;
        lock(ErrorGate){if(ErrorTimes.TryGetValue(kind,out long at)&&now-at<10000)return;ErrorTimes[kind]=now;}
        PlaybackTransport.Write("Warning","Playback.Color","event="+kind+"; scope=native-log; session=unknown; rawTextOmitted=true");
    }
}
