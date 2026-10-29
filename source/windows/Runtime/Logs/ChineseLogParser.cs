using System.Globalization;
using System.Text.RegularExpressions;

namespace Yingyu.LogCenter;

public sealed record LogRow(string Time, string FullTime, string Place, string Level, string Kind, string Result);

internal sealed class ChineseLogParser
{
    static readonly Regex Header = new(@"^(?<time>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3} [+-]\d{2}:\d{2}) \[(?<level>[A-Z]{3,8})\] \[(?<area>[^\]\r\n]{1,128})\] ?(?<body>.*)$", RegexOptions.CultureInvariant, TimeSpan.FromMilliseconds(100));
    static readonly Regex Observed = new(@"^observedAt=(?<time>\d{2}:\d{2}:\d{2}\.\d{3});\s*", RegexOptions.CultureInvariant, TimeSpan.FromMilliseconds(100));
    static readonly Regex StartedVersion = new(@"^日志已启动；进程 \d+；版本 (?<version>\d+\.\d+\.\d+)(?:\.\d+)?[。.]?", RegexOptions.CultureInvariant, TimeSpan.FromMilliseconds(100));
    static readonly Regex EntryVersion = new(@"^appVersion=(?<version>\d+\.\d+\.\d+)(?:\.\d+)?; ", RegexOptions.CultureInvariant, TimeSpan.FromMilliseconds(100));
    DateTimeOffset? _stamp;
    string _area = "", _kind = "Info", _version = "版本未记录";
    internal void Reset(bool preserveVersion = false) { _stamp = null; _area = ""; _kind = "Info"; if (!preserveVersion) _version = "版本未记录"; }
    internal LogRow? Parse(string line)
    {
        if (string.IsNullOrWhiteSpace(line)) return null;
        line = line.TrimStart('\uFEFF');
        try
        {
            var header = Header.Match(line);
            if (header.Success)
            {
                _stamp = DateTimeOffset.TryParseExact(header.Groups["time"].Value, "yyyy-MM-dd HH:mm:ss.fff zzz", CultureInfo.InvariantCulture, DateTimeStyles.None, out var parsed) ? parsed : null;
                _area = header.Groups["area"].Value;
                _kind = header.Groups["level"].Value switch { "WARN" or "WARNING" => "Warning", "ERROR" or "FATAL" => "Error", "DEBUG" or "TRACE" => "Debug", _ => "Info" };
                // Different versions may append to the same local file. Each
                // header must carry its own evidence, never inherit a version
                // from a previous process or a truncated history segment.
                _version = "版本未记录";
                line = header.Groups["body"].Value;
                var explicitVersion = EntryVersion.Match(line);
                if (explicitVersion.Success)
                {
                    _version = explicitVersion.Groups["version"].Value;
                    line = line[explicitVersion.Length..];
                }
                if (_area == "App" && line.StartsWith("日志已启动", StringComparison.Ordinal))
                {
                    var version = StartedVersion.Match(line);
                    _version = version.Success ? version.Groups["version"].Value : "版本未记录";
                }
            }
            DateTimeOffset? stamp = _stamp;
            string time = stamp?.ToString("HH:mm:ss.fff", CultureInfo.InvariantCulture) ?? "—";
            var observed = Observed.Match(line);
            if (observed.Success)
            {
                time = observed.Groups["time"].Value;
                if (stamp.HasValue && TimeSpan.TryParseExact(time, "hh\\:mm\\:ss\\.fff", CultureInfo.InvariantCulture, out var clock))
                {
                    var actual = new DateTimeOffset(stamp.Value.Date + clock, stamp.Value.Offset);
                    if (actual - stamp.Value > TimeSpan.FromHours(12)) actual = actual.AddDays(-1);
                    stamp = actual;
                }
                line = line[observed.Length..];
            }
            string place = Place(_area);
            string result;
            if (line.Contains("event=", StringComparison.Ordinal)) (place, result) = DiagnosticChinese.Translate(line);
            else result = SensitiveText.Hide(line);
            if (result.Length == 0) return null;
            return new(time, stamp?.ToString("yyyy-MM-dd HH:mm:ss.fff", CultureInfo.InvariantCulture) ?? time, place + "（" + _version + "）",
                _kind switch { "Warning" => "警告", "Error" => "错误", "Debug" => "调试", _ => "信息" }, _kind, result);
        }
        catch (RegexMatchTimeoutException)
        {
            return new("—", "时间未记录", "日志解析（版本未记录）", "警告", "Warning", "一条记录解析超时，内容已隐藏，原日志保留。");
        }
    }
    static string Place(string area) => area switch
    {
        "App" => "软件运行", "Diagnostics" => "日志诊断", "Playback.Diagnostic" => "播放诊断",
        "Playback.Iso" => "蓝光读取", "Playback.Startup" => "播放起步", "Playback.Seek" => "进度跳转",
        "Playback.Transport" => "播放取址", "Playback.BlurayMpv" => "蓝光播放器", "Playback.BlurayBuffer" => "蓝光缓冲",
        "Playback.Native" => "播放核心", "Playback" => "播放流程", "Navigation" => "页面操作",
        "Playback.Subtitles" => "字幕状态", "Playback.Tracks" => "音轨与字幕",
        "Playback.SpeedMpv" => "倍速与缓存",
        "Playback.RouteIdentity" => "播放路线",
        "Artwork.Detail" or "DetailArtwork" => "详情大图", "Artwork.Browse" or "BrowseArtwork" => "海报墙",
        "Cache" or "PosterCache" => "图片缓存", "Settings" => "软件设置", "Auth" => "账户状态",
        _ when area.StartsWith("Playback", StringComparison.Ordinal) => "播放流程",
        _ when area.Contains("Artwork", StringComparison.OrdinalIgnoreCase) || area.Contains("Poster", StringComparison.OrdinalIgnoreCase) => "海报图片",
        _ when area.Contains("Browse", StringComparison.OrdinalIgnoreCase) || area.Contains("Library", StringComparison.OrdinalIgnoreCase) => "媒体列表",
        _ when area.Contains("Sync", StringComparison.OrdinalIgnoreCase) => "进度同步",
        _ => "软件记录"
    };
}

