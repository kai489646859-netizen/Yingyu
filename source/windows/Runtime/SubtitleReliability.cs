using System.Diagnostics;
using System.Globalization;
using System.Reflection;
using System.Runtime.CompilerServices;
using Richasy.MpvKernel.Core;
using Richasy.MpvKernel.Core.Enums;
using Richasy.MpvKernel.Core.Models;

namespace Yingyu.Update;

// Read-only observations from the existing MPV handle. This component owns no
// timer, source, native callback or subtitle text, and never sets sid/options.
public static class SubtitleReliability
{
    static readonly ConditionalWeakTable<object, State> States = new();
    public static void Notify(object session, MpvClientNotifyEventArgs e)
    {
        if (e.Id == MpvClientEventId.PositionChanged) Sample(session, "播放采样");
        else if (e.Id == MpvClientEventId.PlaybackRestart) Sample(session, "解码恢复");
        else if (e.Id == MpvClientEventId.TrackCountChanged) Sample(session, "轨道变化");
    }
    internal static void Sample(object session, string reason)
    {
        try
        {
            if (reason is not ("播放采样" or "解码恢复" or "轨道变化" or "文件载入" or "轨道读取")) return;
            if (!Access.Get<bool>(session, "_acceptPlaybackEvents") || (bool)session.GetType().GetProperty("_isClosing",
                BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic)!.GetValue(session)!) return;
            var client = Access.Get<MpvClient?>(session, "_mpvClient");
            if (client == null || client.IsDisposed) return;
            int generation = Access.Get<int>(session, "_mediaGeneration");
            var state = States.GetValue(session, _ => new State());
            if (!state.Allow(generation)) return;
            // Only bounded numeric or closed-enum values leave this function.
            // Unknown cue timing (notably bitmap subtitles) is not a missing cue.
            string sid = Track(PlaybackTransport.Get(client, "sid"));
            string visible = Flag(PlaybackTransport.Get(client, "sub-visibility"));
            string forced = Flag(PlaybackTransport.Get(client, "sub-forced-events-only"));
            string forcedTrack = Flag(PlaybackTransport.Get(client, "current-tracks/sub/forced"));
            string delay = Number(PlaybackTransport.Get(client, "sub-delay"));
            string start = Number(PlaybackTransport.Get(client, "sub-start/full"));
            string end = Number(PlaybackTransport.Get(client, "sub-end/full"));
            string codec = Codec(PlaybackTransport.Get(client, "current-tracks/sub/codec"));
            double position = Access.Get<double>(session, "_position");
            bool manual = Access.Get<int>(session, "_manualSubtitleGeneration") == generation;
            int? chosen = manual ? Access.Get<int?>(session, "_manuallySelectedSubtitleId") : null;
            if (generation != Access.Get<int>(session, "_mediaGeneration") || client.IsDisposed
                || !ReferenceEquals(client, Access.Get<MpvClient?>(session, "_mpvClient"))) return;
            PlaybackTransport.Write("Info", "Playback.Subtitles",
                $"字幕状态；代次={generation}；触发={reason}；位置={Number(position)}秒；轨道={sid}；显示={visible}；仅强制事件={forced}；轨道强制标记={forcedTrack}；延迟={delay}秒；当前事件起止={start} / {end}秒；类型={codec}；本代次手选={(manual ? "是" : "否")}；手选轨道={(manual ? chosen?.ToString(CultureInfo.InvariantCulture) ?? "关闭" : "未手选")}；状态不证明每句都有字幕，未记录字幕正文或片源信息。 ");
        }
        catch (Exception error)
        {
            // Reflection/native races are diagnostic failures, never playback failures.
            try
            {
                var state = States.GetValue(session, _ => new State());
                if (state.Fault()) PlaybackTransport.Write("Warning", "Playback.Subtitles", "字幕状态诊断暂不可用，保留原播放和字幕选择；异常类型=" + error.GetType().Name);
            }
            catch { }
        }
    }
    internal static string Track(string value) => value == "no" ? "关闭" : value == "auto" ? "自动"
        : int.TryParse(value, NumberStyles.Integer, CultureInfo.InvariantCulture, out int id) && id > 0 ? id.ToString(CultureInfo.InvariantCulture) : "未知";
    internal static string Flag(string value) => value switch { "yes" => "是", "no" => "否", _ => "未知" };
    internal static string Number(string value) => double.TryParse(value, NumberStyles.Float, CultureInfo.InvariantCulture, out double parsed) ? Number(parsed) : "未知";
    internal static string Number(double value) => double.IsFinite(value) ? value.ToString("0.###", CultureInfo.InvariantCulture) : "未知";
    internal static string Codec(string value) => value.ToLowerInvariant() switch
    {
        "hdmv_pgs_subtitle" or "pgs" => "PGS 图像字幕", "dvd_subtitle" => "DVD 图像字幕",
        "dvb_subtitle" => "DVB 图像字幕", "ass" or "ssa" => "ASS/SSA 文本字幕",
        "subrip" or "srt" => "SRT 文本字幕", "webvtt" => "WebVTT 文本字幕",
        "mov_text" or "text" => "文本字幕", _ => "其他或未知"
    };
    sealed class State
    {
        readonly object _gate = new();
        int _generation = int.MinValue, _samples, _faults;
        long _last;
        internal bool Allow(int generation)
        {
            lock (_gate)
            {
                if (_generation != generation) { _generation = generation; _samples = _faults = 0; _last = 0; }
                if (_samples >= 1024 || _last != 0 && Stopwatch.GetElapsedTime(_last).TotalSeconds < 15) return false;
                _last = Stopwatch.GetTimestamp(); _samples++; return true;
            }
        }
        internal bool Fault() { lock (_gate) return _faults++ < 1; }
    }
}
