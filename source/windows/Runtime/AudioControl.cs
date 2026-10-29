using System.Globalization;
using System.Runtime.CompilerServices;
using FluentResults;
using Richasy.MpvKernel.Core;

namespace Yingyu.Update;

// Preserve MPV's own audio processing and the original typed property setters.
// Serialize the application's previously independent Task.Run setters; only
// the explicit control operation reads the current property (no polling).
public static class AudioControl
{
    static readonly ConditionalWeakTable<MpvClient, SerialAudioQueue> Queues = new();

    public static Task<Result> Volume(MpvClient client, double value)
        => Number(client, "volume", "音量", value, 0, 300, () => client.SetVolumeAsync(value));

    public static Task<Result> Speed(MpvClient client, double value)
        => Number(client, "speed", "倍速", value, .01, 100, () => client.SetSpeedAsync(value));

    static Task<Result> Number(MpvClient client, string property, string label, double value,
        double minimum, double maximum, Func<Task<Result>> apply)
        => Queues.GetValue(client, _ => new SerialAudioQueue()).Enqueue(async () =>
        {
            if (!double.IsFinite(value) || value < minimum || value > maximum)
                throw new ArgumentOutOfRangeException(nameof(value), label + "设置超出支持范围。");
            RequireLive(client);
            string current = PlaybackTransport.Get(client, property);
            if (double.TryParse(current, NumberStyles.Float, CultureInfo.InvariantCulture, out double actual)
                && double.IsFinite(actual) && actual == value) return Result.Ok();
            RequireLive(client);
            return Checked(await apply().ConfigureAwait(false), label);
        });

    public static Task<Result> Track(MpvClient client, int? value)
        => Queues.GetValue(client, _ => new SerialAudioQueue()).Enqueue(async () =>
        {
            if (value.HasValue && value.Value <= 0)
                throw new ArgumentOutOfRangeException(nameof(value), "音轨编号无效。");
            RequireLive(client);
            string current = PlaybackTransport.Get(client, "aid");
            bool same = value.HasValue
                ? int.TryParse(current, NumberStyles.Integer, CultureInfo.InvariantCulture, out int actual) && actual == value.Value
                : current == "no";
            if (same) return Result.Ok();
            RequireLive(client);
            return Checked(await client.SetAudioTrackAsync(value).ConfigureAwait(false), "音轨");
        });

    static void RequireLive(MpvClient client)
    {
        if (client.IsDisposed) throw new ObjectDisposedException("播放器", "播放会话已关闭，声音控制未执行。");
    }

    static Result Checked(Result result, string label)
    {
        // The original caller awaits Task<Result> but ignores IsFailed and then
        // commits its state/"success" feedback. Use its existing error handler
        // instead. Never persist the raw native error or media information.
        if (result.IsFailed) throw new InvalidOperationException("MPV 未接受" + label + "设置，操作未完成。");
        return result;
    }
}
