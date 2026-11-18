using System.Globalization;

namespace Yingyu.Update;

internal static class PlaybackEndPolicy
{
    internal static bool ConfirmsNaturalEnd(string positionText, string durationText,
        out double position, out double duration)
    {
        position = duration = double.NaN;
        if (!double.TryParse(positionText, NumberStyles.Float, CultureInfo.InvariantCulture, out position)
            || !double.TryParse(durationText, NumberStyles.Float, CultureInfo.InvariantCulture, out duration)
            || !double.IsFinite(position) || !double.IsFinite(duration)
            || position < 0 || duration <= 0 || position > duration + 10)
            return false;

        double remaining = Math.Max(0, duration - position);
        double tolerance = Math.Clamp(duration * .002, 2, 10);
        return position / duration >= .98 && remaining <= tolerance;
    }
}
