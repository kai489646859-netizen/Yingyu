using System.Diagnostics;

namespace Yingyu.Update;

internal static class AudioDiagnostics
{
    static readonly object Gate = new();
    static readonly Dictionary<string, (long At, int Skipped)> Recent = new();
    internal static string? Classify(string text)
    {
        bool Has(string value) => text.Contains(value, StringComparison.OrdinalIgnoreCase);
        if (Has("Audio device underrun detected") || Has("Under-run: Device delay") || Has("Unable to fill buffer fast enough"))
            return "audio-underrun";
        if (Has("Reset playback due to audio timestamp reset")) return "audio-timestamp-reset";
        // These are emitted by this bundled MPV's ad_lavc, decoder wrapper,
        // and f_swresample paths. They previously fell through the allowlist.
        if (Has("Invalid audio PTS:")) return "audio-timestamp-discontinuity";
        if (Has("Error decoding audio.") || Has("Converting libavcodec frame to mpv frame failed."))
            return "audio-decode-failed";
        if (Has("Error on resampling.") || Has("libswresample failed to initialize.")
            || Has("Cannot open Libavresample context.")) return "audio-resample-failed";
        if (Has("Audio filter initialized failed")) return "audio-filter-failed";
        if (Has("Error reinitializing audio") || Has("Could not open/initialize audio device")) return "audio-init-failed";
        if (Has("Error feeding audio") || Has("Error writing audio to device") || Has("Error getting device delay")) return "audio-output-failed";
        if (Has("IAudioClient_Stop returned") || Has("IAudioClient_Start returned") || Has("IAudioClient_Reset returned")) return "audio-device-state-failed";
        return null;
    }
    internal static void Record(string category)
    {
        int skipped = 0;
        lock (Gate)
        {
            long now = Stopwatch.GetTimestamp();
            if (Recent.TryGetValue(category, out var old))
            {
                if (Stopwatch.GetElapsedTime(old.At, now).TotalSeconds < 1)
                {
                    Recent[category] = (old.At, Math.Min(old.Skipped + 1, 1000000));
                    return;
                }
                skipped = old.Skipped;
            }
            Recent[category] = (now, 0);
        }
        // Existing bounded asynchronous queue; never wait for disk on MPV's event thread.
        PlaybackTelemetry.Emit($"scope=audio; event={category}; repeatedSincePrevious={skipped}");
    }
}
