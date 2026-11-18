using System.Globalization;
using System.Runtime.CompilerServices;
using Microsoft.UI.Xaml;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml.Controls;
using Richasy.MpvKernel.Core;

namespace Yingyu.Update;

// File-local output policy; decode, RPU and FEL processing remain unchanged.
internal static class DolbyHdrFallback
{
    static readonly ConditionalWeakTable<object,State> States=new();
    static readonly ConditionalWeakTable<object,WeakReference<object>> QualityOverlays=new();
    static readonly AsyncLocal<State?> Loading=new();
    static readonly (string Key,string Value)[] Common=[("tone-mapping-param","0.5"),("inverse-tone-mapping","no"),("target-colorspace-hint-strict","yes"),("dscale","mitchell"),("correct-downscaling","yes")];
    static readonly Lazy<WindowsHdrLease> WindowsHdr = new(() => new(
        Path.Combine(ApplicationStorage.DataRoot, "windows-hdr-restore"), WindowsHdrDisplay.ForWindow,
        WindowsHdrDisplay.ByKey, WindowsHdrDisplay.SetHdr));
    internal static bool IsFailed(object session)=>TryState(session,out var state)&&state.Failed;
    internal static bool HdrDisplayActive(object session) => TryState(session,out var state) && state.Display.HdrActive;
    internal static string Policy(object session)=>TryState(session,out var state) ? state.Output switch
    {
        HdrOutput.Hdr10 => "hdr10",
        HdrOutput.ScRgb => "hdr-scrgb",
        HdrOutput.SdrWithHighlightMapping => "sdr-bt2446a",
        HdrOutput.SdrWithDynamicMetadata => "sdr-display-mapped-scene-data",
        HdrOutput.Hdr10WithDynamicMetadata => "hdr10-display-mapped-scene-data",
        _ => "sdr"
    } : "pending";

    sealed class State(int generation, DesktopThemeOptions preferences)
    {
        internal readonly int Generation=generation;
        internal readonly DesktopThemeOptions QualityPreferences=preferences;
        internal bool Adaptive => QualityPreferences.HdrExperimental;
        internal bool Compatibility => QualityPreferences.CompatibilityRenderer && !Adaptive;
        internal bool SharedAudio, Failed;
        internal int? LiveQuality;
        internal bool QualityReduced;
        internal int QualitySlowSamples;
        internal long QualityFrames, QualitySampleTime;
        internal long Last, FirstMismatch;
        internal int Samples;

        internal HdrMedia Media;
        internal HdrOutput Output;
        internal HdrDisplay Display;
        internal string AppliedPeak = "203";
        internal string? PeakDisplayKey;
        internal int? DisplayPeak;
        internal long NextPeakRead;
        internal bool AppliedDolby, AppliedSdrDisplay;
        internal DispatcherQueueTimer? Monitor;
        internal bool Polling, BlockHdr10, BlockDynamic, BlockScRgb, BlockHighlightMapping;
        internal bool ScRgbRenderer, SceneMapper, ManageSdrMapping;
        internal long IdleSince;
        internal string VideoTrack = "";
    }

    static bool TryState(object session, out State state)
        => States.TryGetValue(session,out state!) && state.Generation==Access.Get<int>(session,"_mediaGeneration");
    static bool Current(object session, State state)
        => TryState(session,out var latest) && ReferenceEquals(latest,state);

    static IEnumerable<(string Key,string Value)> Options(State? state)
    {
        var output = state is { Adaptive:true } ? state.Output : HdrOutput.Sdr;
        return Common.Concat(HdrPlaybackPolicy.Colors(output, state?.AppliedSdrDisplay == true,
            state?.AppliedDolby == true));
    }

    internal static void RecoverWindowsHdr() => WindowsHdr.Value.Recover();

    internal static void Close(object session)
    {
        if (!States.TryGetValue(session, out var state)) return;
        States.Remove(session);
        state.Monitor?.Stop();
        WindowsHdr.Value.End(state);
    }

