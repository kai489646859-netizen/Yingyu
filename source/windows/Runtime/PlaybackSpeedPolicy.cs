using System.Globalization;

namespace Yingyu.Update;

// Preserve the 1x/2x reserve; 3x can retain up to 1.5 GiB and 180 media seconds.
// These are bounded capacity/readahead targets, not a network rate or a fill gate.
// The backward cache, decoding and picture processing are unchanged.
internal static class PlaybackSpeedPolicy
{
    internal const long MaximumForwardBytes = 1536L * 1024 * 1024;

    internal static long ForwardBytes(long original, double speed)
    {
        if (original <= 0 || !double.IsFinite(speed) || speed < 1) return original;
        // Keep a larger pre-existing user budget; never lower it as a side effect.
        if (original >= 896L * 1024 * 1024) return original;
        long limit = speed >= 3 ? MaximumForwardBytes : 896L * 1024 * 1024;
        double reserve = speed >= 3 ? 6 : Math.Min(speed, 3) + .5;
        return Math.Min(limit, (long)Math.Ceiling(original * reserve));
    }

    internal static double ForwardSeconds(double original, double speed)
    {
        if (!double.IsFinite(original) || original < 0 || !double.IsFinite(speed) || speed < 1) return original;
        // Preserve the original >=2x 90-second target rather than lowering it
        // to 75 seconds. A larger pre-existing per-session target stays intact.
        double target = speed >= 3 ? 180 : Math.Max(speed >= 2 ? 90 : 30, 30 * (Math.Min(speed, 3) + .5));
        return Math.Max(original, target);
    }

    internal static bool TrySeconds(string value, out double seconds)
        => double.TryParse(value, NumberStyles.Float, CultureInfo.InvariantCulture, out seconds)
            && double.IsFinite(seconds) && seconds >= 0;

    internal static double WaitSeconds(double original, double speed)
    {
        if (!double.IsFinite(original) || original < 0 || !double.IsFinite(speed) || speed <= 1) return original;
        // Twelve media seconds provide four seconds of actual playback at 3x.
        // Initial/resume/seek still request one media second; only ordinary
        // rebuffer recovery grows, without forcing a pause on a speed change.
        return speed >= 3 && original == 3 ? 12 : original;
    }

    internal static bool TryBytes(string value, out long bytes)
    {
        if (long.TryParse(value, NumberStyles.Integer, CultureInfo.InvariantCulture, out bytes)) return bytes >= 0;
        string[] units = ["KiB", "MiB", "GiB"];
        for (int i = 0; i < units.Length; i++)
            if (value.EndsWith(units[i], StringComparison.OrdinalIgnoreCase)
                && double.TryParse(value[..^units[i].Length], NumberStyles.Float, CultureInfo.InvariantCulture, out double number)
                && double.IsFinite(number) && number >= 0 && number < long.MaxValue / Math.Pow(1024, i + 1))
            { bytes = (long)Math.Round(number * Math.Pow(1024, i + 1)); return true; }
        bytes = 0; return false;
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
