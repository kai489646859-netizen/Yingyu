namespace Yingyu.Update;

// Progress extends the initial deadline, never the inactivity or total bound.
internal sealed class BlurayStartupPolicy(long bytes)
{
    internal const double IdleSeconds = 20;
    internal const double MaximumSeconds = 120;
    long _bytes = bytes;
    double _lastProgress;
    internal double IdleAt(double elapsed) => elapsed - _lastProgress;
    internal bool Expired(double elapsed, long bytes)
    {
        if (bytes > _bytes) { _bytes = bytes; _lastProgress = elapsed; }
        return elapsed >= MaximumSeconds || IdleAt(elapsed) >= IdleSeconds;
    }

    // mpv_event_end_file.reason, bundled MPV API: actual EOF/error/unknown
    // remain visible. Replacing, stopping or redirecting isn't natural EOF.
    internal static bool IsControlEnd(int reason) => reason is 2 or 3 or 5;
}
