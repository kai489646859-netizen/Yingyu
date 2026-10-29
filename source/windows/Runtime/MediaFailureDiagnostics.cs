namespace Yingyu.Update;

// Classify only the already-read response; never return body text or values.
public static class MediaFailureDiagnostics
{
    public static string Forbidden(string? body)
    {
        string text = body ?? "";
        if (text.Length > 65536) text = text[..65536];
        bool Has(string marker) => text.Contains(marker, StringComparison.OrdinalIgnoreCase);
        string kind = string.IsNullOrWhiteSpace(text) ? "未提供拒绝说明"
            : Has("cloudflare") || Has("error code: 1020") || Has("request blocked") || Has("web application firewall") ? "响应含访问防护标记"
            : Has("DeviceNotAllowed") || Has("device is not allowed") || Has("device access") ? "响应含设备访问限制标记"
            : Has("PlaybackNotAllowed") || Has("not allowed to play") || Has("playback is not allowed") ? "响应含播放权限限制标记"
            : Has("UnauthorizedAccessException") || Has("access denied") ? "响应含拒绝访问标记"
            : Has("nginx") ? "响应含代理拒绝标记"
            : "响应未匹配已知拒绝类别";
        return "媒体路线请求被拒绝（403）；" + kind + "。未输出响应正文，不能据此认定唯一原因。";
    }
}
