namespace Yingyu.Update;

public static class BlurayMpvOptions
{
    public static void Append(List<string> options, string path)
    {
        EpisodePlaybackIntent.Append(options);
        DolbyHdrFallback.Append(options);
        OfflineViewing.Append(options,path);
        bool bridged = Uri.TryCreate(path, UriKind.Absolute, out var uri) && uri.Scheme == "yingyu-bd";
        bool disc = bridged || path.StartsWith("bd://", StringComparison.OrdinalIgnoreCase);
        if (DolbyHdrFallback.CompatibilityRequested)
        {
            options.Add("vo=%12%gpu,gpu-next");
            options.Add("gpu-api=d3d11");
            options.Add("gpu-context=d3d11");
            options.Add(disc ? "hwdec=%23%d3d11va-copy,dxva2-copy" : "hwdec=%18%d3d11va,dxva2-copy");
            options.Add("d3d11va-zero-copy=no");
        }
        else
        {
            // Prefer the Windows D3D11 color-space negotiation for HDR, with
            // winvk as an initialization fallback. Preserve the disc decoder.
            if (DolbyHdrFallback.AdaptiveRequested)
            {
                options.Add("vo=gpu-next");
                options.Add("gpu-api=%12%d3d11,vulkan");
                options.Add("gpu-context=%11%d3d11,winvk");
            }
            else if (disc)
            {
                options.Add("gpu-api=%12%vulkan,d3d11");
                options.Add("gpu-context=%11%winvk,d3d11");
            }
            if (disc)
            {
                options.Add(bridged ? "hwdec=%33%nvdec-copy,d3d11va-copy,auto-copy" : "hwdec=%23%nvdec,d3d11va,auto-copy");
                options.Add("d3d11va-zero-copy=no");
            }
        }
        if (!disc && uri is { Scheme: "https" or "http" }) AppendNetworkFileProbe(options, uri);
        if (!bridged)
        {
            AppendMountedStartup(options, disc);
            return;
        }
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
        PlaybackTransport.Write("Info", "Playback.BlurayMpv", DolbyHdrFallback.CompatibilityRequested
            ? "网络蓝光请求 D3D11 兼容渲染及回拷硬解。"
            : DolbyHdrFallback.AdaptiveRequested ? "网络蓝光 HDR 路径优先请求 D3D11，保留 Vulkan 初始化回退。"
            : "网络蓝光优先请求 Vulkan，保留 D3D11 初始化回退及回拷硬解。");
    }

    internal static void AppendMountedStartup(List<string> options, bool mountedDisc)
    {
        if (!mountedDisc) return;
        // Submit the decoded target frame without the initial cache gate.
        // MPV still pauses on a real underrun using the existing refill target.
        options.RemoveAll(option => option.StartsWith("cache-pause-initial=", StringComparison.Ordinal));
        options.Add("cache-pause-initial=no");
    }

    internal static void AppendNetworkFileProbe(List<string> options, Uri address)
    {
        string extension = Path.GetExtension(address.AbsolutePath).ToLowerInvariant();
        if (extension is (".mp4" or ".m4v") &&
            !options.Any(option => option.StartsWith("demuxer-lavf-probe-info=", StringComparison.Ordinal)))
            options.Add("demuxer-lavf-probe-info=auto");
        if (extension == ".mkv" &&
            !options.Any(option => option.StartsWith("demuxer-mkv-probe-start-time=", StringComparison.Ordinal)))
            options.Add("demuxer-mkv-probe-start-time=no");
    }
}
