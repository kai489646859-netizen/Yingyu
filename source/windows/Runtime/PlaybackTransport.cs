using System.Diagnostics;
using System.Globalization;
using System.Reflection;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using EmbyDesktop.Core.Models;
using EmbyDesktop.Core.Services;
using FluentResults;
using Microsoft.Extensions.Logging;
using Richasy.MpvKernel.Core;
using Richasy.MpvKernel.Core.Enums;
using Richasy.MpvKernel.Core.Models;

namespace Yingyu.Update;

public static class PlaybackTransport
{
    static readonly ConditionalWeakTable<MpvClient, State> States = new();
    static readonly Lazy<Api> Native = new(() => new Api());
    public static ILogger Logger() => SafeLogger.Instance;
    internal static int Set(MpvClient client, string property, string value) => Native.Value.Set(Handle(client), property, value);
    internal static string Get(MpvClient client, string property) => Native.Value.Get(Handle(client), property);

    public static void PrepareMedia(object session)
    {
        var client = Access.Get<MpvClient?>(session, "_mpvClient");
        if (client == null || !States.TryGetValue(client, out var state)) return;
        NetworkBluray.Probing(session, true);
        double target = (Access.Get<EmbyItem>(session, "_item").UserData?.PlaybackPositionTicks ?? 0) / 10000000.0;
        // Resume seeks happen inside loadfile rather than the UI SeekAsync path.
        // Apply the same temporary refill policy after original buffer options.
        state.Speed(Access.Get<double>(session, "_currentSpeed"), client);
        if (target > 0) state.Begin(target, client);
    }

    public static string MediaAddress(Uri uri) => uri.Scheme is "http" or "https" ? uri.AbsoluteUri : uri.ToString();

    // Reuse a validated final address even when the original source has headers.
    // The original BuildPlaybackHeaders still removes cross-origin credentials.
    public static PlaybackRouteSelection Select(Uri original, MediaUriResolution resolution, bool preferred)
    {
        if (resolution.RedirectCount > 0 && (resolution.SupportsByteRanges || resolution.IsExternalRedirectHandoff)
            && resolution.Uri.Scheme is "http" or "https")
            return new PlaybackRouteSelection(resolution.Uri, resolution.Uri);
        return PlaybackRouteSelectionPolicy.Select(original, resolution, preferred);
    }

    public static void Configure(object session)
    {
        var client = Access.Get<MpvClient?>(session, "_mpvClient");
        if (client == null) return;
        var state = States.GetValue(client, _ => new State(session));
        state.NewMedia();
        PlayerFeedback.Bind(session);
        PlaybackOutput.Configure(session, client);
        PlaybackTelemetry.Start(session, client);
        // Keep the new renderer/decoder, but use the HTTP backend used by 0.5.8/6.
        // curl takes unescaped URLs literally; FFmpeg normalizes them and retains
        // the existing 302/Range, proxy and HTTP-header behavior.
        int result = Native.Value.Set(Handle(client), "curl-enabled", "no");
        if (result < 0) throw new InvalidOperationException("无法恢复兼容网络读取后端：" + result);
        result = Native.Value.Set(Handle(client), "volume-max", "300");
        if (result < 0) throw new InvalidOperationException("无法设置播放器音量上限：" + result);
        if (Access.Get<Uri>(session, "_playbackUri").Scheme is "http" or "https") PlaybackTrust.Configure(client);
        _ = client.SetLogLevelAsync(Richasy.MpvKernel.MpvLogLevel.Warn);
        Write("Info", "Playback.Transport", "使用兼容 FFmpeg 网络后端；已验证的 302 目标直接读取，沿用原跨源请求头过滤及代理设置。 ");
    }

    // Keep the original exact time-pos seek, its result type and playback reports.
    // Only shorten the refill threshold during a user seek, then restore it on restart.
    public static async Task<Result> Seek(MpvClient client, double position)
    {
        if (!States.TryGetValue(client, out var state)) return await client.SetCurrentPositionAsync(position);
        state.Begin(position, client);
        state.ArmNotice();
        try
        {
            var result = await client.SetCurrentPositionAsync(position);
            if (result.IsFailed) state.Restore();
            return result;
        }
        catch { state.Restore(); throw; }
    }

