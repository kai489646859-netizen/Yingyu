using System.Net;
using System.Net.Http.Headers;

namespace Yingyu.Update;

public static class OfflineResume
{
    public static void Verify(HttpResponseMessage response, long offset, string? savedETag)
    {
        // A 200 follows the existing restart-from-zero path. Only a 206 is
        // eligible to be appended to a partially downloaded file.
        if (response.StatusCode != HttpStatusCode.PartialContent) return;
        var range = response.Content.Headers.ContentRange;
        if (range?.Unit != "bytes" || range.From != offset || range.To is not long end
            || range.Length is not long total || end < offset || end != total - 1
            || response.Content.Headers.ContentLength is long bodyLength && bodyLength != total - offset
            || response.Content.Headers.ContentEncoding.Any(encoding =>
                !encoding.Equals("identity", StringComparison.OrdinalIgnoreCase)))
            throw new InvalidDataException("服务器返回的下载范围不完整，已保留原下载进度。");

        if (offset > 0 && (!EntityTagHeaderValue.TryParse(savedETag, out var expected)
            || expected.IsWeak || expected == EntityTagHeaderValue.Any
            || response.Headers.ETag is not { IsWeak: false } actual || !actual.Equals(expected)))
            throw new InvalidDataException("服务器未确认续传文件与原文件一致，已保留原下载进度。");
    }
}
