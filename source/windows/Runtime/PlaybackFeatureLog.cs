using System.Globalization;
using System.Runtime.CompilerServices;
using Richasy.MpvKernel.Core;

namespace Yingyu.Update;

// Existing local AppLog/export pipeline; no separate worker, timer or media IO.
internal static class PlaybackFeatureLog
{
    static int next;
    static readonly ConditionalWeakTable<object,State> States=new();
    sealed class State(int generation,object? client)
    {
        internal readonly int Id=Interlocked.Increment(ref next),Generation=generation;
        internal readonly object? Client=client;
        internal int Successes;
        internal string LastIntegrity="";
        internal readonly Dictionary<string,(long At,int Skipped)> Errors=new();
    }
    internal static void Begin(object session)
    {
        States.Remove(session);States.Add(session,new(Access.Get<int>(session,"_mediaGeneration"),Access.Get<object?>(session,"_mpvClient")));
        Write(session,"media-begin","ready");
    }
    static State? Current(object session)=>States.TryGetValue(session,out var state)&&state.Generation==Access.Get<int>(session,"_mediaGeneration")&&ReferenceEquals(state.Client,Access.Get<object?>(session,"_mpvClient"))?state:null;
    static string Token(string? value)=>string.IsNullOrEmpty(value)?"none":value.Length<=48&&value.All(c=>char.IsAsciiLetterOrDigit(c)||c is '-' or '_' or '.')?value:"other";
    internal static void Write(object session,string action,string result,double? value=null,string? errorType=null)
    {
        var state=Current(session);if(state==null)return;
        bool failure=errorType!=null||result is "failed" or "rejected" or "sdr-blocked";int skipped=0;
        lock(state)
        {
            if(!failure&&state.Successes++>=80)return;
            if(failure){string key=Token(action);long now=Environment.TickCount64;if(state.Errors.TryGetValue(key,out var prior)){if(now-prior.At<1000){state.Errors[key]=(prior.At,Math.Min(100000,prior.Skipped+1));return;}skipped=prior.Skipped;}if(state.Errors.Count<64||state.Errors.ContainsKey(key))state.Errors[key]=(now,0);}
        }
        string number=value is {} n&&double.IsFinite(n)?n.ToString("0.###",CultureInfo.InvariantCulture):"unknown";
        PlaybackTransport.Write(failure?"Warning":"Info","Playback.Features",$"功能诊断；版本=0.5.8；会话={state.Id}；媒体代次={state.Generation}；event={Token(action)}; result={Token(result)}; value={number}; type={Token(errorType)}; repeated={skipped}。");
    }
    internal static void Native(object session,NativeDolby.Status status)
    {
        var state=Current(session);if(state==null)return;
        // Transport is disabled. Only integrity failures/warnings merit a separate record.
        if(!status.Available||(!status.Fatal&&status.Reason is not (>=10 and <=17)))return;
        string signature=$"{status.Epoch}/{status.Reason}/{status.Fatal}";
        lock(state){if(state.LastIntegrity==signature)return;state.LastIntegrity=signature;}
        PlaybackTransport.Write(status.Fatal?"Warning":"Info","Playback.DolbyIntegrity",$"版本=0.5.8; session={state.Id}; generation={state.Generation}; {status.Diagnostic}; physicalSignalAndColorValidated=false");
    }
    internal static void Output(object session,string trigger)
    {
        ColorDiagnostics.Capture(session,trigger);
    }
    internal static void Color(object session,string trigger,string body)
    {
        var state=Current(session);if(state is null)return;
        PlaybackTransport.Write("Info","Playback.Color",$"版本=0.5.8; session={state.Id}; generation={state.Generation}; event={trigger}; {body}");
    }
    internal static void Display(object session,string body)
    {
        var state=Current(session);if(state is null)return;
        PlaybackTransport.Write("Info","Playback.Display",$"版本=0.5.8; session={state.Id}; generation={state.Generation}; {body}; fullscreenRequiredForHdr=false; wireHdrSignal=unverified");
    }
}