    internal static async Task Play(object session,Func<Task> play)
    {
        int generation = Access.Get<int>(session,"_mediaGeneration");
        var state = new State(generation,DesktopTheme.Options);
        if (States.TryGetValue(session,out var previousState)) previousState.Monitor?.Stop();
        States.AddOrUpdate(session,state);
        if (Access.Get<object?>(session,"_overlay") is FrameworkElement overlay)
        {
            QualityOverlays.Remove(overlay);
            QualityOverlays.Add(overlay,new(session));
        }

        WindowsHdr.Value.Begin(state);
        var previous = Loading.Value;
        Loading.Value = state;
        try
        {
            // Read the display even when HDR adaptation is disabled: ordinary
            // SDR may use its ICC profile, while HDR/WCG must not double-map it.
            var result = await ReadDisplay(session,state,false);
            state.Display = result.Display;
            // Use SDR at load. Confirm the actual decoded video before
            // promoting the renderer or enabling Windows HDR.
            state.Output = HdrOutput.Sdr;
            state.AppliedSdrDisplay = state.Display.Mode == DisplayColorMode.Sdr;
            if (!Current(session,state) || NativeDolby.IsClosing(session))
            {
                WindowsHdr.Value.End(state);
                return;
            }
            PlaybackFeatureLog.Write(session,"output-policy",Policy(session));
            await play();
            if (Current(session,state) && !NativeDolby.IsClosing(session)
                && Access.Get<object?>(session,"_overlay") is FrameworkElement element)
            {
                var dispatcher = element.DispatcherQueue;
                dispatcher.TryEnqueue(() =>
                {
                    if (Current(session,state) && !NativeDolby.IsClosing(session))
                        StartMonitor(session,state,dispatcher);
                });
            }
        }
        catch { WindowsHdr.Value.End(state); throw; }
        finally { Loading.Value = previous; }
    }

    static Task<WindowsHdrLease.Result> ReadDisplay(object session, State state, bool idle)
    {
        IntPtr window = WindowsHdrDisplay.Window(session);
        bool? hdrMedia = idle ? false : state.Media == HdrMedia.Unknown
            ? null : HdrPlaybackPolicy.CanRenderHdr(state.Media,DiscConversion(session));
        bool allow = state.Adaptive && state.QualityPreferences.HdrAutoSwitchWindows;
        return Task.Run(() =>
        {
            var result = WindowsHdr.Value.Prepare(state,window,hdrMedia,allow,() => Current(session,state));
            var display = result.Display;
            if (hdrMedia != true || !state.Adaptive || !display.HdrActive || display.Key is null)
            {
                state.PeakDisplayKey = null;
                return result;
            }
            long now = Environment.TickCount64;
            if (display.Key != state.PeakDisplayKey || now >= state.NextPeakRead)
            {
                state.DisplayPeak = WindowsHdrDisplay.ReadHdrPeak(window,display.Key);
                state.PeakDisplayKey = display.Key;
                state.NextPeakRead = now + 5000;
            }
            return result with { Display = display with { PeakNits = state.DisplayPeak } };
        });
    }

    static void StartMonitor(object session, State state, DispatcherQueue dispatcher)
    {
        var timer = dispatcher.CreateTimer();
        timer.Interval = TimeSpan.FromSeconds(1);
        timer.Tick += async (_,_) =>
        {
            try { await MonitorOutput(session,state,dispatcher); }
            catch (Exception error)
            {
                timer.Stop();
                WindowsHdr.Value.End(state);
                PlaybackTransport.Write("Warning","Playback.HDR","显示状态监测已结束；异常类型=" + error.GetType().Name);
            }
        };
        state.Monitor = timer;
        timer.Start();
    }

    static readonly string[] MonitorProperties =
    [
        "idle-active", "eof-reached", "seeking", "vid", "video-params/gamma",
        "video-params/colormatrix", "current-tracks/video/dolby-vision-profile",
        "video-params/scene-avg", "video-target-params/gamma",
        "video-target-params/primaries", "current-vo", "current-gpu-context", "options/tone-mapping"
    ];

