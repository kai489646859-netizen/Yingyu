using System.Diagnostics;
using System.Globalization;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Threading.Channels;
using EmbyDesktop.Core.Models;
using Richasy.MpvKernel;
using Richasy.MpvKernel.Core;
using Richasy.MpvKernel.Core.Enums;
using Richasy.MpvKernel.Core.Models;

namespace Yingyu.Update;

// Passive local diagnostics. No HTTP, media reads, polling of native handles,
// playback commands, configuration changes, or global keyboard hooks.
public static class PlaybackTelemetry
{
    static readonly ConditionalWeakTable<MpvClient, State> Clients = new();
    static readonly ConditionalWeakTable<object, State> Sessions = new();
    static readonly ConditionalWeakTable<object, State> Overlays = new();
    static readonly ConditionalWeakTable<MpvClient, object> Observed = new();
    static readonly object ConfigurationGate = new();
    static int _next, _warnings;
    static readonly (string Name, MpvFormat Format)[] Properties =
    [
        ("decoder-frame-drop-count", MpvFormat.Int64),
        ("frame-drop-count", MpvFormat.Int64),
        ("vo-delayed-frame-count", MpvFormat.Int64),
        ("video-bitrate", MpvFormat.Double),
        ("audio-bitrate", MpvFormat.Double),
        ("avsync", MpvFormat.Double)
    ];

    static void Fault(Exception error)
    {
        if (Interlocked.Increment(ref _warnings) <= 3)
            DiagnosticQueue.Emit("scope=diagnostics; event=local-failure; type=" + error.GetType().Name);
    }
    internal static void Emit(string value) => DiagnosticQueue.Emit(value);

    public static void Start(object session, MpvClient client)
    {
        try
        {
            if (client.IsDisposed || !client.IsInitialized) return;
            lock (ConfigurationGate)
            {
                if (Sessions.TryGetValue(session, out var previous)) previous.Close("media-reconfigured");
                if (Clients.TryGetValue(client, out var old) && !ReferenceEquals(old, previous)) old.Close("client-reconfigured");
                var state = new State(client, Interlocked.Increment(ref _next));
                Clients.Remove(client); Clients.Add(client, state);
                Sessions.Remove(session); Sessions.Add(session, state);
                var overlay = Access.Get<object?>(session, "_overlay");
                if (overlay != null) { Overlays.Remove(overlay); Overlays.Add(overlay, state); }
                var item = Access.Get<EmbyItem>(session, "_item");
                var uri = Access.Get<Uri>(session, "_playbackUri");
                string kind = uri.Scheme == "yingyu-bd" ? "network-ISO" : uri.Scheme is "http" or "https" ? "HTTP" : "local-or-mounted";
                string type = item.Type is "Movie" or "Episode" or "Video" or "Audio" ? item.Type : "other";
                double resume = (item.UserData?.PlaybackPositionTicks ?? 0) / 10000000.0;
                state.Begin(kind, type, resume, NetworkBluray.DiagnosticId(session));
                client.CacheStateChanged += state.Cache;
                if (!Observed.TryGetValue(client, out _))
                {
                    int accepted = 0;
                    for (int i = 0; i < Properties.Length; i++)
                    {
                        if (client.IsDisposed) break;
                        if ((int)MpvNative.ObserveProperty(client.Handle, 0x5949000000000000UL + (ulong)i,
                            Properties[i].Name, Properties[i].Format) >= 0) accepted++;
                    }
                    Observed.Add(client, new object());
                    state.Record("observations", $"accepted={accepted}; requested={Properties.Length}");
                }
            }
        }
        catch (Exception error) { Stop(session); Fault(error); }
    }
    public static void Stop(object session)
    {
        try { if (Sessions.TryGetValue(session, out var state)) state.Close("session-dispose"); }
        catch (Exception error) { Fault(error); }
    }
    public static void Notify(object session, MpvClientNotifyEventArgs e)
    {
        try { if (Sessions.TryGetValue(session, out var state)) state.Notify(e); }
        catch (Exception error) { Fault(error); }
    }
    // Called synchronously before the original event parser. DataPtr belongs to
    // this event only: copy a checked numeric scalar, never retain the pointer.
    public static void Property(object client, MpvEventProperty property)
    {
        try
        {
            if (client is not MpvClient mpv || !Clients.TryGetValue(mpv, out var state)) return;
            ColorDiagnostics.Property(mpv,property);
            if (property.DataPtr == IntPtr.Zero) { state.Unavailable(property.Name); return; }
            if (property.Format == MpvFormat.Int64 && property.Name is "decoder-frame-drop-count" or "frame-drop-count" or "vo-delayed-frame-count")
                state.Number(property.Name, Marshal.ReadInt64(property.DataPtr));
            else if (property.Format == MpvFormat.Double && property.Name is "video-bitrate" or "audio-bitrate" or "avsync")
                state.Number(property.Name, Marshal.PtrToStructure<double>(property.DataPtr));
        }
        catch (Exception error) { Fault(error); }
    }
    public static void Action(object session, string action, double value)
    {
        try
        {
            if (action is not ("toggle-play" or "seek" or "volume" or "speed" or "audio-track" or "subtitle-track"
                or "fullscreen" or "exit-fullscreen" or "episode" or "retry" or "close")) return;
            if (Sessions.TryGetValue(session, out var state)) state.Action(action, value);
        }
        catch (Exception error) { Fault(error); }
    }
    public static void Track(object session, string action, int? track)
        => Action(session, action, track ?? -1);
    public static void Key(object overlay, int key, bool release)
    {
        try
        {
            string? name = key switch
            {
                37 => "Left", 38 => "Up", 39 => "Right", 40 => "Down", 77 => "M",
                74 => "J", 76 => "L", 75 => "K", 8 => "Back", 32 => "Space",
                70 => "F", 27 => "Escape", 219 => "BracketLeft", 221 => "BracketRight", _ => null
            };
            if (name != null && Overlays.TryGetValue(overlay, out var state)) state.Action("key-" + name + (release ? "-end" : "-press"), double.NaN);
        }
        catch (Exception error) { Fault(error); }
    }
    static string N(double? value) => value.HasValue && double.IsFinite(value.Value) ? value.Value.ToString("0.###", CultureInfo.InvariantCulture) : "unknown";
    static double Seconds(long ticks) => (double)ticks / Stopwatch.Frequency;

