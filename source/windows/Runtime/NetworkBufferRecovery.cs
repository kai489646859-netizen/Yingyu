using System.Globalization;

namespace Yingyu.Update;

// Event-driven refill policy for finite ordinary HTTP video only. No network
// requests, timers, seek/play commands, or changes to cache capacity/first load.
internal sealed class NetworkBufferRecovery(Func<string> read, Func<string, int> write, Action<string> log)
{
    double? baseline;
    double applied, playingSince = double.NaN, lastBuffer = double.NaN, eligibleAt = double.NaN;
    int level;
    bool playing, buffering, disabled;

    internal static bool Eligible(Uri uri, bool infinite, string? container, bool disc)
        => !disc && !infinite && uri.IsAbsoluteUri && uri.Scheme is "http" or "https"
            && !new[] { "m3u8", "m3u", "mpd" }.Contains((container ?? "").TrimStart('.'), StringComparer.OrdinalIgnoreCase)
            && !new[] { ".m3u8", ".m3u", ".mpd" }.Contains(Path.GetExtension(uri.AbsolutePath), StringComparer.OrdinalIgnoreCase);

    internal void Playing(double now)
    {
        if (!double.IsFinite(eligibleAt)) eligibleAt = now + 3;
        if (!playing) playingSince = now;
        playing = true; buffering = false;
    }

    internal void Buffering(double now, double speed)
    {
        if (disabled || buffering) return;
        buffering = true;
        bool eligible = playing && now >= eligibleAt;
        playing = false;
        if (!eligible) return; // Initial load, seek/restart, or a user pause.
        level = double.IsFinite(lastBuffer) && now - lastBuffer < 60 ? Math.Min(level + 1, 3) : 1;
        lastBuffer = now;
        Apply(speed);
    }

    internal void Speed(double speed) { if (level > 0) Apply(speed); }

    internal void Progress(double now)
    {
        if (!playing || level == 0 || now - playingSince < 120) return;
        Restore(); level = 0; lastBuffer = double.NaN;
    }

    internal void Interrupt()
    {
        playing = buffering = false; playingSince = lastBuffer = eligibleAt = double.NaN; level = 0;
        Restore();
    }

    void Apply(double speed)
    {
        if (disabled || !double.IsFinite(speed) || speed <= 0) return;
        if (baseline == null)
        {
            if (!TryRead(out double initial)) { disabled = true; return; }
            baseline = applied = initial;
        }
        // Seconds here are media seconds. Keep a bounded real-time reserve at
        // higher speeds and never reduce a larger existing/user refill target.
        double seconds = level == 1 ? 2 : level == 2 ? 3 : 4;
        Set(Math.Max(baseline.Value, Math.Min(12, seconds * Math.Clamp(speed, 1, 3))));
    }

    bool TryRead(out double value) => double.TryParse(read(), NumberStyles.Float,
        CultureInfo.InvariantCulture, out value) && double.IsFinite(value) && value >= 0;

    void Set(double target)
    {
        if (disabled || Math.Abs(target - applied) < .001) return;
        double previous = applied;
        int status = write(target.ToString("0.###", CultureInfo.InvariantCulture));
        if (status >= 0 && TryRead(out double actual) && Math.Abs(actual - target) < .002)
        {
            applied = actual;
            log("网络视频缓冲恢复门槛=" + actual.ToString("0.###", CultureInfo.InvariantCulture)
                + "媒体秒；仅调整客户端补缓存，不新增连接或服务器中转。");
            return;
        }
        // A failed optimization never makes a playback command or hides a
        // transport failure. Try to restore the previously confirmed value.
        int restored = write(previous.ToString("0.###", CultureInfo.InvariantCulture));
        bool confirmed = restored >= 0 && TryRead(out double back) && Math.Abs(back - previous) < .002;
        disabled = true;
        log("网络视频缓冲优化未应用；原值恢复=" + (confirmed ? "已核对" : "未确认") + "；本次播放停止自动调整。");
    }

    void Restore()
    {
        if (baseline is { } value) Set(value);
    }
}
