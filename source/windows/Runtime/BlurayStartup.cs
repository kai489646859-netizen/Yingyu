using System.Diagnostics;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using Richasy.MpvKernel;
using Richasy.MpvKernel.Core;

namespace Yingyu.Update;

public static class BlurayStartup
{
    static readonly ConditionalWeakTable<MpvClient, WeakReference<object>> Sessions = new();
    static long Bytes(object session) => NetworkBluray.Active.TryGetValue(Access.Get<Uri>(session, "_playbackUri").ToString(), out var disc) ? disc.Received : 0;

    public static Task Delay(TimeSpan original, CancellationToken token, object session)
    {
        if (!NetworkBluray.IsFallbackSession(session)) return Task.Delay(original, token);
        var client = Access.Get<MpvClient>(session, "_mpvClient");
        Sessions.GetValue(client, _ => new WeakReference<object>(session)).SetTarget(session);
        return WaitAsync(session, token);
    }

    static async Task WaitAsync(object session, CancellationToken token)
    {
        int generation = Access.Get<int>(session, "_mediaGeneration");
        var uri = Access.Get<Uri>(session, "_playbackUri");
        long began = Stopwatch.GetTimestamp();
        var policy = new BlurayStartupPolicy(Bytes(session));
        bool reported = false;
        while (true)
        {
            await Task.Delay(TimeSpan.FromSeconds(1), token);
            token.ThrowIfCancellationRequested();
            if (generation != Access.Get<int>(session, "_mediaGeneration")
                || uri != Access.Get<Uri>(session, "_playbackUri")
                || !Access.Get<bool>(session, "_acceptPlaybackEvents"))
                throw new OperationCanceledException(token);
            double elapsed = Stopwatch.GetElapsedTime(began).TotalSeconds;
            long bytes = Bytes(session);
            if (policy.Expired(elapsed, bytes))
            {
                PlaybackTransport.Write("Warning", "Playback.Startup",
                    $"网络蓝光首帧等待到期；累计={elapsed:0}秒，无读取进展={policy.IdleAt(elapsed):0}秒；保留原重试及失败处理。 ");
                return;
            }
            if (!reported && elapsed >= BlurayStartupPolicy.IdleSeconds)
            {
                reported = true;
                PlaybackTransport.Write("Info", "Playback.Startup",
                    "网络蓝光仍有读取进展，继续当前定位及缓冲；连续20秒无进展或累计120秒仍未出首帧时进入原失败处理。 ");
            }
        }
    }

    // Called synchronously before the original async event handler starts:
    // MPV owns DataPtr and may invalidate it on the next wait_event call.
    public static bool IgnoreControlEnd(MpvClient client, MpvEvent value)
    {
        PictureAdjustment.Notify(client,value);
        if(ColorPropertyReader.Notify(client,value))return true;
        if (value.EventId != MpvEventId.EndFile || value.Error != MpvError.Success
            || value.DataPtr == IntPtr.Zero || !Sessions.TryGetValue(client, out var reference)
            || !reference.TryGetTarget(out var session) || !NetworkBluray.IsFallbackSession(session)) return false;
        int reason = Marshal.ReadInt32(value.DataPtr);
        if (!BlurayStartupPolicy.IsControlEnd(reason)) return false;
        PlaybackTransport.Write("Info", "Playback.Startup",
            $"网络蓝光控制结束事件；原因编号={reason}，不作为自然结尾或新播放失败；真实EOF和错误事件保留。 ");
        return true;
    }
}