    sealed class State(MpvClient client, int id)
    {
        readonly object _gate = new();
        readonly long _origin = Stopwatch.GetTimestamp();
        readonly Queue<string> _history = new();
        readonly Dictionary<string, (long At, int Count)> _actions = new();
        Timer? _timer;
        bool _closed, _first, _stall;
        MpvPlayerState? _state;
        long _lastAdvance, _lastTick, _lastOutput, _detailUntil, _bufferAt;
        int _buffers, _stalls;
        double _bufferSeconds, _position, _speed = 1;
        double? _cacheAhead, _input, _fwBytes, _videoBitrate, _audioBitrate, _avsync;
        double? _decoderDrops, _outputDrops, _delayed;
        double _seenDecoder, _seenOutput, _seenDelayed;
        long _cacheAt, _speedAt, _resourcesAt;
        int _sourceId;
        public void Begin(string kind, string type, double resume, int sourceId)
        {
            lock (_gate)
            {
                _sourceId = sourceId;
                _lastAdvance = _lastTick = Stopwatch.GetTimestamp();
                _detailUntil = _lastTick + 30 * Stopwatch.Frequency;
                Record("media-start", $"kind={kind}; type={type}; resumeSeconds={N(resume)}; source={sourceId}; normalSummarySeconds=15; anomalySampleSeconds=2");
                _timer = new Timer(_ => Tick(), null, TimeSpan.FromSeconds(2), TimeSpan.FromSeconds(2));
            }
        }
        public void Record(string kind, string details)
        {
            DiagnosticQueue.Emit($"session={id}; elapsedMs={Stopwatch.GetElapsedTime(_origin).TotalMilliseconds:0}; event={kind}; {details}");
        }
        public void Close(string reason)
        {
            lock (_gate)
            {
                if (_closed) return;
                _closed = true;
                _timer?.Dispose(); _timer = null;
                client.CacheStateChanged -= Cache;
                long now = Stopwatch.GetTimestamp();
                if (_bufferAt != 0) _bufferSeconds += Seconds(now - _bufferAt);
                string operations = string.Join(",", _actions.OrderBy(a => a.Key).Select(a => a.Key + ":" + a.Value.Count));
                Record("session-summary", $"reason={reason}; buffers={_buffers}; bufferSeconds={N(_bufferSeconds)}; suspectedStalls={_stalls}; {Snapshot(now)}; operations={operations}");
            }
        }
        public void Number(string key, double value)
        {
            if (!double.IsFinite(value)) return;
            lock (_gate)
            {
                if (_closed) return;
                switch (key)
                {
                    case "decoder-frame-drop-count": if (!_decoderDrops.HasValue) _seenDecoder = Math.Max(0, value); _decoderDrops = Math.Max(0, value); break;
                    case "frame-drop-count": if (!_outputDrops.HasValue) _seenOutput = Math.Max(0, value); _outputDrops = Math.Max(0, value); break;
                    case "vo-delayed-frame-count": if (!_delayed.HasValue) _seenDelayed = Math.Max(0, value); _delayed = Math.Max(0, value); break;
                    case "video-bitrate": _videoBitrate = value >= 0 ? value : null; break;
                    case "audio-bitrate": _audioBitrate = value >= 0 ? value : null; break;
                    case "avsync": _avsync = value; break;
                }
            }
        }
        public void Unavailable(string key)
        {
            lock (_gate)
            {
                if (_closed) return;
                switch (key)
                {
                    case "decoder-frame-drop-count": _decoderDrops = null; _seenDecoder = 0; break;
                    case "frame-drop-count": _outputDrops = null; _seenOutput = 0; break;
                    case "vo-delayed-frame-count": _delayed = null; _seenDelayed = 0; break;
                    case "video-bitrate": _videoBitrate = null; break;
                    case "audio-bitrate": _audioBitrate = null; break;
                    case "avsync": _avsync = null; break;
                }
            }
        }
        public void Cache(object? sender, MpvCacheStateEventArgs e)
        {
            try
            {
                lock (_gate)
                {
                    if (_closed) return;
                    long now = Stopwatch.GetTimestamp();
                    if (_cacheAt != 0 && Seconds(now - _cacheAt) < 1) return;
                    _cacheAt = now;
                    _fwBytes = e.FwBytes;
                    _cacheAhead = null;
                    int visited = 0;
                    foreach (var range in e.SeekableRanges)
                    {
                        if (++visited > 64) break;
                        if (_position >= range.Start && _position <= range.End)
                            _cacheAhead = Math.Max(_cacheAhead ?? 0, range.End - _position);
                    }
                }
            }
            catch (Exception error) { Fault(error); }
        }
        public void Action(string action, double value)
        {
            lock (_gate)
            {
                if (_closed) return;
                long now = Stopwatch.GetTimestamp();
                _actions.TryGetValue(action, out var old);
                _actions[action] = (old.At, old.Count + 1);
                if (action is "seek" or "retry" or "episode") _detailUntil = now + 30 * Stopwatch.Frequency;
                if (old.At != 0 && Seconds(now - old.At) < .5) return;
                _actions[action] = (now, old.Count + 1);
                Record("operation", $"action={action}; value={N(value)}; count={old.Count + 1}; positionSeconds={N(_position)}");
            }
        }
        public void Notify(MpvClientNotifyEventArgs e)
        {
            lock (_gate)
            {
                if (_closed) return;
                long now = Stopwatch.GetTimestamp();
                switch (e.Id)
                {
                    case MpvClientEventId.PositionChanged when e.Data is double position && double.IsFinite(position):
                        if (Math.Abs(position - _position) > .01)
                        {
                            _lastAdvance = now;
                            if (_stall) { _stall = false; Record("progress-resumed", Snapshot(now)); }
                        }
                        _position = position; break;
                    case MpvClientEventId.CacheSpeedChanged when e.Data is long speed:
                        _input = speed >= 0 ? speed : null; _speedAt = now; break;
                    case MpvClientEventId.SpeedChanged when e.Data is double speed:
                        _speed = double.IsFinite(speed) && speed > 0 ? speed : 1;
                        Record("speed-applied", $"speed={N(_speed)}"); break;
                    case MpvClientEventId.VolumeChanged when e.Data is double volume:
                        Action("volume-applied", volume); break;
                    case MpvClientEventId.FullScreenChanged when e.Data is bool full:
                        Record("fullscreen-applied", $"enabled={full}"); break;
                    case MpvClientEventId.PlaybackRestart:
                        Record("decoder-restart", Snapshot(now)); break;
                    case MpvClientEventId.StateChanged when e.Data is MpvPlayerState next:
                        if (_state == next) break;
                        if (_bufferAt != 0 && next != MpvPlayerState.Buffering)
                        {
                            double duration = Seconds(now - _bufferAt); _bufferSeconds += duration; _bufferAt = 0;
                            Record("buffer-end", $"durationMs={duration * 1000:0}; next={next}; {Snapshot(now)}");
                        }
                        _state = next; _lastAdvance = now; _stall = false;
                        if (next == MpvPlayerState.Buffering)
                        {
                            _bufferAt = now; _buffers++; Anomaly("buffer-start", now);
                        }
                        else if (next == MpvPlayerState.Playing && !_first)
                        {
                            _first = true; Record("first-playing", Snapshot(now));
                        }
                        else Record("state", $"value={next}; {Snapshot(now)}");
                        break;
                }
            }
        }
        string Snapshot(long now)
        {
            string age(long at) => at == 0 ? "unknown" : N(Seconds(now - at));
            return $"source={_sourceId}; state={_state?.ToString() ?? "unknown"}; positionSeconds={N(_position)}; speed={N(_speed)}; forwardBytes={N(_fwBytes)}; seekableAheadEstimateSeconds={N(_cacheAhead)}; cacheObservationAgeSeconds={age(_cacheAt)}; inputBytesPerSecondLast={N(_input)}; inputObservationAgeSeconds={age(_speedAt)}; videoBitrateBitsPerSecond={N(_videoBitrate)}; audioBitrateBitsPerSecond={N(_audioBitrate)}; avsyncSeconds={N(_avsync)}; decoderDrops={N(_decoderDrops)}; outputDrops={N(_outputDrops)}; delayedFramesEstimate={N(_delayed)}";
        }
        void Anomaly(string kind, long now)
        {
            _detailUntil = now + 30 * Stopwatch.Frequency;
            Record(kind, Snapshot(now));
            if (_history.Count > 0) Record("preceding-samples", string.Join(" | ", _history.TakeLast(4)));
        }
        void Tick()
        {
            try
            {
                lock (_gate)
                {
                    if (_closed) return;
                    long now = Stopwatch.GetTimestamp();
                    if(_resourcesAt==0||Seconds(now-_resourcesAt)>=30)
                    {
                        _resourcesAt=now;Record("process-resources",ProcessResources.Read());
                    }
                    double timerGap = Seconds(now - _lastTick); _lastTick = now;
                    double decoderDelta = Math.Max(0, (_decoderDrops ?? 0) - _seenDecoder);
                    double outputDelta = Math.Max(0, (_outputDrops ?? 0) - _seenOutput);
                    double delayedDelta = Math.Max(0, (_delayed ?? 0) - _seenDelayed);
                    _seenDecoder = _decoderDrops ?? 0; _seenOutput = _outputDrops ?? 0; _seenDelayed = _delayed ?? 0;
                    if (decoderDelta > 0 || outputDelta > 0 || delayedDelta > 0)
                    {
                        Anomaly("frame-counters-increased", now);
                        Record("frame-counter-delta", $"decoder={N(decoderDelta)}; output={N(outputDelta)}; delayedEstimate={N(delayedDelta)}; intervalSeconds={N(timerGap)}");
                    }
                    if (_state == MpvPlayerState.Playing && !_stall && Seconds(now - _lastAdvance) >= 3)
                    {
                        _stall = true; _stalls++; Anomaly("suspected-no-position-progress", now);
                    }
                    string sample = $"elapsedMs={Stopwatch.GetElapsedTime(_origin).TotalMilliseconds:0}; {Snapshot(now)}";
                    if (_history.Count == 16) _history.Dequeue();
                    _history.Enqueue(sample);
                    if (_lastOutput == 0 || Seconds(now - _lastOutput) >= (now < _detailUntil || !_first ? 2 : 15))
                    {
                        _lastOutput = now;
                        Record("sample", $"timerGapSeconds={N(timerGap)}; {Snapshot(now)}");
                    }
                }
            }
            catch (Exception error) { Fault(error); }
        }
    }

