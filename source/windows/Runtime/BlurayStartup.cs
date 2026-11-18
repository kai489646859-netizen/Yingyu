using System.Diagnostics;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using Richasy.MpvKernel;
using Richasy.MpvKernel.Core;

namespace Yingyu.Update;

public static class BlurayStartup
{
    static readonly ConditionalWeakTable<MpvClient, WeakReference<object>> Sessions = new();
    static long Bytes(object session, Uri uri) => NetworkBluray.Active.TryGetValue(uri.ToString(), out var disc)
        ? disc.Received : PlaybackTelemetry.StartupForwardBytes(session);

    public static Task Delay(TimeSpan original, CancellationToken token, object session)
    {
        var uri = Access.Get<Uri>(session, "_playbackUri");
        bool bridged = NetworkBluray.IsFallbackSession(session);
        if (bridged)
        {
            var client = Access.Get<MpvClient>(session, "_mpvClient");
            Sessions.GetValue(client, _ => new WeakReference<object>(session)).SetTarget(session);
        }
        bool disc = bridged || BlurayStartupPolicy.IsDiscUri(uri)
            || !string.IsNullOrWhiteSpace(Access.Get<string?>(session, "_nativeDiscPath"));
        return WaitAsync(session, uri, original, disc, disc && !bridged, token);
    }

    static async Task WaitAsync(object session, Uri uri, TimeSpan original, bool disc, bool mounted, CancellationToken token)
    {
        int generation = Access.Get<int>(session, "_mediaGeneration");
        if (!disc)
        {
            await Task.Delay(original, token);
            while (DolbyHdrFallback.IsFailed(session))
            {
                await Task.Delay(TimeSpan.FromSeconds(1), token);
                CheckCurrent();
            }
            return;
        }
        long began = Stopwatch.GetTimestamp();
        var policy = new BlurayStartupPolicy(Bytes(session, uri), mounted);
        bool reported = false;
        while (true)
        {
            await Task.Delay(TimeSpan.FromSeconds(1), token);
            CheckCurrent();
            // Keep the original integrity failure onscreen until the user
            // leaves or selects another source. A route retry cannot repair it.
            if (DolbyHdrFallback.IsFailed(session)) continue;
            double elapsed = Stopwatch.GetElapsedTime(began).TotalSeconds;
            long bytes = Bytes(session, uri);
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
                    bytes > 0
                        ? "蓝光已有读取进展，继续等待实际首帧。 "
                        : "挂载原盘正在初始化，尚未观察到首个前向缓存样本；初始等待上限32秒。 ");
            }
        }

        void CheckCurrent()
        {
            token.ThrowIfCancellationRequested();
            if (generation != Access.Get<int>(session, "_mediaGeneration")
                || uri != Access.Get<Uri>(session, "_playbackUri")
                || !Access.Get<bool>(session, "_acceptPlaybackEvents"))
                throw new OperationCanceledException(token);
        }
    }

    // Called synchronously before the original async event handler starts:
    // MPV owns DataPtr and may invalidate it on the next wait_event call.
    public static bool IgnoreControlEnd(MpvClient client, MpvEvent value)
    {
        KeepOpenCompletion.NativeEvent(client, value);
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
