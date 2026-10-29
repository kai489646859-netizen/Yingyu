using System.Globalization;
using System.Runtime.CompilerServices;
using Richasy.MpvKernel.Core;

namespace Yingyu.Update;

public static class PlaybackOutput
{
    static readonly ConditionalWeakTable<object, Counter> Counts = new();
    sealed class Counter { internal int Restarts; }
    internal static void Configure(object session, MpvClient client)
    {
        ColorDiagnostics.Begin(session,client);
        Counts.Remove(session); Counts.Add(session, new Counter());
        // Hardware decode on integrated and discrete GPUs; mpv keeps its normal
        // software decoder fallback if no safe hardware decoder accepts the file.
        if(PlaybackTransport.Set(client,"hwdec","auto-safe")<0)
            PlaybackTransport.Write("Warning","Playback.Output","GPU 优先解码设置未被接受，沿用原内核策略。");
        // --no-config disables MPV's default platform cache directory too.
        // An explicit directory restores MPV's own shader cache without enabling
        // arbitrary user configuration/scripts or changing quality settings.
        string path = CachePaths.Shaders;
        if (PlaybackTransport.Set(client, "gpu-shader-cache-dir", path) < 0)
            throw new IOException("无法将播放器着色器缓存保存到安装目录，未改用其他磁盘。");
        // The original initialization forces 'yes', including SDR desktops.
        // MPV's auto mode negotiates with the actual display/compositor and
        // retains HDR output when supported. No source color metadata is edited.
        if (PlaybackTransport.Get(client, "target-colorspace-hint") == "yes"
            && PlaybackTransport.Set(client, "target-colorspace-hint", "auto") < 0)
            PlaybackTransport.Write("Warning", "Playback.Output", "自动显示色彩提示未被接受，保留原显示参数。 ");
    }
    internal static string SafeValue(string value) => value.Length is > 0 and <= 40
        && value.All(c => char.IsAsciiLetterOrDigit(c) || c is '-' or '_' or '.') ? value : "unknown";
    internal static void Snapshot(object session, MpvClient client)
    {
        try
        {
            ColorDiagnostics.Capture(session,"playback-restart");
            if (client.IsDisposed || !Counts.TryGetValue(session, out var count)
                || Interlocked.Increment(ref count.Restarts) > 6) return;
            string Read(string name) => SafeValue(PlaybackTransport.Get(client, name));
            string Number(string name) => double.TryParse(PlaybackTransport.Get(client, name), NumberStyles.Float,
                CultureInfo.InvariantCulture, out double value) && double.IsFinite(value)
                ? value.ToString("0.###", CultureInfo.InvariantCulture) : "unknown";
            PlaybackTelemetry.Emit(
                $"scope=audio; event=output-format; ao={Read("current-ao")}; codec={Read("audio-codec-name")}; " +
                $"track={Number("aid")}; exclusive={Read("audio-exclusive")}; " +
                $"inputFormat={Read("audio-params/format")}; inputRate={Number("audio-params/samplerate")}; inputChannels={Number("audio-params/channel-count")}; " +
                $"outputFormat={Read("audio-out-params/format")}; outputRate={Number("audio-out-params/samplerate")}; outputChannels={Number("audio-out-params/channel-count")}; " +
                $"bufferSeconds={Number("audio-buffer")}; sync={Read("video-sync")}; pitchCorrection={Read("audio-pitch-correction")}");
        }
        catch (Exception error) { PlaybackTransport.Write("Warning", "Playback.Output", "解码输出诊断未完成；异常类型=" + error.GetType().Name); }
    }
}
