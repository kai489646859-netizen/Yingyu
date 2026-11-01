using System.Net;
using System.Text;
using EmbyDesktop.Core.Services;

namespace Yingyu.Update;

// API metadata only. Never installed on media, image, ISO or cache streams.
public static class ApiResponseGuard
{
    internal const long MaximumBytes = 64L * 1024 * 1024;
    internal const int ErrorBytes = 32 * 1024;
    internal static readonly TimeSpan BodyTimeout = TimeSpan.FromSeconds(30);

    // Public server discovery owns its redirect loop and HTTPS downgrade guard.
    // Bound this response body without following redirects inside the wrapper.
    public static Task<HttpResponseMessage> SendPublicInfoAsync(HttpClient client, HttpRequestMessage request,
        HttpCompletionOption completion, CancellationToken token) => SendOne(client, request, token);

    public static async Task<HttpResponseMessage> SendAsync(HttpClient client, HttpRequestMessage request,
        HttpCompletionOption completion, CancellationToken token)
    {
        var response = await SendOne(client, request, token).ConfigureAwait(false);
        try
        {
            if (response.StatusCode is not (HttpStatusCode.TemporaryRedirect or HttpStatusCode.PermanentRedirect)) return response;
            var location = response.Headers.Location ?? throw new EmbyApiException("服务器返回了没有目标地址的重定向，请检查反向代理配置。");
            var target = location.IsAbsoluteUri ? location : new Uri(request.RequestUri!, location);
            if (target.Scheme != Uri.UriSchemeHttp && target.Scheme != Uri.UriSchemeHttps)
                throw new EmbyApiException("服务器重定向到了不受支持的地址。");
            var original = request.RequestUri!;
            if (!original.Scheme.Equals(target.Scheme, StringComparison.OrdinalIgnoreCase)
                || !original.Host.Equals(target.Host, StringComparison.OrdinalIgnoreCase) || original.Port != target.Port)
                return response; // Original caller classifies the refused cross-origin redirect.
            using var clone = await Clone(request, target, token).ConfigureAwait(false);
            response.Dispose();
            // Exactly one same-origin redirect, as in the original API client.
            return await SendOne(client, clone, token).ConfigureAwait(false);
        }
        catch { response.Dispose(); throw; }
    }

    static async Task<HttpRequestMessage> Clone(HttpRequestMessage request, Uri target, CancellationToken token)
    {
        var clone = new HttpRequestMessage(request.Method, target) { Version = request.Version, VersionPolicy = request.VersionPolicy };
        try
        {
            foreach (var header in request.Headers) clone.Headers.TryAddWithoutValidation(header.Key, header.Value);
            if (request.Content != null)
            {
                clone.Content = new ByteArrayContent(await request.Content.ReadAsByteArrayAsync(token).ConfigureAwait(false));
                foreach (var header in request.Content.Headers) clone.Content.Headers.TryAddWithoutValidation(header.Key, header.Value);
            }
            return clone;
        }
        catch { clone.Dispose(); throw; }
    }

