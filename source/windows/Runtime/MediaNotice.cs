using System.Runtime.CompilerServices;
using System.Reflection;
using Microsoft.UI.Xaml;
using Richasy.MpvKernel.Core;
using EmbyDesktop.Core.Models;

namespace Yingyu.Update;

// Event-driven, per media generation. Uses the existing two-second action
// feedback canvas; it never adds a permanent badge or a polling timer.
public static class MediaNotice
{
    static readonly ConditionalWeakTable<object, State> States = new();
    sealed class State(int generation, object client, bool bluray)
    {
        internal readonly int Generation = generation;
        internal readonly object Client = client;
        internal readonly bool Bluray = bluray;
        internal int Profile;
        internal bool Dolby, Pending = true;
        internal string Track = "",LastMessage="";
        internal long LastSample,FirstSample;
        internal int Notices;
        internal long Revision;
    }
    static bool Closing(object session) => (bool)session.GetType().GetProperty("_isClosing",
        BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic)!.GetValue(session)!;
    static bool Current(object session, State state) => state.Generation == Access.Get<int>(session, "_mediaGeneration")
        && ReferenceEquals(state.Client, Access.Get<object?>(session, "_mpvClient"))
        && States.TryGetValue(session, out var current) && ReferenceEquals(state, current);