    static async Task MonitorOutput(object session, State state, DispatcherQueue dispatcher)
    {
        if (!Current(session,state) || NativeDolby.IsClosing(session))
        {
            state.Monitor?.Stop();
            WindowsHdr.Value.End(state);
            return;
        }
        if (state.Polling || state.Failed
            || Access.Get<MpvClient?>(session,"_mpvClient") is not { IsDisposed:false } client) return;

        state.Polling = true;
        try
        {
            bool OwnsClient() => Current(session,state) && !NativeDolby.IsClosing(session)
                && !client.IsDisposed && ReferenceEquals(client, Access.Get<MpvClient?>(session,"_mpvClient"));
            // A busy decoder must not make this WinUI timer wait in a
            // synchronous native property call. Incomplete samples are retried.
            var properties = await ColorPropertyReader.Read(client, dispatcher, MonitorProperties, OwnsClient);
            if (!OwnsClient()) return;
            string Get(string key) => properties.TryGetValue(key, out var result) && result.Status >= 0
                ? result.Value.ToLowerInvariant() : "";
            string idleState = Get("idle-active"), eofState = Get("eof-reached");
            if (idleState is not ("yes" or "no")) return;
            bool idle = idleState == "yes" || eofState == "yes";
            long now = Environment.TickCount64;
            state.IdleSince = idle ? state.IdleSince == 0 ? now : state.IdleSince : 0;
            bool release = idle && now-state.IdleSince >= 8000;
            string seeking = Get("seeking"), track = Get("vid");
            if (seeking == "yes") Reset(state);
            bool ready = !idle && Access.Get<bool>(session,"_hasStartedPlayback")
                && Access.Get<bool>(session,"_acceptPlaybackEvents") && seeking == "no"
                && int.TryParse(track, NumberStyles.None, CultureInfo.InvariantCulture, out int videoId)
                && videoId > 0;

            if (ready)
            {
                string gamma = Get("video-params/gamma");
                var decoded = HdrPlaybackPolicy.FromDecoder(gamma,Get("video-params/colormatrix"),
                    Get("current-tracks/video/dolby-vision-profile"),Get("video-params/scene-avg"));
                bool trackChanged = state.VideoTrack.Length > 0 && state.VideoTrack != track;
                // During track switches the first poll can have a selected ID
                // but no decoded frame. Keep the current route until decoded.
                if (decoded == HdrMedia.Unknown) ready = false;
                else
                {
                    bool sceneUpdatePending = !trackChanged && decoded == HdrMedia.Hdr
                        && state.Media == HdrMedia.Hdr10Plus && gamma is ("pq" or "smpte2084");
                    if (trackChanged)
                    {
                        ResetRejectedRoutes(state);
                        Reset(state);
                    }
                    state.VideoTrack = track;
                    if (!sceneUpdatePending) state.Media = decoded;
                    var renderer = Get("current-vo");
                    var context = Get("current-gpu-context");
                    if (renderer.Length > 0) state.SceneMapper = renderer == "gpu-next";
                    // With adaptive HDR disabled, respect an existing custom
                    // curve. A route this session applied still owns its curve.
                    string toneMapping = Get("options/tone-mapping");
                    if (state.Adaptive || toneMapping.Length > 0)
                        state.ManageSdrMapping = state.Adaptive || toneMapping == "bt.2390"
                            || (HdrPlaybackPolicy.ConvertsToSdr(state.Output)
                                && toneMapping is "bt.2446a" or "st2094-40");
                    if (renderer.Length > 0 && context.Length > 0)
                        state.ScRgbRenderer = renderer == "gpu-next" && context == "d3d11";
                }
            }

            var result = await ReadDisplay(session,state,release);
            if (!OwnsClient()) return;
            // Give a just-switched Windows desktop one tick to finish the
            // swap-chain transition. The OS API result alone never enables HDR.
            if (result.Changed)
            {
                Reset(state);
                return;
            }
            if (!ready) return;

            var display = result.Display;
            if (display.Key != state.Display.Key || display.Mode != state.Display.Mode)
            {
                ResetRejectedRoutes(state);
                Reset(state);
            }
            state.Display = display;
            var desired = Select(session,state);
            if (desired != state.Output || state.AppliedDolby != (state.Media == HdrMedia.DolbyVision)
                || state.AppliedPeak != HdrPlaybackPolicy.TargetPeak(desired,display)
                || (HdrPlaybackPolicy.IsSdr(desired) && state.AppliedSdrDisplay != (display.Mode == DisplayColorMode.Sdr)))
            {
                // A display query may complete after an interactive seek.
                // Recheck only on an actual transition, via the same async IO.
                var currentTrack = await ColorPropertyReader.Read(client, dispatcher, ["seeking", "vid"], OwnsClient);
                if (OwnsClient() && !state.Failed
                    && currentTrack["seeking"] is { Status: >= 0, Value: "no" }
                    && currentTrack["vid"] is { Status: >= 0 } selected && selected.Value == track)
                    ChangeOutput(session,state,client,desired);
                return;
            }
            VerifyOutput(session,state,client,now,Get("video-target-params/gamma"),
                Get("video-target-params/primaries"));
        }
        finally { state.Polling = false; }
    }

