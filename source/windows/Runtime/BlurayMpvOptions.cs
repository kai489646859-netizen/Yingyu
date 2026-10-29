namespace Yingyu.Update;

public static class BlurayMpvOptions
{
    public static void Append(List<string> options, string path)
    {
        EpisodePlaybackIntent.Append(options);
        DolbyHdrFallback.Append(options);
        bool bridged = Uri.TryCreate(path, UriKind.Absolute, out var uri) && uri.Scheme == "yingyu-bd";
        if (!bridged && !path.StartsWith("bd://", StringComparison.OrdinalIgnoreCase)) return;
        // Keep the same gpu-next/core/quality pipeline, prefer the Vulkan driver
        // backend for the reported D3D11 output stalls/color flashes. Both API
        // and context lists retain the original D3D11 initialization fallback.
        // loadfile joins these pairs with commas. Quote list values using MPV's
        // byte-length syntax so the next option name cannot absorb a list item.
        options.Add("gpu-api=%12%vulkan,d3d11");
        options.Add("gpu-context=%11%winvk,d3d11");
        // The reported remote-disc seek ended with hardware decoder failures
        // followed by a native fail-fast. Copy-back avoids sharing live decoder
        // surfaces with the renderer, while retaining the same core and output.
        // This is a bounded compatibility mitigation, not a proven crash cause.
        options.Add(bridged ? "hwdec=%33%nvdec-copy,d3d11va-copy,auto-copy" : "hwdec=%23%nvdec,d3d11va,auto-copy");
        options.Add("d3d11va-zero-copy=no");
        if (!bridged) return;
        // The bridge emits the selected title's MPEG-TS bytes. Let MPV handle
        // demuxing directly with the native-disc profile's analysis duration.
        // loadfile's options are file-local, automatically reset for the next file.
        options.Add("demuxer-lavf-format=mpegts");
        options.Add("demuxer-lavf-analyzeduration=1");
        // MPV owns the short seek-back buffer. Keep nearby TS probes inside
        // that buffer instead of calling the ISO bridge again for each probe.
        options.Add("stream-buffer-size=4MiB");
        options.Add("cache-pause-initial=yes");
        options.Add("cache-pause-wait=" + PlaybackSpeedPolicy.InitialBlurayWait(options));
        PlaybackTransport.Write("Info", "Playback.BlurayMpv", "内置网络蓝光使用同一 mpv 核心及回拷硬解，保留 Vulkan/D3D11 输出选择；时长/音轨探测、精确跳转及原倍速缓冲策略保留。实际后端与跳转稳定性待实播确认。 ");
    }
}
