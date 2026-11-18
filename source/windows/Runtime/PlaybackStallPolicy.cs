namespace Yingyu.Update;

internal static class PlaybackStallPolicy
{
    internal static bool Eligible(double stalledSeconds, double position, double? cachedAhead, double cacheAge)
        => stalledSeconds >= 6 && double.IsFinite(position) && position > 0
            && cachedAhead is >= 2 and < double.PositiveInfinity && cacheAge is >= 0 and <= 3;

    internal static bool Confirm(double sampledPosition, double livePosition, double duration,
        string pause, string cachePause, string seeking, string idle, string eof)
        => pause == "no" && cachePause == "no" && seeking == "no" && idle == "no" && eof == "no"
            && double.IsFinite(duration) && duration - livePosition > 2
            && Math.Abs(livePosition - sampledPosition) < .05;
}