internal static class SensitiveText
{
    static readonly Regex[] Patterns =
    [
        new(@"\b(?:https?|ftp|smb|file|yingyu-bd)://[^\s<>""，；]+", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant, TimeSpan.FromMilliseconds(100)),
        new(@"\b\d{1,3}(?:\.\d{1,3}){3}(?::\d+)?\b", RegexOptions.CultureInvariant, TimeSpan.FromMilliseconds(100)),
        new(@"(?<!\w)[A-Z]:[\\/][^\r\n;；""<>]+|\\\\[^\r\n;；""<>]+", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant, TimeSpan.FromMilliseconds(100)),
        new(@"(?<!\w)/(?:Users|home|mnt|media|storage|volume\d*)/[^\s;；""<>]+", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant, TimeSpan.FromMilliseconds(100)),
        new(@"(?:authorization|access[_-]?token|api[_-]?key|x-emby-token|password|username|server(?:url|address)?|(?:user|account|item|media|server)(?:id|name)|令牌|账号|账户|服务器(?:地址)?|片源(?:地址)?|文件(?:路径|名)|片名)\s*[:=：]\s*[^;；\r\n]+", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant, TimeSpan.FromMilliseconds(100))
    ];
    // Native export keeps machine values and stack structure. Mask sensitive
    // values without the visual viewer's translation or line-length omission.
    internal static string HideRaw(string text)
    {
        foreach (var pattern in Patterns) text = pattern.Replace(text, "[敏感信息已隐藏]");
        return text;
    }
    internal static string Hide(string text)
    {
        if (text.Length > BoundedLines.MaxLineCharacters) return "超长记录已省略，原日志保留。";
        try
        {
            foreach (var pattern in Patterns) text = pattern.Replace(text, "[敏感信息已隐藏]");
            return text.Replace("unknown", "未记录", StringComparison.Ordinal)
                .Replace("LoadingFailed", "加载失败", StringComparison.Ordinal)
                .Replace("Buffering", "缓冲中", StringComparison.Ordinal).Replace("Seeking", "跳转中", StringComparison.Ordinal)
                .Replace("Playing", "播放中", StringComparison.Ordinal).Replace("Paused", "已暂停", StringComparison.Ordinal)
                .Replace("True", "是", StringComparison.Ordinal).Replace("False", "否", StringComparison.Ordinal);
        }
        catch (RegexMatchTimeoutException) { return "敏感信息过滤超时，内容已隐藏，原日志保留。"; }
    }
}