    static void ChangeOutput(object session, State state, MpvClient client, HdrOutput desired)
    {
        bool sdrDisplay = state.Display.Mode == DisplayColorMode.Sdr;
        bool dolby = state.Media == HdrMedia.DolbyVision;
        bool Apply(HdrOutput value) => HdrPlaybackPolicy.TryApply(value,
            key => PlaybackTransport.Get(client,"options/" + key),
            (key,option) => PlaybackTransport.Set(client,"file-local-options/" + key,option) >= 0,
            Matches, sdrDisplay, dolby,
            manageToneMapping:state.Adaptive || state.ManageSdrMapping, display:state.Display);
        while (!Apply(desired))
        {
            if (desired == HdrOutput.Sdr)
            {
                Fail(session,state,client,"SDR 安全回退未获播放器确认，已暂停。");
                return;
            }
            desired = Reject(session,state,desired);
        }
        Commit();

        void Commit()
        {
            state.Output = desired;
            state.AppliedSdrDisplay = sdrDisplay;
            state.AppliedDolby = dolby;
            state.AppliedPeak = HdrPlaybackPolicy.TargetPeak(desired,state.Display);
            Reset(state);
            PlaybackFeatureLog.Write(session,"output-policy",Policy(session));
            if (!HdrPlaybackPolicy.IsSdr(desired))
                PlaybackTransport.Write("Info","Playback.HDR","HDR 渲染目标峰值（尼特）=" + state.AppliedPeak);
        }
    }
    internal static void Append(List<string> options)
    {
        // Missing load context is conservative SDR.
        foreach(var (key,value) in Options(Loading.Value))options.Add(key+"="+value);
        if(Loading.Value?.QualityPreferences is {} audioPreferences)
            HomeCinemaAudio.Append(options,audioPreferences.AudioOutputMode);
        if (Loading.Value is { Adaptive:false } state)
        {
            var preferences = state.QualityPreferences;
            string[] shaders=[];
            if(!state.Compatibility&&preferences.CustomShadersEnabled&&preferences.ShaderFiles.Length>0)
            {
                try { shaders=ShaderSettings.Available(preferences.ShaderFiles); }
                catch(Exception error) when(error is IOException or UnauthorizedAccessException)
                { PlaybackTransport.Write("Warning","Playback.Shader","无法读取已导入的 Shader，继续播放。"); }
            }
            VideoQuality.Append(options,preferences.VideoQualityPreset,false,state.Compatibility,
                preferences.CustomShadersEnabled,shaders);
            QualityConfiguration.Overlay(options,QualityConfiguration.Parse(preferences.QualityMpvOptions));
        }
    }
    internal static bool CompatibilityRequested => Loading.Value?.Compatibility==true;
    internal static bool AdaptiveRequested => Loading.Value?.Adaptive==true;
    internal static void CheckAudio(object session,MpvClient client)
    {
        if(!States.TryGetValue(session,out var state) || state.Generation!=Access.Get<int>(session,"_mediaGeneration")
            || state.SharedAudio || state.QualityPreferences.AudioOutputMode is not (1 or 2)
            || !HomeCinemaAudio.ShouldFallback(PlaybackTransport.Get(client,"aid"),
                PlaybackTransport.Get(client,"audio-out-params/format"),PlaybackTransport.Get(client,"current-ao")))return;
        state.SharedAudio=true;
        if(HomeCinemaAudio.TryShared(client))
            PlaybackTransport.Write("Info","Playback.Audio","无法确认独占或直通输出，已请求共享 PCM。");
    }
    internal static string QualityName(object session) => !States.TryGetValue(session,out var state)
        || state.Generation!=Access.Get<int>(session,"_mediaGeneration")
        ? "未提供" : state.Adaptive ? "原画" : VideoQuality.Name(state.LiveQuality??state.QualityPreferences.VideoQualityPreset)
            +(state.QualityReduced?"（自动降级）":"");