    public static void Notify(object session, MpvClientNotifyEventArgs e)
    {
        if (!Access.Get<bool>(session, "_acceptPlaybackEvents") || (bool)session.GetType().GetProperty("_isClosing",
            BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic)!.GetValue(session)!) return;
        PlaybackTelemetry.Notify(session, e);
        if(e.Id is MpvClientEventId.PlaybackRestart or MpvClientEventId.PositionChanged or MpvClientEventId.StateChanged)ColorDiagnostics.Capture(session,"property-change");
        SubtitleReliability.Notify(session, e);
        SubtitlePlacement.Notify(session,e);
        if(e.Id is MpvClientEventId.PlaybackRestart or MpvClientEventId.PositionChanged or MpvClientEventId.StateChanged) {DolbyHdrFallback.Observe(session);MediaNotice.Sample(session);}
        var client = Access.Get<MpvClient?>(session, "_mpvClient");
        if (client == null || !States.TryGetValue(client, out var state)) return;
        if (e.Id == MpvClientEventId.PlaybackRestart) { state.Complete(client); MediaNotice.Refresh(session); PlaybackOutput.Snapshot(session, client); }
        else if (e.Id == MpvClientEventId.StateChanged && e.Data is MpvPlayerState.Playing)
            state.Playing(client);
        else if (e.Id == MpvClientEventId.StateChanged && e.Data is MpvPlayerState.Buffering)
            state.Buffering(client);
        else if (e.Id == MpvClientEventId.SpeedChanged && e.Data is double speed)
            state.Speed(speed, client);
        else if (e.Id == MpvClientEventId.StateChanged && e.Data is MpvPlayerState.Paused or MpvPlayerState.Seeking)
        {
            if (e.Data is MpvPlayerState.Seeking) NetworkBluray.Probing(session, true);
            state.InterruptStartup();
        }
    }

