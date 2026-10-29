using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Runtime.CompilerServices;
using EmbyDesktop.Core.Services;

namespace Yingyu.Update;

// Cache only raw ISO bytes already demanded by the unchanged reader. The
// original authenticated opener remains responsible for every network range.
public static class VideoCacheIso
{
    static readonly ConditionalWeakTable<object, Scope> Sources = new();
    static readonly ConditionalWeakTable<object, SemaphoreSlim> HeaderGates = new();
    sealed record Scope(string Value);
    public static void BindSource(object source)
    {
        if (VideoCache.CurrentIsoScope is { } scope) Sources.GetValue(source, _ => new Scope(scope));
    }
    public static Task<HttpResponseMessage> OpenRange(object source, long start, long end, CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        if (VideoCacheSettings.LimitGB == 0 || !Sources.TryGetValue(source, out var scope)) return Original(source, start, end, token);
        long total = ((NetworkIsoSource)source).Length;
        string? tag = Access.Get<string?>(source, "_etag");
        // The existing startup probe has not completed yet, or its validator
        // is unavailable: use it verbatim, never revive another open's bytes.
        if (total <= 0 || !EntityTagHeaderValue.TryParse(tag, out var etag) || etag.IsWeak || etag.Tag == "*") return Original(source, start, end, token);
        if (start < 0 || end < start || end >= total) throw new IOException("原盘缓存读取范围无效");
        VideoCacheStore store;
        try { store = VideoCacheSettings.Store; }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        { VideoCacheSettings.Warning = "视频缓存暂不可用，继续直接播放"; return Original(source, start, end, token); }
        string identity = VideoCacheStore.Hash(scope.Value, etag.Tag, total.ToString(System.Globalization.CultureInfo.InvariantCulture));
        var response = new HttpResponseMessage(HttpStatusCode.PartialContent)
        {
            RequestMessage = new HttpRequestMessage(HttpMethod.Get, Access.Get<Uri>(source, "_current")),
            Content = new StreamContent(new RangeStream(source, start, end, total, etag.Tag, identity, store, token))
        };
        response.Headers.ETag = etag;
        response.Content.Headers.ContentRange = new ContentRangeHeaderValue(start, end, total);
        response.Content.Headers.ContentLength = end - start + 1;
        return Task.FromResult(response);
    }
    static async Task<HttpResponseMessage> Original(object source, long start, long end, CancellationToken token)
    {
        // Cached responses defer actual HTTP opening until their first miss.
        // Serialize the original source's mutable redirect/refresh headers even
        // when two independent validated bodies are allowed to overlap.
        var gate = HeaderGates.GetValue(source, _ => new SemaphoreSlim(1, 1));
        await gate.WaitAsync(token).ConfigureAwait(false);
        try { return await ((Task<HttpResponseMessage>)Access.Call(source, "OpenRangeWithoutVideoCacheAsync", start, end, token)!).ConfigureAwait(false); }
        finally { gate.Release(); }
    }

    sealed class RangeStream : Stream
    {
        const int Block = 64 * 1024;
        readonly object _source;
        readonly long _end, _total;
        readonly string _tag, _identity;
        readonly VideoCacheStore _store;
        readonly CancellationToken _token;
        VideoCacheStore.Lease? _lease;
        HttpResponseMessage? _response;
        Stream? _body;
        long _cursor, _networkAt;
        byte[]? _hot;
        long _hotAt;
        bool _disposed;
        internal RangeStream(object source, long start, long end, long total, string tag, string identity, VideoCacheStore store, CancellationToken token)
        {
            _source = source; _cursor = start; _end = end; _total = total; _tag = tag; _identity = identity; _store = store; _token = token;
            try { _lease = _store.Begin(identity); }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { VideoCacheSettings.Warning = "视频缓存暂不可用，继续直接播放"; }
        }
        public override int Read(byte[] buffer, int offset, int count)
        {
            ObjectDisposedException.ThrowIf(_disposed, this); _token.ThrowIfCancellationRequested();
            if (_cursor > _end || count == 0) return 0;
            if (_hot == null || _cursor < _hotAt || _cursor >= _hotAt + _hot.Length)
            {
                long first = _cursor / Block * Block;
                int size = (int)Math.Min(Block, _total - first);
                _lease?.Protect(Math.Max(0, first - Block), first + 2L * Block);
                byte[]? bytes = null;
                if (_lease != null)
                    try { bytes = _store.Read(_identity, first, size); }
                    catch (Exception e) when (e is IOException or UnauthorizedAccessException) { VideoCacheSettings.Warning = "视频缓存读取失败，继续从片源读取"; }
                _hotAt = bytes == null ? _cursor : first;
                if (bytes == null)
                {
                    int needed = (int)Math.Min(Block - _cursor % Block, _end - _cursor + 1);
                    bytes = new byte[needed];
                    if (_body == null || _networkAt != _cursor)
                    {
                        _body?.Dispose(); _response?.Dispose();
                        _response = Original(_source, _cursor, _end, _token).ConfigureAwait(false).GetAwaiter().GetResult();
                        var range = _response.Content.Headers.ContentRange;
                        if (_response.StatusCode != HttpStatusCode.PartialContent || range?.From != _cursor || range.To != _end || range.Length != _total ||
                            _response.Headers.ETag is not { IsWeak: false } current || current.Tag != _tag)
                            throw new IsoSourceChangedException("原盘来源校验变化，不能混用已缓存视频片段");
                        _body = _response.Content.ReadAsStream(_token); _networkAt = _cursor;
                    }
                    int filled = 0;
                    while (filled < needed)
                    {
                        int n = _body.ReadAsync(bytes.AsMemory(filled), _token).ConfigureAwait(false).GetAwaiter().GetResult();
                        if (n == 0) throw new EndOfStreamException("原盘缓存分段正文不完整");
                        filled += n; _networkAt += n;
                    }
                    _token.ThrowIfCancellationRequested();
                    if (_lease != null && _hotAt == first && bytes.Length == size)
                        try { _store.Write(_identity, first, bytes); }
                        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { VideoCacheSettings.Warning = "视频缓存写入失败，继续直接播放"; }
                }
                _hot = bytes;
            }
            int from = (int)(_cursor - _hotAt), take = (int)Math.Min(Math.Min(count, _hot!.Length - from), _end - _cursor + 1);
            Buffer.BlockCopy(_hot, from, buffer, offset, take); _cursor += take; return take;
        }
        public override ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            byte[] temporary = new byte[Math.Min(buffer.Length, Block)];
            int count = Read(temporary, 0, temporary.Length); temporary.AsMemory(0, count).CopyTo(buffer); return ValueTask.FromResult(count);
        }
        public override Task<int> ReadAsync(byte[] buffer, int offset, int count, CancellationToken cancellationToken)
        { cancellationToken.ThrowIfCancellationRequested(); return Task.FromResult(Read(buffer, offset, count)); }
        protected override void Dispose(bool disposing)
        {
            if (!_disposed && disposing)
            {
                _disposed = true; _body?.Dispose(); _response?.Dispose(); _hot = null;
                try { _lease?.Dispose(); } catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
            }
            base.Dispose(disposing);
        }
        public override bool CanRead => !_disposed;
        public override bool CanSeek => false;
        public override bool CanWrite => false;
        public override long Length => _end + 1;
        public override long Position { get => _cursor; set => throw new NotSupportedException(); }
        public override void Flush() { }
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    }
}