    internal static bool CycleQuality(object overlay)
    {
        if(!QualityOverlays.TryGetValue(overlay,out var link)||!link.TryGetTarget(out var session)
            ||NativeDolby.IsClosing(session)||!States.TryGetValue(session,out var state)
            ||state.Generation!=Access.Get<int>(session,"_mediaGeneration")
            ||state.Adaptive||state.Failed
            ||Access.Get<MpvClient?>(session,"_mpvClient") is not {IsDisposed:false} client
            ||!Access.Get<bool>(session,"_hasStartedPlayback"))return false;
        int next=((state.LiveQuality??state.QualityPreferences.VideoQualityPreset)+1)%VideoQuality.Labels.Length;
        if(SetQuality(state,client,next,false))
        {
            state.QualitySlowSamples=0;
            DolbyVision.ShowText(client,"画质："+VideoQuality.Name(next));
        }
        return true;
    }

    static readonly string[] QualityKeys=["scale","cscale","dscale","deband","deband-iterations","deband-threshold",
        "deband-range","deband-grain","correct-downscaling","sigmoid-upscaling","glsl-shaders"];
    static bool SetQuality(State state,MpvClient client,int preset,bool reduced)
    {
        var prefs=state.QualityPreferences;
        var values=Options(state).Select(o=>o.Key+"="+o.Value).ToList();
        VideoQuality.Append(values,preset,false,state.Compatibility,false,[]);
        if(!reduced)QualityConfiguration.Overlay(values,QualityConfiguration.Parse(prefs.QualityMpvOptions));
        string shaders="";
        if(!reduced&&!state.Compatibility&&prefs.CustomShadersEnabled)
        {
            try{shaders=string.Join(';',ShaderSettings.Available(prefs.ShaderFiles));}
            catch(IOException){return false;}
        }
        values.Add("glsl-shaders="+shaders);
        var desired=values.Select(v=>v.Split('=',2)).ToDictionary(v=>v[0],v=>v[1],StringComparer.Ordinal);
        var previous=QualityKeys.ToDictionary(key=>key,key=>PlaybackTransport.Get(client,"options/"+key));
        var written=new List<string>();
        foreach(string key in QualityKeys)
        {
            if(!desired.TryGetValue(key,out string? target))
                target=PlaybackTransport.Get(client,"option-info/"+key+"/default-value");
            if(key!="glsl-shaders"&&(target.Length==0||previous[key].Length==0))continue;
            if(Matches(previous[key],target))continue;
            if(PlaybackTransport.Set(client,"file-local-options/"+key,target)>=0)
            {
                written.Add(key);
                if(key=="glsl-shaders"||Matches(PlaybackTransport.Get(client,"options/"+key),target))continue;
            }
            foreach(string changed in written)
                PlaybackTransport.Set(client,"file-local-options/"+changed,previous[changed]);
            PlaybackTransport.Write("Warning","Playback.Quality","播放器未确认画质切换，已尝试恢复原参数。");
            return false;
        }
        state.LiveQuality=preset;state.QualityReduced=reduced;
        return true;
    }

