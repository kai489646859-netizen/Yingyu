using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;

namespace Yingyu.Update;

// Retain the original opener's redirects, authentication, exact Range and
// length validation. Serialize its mutable address refresh before overlapping
// bodies. Missing optional identity disables the optimization, not playback.
internal sealed class BlurayRangeIdentity(Uri original, long length, string? initialTag,
    Func<long, long, CancellationToken, Task<HttpResponseMessage>> open,
    Action<string> report) : IDisposable
{
    readonly SemaphoreSlim _headers = new(1, 1);
    readonly string? _tag = StrongTag(initialTag);
    int _qualified, _disabled, _samples;
    internal bool CanParallel => Volatile.Read(ref _qualified) != 0 && Volatile.Read(ref _disabled) == 0;

    internal async Task<HttpResponseMessage> Open(long start, long end, CancellationToken token)
    {
        await _headers.WaitAsync(token).ConfigureAwait(false);
        HttpResponseMessage? response = null;
        try
        {
            token.ThrowIfCancellationRequested();
            try { response = await open(start, end, token).ConfigureAwait(false); }
            catch (Exception error) when (CanParallel && end - start + 1 <= BlurayReadAhead.HighRateRangeBytes
                && error.GetType().Name == "EmbyApiException"
                && error.Message.StartsWith("原盘来源未正确支持分段读取，或文件已变化。", StringComparison.Ordinal))
            {
                throw new IsoSourceChangedException("原盘分段或来源身份校验失败，请刷新片源后重试。", error);
            }
            token.ThrowIfCancellationRequested();
            var range = response.Content.Headers.ContentRange;
            if (response.StatusCode != HttpStatusCode.PartialContent || range == null
                || range.From != start || range.To != end || range.Length != length)
                throw new IsoSourceChangedException("原盘分段或长度已变化，请刷新片源后重试。");
            string? tag = response.Headers.ETag is { IsWeak: false } value ? StrongTag(value.Tag) : null;
            if (_tag != null && tag != null && tag != _tag)
                throw new IsoSourceChangedException("原盘ETag已变化，请刷新片源后重试。");
            Uri? target = response.RequestMessage?.RequestUri;
            bool external = target is { IsAbsoluteUri: true } && target.Scheme is "http" or "https"
                && string.IsNullOrEmpty(target.UserInfo)
                && !string.Equals(original.IdnHost, target.IdnHost, StringComparison.OrdinalIgnoreCase);
            bool qualified = external && _tag != null && tag == _tag;
            if (!qualified) Volatile.Write(ref _disabled, 1);
            Volatile.Write(ref _qualified, qualified ? 1 : 0);
            if (Interlocked.Increment(ref _samples) <= 12)
                Report($"event=validated-range; external={external}; strongIdentity={_tag != null && tag == _tag}; parallelEligible={CanParallel}");
            var result = response; response = null; return result;
        }
        finally { response?.Dispose(); _headers.Release(); }
    }
    static string? StrongTag(string? text) => EntityTagHeaderValue.TryParse(text, out var tag)
        && !tag.IsWeak && tag.Tag != "*" ? tag.Tag : null;
    void Report(string text) { try { report(text); } catch { } }
    public void Dispose() => _headers.Dispose();
}

internal sealed class IsoSourceChangedException(string message, Exception? inner = null) : IOException(message, inner);