    internal static IntPtr Handle(MpvClient client)
    {
        object handle = client.GetType().GetProperty("Handle")!.GetValue(client)!;
        return (IntPtr)handle.GetType().GetProperty("Handle")!.GetValue(handle)!;
    }
    sealed class State(object session)
    {
        readonly object _gate = new();
        readonly WeakReference<object> _session = new(session);
        string? _initial, _wait;
        long _started;
        double _target;
        int _cacheSamples;
        bool _firstRestart;
        int _bufferSamples;
        long _lastBufferSample;
        long _firstPlayingAt;
        bool _earlyRefillRaised;
        bool _earlyRefillSuppressed;
        double _speed = 1;
        string? _originalForwardBytes;
        string? _originalCacheSeconds, _originalReadAheadSeconds;
        int _budgetWarnings;
        public void ArmNotice()
        {
            if (_session.TryGetTarget(out var session)) MediaNotice.Arm(session);
        }
        public void NewMedia()
        {
            Restore();
            lock (_gate)
            {
                _firstRestart = false; _cacheSamples = _bufferSamples = 0; _lastBufferSample = 0;
                _firstPlayingAt = 0; _earlyRefillRaised = _earlyRefillSuppressed = false; _speed = 1; _originalForwardBytes = null;
                _originalCacheSeconds = _originalReadAheadSeconds = null; _budgetWarnings = 0;
            }
        }
        public void Begin(double target, MpvClient client)
        {
            if (!_session.TryGetTarget(out var current)) return;
            var uri = Access.Get<Uri>(current, "_playbackUri");
            if (uri.Scheme is not ("http" or "https" or "yingyu-bd")
                && !(Access.Get<string?>(current, "_nativeDiscPath") != null
                    && NetworkIsoMount.IsRemoteIso(Access.Get<MediaSourceInfo>(current, "_source")))) return;
            lock (_gate)
            {
                var handle = Handle(client);
                if (_firstPlayingAt != 0) _earlyRefillSuppressed = true;
                bool bluray = uri.Scheme == "yingyu-bd";
                if (bluray) NetworkBluray.Probing(current, true);
                if (_initial == null)
                {
                    // Resume runs before loadfile applies its file-local options.
                    // Saving the pre-load generic "no/1" would later overwrite
                    // the Blu-ray "yes/3" on PlaybackRestart and disable refill.
                    _initial = bluray ? "yes" : Native.Value.Get(handle, "cache-pause-initial");
                    _wait = bluray ? MediaSeconds(3) : Native.Value.Get(handle, "cache-pause-wait");
                }
                // Cache stays enabled; only this bridged Blu-ray speed budget scales.
                // The user's Blu-ray log shows cache=0 on restart followed by
                // an immediate Buffering state. Keep MPV's short initial refill
                // for this path; ordinary video retains its fast seek policy.
                Native.Value.Set(handle, "cache-pause-initial", bluray ? "yes" : "no");
                Native.Value.Set(handle, "cache-pause-wait", bluray ? MediaSeconds(1) : "0.25");
                _target = target;
                _started = Stopwatch.GetTimestamp();
            }
        }
        public void Complete(MpvClient client)
        {
            lock (_gate)
            {
                if (_session.TryGetTarget(out var session) && IsBluray(session) && _cacheSamples++ < 6)
                {
                    string Number(string key) => double.TryParse(Native.Value.Get(Handle(client), key), NumberStyles.Float,
                        CultureInfo.InvariantCulture, out double value) ? value.ToString("0.###", CultureInfo.InvariantCulture) : "未知";
                    Write("Info", "Playback.BlurayMpv", $"mpv 恢复播放；缓存时长={Number("demuxer-cache-duration")}秒，解码丢帧={Number("decoder-frame-drop-count")}，输出丢帧={Number("frame-drop-count")}；未记录片源地址。 ");
                }
                _firstRestart = true;
                // PlaybackRestart is a decoded-frame signal, not proof that
                // initial buffering finished. Keep the seek refill threshold
                // through any immediate Buffering until actual Playing.
                if (_session.TryGetTarget(out var pending) && IsBluray(pending))
                {
                    NetworkBluray.Probing(pending, false);
                    return;
                }
                if (_started == 0)
                {
                    return;
                }
                Write("Info", "Playback.Seek", $"跳转目标={_target.ToString("0.###", CultureInfo.InvariantCulture)}秒；解码器恢复耗时={Stopwatch.GetElapsedTime(_started).TotalMilliseconds:0}ms；保持精确跳转。 ");
                RestoreCore(client);
            }
        }
        public void Playing(MpvClient client)
        {
            lock (_gate)
            {
                if (!_session.TryGetTarget(out var current) || !IsBluray(current)) return;
                NetworkBluray.Probing(current, false);
                if (_firstPlayingAt == 0) _firstPlayingAt = Stopwatch.GetTimestamp();
                _firstRestart = true;
                if (_started != 0)
                    Write("Info", "Playback.Seek", $"跳转目标={_target.ToString("0.###", CultureInfo.InvariantCulture)}秒；恢复实际播放耗时={Stopwatch.GetElapsedTime(_started).TotalMilliseconds:0}ms（含缓冲）；保持精确跳转。 ");
                RestoreCore(client);
                Native.Value.Set(Handle(client), "cache-pause-wait", MediaSeconds(3));
            }
        }
        static bool IsBluray(object session) => Access.Get<Uri>(session, "_playbackUri").Scheme == "yingyu-bd";
        public void InterruptStartup()
        {
            lock (_gate) { if (_firstPlayingAt != 0) _earlyRefillSuppressed = true; }
        }
        string MediaSeconds(double seconds) => PlaybackSpeedPolicy.WaitSeconds(seconds, _speed).ToString("0.###", CultureInfo.InvariantCulture);
        public void Speed(double speed, MpvClient client)
        {
            lock (_gate)
            {
                if (!double.IsFinite(speed) || speed <= 0) return;
                _speed = speed;
                if (_session.TryGetTarget(out var current) && IsBluray(current))
                {
                    NetworkBluray.Speed(current, speed);
                    var handle = Handle(client);
                    string forward = _originalForwardBytes ?? Native.Value.Get(handle, "demuxer-max-bytes");
                    if (PlaybackSpeedPolicy.TryBytes(forward, out var original) && original > 0)
                    {
                        _originalForwardBytes ??= forward;
                        long bytes = PlaybackSpeedPolicy.ForwardBytes(original, speed);
                        SetBudget(handle, "demuxer-max-bytes", bytes.ToString(CultureInfo.InvariantCulture), "apply");
                    }
                    SetTimeBudget(handle, "cache-secs", ref _originalCacheSeconds, speed);
                    SetTimeBudget(handle, "demuxer-readahead-secs", ref _originalReadAheadSeconds, speed);
                    int waitResult = Native.Value.Set(handle, "cache-pause-wait", MediaSeconds(_firstPlayingAt == 0 || _started != 0 ? 1 : 3));
                    if (waitResult < 0) Write("Warning", "Playback.Buffer", "蓝光倍速恢复门槛设置失败；错误码=" + waitResult);
                    if (_initial != null) _wait = MediaSeconds(3);
                    string BudgetValue(string name) => PlaybackSpeedPolicy.TryBytes(Native.Value.Get(handle, name), out var bytes)
                        ? bytes.ToString(CultureInfo.InvariantCulture) : "unknown";
                    Write("Info", "Playback.Buffer", $"蓝光倍速缓存；倍速={speed.ToString(CultureInfo.InvariantCulture)}，实际容量字节={BudgetValue("demuxer-max-bytes")}，目标恢复媒体秒={MediaSeconds(_firstPlayingAt == 0 || _started != 0 ? 1 : 3)}，门槛设置结果={waitResult}；不强制暂停或改变播放速度。 ");
                }
                if (_firstPlayingAt != 0 && Math.Abs(speed - 1) >= .001) _earlyRefillSuppressed = true;
            }
        }
        void SetTimeBudget(IntPtr handle, string property, ref string? saved, double speed)
        {
            string original = saved ?? Native.Value.Get(handle, property);
            if (!PlaybackSpeedPolicy.TrySeconds(original, out double seconds)) return;
            saved ??= original;
            // Always derive from the saved session baseline, not our previous
            // target, so returning to 1x cannot retain the 3x target by accident.
            double target = PlaybackSpeedPolicy.ForwardSeconds(seconds, speed);
            SetBudget(handle, property, target.ToString("0.###", CultureInfo.InvariantCulture), "apply");
        }
        void SetBudget(IntPtr handle, string property, string value, string phase)
        {
            int result = Native.Value.Set(handle, property, value);
            if (result < 0 && _budgetWarnings++ < 6)
                Write("Warning", "Playback.Buffer", $"蓝光预读参数设置未完成；参数={property}，阶段={phase}，错误码={result}；保留实际播放与错误反馈。 ");
        }
        public void Buffering(MpvClient client)
        {
            lock (_gate)
            {
                if (!_session.TryGetTarget(out var current) || !IsBluray(current)) return;
                if (!_earlyRefillRaised && !_earlyRefillSuppressed && _firstPlayingAt != 0 && _started == 0
                    && Stopwatch.GetElapsedTime(_firstPlayingAt).TotalSeconds <= 15 && Math.Abs(_speed - 1) < .001)
                {
                    int status = Native.Value.Set(Handle(client), "cache-pause-wait", "6");
                    _earlyRefillRaised = true;
                    Write(status < 0 ? "Warning" : "Info", "Playback.Startup",
                        $"开头再次缓冲；临时媒体缓存门槛=6秒，设置结果={status}；恢复实际播放后还原3秒，沿用 mpv 已有媒体缓存读取。 ");
                }
                if (_bufferSamples >= 10) return;
                if (_lastBufferSample != 0 && Stopwatch.GetElapsedTime(_lastBufferSample).TotalSeconds < 1) return;
                _lastBufferSample = Stopwatch.GetTimestamp(); _bufferSamples++;
                string Number(string key) => double.TryParse(Native.Value.Get(Handle(client), key), NumberStyles.Float,
                    CultureInfo.InvariantCulture, out double value) ? value.ToString("0.###", CultureInfo.InvariantCulture) : "未知";
                Write("Info", "Playback.BlurayBuffer", $"mpv 缓冲；首次就绪={_firstRestart}，缓存估计={Number("demuxer-cache-duration")}秒，输入速率={Number("cache-speed")}字节/秒，解码丢帧={Number("decoder-frame-drop-count")}，输出丢帧={Number("frame-drop-count")}；仅记录数值，不记录地址。 ");
            }
        }
        public void Restore()
        {
            lock (_gate)
                if (_session.TryGetTarget(out var current) && Access.Get<MpvClient?>(current, "_mpvClient") is { } client)
                {
                    NetworkBluray.Probing(current, false);
                    RestoreCore(client);
                    if (_originalForwardBytes != null || _originalCacheSeconds != null || _originalReadAheadSeconds != null)
                    {
                        var handle = Handle(client);
                        if (_originalForwardBytes != null) SetBudget(handle, "demuxer-max-bytes", _originalForwardBytes, "restore");
                        if (_originalCacheSeconds != null) SetBudget(handle, "cache-secs", _originalCacheSeconds, "restore");
                        if (_originalReadAheadSeconds != null) SetBudget(handle, "demuxer-readahead-secs", _originalReadAheadSeconds, "restore");
                    }
                }
        }
        void RestoreCore(MpvClient client)
        {
            if (_initial != null)
            {
                var handle = Handle(client);
                if (_initial.Length > 0) Native.Value.Set(handle, "cache-pause-initial", _initial);
                if (!string.IsNullOrEmpty(_wait)) Native.Value.Set(handle, "cache-pause-wait", _wait);
            }
            _initial = _wait = null; _started = 0;
        }
    }

    internal static void Write(string level, string category, string text)
    {
        try { Assembly.Load("Yingyu").GetType("EmbyDesktop.Services.AppLog")!.GetMethod(level,
            BindingFlags.Static | BindingFlags.Public | BindingFlags.NonPublic)!.Invoke(null, new object[] { category, text }); }
        catch { }
    }
    // Allowlist diagnostics: no raw MPV text, URLs, headers or filenames persisted.
    sealed class SafeLogger : ILogger
    {
        internal static readonly SafeLogger Instance = new();
        public IDisposable? BeginScope<TState>(TState state) where TState : notnull => null;
        public bool IsEnabled(LogLevel level) => true;
        public void Log<TState>(LogLevel level, EventId id, TState state, Exception? exception, Func<TState, Exception?, string> formatter)
        {
            string text = formatter(state, exception);
            if (!text.StartsWith("[MPV] Log message:", StringComparison.Ordinal)) return;
            ColorDiagnostics.NativeMessage(text);
            if (AudioDiagnostics.Classify(text) is { } audio) AudioDiagnostics.Record(audio);
            string? category = text switch
            {
                var s when s.Contains("CUDA_ERROR_OUT_OF_MEMORY", StringComparison.Ordinal) => "CUDA 解码资源不足",
                var s when s.Contains("CUDA_ERROR_INVALID_VALUE", StringComparison.Ordinal) => "CUDA 解码参数无效",
                var s when s.Contains("CUDA_ERROR_INVALID_HANDLE", StringComparison.Ordinal) => "CUDA 解码句柄无效",
                var s when s.Contains("CUDA_ERROR_CONTEXT_IS_DESTROYED", StringComparison.Ordinal) => "CUDA 解码上下文已销毁",
                var s when s.Contains("CUDA_ERROR_NOT_SUPPORTED", StringComparison.Ordinal) => "CUDA 解码能力不支持",
                var s when s.Contains("CUDA_ERROR_UNKNOWN", StringComparison.Ordinal) => "CUDA 解码未分类错误",
                var s when s.Contains("Failed rendering", StringComparison.OrdinalIgnoreCase)
                    || s.Contains("Failed dispatching", StringComparison.OrdinalIgnoreCase)
                    || s.Contains("incompatible signature", StringComparison.OrdinalIgnoreCase)
                    || s.Contains("Peak detection usage error", StringComparison.OrdinalIgnoreCase) => "视频渲染着色器或峰值检测失败",
                var s when s.Contains("shader", StringComparison.OrdinalIgnoreCase)
                    && (s.Contains("compil", StringComparison.OrdinalIgnoreCase) && s.Contains("fail", StringComparison.OrdinalIgnoreCase)) => "视频着色器编译失败",
                var s when s.Contains("device", StringComparison.OrdinalIgnoreCase)
                    && (s.Contains("removed", StringComparison.OrdinalIgnoreCase) || s.Contains("lost", StringComparison.OrdinalIgnoreCase)) => "图形设备丢失或重置",
                var s when s.Contains("hardware", StringComparison.OrdinalIgnoreCase)
                    && (s.Contains("fail", StringComparison.OrdinalIgnoreCase) || s.Contains("error", StringComparison.OrdinalIgnoreCase)) => "硬件解码异常",
                var s when s.Contains("corrupt", StringComparison.OrdinalIgnoreCase)
                    || s.Contains("error while decoding", StringComparison.OrdinalIgnoreCase)
                    || s.Contains("reference picture missing", StringComparison.OrdinalIgnoreCase) => "解码帧或参考帧异常",
                var s when s.Contains("certificate", StringComparison.OrdinalIgnoreCase)
                    && (s.Contains("failed", StringComparison.OrdinalIgnoreCase) || s.Contains("unable", StringComparison.OrdinalIgnoreCase)) => "TLS 证书验证或证书文件读取失败",
                var s when s.Contains("handshake", StringComparison.OrdinalIgnoreCase) && s.Contains("fail", StringComparison.OrdinalIgnoreCase) => "TLS 握手失败",
                var s when s.Contains("URL", StringComparison.OrdinalIgnoreCase) && s.Contains("malformat", StringComparison.OrdinalIgnoreCase) => "媒体地址格式无效",
                var s when s.Contains("HTTP error", StringComparison.OrdinalIgnoreCase) => "HTTP 来源拒绝或暂时不可用",
                var s when s.Contains("TLS", StringComparison.OrdinalIgnoreCase) && s.Contains("error", StringComparison.OrdinalIgnoreCase) => "TLS 连接错误",
                var s when s.Contains("Failed to open", StringComparison.OrdinalIgnoreCase) => "打开媒体失败",
                var s when s.Contains("Seek failed", StringComparison.OrdinalIgnoreCase) => "来源跳转失败",
                var s when s.Contains("error reading packet", StringComparison.OrdinalIgnoreCase) => "读取媒体包失败",
                var s when s.Contains("decoder", StringComparison.OrdinalIgnoreCase) && s.Contains("fail", StringComparison.OrdinalIgnoreCase) => "解码器初始化失败",
                var s when s.Contains("filter", StringComparison.OrdinalIgnoreCase) && s.Contains("fail", StringComparison.OrdinalIgnoreCase) => "视频滤镜初始化失败",
                var s when s.Contains("VO", StringComparison.Ordinal) && s.Contains("fail", StringComparison.OrdinalIgnoreCase) => "视频输出初始化失败",
                _ => null
            };
            if (category != null) Write("Warning", "Playback.Native", category + "；原始地址及请求信息已隐藏。 ");
        }
    }
    sealed class Api
    {
        readonly IntPtr _library;
        readonly SetFn _set; readonly GetFn _get; readonly FreeFn _free;
        internal Api()
        {
            _library = LoadLibraryEx(DolbyVision.CorePath(), IntPtr.Zero, 0x1100);
            if (_library == IntPtr.Zero) throw new InvalidOperationException("网络播放组件加载失败。");
            T Get<T>(string name) where T : Delegate => Marshal.GetDelegateForFunctionPointer<T>(GetProcAddress(_library, name));
            _set=Get<SetFn>("mpv_set_property_string"); _get=Get<GetFn>("mpv_get_property_string"); _free=Get<FreeFn>("mpv_free");
        }
        internal int Set(IntPtr handle, string property, string value) => _set(handle, property, value);
        internal string Get(IntPtr handle, string property)
        {
            IntPtr text = _get(handle, property);
            if (text == IntPtr.Zero) return "";
            try { return Marshal.PtrToStringUTF8(text) ?? ""; }
            finally { _free(text); }
        }
    }
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int SetFn(IntPtr handle, [MarshalAs(UnmanagedType.LPUTF8Str)] string property, [MarshalAs(UnmanagedType.LPUTF8Str)] string value);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate IntPtr GetFn(IntPtr handle, [MarshalAs(UnmanagedType.LPUTF8Str)] string property);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate void FreeFn(IntPtr text);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode)] static extern IntPtr LoadLibraryEx(string path, IntPtr file, uint flags);
    [DllImport("kernel32.dll", CharSet=CharSet.Ansi, ExactSpelling=true)] static extern IntPtr GetProcAddress(IntPtr module, string name);
}
