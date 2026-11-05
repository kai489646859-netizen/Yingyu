using System.Diagnostics;
using Richasy.MpvKernel.Core.Enums;
using Richasy.MpvKernel.Core.Models;

namespace Yingyu.Update;

// Samples come from the player event thread. Rendering reads a single coherent
// snapshot and interpolates without asking mpv for a property on the UI thread.
internal sealed class DanmakuClock
{
    internal readonly record struct Sample(double Position, double Speed, long PositionAt, bool Playing, int Epoch, double Cadence);
    readonly object gate = new();
    bool awaitingSeekPosition;
    Sample latest = new(double.NaN, 1, 0, false, 0, .2);

    internal void Reset(double position, double speed)
    {
        lock (gate)
        {
            awaitingSeekPosition = false;
            latest = new(position, double.IsFinite(speed) && speed > 0 ? speed : 1, Stopwatch.GetTimestamp(), false, latest.Epoch + 1, .2);
        }
    }

    internal void Seek(double position)
    {
        lock (gate)
        {
            awaitingSeekPosition = false;
            latest = latest with { Position = position, PositionAt = Stopwatch.GetTimestamp(), Epoch = latest.Epoch + 1 };
        }
    }

    internal void Observe(MpvClientNotifyEventArgs args)
    {
        long now = Stopwatch.GetTimestamp();
        lock (gate)
        {
            if (args.Id == MpvClientEventId.PositionChanged && args.Data is double position && double.IsFinite(position) && position >= 0)
            {
                double elapsed = Stopwatch.GetElapsedTime(latest.PositionAt, now).TotalSeconds;
                if (position == latest.Position) return;
                // Clock drift or a delayed notification does not establish a seek.
                bool seek = awaitingSeekPosition;
                awaitingSeekPosition = false;
                double cadence = latest.Playing && !seek && elapsed is >= .015 and <= 2.0
                    ? latest.Cadence * .8 + elapsed * .2
                    : latest.Cadence;
                latest = latest with { Position = position, PositionAt = now, Epoch = seek ? latest.Epoch + 1 : latest.Epoch, Cadence = cadence };
            }
            else if (args.Id == MpvClientEventId.SpeedChanged && args.Data is double speed && double.IsFinite(speed) && speed > 0)
            {
                // Advance the old anchor at its original speed up to the rate
                // change. The next position event can gently correct it.
                double positionAtChange = latest.Playing
                    ? latest.Position + latest.Speed * Math.Min(Horizon(latest), Stopwatch.GetElapsedTime(latest.PositionAt, now).TotalSeconds)
                    : latest.Position;
                latest = latest with { Position = positionAtChange, Speed = speed, PositionAt = now };
            }
            else if (args.Id == MpvClientEventId.StateChanged && args.Data is MpvPlayerState state)
            {
                if (state == MpvPlayerState.Seeking) awaitingSeekPosition = true;
                bool playing = state == MpvPlayerState.Playing;
                if (latest.Playing != playing)
                    latest = latest with { Playing = playing, PositionAt = now };
            }
        }
    }

    internal Sample Read()
    {
        lock (gate) return latest;
    }

    // Give ordinary callback gaps enough room to keep moving. The explicit
    // pause, buffering and seek events still cut motion at the next render.
    internal static double Horizon(Sample sample) => Math.Clamp(sample.Cadence * 3 + .25, 1.2, 2.5);

    internal static double Rate(double current, double target, double speed)
    {
        double error = target - current;
        double drift = Math.CopySign(Math.Max(0, Math.Abs(error) - .025), error);
        return speed + Math.Clamp(drift / .8, -.20 * speed, .20 * speed);
    }
}
