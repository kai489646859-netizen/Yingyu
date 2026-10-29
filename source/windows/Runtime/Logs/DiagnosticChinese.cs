using System.Globalization;

namespace Yingyu.LogCenter;

internal static class DiagnosticChinese
{
    static Dictionary<string, string> Fields(string line)
    {
        var fields = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (string part in line.Split(';', 80))
        {
            int equals = part.IndexOf('=');
            if (equals > 0) fields[part[..equals].Trim()] = part[(equals + 1)..].Trim();
        }
        return fields;
    }
    static string Get(Dictionary<string, string> fields, string key) => fields.GetValueOrDefault(key, "unknown");
    static string Number(Dictionary<string, string> fields, string key, string unit = "")
        => double.TryParse(Get(fields, key), NumberStyles.Float, CultureInfo.InvariantCulture, out double value) && double.IsFinite(value)
            ? value.ToString("0.###", CultureInfo.InvariantCulture) + unit : "未记录";
    static string AudioCodec(string codec) => codec switch
    {
        "aac" => "AAC", "ac3" => "杜比数字（AC-3）", "eac3" => "杜比数字增强（E-AC-3）",
        "truehd" => "杜比无损（TRUEHD）", "dts" => "DTS", "flac" => "FLAC", "opus" => "Opus",
        "mp3" => "MP3", "alac" => "ALAC", "vorbis" => "Vorbis",
        _ when codec is "pcm_s16le" or "pcm_s24le" or "pcm_s32le" or "pcm_f32le" or "pcm_bluray" => "PCM",
        _ => "其他／未记录"
    };
    static string State(string state) => state switch
    {
        "Playing" => "播放中", "Paused" => "已暂停", "Buffering" => "缓冲中", "Seeking" => "跳转中",
        "Loading" => "加载中", "LoadingFailed" => "加载失败", "Stopped" => "已停止", "End" or "Ended" => "已结束", "Idle" => "空闲",
        "Opening" => "打开资源中", "None" => "未开始", _ => "未记录"
    };
    static string Action(string action)
    {
        if (action.StartsWith("key-", StringComparison.Ordinal))
        {
            string key = action[4..].Replace("-press", "", StringComparison.Ordinal).Replace("-end", "", StringComparison.Ordinal);
            return "播放器快捷键 · " + (key switch { "Left" => "左方向键", "Right" => "右方向键", "Up" => "上方向键", "Down" => "下方向键", "Space" => "空格键", "Escape" => "退出键", "Back" => "退格键", "BracketLeft" => "左方括号", "BracketRight" => "右方括号", "M" or "J" or "L" or "K" or "F" => key + "键", _ => "控制键" });
        }
        return action switch
        {
            "detail-play" => "详情页播放按钮", "log-center" => "设置 · 日志中心", "toggle-play" => "播放器播放／暂停",
            "seek" => "播放器进度跳转", "volume" => "播放器音量操作", "volume-applied" => "播放器音量状态",
            "speed" => "播放器倍速操作", "audio-track" => "播放器音轨操作", "subtitle-track" => "播放器字幕操作",
            "fullscreen" => "进入全屏操作", "exit-fullscreen" => "退出全屏操作", "episode" => "播放器选集操作",
            "retry" => "播放器重试操作", "close" => "播放器关闭操作", _ => "播放器操作"
        };
    }
    internal static (string Place, string Result) Translate(string line)
    {
        int history = line.IndexOf("event=preceding-samples;", StringComparison.Ordinal);
        var f = Fields(history < 0 ? line : line[..(history + "event=preceding-samples;".Length)]);
        string kind = Get(f, "event");
        string result, place = "播放诊断";
        switch (kind)
        {
            case "audio-underrun": place = "音频输出"; result = "MPV 检测到声音输出供给不足，可能发生断音；不能据此认定网络不足。"; break;
            case "audio-timestamp-reset": place = "音频时间戳"; result = "音频时间戳重置，MPV 正在重新同步播放。"; break;
            case "audio-timestamp-discontinuity": place = "音频时间戳"; result = "MPV 检测到音频时间戳不连续；可能影响声音连续性，尚不能确定来源。"; break;
            case "audio-decode-failed": place = "音频解码"; result = "MPV 报告音频帧解码或帧转换失败，可能出现断音；未记录原始媒体内容。"; break;
            case "audio-resample-failed": place = "音频采样转换"; result = "MPV 的音频采样转换失败；需要结合输入、输出采样率定位。"; break;
            case "audio-filter-failed": place = "音频处理"; result = "MPV 音频处理初始化失败。"; break;
            case "audio-init-failed": place = "音频设备"; result = "MPV 无法打开或重新初始化声音输出。"; break;
            case "audio-output-failed": place = "音频输出"; result = "向声音设备提交数据或读取设备时钟失败。"; break;
            case "audio-device-state-failed": place = "音频设备"; result = "系统声音设备启动、停止或重置失败。"; break;
            case "output-format" when Get(f, "scope") == "audio":
                place = "音频输出参数";
                result = "音轨编码=" + AudioCodec(Get(f, "codec")) + "；音轨编号=" + Number(f, "track")
                    + "；独占请求=" + (Get(f, "exclusive") switch { "yes" => "启用", "no" => "未启用", _ => "未记录" })
                    + "；输入采样率=" + Number(f, "inputRate", "赫兹") + "，声道=" + Number(f, "inputChannels")
                    + "；输出采样率=" + Number(f, "outputRate", "赫兹") + "，声道=" + Number(f, "outputChannels")
                    + "；声音输出缓冲=" + Number(f, "bufferSeconds", "秒") + "。详细格式保留在原日志，无设备名称。";
                break;
            case "byte-seek":
            case "resolved-byte-seek":
                place = "蓝光字节定位";
                result = "定位结果=" + (Get(f, "success") switch { "True" => "成功", "False" => "失败", _ => "未记录" })
                    + "；定位读取=" + Number(f, "readBytes", "字节") + "；新增分段请求=" + Number(f, "ranges") + "次。";
                break;
            case "operation":
                string action = Get(f, "action"); place = Action(action);
                result = action switch
                {
                    "detail-play" => "已点击，正在处理播放操作请求；实际状态随后记录。",
                    "log-center" => "已请求打开日志中心。",
                    "volume-applied" => "音量已更新为 " + Number(f, "value") + "。",
                    _ when action.StartsWith("key-", StringComparison.Ordinal) => action.EndsWith("-end", StringComparison.Ordinal) ? "已松开。" : "已按下，控制键事件已接受。",
                    _ => "已接收操作请求，实际结果以随后状态为准。"
                };
                if (f.ContainsKey("value") && Get(f, "value") != "unknown" && action != "volume-applied")
                    result += " 目标=" + Number(f, "value", action == "seek" ? "秒" : "") + "。";
                if (f.ContainsKey("count")) result += " 本会话同类操作累计=" + Number(f, "count") + "次。";
                break;
            case "media-start":
                place = "播放准备";
                result = "开始准备" + (Get(f, "kind") switch { "network-ISO" => "网络蓝光原盘", "HTTP" => "网络影视", "local-or-mounted" => "本地或挂载资源", _ => "媒体资源" })
                    + "；类别=" + (Get(f, "type") switch { "Movie" => "电影", "Episode" => "剧集／动漫单集", "Audio" => "音频", "Video" => "视频", _ => "其他" })
                    + "；续播位置=" + Number(f, "resumeSeconds", "秒") + "。";
                break;
            case "first-playing": place = "播放状态"; result = "已开始实际播放。" + Snapshot(f); break;
            case "state": place = "播放状态"; result = "状态已变为：" + State(Get(f, "value")) + "。" + Snapshot(f); break;
            case "buffer-start": place = "播放缓冲"; result = "开始缓冲。" + Snapshot(f); break;
            case "buffer-end": place = "播放缓冲"; result = "本次缓冲结束，耗时=" + Number(f, "durationMs", "毫秒") + "；后续状态=" + State(Get(f, "next")) + "。" + Snapshot(f); break;
            case "decoder-restart": place = "解码器恢复"; result = "解码器已恢复输出，实际播放状态另行记录。" + Snapshot(f); break;
            case "speed-applied": place = "播放器倍速状态"; result = "倍速已更新为 " + Number(f, "speed", "倍") + "。"; break;
            case "fullscreen-applied": place = "播放器全屏状态"; result = Get(f, "enabled") switch { "True" => "已进入全屏。", "False" => "已退出全屏。", _ => "全屏状态未记录。" }; break;
            case "sample": place = "播放状态采样"; result = "当前播放观测。" + Snapshot(f); break;
            case "suspected-no-position-progress": place = "进度停滞线索"; result = "疑似播放进度连续三秒未变化，需结合缓冲和丢帧判断。" + Snapshot(f); break;
            case "progress-resumed": place = "播放进度"; result = "进度已重新变化。" + Snapshot(f); break;
            case "frame-counters-increased": place = "画面丢帧线索"; result = "丢帧或延迟帧计数增加。" + Snapshot(f); break;
            case "frame-counter-delta": place = "画面丢帧增量";
                result = "本次采样间隔=" + Number(f, "intervalSeconds", "秒") + "；新增解码丢帧=" + Number(f, "decoder") + "；新增输出丢帧=" + Number(f, "output") + "；新增延迟帧估计=" + Number(f, "delayedEstimate") + "。"; break;
            case "preceding-samples":
                place = "异常前播放采样";
                int start = line.IndexOf("event=preceding-samples;", StringComparison.Ordinal);
                string samples = start < 0 ? "" : line[(start + "event=preceding-samples;".Length)..];
                result = string.Join("\n", samples.Split('|', 5).Take(4).Select((part, index) => $"此前样本{index + 1}：" + Snapshot(Fields(part))));
                break;
            case "ISO-IO":
                place = "蓝光按需读取";
                result = "阶段=" + (Get(f, "phase") switch { "range" => "分段请求", "read" => "媒体读取", "read-retry" => "读取重试", "metadata-ready" => "目录准备完成", "source-dispose" => "读取流关闭", _ => "读取统计" })
                    + "；累计请求=" + Number(f, "ranges") + "次；按需读取=" + Number(f, "bytes", "字节")
                    + "；请求头等待=" + Number(f, "headerWaitMs", "毫秒") + "；读取等待=" + Number(f, "readWaitMs", "毫秒")
                    + "；最长单次等待=" + Number(f, "longestWaitMs", "毫秒") + "；重试=" + Number(f, "retries") + "次。"; break;
            case "session-summary":
                place = "播放结束摘要";
                result = "原因=" + (Get(f, "reason") switch { "session-dispose" => "播放会话关闭", "media-reconfigured" => "媒体重新配置", "client-reconfigured" => "播放器重新配置", _ => "会话结束" })
                    + "；累计缓冲=" + Number(f, "buffers") + "次，耗时=" + Number(f, "bufferSeconds", "秒")
                    + "；疑似进度停滞=" + Number(f, "suspectedStalls") + "次。" + Snapshot(f);
                if (f.TryGetValue("operations", out var operations) && operations.Length > 0)
                    result += "\n操作统计：" + string.Join("；", operations.Split(',', 32).Select(part =>
                    { int split = part.LastIndexOf(':'); return split > 0 ? Action(part[..split]) + "=" + NumericText(part[(split + 1)..]) + "次" : ""; }).Where(part => part.Length > 0));
                break;
            case "observations": place = "诊断属性订阅"; result = "已接受 " + Number(f, "accepted") + "／" + Number(f, "requested") + " 项数值通知；不轮询原生句柄。"; break;
            case "local-failure": place = "本地诊断"; result = "本地诊断记录出现异常，类型=" + SafeType(Get(f, "type")) + "。"; break;
            case "diagnostic-queue-overflow": place = "诊断写入队列"; result = "诊断队列已满，省略 " + Number(f, "discarded") + " 条记录，播放线程未等待。"; break;
            default: place = "播放诊断"; result = "收到暂未识别的诊断记录，原日志保留。"; break;
        }
        if (f.ContainsKey("session")) result += " 会话=" + Number(f, "session") + "。";
        if (f.ContainsKey("source")) result += " 读取源序号=" + Number(f, "source") + "。";
        if (f.ContainsKey("elapsedMs")) result += " 本阶段累计=" + Number(f, "elapsedMs", "毫秒") + "。";
        if (f.ContainsKey("repeatedSincePrevious")) result += " 此前同类重复=" + Number(f, "repeatedSincePrevious") + "次。";
        return (place, SensitiveText.Hide(result));
    }
    static string NumericText(string value) => double.TryParse(value, NumberStyles.Float, CultureInfo.InvariantCulture, out double number) && double.IsFinite(number) ? number.ToString("0.###", CultureInfo.InvariantCulture) : "未记录";
    static string SafeType(string value) => value.Length <= 120 && value.All(c => char.IsAsciiLetterOrDigit(c) || c == '_') ? value : "未记录";
    static string Snapshot(Dictionary<string, string> f)
        => " 状态=" + State(Get(f, "state")) + "；播放位置=" + Number(f, "positionSeconds", "秒") + "；倍速=" + Number(f, "speed")
            + "；前向缓存=" + Number(f, "forwardBytes", "字节") + "；可跳转前向范围估计=" + Number(f, "seekableAheadEstimateSeconds", "秒")
            + "；最近输入速率=" + Number(f, "inputBytesPerSecondLast", "字节／秒")
            + "；解码丢帧=" + Number(f, "decoderDrops") + "；输出丢帧=" + Number(f, "outputDrops")
            + "；延迟帧估计=" + Number(f, "delayedFramesEstimate") + "；音画差=" + Number(f, "avsyncSeconds", "秒")
            + "；视频码率=" + Number(f, "videoBitrateBitsPerSecond", "位／秒") + "；音频码率=" + Number(f, "audioBitrateBitsPerSecond", "位／秒")
            + "；缓存观测距今=" + Number(f, "cacheObservationAgeSeconds", "秒") + "；输入观测距今=" + Number(f, "inputObservationAgeSeconds", "秒") + "。";
}
