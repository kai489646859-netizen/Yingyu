using System.Net;
using System.Net.Http.Headers;

namespace Yingyu.Update;

// One demand-driven HTTP body. A first real GET also establishes the file
// identity; its response is retained for the first read, never discarded for
// a second "probe" request. Seeking only opens the required new byte range.
internal sealed class VideoCacheReader : IDisposable
{
    readonly HttpClient _http;
    readonly Uri _initial;
    readonly Func<Uri, IReadOnlyDictionary<string, string>> _headers;
    readonly VideoCacheStore _cache;
    readonly string _scope;
    readonly CancellationTokenSource _cancel = new();
    readonly object _gate = new();
    HttpResponseMessage? _response;
    Stream? _body;
    Uri _current;
    string? _tag, _identity;
    VideoCacheStore.Lease? _lease;
    long _streamPosition, _responseEnd, _position;
    bool _initialized, _disposed, _seekable;
    byte[]? _hot;
    long _hotAt = -1;
    internal long Length { get; private set; }
    internal long Position => _position;
    internal VideoCacheReader(HttpClient http, Uri initial, string scope, VideoCacheStore cache,
        Func<Uri, IReadOnlyDictionary<string, string>> headers)
    { _http = http; _initial = _current = initial; _scope = scope; _cache = cache; _headers = headers; }
    internal void Initialize()
    {
        lock (_gate)
        {
            if (_initialized) return;
            Open(0); _initialized = true;
            if (_tag != null && _seekable)
            {
                _identity = VideoCacheStore.Hash(_scope, _tag, Length.ToString(System.Globalization.CultureInfo.InvariantCulture));
                try { _lease = _cache.Begin(_identity); }
                catch (Exception e) when (e is IOException or UnauthorizedAccessException)
                { _identity = null; VideoCacheSettings.Warning = "视频缓存暂不可用，继续直接播放"; }
            }
            else VideoCacheSettings.Warning = "此片源没有可靠的文件校验标记或分段读取，仅使用本次临时缓冲";
        }
    }
    void Open(long start)
    {
        _cancel.Token.ThrowIfCancellationRequested(); CloseBody();
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(_cancel.Token);
        timeout.CancelAfter(TimeSpan.FromSeconds(30));
        var seen = new HashSet<string>(StringComparer.Ordinal);
        Uri address = _current;
        for (int redirects = 0; redirects <= 8; redirects++)
        {
            if (!seen.Add(address.AbsoluteUri)) throw new IOException("视频地址循环跳转");
            if (address.Scheme is not ("http" or "https") || !string.IsNullOrEmpty(address.UserInfo)) throw new IOException("视频读取地址不支持");
            using var request = new HttpRequestMessage(HttpMethod.Get, address);
            foreach (var pair in _headers(address))
            {
                if (pair.Key.Equals("Range", StringComparison.OrdinalIgnoreCase) || pair.Key.Equals("If-Match", StringComparison.OrdinalIgnoreCase) || pair.Key.Equals("Accept-Encoding", StringComparison.OrdinalIgnoreCase)) continue;
                if (pair.Key.IndexOfAny(['\r', '\n', '\0']) >= 0 || pair.Value.IndexOfAny(['\r', '\n', '\0']) >= 0) throw new IOException("视频请求头无效");
                request.Headers.TryAddWithoutValidation(pair.Key, pair.Value);
            }
            request.Headers.Range = new RangeHeaderValue(start, null);
            request.Headers.AcceptEncoding.Add(new StringWithQualityHeaderValue("identity"));
            if (_tag != null) request.Headers.IfMatch.Add(new EntityTagHeaderValue(_tag));
            var response = _http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, timeout.Token).ConfigureAwait(false).GetAwaiter().GetResult();
            if ((int)response.StatusCode is 301 or 302 or 303 or 307 or 308)
            {
                var location = response.Headers.Location; response.Dispose();
                if (location == null) throw new IOException("视频跳转缺少目标");
                address = location.IsAbsoluteUri ? location : new Uri(address, location); continue;
            }
            try
            {
                if (response.StatusCode == HttpStatusCode.PreconditionFailed) throw new IOException("视频文件已变化，请重新打开；不会混入旧缓存");
                response.EnsureSuccessStatusCode();
                if (response.Content.Headers.ContentEncoding.Any(v => !v.Equals("identity", StringComparison.OrdinalIgnoreCase))) throw new IOException("视频字节响应被压缩，不能按原字节定位");
                var range = response.Content.Headers.ContentRange;
                long total, end;
                bool seekable = response.StatusCode == HttpStatusCode.PartialContent;
                if (seekable)
                {
                    if (range?.From != start || range.To is not { } last || range.Length is not { } size || last < start || last >= size || size <= 0
                        || response.Content.Headers.ContentLength is { } contentLength && contentLength != last - start + 1) throw new IOException("视频分段范围或长度无效");
                    total = size; end = last + 1;
                }
                else
                {
                    if (response.StatusCode != HttpStatusCode.OK || start != 0) throw new IOException("视频来源不支持所需字节定位");
                    // A server may ignore Range or stream with chunked transfer.
                    // Preserve sequential playback without persisting bytes.
                    total = response.Content.Headers.ContentLength ?? -1; end = total < 0 ? long.MaxValue : total;
                }
                string? tag = response.Headers.ETag is { IsWeak: false, Tag: not "*" } etag ? etag.Tag : null;
                if (_initialized && (Length != total || _tag != tag || _seekable != seekable)) throw new IOException("视频文件校验标记或长度变化，请重新打开；不会混入旧缓存");
                Length = total; _tag = tag; _seekable = seekable; _current = address;
                _response = response; _body = response.Content.ReadAsStream(timeout.Token); _streamPosition = start; _responseEnd = end;
                return;
            }
            catch { response.Dispose(); throw; }
        }
        throw new IOException("视频地址跳转次数超限");
    }
    internal int Read(byte[] destination, int offset, int count)
    {
        lock (_gate)
        {
            ObjectDisposedException.ThrowIf(_disposed, this); Initialize(); _cancel.Token.ThrowIfCancellationRequested();
            if (_position == Length || count == 0) return 0;
            if (!_seekable)
            {
                int n = BodyRead(destination.AsMemory(offset, Length < 0 ? count : (int)Math.Min(count, Length - _position)));
                if (n == 0 && Length >= 0 && _position < Length) throw new EndOfStreamException("视频正文提前结束");
                _position += n; _streamPosition += n; return n;
            }
            long first = _position / VideoCacheStore.BlockBytes * VideoCacheStore.BlockBytes;
            int length = (int)Math.Min(VideoCacheStore.BlockBytes, Length - first);
            _lease?.Protect(Math.Max(0, first - VideoCacheStore.BlockBytes), first + 2L * VideoCacheStore.BlockBytes);
            if (_hotAt != first)
            {
                byte[]? bytes = null;
                if (_identity != null)
                    try { bytes = _cache.Read(_identity, first, length); }
                    catch (Exception e) when (e is IOException or UnauthorizedAccessException) { VideoCacheSettings.Warning = "视频缓存读取失败，继续从片源读取"; }
                if (bytes == null)
                {
                    bytes = new byte[length];
                    if (_body == null || _streamPosition != first || _responseEnd < first + length) Open(first);
                    int filled = 0;
                    while (filled < length)
                    {
                        int n = BodyRead(bytes.AsMemory(filled, length - filled));
                        if (n == 0) throw new EndOfStreamException("视频分段正文不完整");
                        filled += n; _streamPosition += n;
                    }
                    _cancel.Token.ThrowIfCancellationRequested();
                    if (_identity != null)
                        try { _cache.Write(_identity, first, bytes); }
                        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { VideoCacheSettings.Warning = "视频缓存写入失败，继续直接播放"; }
                }
                _hot = bytes; _hotAt = first;
            }
            int from = (int)(_position - first), take = Math.Min(count, _hot!.Length - from);
            Buffer.BlockCopy(_hot, from, destination, offset, take); _position += take; return take;
        }
    }
    int BodyRead(Memory<byte> memory)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(_cancel.Token); timeout.CancelAfter(TimeSpan.FromSeconds(30));
        return _body!.ReadAsync(memory, timeout.Token).ConfigureAwait(false).GetAwaiter().GetResult();
    }
    internal long Seek(long offset)
    {
        lock (_gate)
        {
            ObjectDisposedException.ThrowIf(_disposed, this); _cancel.Token.ThrowIfCancellationRequested();
            if (offset < 0 || Length >= 0 && offset > Length || !_seekable && offset != _position) return -1;
            if (offset != _position && _body != null && offset != _streamPosition) CloseBody();
            return _position = offset;
        }
    }
    internal void Cancel() { try { _cancel.Cancel(); } catch (ObjectDisposedException) { } }
    void CloseBody() { _body?.Dispose(); _body = null; _response?.Dispose(); _response = null; }
    public void Dispose()
    {
        Cancel();
        lock (_gate)
        {
            if (_disposed) return; _disposed = true; CloseBody(); _hot = null;
            try { _lease?.Dispose(); } catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
            _http.Dispose(); _cancel.Dispose();
        }
    }
}