    static void ObserveQuality(object session,State state,MpvClient client,long now)
    {
        if(state.Adaptive||state.Compatibility||state.QualityReduced||state.QualityPreferences is not {QualityAutoReduce:true}
            ||now-state.QualitySampleTime<1500)return;
        if(!long.TryParse(PlaybackTransport.Get(client,"frame-drop-count"),out long frames))return;
        bool running=PlaybackTransport.Get(client,"pause")=="no"
            &&PlaybackTransport.Get(client,"paused-for-cache")=="no";
        if(state.QualitySampleTime>0&&running&&now-state.QualitySampleTime<=3000
            &&frames>=state.QualityFrames+4)
            state.QualitySlowSamples++;
        else state.QualitySlowSamples=0;
        state.QualitySampleTime=now;state.QualityFrames=frames;
        if(state.QualitySlowSamples!=3||Access.Get<object?>(session,"_overlay") is not FrameworkElement overlay)return;
        overlay.DispatcherQueue.TryEnqueue(()=>
        {
            if(!States.TryGetValue(session,out var current)||!ReferenceEquals(current,state)||NativeDolby.IsClosing(session)
                ||state.Generation!=Access.Get<int>(session,"_mediaGeneration")||state.Adaptive||state.Failed
                ||state.QualitySlowSamples<3||client.IsDisposed
                ||!ReferenceEquals(client,Access.Get<MpvClient?>(session,"_mpvClient"))
                ||!Access.Get<bool>(session,"_acceptPlaybackEvents"))return;
            if(SetQuality(state,client,4,true))PlaybackTransport.Write("Info","Playback.Quality","持续渲染掉帧，已应用低性能画质。");
        });
    }
    internal static void Observe(object session)
    {
        if(!States.TryGetValue(session,out var state)||state.Generation!=Access.Get<int>(session,"_mediaGeneration")||state.Failed)return;
        NativeDolby.Sample(session);
        var native=NativeDolby.Read(session);
        var client=Access.Get<MpvClient?>(session,"_mpvClient");if(client is null||client.IsDisposed)return;
        if(native.Fatal)
        {
            Fail(session, state, client,
                "杜比播放已暂停："+NativeDolby.Why(native.Reason)+"。可以重试或导出诊断日志。",
                pausedByCore: true);
            return;
        }
        long now=Environment.TickCount64;if(now-state.Last<500)return;state.Last=now;
        if(!Access.Get<bool>(session,"_hasStartedPlayback")||!Access.Get<bool>(session,"_acceptPlaybackEvents"))return;
        if(state.Adaptive||state.Compatibility||state.QualityReduced||!state.QualityPreferences.QualityAutoReduce)return;
        if(PlaybackTransport.Get(client,"seeking")=="yes"){state.QualitySampleTime=0;state.QualitySlowSamples=0;return;}
        ObserveQuality(session,state,client,now);
    }

    static void VerifyOutput(object session, State state, MpvClient client, long now,
        string transfer, string primaries)
    {
        if (transfer.Length==0 || primaries.Length==0) return;
        if (HdrPlaybackPolicy.Confirms(state.Output,transfer,primaries)) { Reset(state); return; }
        if (state.FirstMismatch==0) state.FirstMismatch=now;
        if (++state.Samples<3 || now-state.FirstMismatch<2000) return;

        if (state.Output == HdrOutput.Sdr)
        {
            Fail(session,state,client,"SDR 色彩输出未被确认；已暂停，避免以错误色彩播放。请导出日志。");
            return;
        }
        ChangeOutput(session,state,client,Reject(session,state,state.Output));
    }