    static async Task<HttpResponseMessage> SendOne(HttpClient client, HttpRequestMessage request, CancellationToken token)
    {
        // Successful no-content operations consume headers only. The original
        // caller still checks status and owns/disposes the response and lease.
        var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, token).ConfigureAwait(false);
        try
        {
            response.Content = new BoundedContent(response.Content);
            return response;
        }
        catch { response.Dispose(); throw; }
    }

    public static async Task<string> ReadErrorAsync(HttpContent content, CancellationToken token)
    {
        // Do not trust Content-Length, or turn a proxy error page into a huge
        // string/exception/log entry. Status-specific classification stays upstream.
        await using var stream = content is BoundedContent bounded
            ? await bounded.Open(false, token).ConfigureAwait(false)
            : new LimitedStream(await content.ReadAsStreamAsync(token).ConfigureAwait(false), MaximumBytes, BodyTimeout);
        byte[] bytes = new byte[ErrorBytes + 1];
        int used = 0;
        while (used < bytes.Length)
        {
            int read = await stream.ReadAsync(bytes.AsMemory(used), token).ConfigureAwait(false);
            if (read == 0) break;
            used += read;
        }
        Encoding encoding = Encoding.UTF8;
        try
        {
            if (content.Headers.ContentType?.CharSet is { Length: > 0 } charset)
                encoding = Encoding.GetEncoding(charset.Trim('"'));
        }
        catch (ArgumentException) { }
        using var reader = new StreamReader(new MemoryStream(bytes, 0, Math.Min(used, ErrorBytes)), encoding, true);
        return reader.ReadToEnd() + (used > ErrorBytes ? "\n[服务器错误响应过长，已截断]" : "");
    }

    sealed class BoundedContent : HttpContent
    {
        readonly HttpContent inner;
        internal BoundedContent(HttpContent content)
        {
            inner = content;
            foreach (var header in content.Headers) Headers.TryAddWithoutValidation(header.Key, header.Value);
        }
        internal async Task<Stream> Open(bool checkLength, CancellationToken token)
        {
            token.ThrowIfCancellationRequested();
            if (checkLength && inner.Headers.ContentLength > MaximumBytes) throw TooLarge();
            return new LimitedStream(await inner.ReadAsStreamAsync(token).ConfigureAwait(false), MaximumBytes, BodyTimeout);
        }
        protected override Task<Stream> CreateContentReadStreamAsync() => Open(true, CancellationToken.None);
        protected override Task<Stream> CreateContentReadStreamAsync(CancellationToken token) => Open(true, token);
        protected override Task SerializeToStreamAsync(Stream stream, TransportContext? context) => SerializeToStreamAsync(stream, context, CancellationToken.None);
        protected override async Task SerializeToStreamAsync(Stream stream, TransportContext? context, CancellationToken token)
        {
            await using var input = await Open(true, token).ConfigureAwait(false);
            await input.CopyToAsync(stream, token).ConfigureAwait(false);
        }
        protected override bool TryComputeLength(out long length) { length = 0; return false; }
        protected override void Dispose(bool disposing) { if (disposing) inner.Dispose(); base.Dispose(disposing); }
    }

    static EmbyApiException TooLarge() => new("服务器资料响应超过 64 MiB，已停止读取。请缩小查询范围或检查服务器。", null);

    // Read through the decompressed HTTP stream, with at most one sentinel byte
    // beyond the limit. A body deadline is needed: HeadersRead ends HttpClient's
    // own timeout when headers arrive. A body timeout must not trigger GET retries.
    internal sealed class LimitedStream(Stream inner, long maximum, TimeSpan timeout) : Stream
    {
        readonly CancellationTokenSource deadline = new(timeout);
        long received;
        int disposed;
        public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken token = default)
        {
            ObjectDisposedException.ThrowIf(Volatile.Read(ref disposed) != 0, this);
            if (buffer.IsEmpty) return 0;
            using var linked = CancellationTokenSource.CreateLinkedTokenSource(token, deadline.Token);
            try
            {
                int count = (int)Math.Min(buffer.Length, maximum - received + 1);
                int read = await inner.ReadAsync(buffer[..count], linked.Token).ConfigureAwait(false);
                received += read;
                if (received > maximum) throw TooLarge();
                return read;
            }
            catch (OperationCanceledException) when (!token.IsCancellationRequested && deadline.IsCancellationRequested)
            { throw new EmbyApiException("读取服务器资料超时，已停止本次读取。请稍后重试。", null); }
        }
        public override Task<int> ReadAsync(byte[] buffer, int offset, int count, CancellationToken token) => ReadAsync(buffer.AsMemory(offset, count), token).AsTask();
        public override int Read(byte[] buffer, int offset, int count) => ReadAsync(buffer.AsMemory(offset, count)).AsTask().GetAwaiter().GetResult();
        protected override void Dispose(bool disposing)
        {
            if (disposing && Interlocked.Exchange(ref disposed, 1) == 0)
            { try { inner.Dispose(); } finally { deadline.Dispose(); } }
            base.Dispose(disposing);
        }
        public override bool CanRead => Volatile.Read(ref disposed) == 0 && inner.CanRead;
        public override bool CanSeek => false;
        public override bool CanWrite => false;
        public override long Length => throw new NotSupportedException();
        public override long Position { get => received; set => throw new NotSupportedException(); }
        public override void Flush() { }
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    }
}