    internal static string? Message(bool bluray, int profile, bool dolby)
    {
        string? format = profile > 0 ? $"杜比视界 Profile {profile}" : dolby ? "杜比视界" : null;
        return bluray ? "蓝光原盘" + (format == null ? "" : " · " + format) : format;
    }
    internal static string SourceFormat(object session)
    {
        var client=Access.Get<MpvClient?>(session,"_mpvClient");if(client is null||client.IsDisposed)return "";
        string Read(string key)=>PlaybackTransport.Get(client,key).ToLowerInvariant();
        if(int.TryParse(Read("current-tracks/video/dolby-vision-profile"),out var p)&&p is >0 and <=10)return $"杜比视界 Profile {p}";
        if(Read("video-params/colormatrix")=="dolbyvision")return "杜比视界";
        var videos=Access.Get<MediaSourceInfo>(session,"_source").MediaStreams.Where(s=>s.Type=="Video").ToArray();
        string mark=videos.Length==1?((videos[0].VideoRange??"")+" "+(videos[0].VideoRangeType??"")).ToLowerInvariant():"";
        if(mark.Contains("dolbyvision")||mark.Contains("dolby vision")||mark.Contains("dovi"))return "杜比视界（服务器标注）";
        string transfer=Read("video-params/gamma");
        if(transfer is "pq" or "smpte2084")return "HDR";
        if(transfer is "hlg" or "arib-std-b67")return "HLG";
        if(transfer is "bt.1886" or "bt.709" or "gamma2.2" or "gamma2.4" or "srgb")return "SDR";
        return mark.Contains("hdr")?"HDR（服务器标注）":mark.Contains("hlg")?"HLG（服务器标注）":"";
    }
    internal static string OutputFormat(object session)
    {
        var client=Access.Get<MpvClient?>(session,"_mpvClient");if(client is null||client.IsDisposed)return "未核验";
        var native=NativeDolby.Read(session);if(native.Confirmed)return native.Summary;
        if(native.Fatal)return native.Summary;
        string primaries=PlaybackTransport.Get(client,"video-target-params/primaries").ToLowerInvariant();
        return PlaybackTransport.Get(client,"video-target-params/gamma").ToLowerInvariant() switch
        {"pq" or "smpte2084"=>primaries=="bt.2020"?"HDR10 输出":"HDR（色域待确认）","hlg" or "arib-std-b67"=>"HLG 输出","bt.1886" or "bt.709" or "gamma2.2" or "gamma2.4" or "srgb"=>"SDR 输出",_=>"输出方式待确认"};
    }
    internal static string PlaybackMessage(object session,bool bluray)
    {
        string source=SourceFormat(session),output=OutputFormat(session);string suffix=bluray?" · 蓝光原盘":"";
        if(source.StartsWith("杜比视界",StringComparison.Ordinal))return (output=="HDR10 输出"?"杜比视界 → HDR10 播放":output=="SDR 输出"?"杜比视界 → SDR 播放":source+" → "+output)+suffix;
        if(source=="SDR"&&output.StartsWith("SDR",StringComparison.Ordinal))return "SDR · 标准动态范围"+suffix;
        if(source.Length>0)return source+" → "+output+suffix;
        return bluray?"蓝光原盘 · "+output:"";
    }
    internal static void RearmOutput(object session)
    {
        if(!States.TryGetValue(session,out var state))return;
        var native=NativeDolby.Read(session);
        lock(state){
            // Control/foreground transitions do not consume repeated notices.
            if(state.Notices>0&&!native.Confirmed&&!native.Fatal&&native.Reason is >=0 and <=3)return;
            state.Pending=true;state.Revision++;
        }
        Ready(session);
    }
    internal static void Sample(object session)
    {
        if(!States.TryGetValue(session,out var state)||!Current(session,state))return;
        if(!Access.Get<bool>(session,"_hasStartedPlayback")||!Access.Get<bool>(session,"_acceptPlaybackEvents")||Closing(session))return;
        long now=Environment.TickCount64;
        lock(state){if(state.FirstSample==0)state.FirstSample=now;if(now-state.LastSample<1000||state.Notices>=6||now-state.FirstSample>15000)return;state.LastSample=now;}
        Ready(session);
    }
    internal static void Begin(object session)
    {
        PlaybackFeatureLog.Begin(session);
        var client = Access.Get<object?>(session, "_mpvClient");
        if (client == null) return;
        var uri = Access.Get<Uri>(session, "_playbackUri");
        bool bluray = uri.Scheme is "yingyu-bd" or "bd"
            || !string.IsNullOrWhiteSpace(Access.Get<string?>(session, "_nativeDiscPath"));
        States.Remove(session);
        States.Add(session, new State(Access.Get<int>(session, "_mediaGeneration"), client, bluray));
    }
    internal static void Arm(object session)
    {
        if (!States.TryGetValue(session, out var state) || !Current(session, state)) return;
        // A seek invalidates queued callbacks but must not rearm an already
        // shown entry notice. Begin still arms the next opened media.
        lock (state) { state.Revision++; }
    }
    internal static void Refresh(object session)
    {
        try
        {
            if (!States.TryGetValue(session, out var state) || !Current(session, state)
                || !Access.Get<bool>(session, "_acceptPlaybackEvents") || Closing(session)
                || state.Client is not MpvClient client || client.IsDisposed) return;
            int.TryParse(PlaybackTransport.Get(client, "current-tracks/video/dolby-vision-profile"), out int profile);
            bool dolby = PlaybackTransport.Get(client, "video-params/colormatrix") == "dolbyvision";
            lock (state)
            {
                string track=PlaybackTransport.Get(client,"vid");
                if(track!=state.Track){state.Track=track;state.Profile=0;state.Dolby=false;}
                // A container may omit the profile; actual decoded metadata is
                // sufficient for a Dolby label, but never invents a profile.
                if (profile is > 0 and <= 10) state.Profile = profile;
                state.Dolby |= dolby;
            }
        }
        catch (Exception error) { PlaybackTransport.Write("Warning", "Playback.Feedback", "片源格式读取未完成；异常类型=" + error.GetType().Name); }
    }
    internal static void Ready(object session)
    {
        if (!States.TryGetValue(session, out var state) || !Current(session, state)
            || Access.Get<object?>(session, "_overlay") is not FrameworkElement overlay) return;
        long revision;
        lock (state) { if (state.Notices>=6) return; revision = state.Revision; }
        overlay.DispatcherQueue.TryEnqueue(() =>
        {
            try
            {
                if (!Current(session, state) || Closing(session)
                    || !Access.Get<bool>(session, "_acceptPlaybackEvents")
                    || !Access.Get<bool>(session, "_hasStartedPlayback")
                    || Access.Get<bool>(session, "_startupTerminalFailure")
                    || !ReferenceEquals(overlay, Access.Get<object?>(session, "_overlay"))
                    || !PlayerFeedback.CanShowMediaNotice(overlay)) return;
                lock (state)
                {
                    if (state.Notices>=6 || state.Revision != revision) return;
                    var native=NativeDolby.Read(session);
                    if(state.Notices>0&&native.Available&&!native.Confirmed&&!native.Fatal&&native.Reason is >=0 and <=3)return;
                    string message = PlaybackMessage(session,state.Bluray);
                    if (message.Length==0||message==state.LastMessage) return;
                    bool dolby=state.Profile>0||state.Dolby||native.Profile>0;
                    // mpv OSD is composed into the renderer's frame, including
                    // HDR fallback. A notice must not create a new WinUI blocker.
                    if(native.Confirmed||native.Available&&dolby)NativeDolby.ShowNativeNotice(session,message);
                    else Access.Call(overlay, "ShowActionFeedback", message, false);
                    PlaybackFeatureLog.Output(session,"startup-notice");
                    state.Pending = false;state.LastMessage=message;state.Notices++;
                }
            }
            catch (Exception error) { PlaybackTransport.Write("Warning", "Playback.Feedback", "片源临时提示未完成；异常类型=" + error.GetType().Name); }
        });
    }
}