    static bool DiscConversion(object session) => Access.Get<string?>(session,"_nativeDiscPath") != null
        || Access.Get<Uri?>(session,"_playbackUri")?.Scheme == "yingyu-bd";

    static HdrOutput Select(object session, State state) => HdrPlaybackPolicy.Select(state.Adaptive,
        state.Media,state.Display,false,state.BlockHdr10,state.BlockDynamic,preferBase:DiscConversion(session),
        scRgbAvailable:state.ScRgbRenderer && !state.BlockScRgb, sceneMapperAvailable:state.SceneMapper,
        manageSdrMapping:state.ManageSdrMapping, highlightMappingRejected:state.BlockHighlightMapping);

    static HdrOutput Reject(object session, State state, HdrOutput output)
    {
        if (output == HdrOutput.Hdr10) state.BlockHdr10 = true;
        else if (output == HdrOutput.ScRgb) state.BlockScRgb = true;
        else if (output == HdrOutput.SdrWithHighlightMapping) state.BlockHighlightMapping = true;
        else state.BlockDynamic = true;
        return Select(session,state);
    }

    static void ResetRejectedRoutes(State state)
        => state.BlockDynamic = state.BlockHdr10 = state.BlockScRgb = state.BlockHighlightMapping = false;

    static void Reset(State state){state.FirstMismatch=0;state.Samples=0;}
    static bool Matches(string actual,string expected)
        =>actual==expected||double.TryParse(actual,NumberStyles.Float,CultureInfo.InvariantCulture,out var a)
            &&double.TryParse(expected,NumberStyles.Float,CultureInfo.InvariantCulture,out var b)&&Math.Abs(a-b)<1e-6;
    static void Fail(object session, State state, MpvClient client, string message,
        bool pausedByCore = false)
    {
        state.Failed = true;
        PlaybackFeatureLog.Write(session, pausedByCore ? "dolby-integrity" : "hdr-route",
            pausedByCore ? "required-layer-blocked" : "output-unconfirmed-blocked",
            null, pausedByCore ? "NativeIntegrityFailure" : "OutputNotConfirmed");
        PlaybackFeatureLog.Output(session, "output-rejected");
        PlaybackTransport.Write("Warning", "Playback.DolbyVision", message);
        if (Access.Get<object?>(session, "_overlay") is not FrameworkElement overlay) return;
        overlay.DispatcherQueue.TryEnqueue(() =>
        {
            if (!Current(session, state) || NativeDolby.IsClosing(session)
                || !ReferenceEquals(client, Access.Get<MpvClient?>(session, "_mpvClient"))
                || client.IsDisposed || !Access.Get<bool>(session, "_acceptPlaybackEvents"))
                return;

            // A native integrity failure has already paused MPV. Avoid sending
            // a second synchronous command from the WinUI dispatcher.
            int result = pausedByCore ? 0 : PlaybackTransport.Set(client, "pause", "yes");
            state.Monitor?.Stop();
            WindowsHdr.Value.End(state);
            try
            {
                if (!overlay.IsLoaded || overlay.XamlRoot is null
                    || !ReferenceEquals(overlay, Access.Get<object?>(session, "_overlay"))
                    || Access.Get<bool>(overlay, "_updateDisconnected")) return;
                Access.Call(overlay, "ShowPlaybackFailure",
                    message + (result < 0 ? " 暂停请求未被接受，请退出播放。" : ""));
            }
            catch (Exception error) when (InvalidPlayerUi(error))
            {
                PlaybackTransport.Write("Warning", "Playback.UI",
                    "播放器错误提示界面已失效；HRESULT=0x"
                    + (error.InnerException ?? error).HResult.ToString("X8") + "。");
            }
        });
    }

    static bool InvalidPlayerUi(Exception error)
    {
        if (error is System.Reflection.TargetInvocationException { InnerException: { } inner })
            error = inner;
        return error.HResult is unchecked((int)0x80070057) or unchecked((int)0x80000013);
    }
}
