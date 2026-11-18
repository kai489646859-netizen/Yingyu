using System.Globalization;

namespace Yingyu.Update;

internal static class PlaybackSpeedPolicy
{
    internal static double WaitSeconds(double original, double speed)
    {
        if (!double.IsFinite(original) || original < 0 || !double.IsFinite(speed) || speed <= 1) return original;
        // Twelve media seconds provide four seconds of actual playback at 3x.
        // Initial/resume/seek still request one media second; only ordinary
        // rebuffer recovery grows, without forcing a pause on a speed change.
        return speed >= 3 && original == 3 ? 12 : original;
    }

    internal static string InitialBlurayWait(List<string> options)
    {
        // Initial speed is already in loadfile's option list. No native polling,
        // seek, extra connection or decode-core change is needed at file start.
        var value = options.LastOrDefault(v => v.StartsWith("speed=", StringComparison.Ordinal));
        double speed = value != null && double.TryParse(value[6..], NumberStyles.Float,
            CultureInfo.InvariantCulture, out double parsed) ? parsed : 1;
        return WaitSeconds(1, speed).ToString("0.###", CultureInfo.InvariantCulture);
    }
}