    static class DiagnosticQueue
    {
        static readonly Channel<string> Queue = Channel.CreateBounded<string>(new BoundedChannelOptions(128)
        { SingleReader = true, SingleWriter = false, FullMode = BoundedChannelFullMode.Wait });
        static readonly Lazy<Task> Worker = new(() => Task.Run(Drain));
        static long _dropped;
        internal static void Emit(string line)
        {
            try
            {
                _ = Worker.Value;
                if (line.Length > 4096) line = line[..4096];
                string record = $"observedAt={DateTimeOffset.Now:HH:mm:ss.fff}; {line}";
                if (!Queue.Writer.TryWrite(record)) Interlocked.Increment(ref _dropped);
            }
            catch { Interlocked.Increment(ref _dropped); }
        }
        static async Task Drain()
        {
            while (await Queue.Reader.WaitToReadAsync().ConfigureAwait(false))
            {
                await Task.Delay(500).ConfigureAwait(false);
                var batch = new List<string>(16);
                long dropped = Interlocked.Exchange(ref _dropped, 0);
                if (dropped > 0) batch.Add($"event=diagnostic-queue-overflow; discarded={dropped}; playback-not-blocked=true");
                while (batch.Count < 16 && Queue.Reader.TryRead(out var record)) batch.Add(record);
                if (batch.Count != 0) PlaybackTransport.Write("Info", "Playback.Diagnostic", string.Join("\n", batch));
            }
        }
    }
}

// Uses durations/byte counts already measured by the original ISO reader.
// This object owns no source, response, cache or native handle.
internal sealed class PlaybackIoTrace
{
    static int _next;
    internal readonly int Id = Interlocked.Increment(ref _next);
    readonly long _origin = Stopwatch.GetTimestamp();
    long _ranges, _reads, _bytes, _headerTicks, _readTicks, _maximumTicks, _last, _lastRangeBytes;
    int _retries;
    internal void Header(long ticks, long requestedBytes, bool preparing)
    {
        try { _ranges++; _lastRangeBytes = requestedBytes; _headerTicks += ticks; _maximumTicks = Math.Max(_maximumTicks, ticks); Flush("range", preparing, false); }
        catch { }
    }
    internal void Read(long ticks, int bytes, bool preparing)
    {
        try { _reads++; _bytes += bytes; _readTicks += ticks; _maximumTicks = Math.Max(_maximumTicks, ticks); Flush("read", preparing, false); }
        catch { }
    }
    internal void Retry(long ticks)
    {
        try { _retries++; _readTicks += ticks; _maximumTicks = Math.Max(_maximumTicks, ticks); Flush("read-retry", false, true); }
        catch { }
    }
    internal void Finish(string phase, bool preparing)
    {
        try { Flush(phase, preparing, true); }
        catch { }
    }
    void Flush(string phase, bool preparing, bool force)
    {
        long now = Stopwatch.GetTimestamp();
        int interval = preparing || Stopwatch.GetElapsedTime(_origin).TotalSeconds < 45 ? 2 : 15;
        if (!force && _last != 0 && (double)(now - _last) / Stopwatch.Frequency < interval) return;
        _last = now;
        double ms(long ticks) => ticks * 1000.0 / Stopwatch.Frequency;
        PlaybackTelemetry.Emit(FormattableString.Invariant($"source={Id}; event=ISO-IO; phase={phase}; preparing={preparing}; elapsedMs={Stopwatch.GetElapsedTime(_origin).TotalMilliseconds:0}; ranges={_ranges}; lastRangeBytes={_lastRangeBytes}; chunks={_reads}; bytes={_bytes}; headerWaitMs={ms(_headerTicks):0}; readWaitMs={ms(_readTicks):0}; longestWaitMs={ms(_maximumTicks):0}; retries={_retries}"));
    }
}
