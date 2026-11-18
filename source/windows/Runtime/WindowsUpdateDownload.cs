using System.Diagnostics;
using System.Net;
using System.Net.Http.Headers;
using System.Security.Cryptography;

namespace Yingyu.Update;

internal static class WindowsUpdateDownload
{
    static readonly SemaphoreSlim Gate = new(1, 1);
    static readonly HttpClient Client = new(new SocketsHttpHandler
    {
        AllowAutoRedirect = false, UseCookies = false, ConnectTimeout = TimeSpan.FromSeconds(12)
    }) { Timeout = Timeout.InfiniteTimeSpan };

    static string DirectoryPath => Path.Combine(CachePaths.Temporary, "WindowsUpdate");

    static string InstallerPath(string root, WindowsReleaseCheck.Asset asset)
    {
        string path = Path.Combine(root, asset.Sha256, asset.Name);
        if (!CacheLayout.IsWithin(root, path)) throw new IOException("更新缓存路径无效。");
        CacheLayout.RejectLinks(path);
        return path;
    }

    internal static Task Fetch(WindowsReleaseCheck.Asset asset, IProgress<long> progress, CancellationToken token)
        => Task.Run(() => Download(Client, DirectoryPath, asset, progress, token), token);

    internal static bool AllowedHost(Uri uri) => uri.IsAbsoluteUri && uri.Scheme == Uri.UriSchemeHttps
        && uri.IsDefaultPort && uri.UserInfo.Length == 0
        && uri.IdnHost is "github.com" or "release-assets.githubusercontent.com" or "objects.githubusercontent.com";

    static async Task<HttpResponseMessage> Open(HttpClient client, Uri address, long offset, EntityTagHeaderValue? tag,
        CancellationToken token)
    {
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(token);
        deadline.CancelAfter(TimeSpan.FromSeconds(25));
        for (int i = 0; i < 5; i++)
        {
            if (!AllowedHost(address)) throw new IOException("安装包重定向到非官方地址。");
            using var request = new HttpRequestMessage(HttpMethod.Get, address);
            request.Headers.UserAgent.ParseAdd("Yingyu-Windows");
            request.Headers.AcceptEncoding.ParseAdd("identity");
            if (offset > 0 && tag is not null)
            {
                request.Headers.Range = new RangeHeaderValue(offset, null);
                request.Headers.IfRange = new RangeConditionHeaderValue(tag);
            }
            var result = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, deadline.Token)
                .ConfigureAwait(false);
            if ((int)result.StatusCode is not (301 or 302 or 303 or 307 or 308)) return result;
            using (result)
            {
                var next = result.Headers.Location ?? throw new IOException("安装包重定向缺少地址。");
                address = new Uri(address, next);
            }
        }
        throw new IOException("安装包重定向次数过多。");
    }

    static async Task<bool> Verify(Stream stream, WindowsReleaseCheck.Asset asset, CancellationToken token)
        => stream.Length == asset.Length && Convert.ToHexStringLower(
            await SHA256.HashDataAsync(stream, token).ConfigureAwait(false)) == asset.Sha256;

    static FileStream Read(string path) => new(path, FileMode.Open, FileAccess.Read, FileShare.Read,
        128 * 1024, FileOptions.Asynchronous | FileOptions.SequentialScan);

    internal static async Task Download(HttpClient client, string root, WindowsReleaseCheck.Asset asset,
        IProgress<long> progress, CancellationToken token)
    {
        await Gate.WaitAsync(token).ConfigureAwait(false);
        try
        {
            string installer = InstallerPath(root, asset);
            string partial = installer + ".part", validator = installer + ".etag";
            CacheLayout.RejectLinks(partial);
            CacheLayout.RejectLinks(validator);
            Directory.CreateDirectory(Path.GetDirectoryName(installer)!);
            if (File.Exists(installer))
            {
                bool valid;
                await using (var file = Read(installer)) valid = await Verify(file, asset, token).ConfigureAwait(false);
                if (valid) { progress.Report(asset.Length); return; }
                File.Delete(installer);
            }
            var restarted = false;
            var retry = 0;
            while (true)
            {
                try
                {
                    await FetchAttempt(client, asset, progress, token, installer, partial, validator).ConfigureAwait(false);
                    return;
                }
                catch (InvalidResumeException) when (!restarted)
                {
                    restarted = true;
                    progress.Report(0);
                    continue;
                }
                catch (Exception error) when (!token.IsCancellationRequested &&
                    (error is TemporaryDownloadException or HttpIOException or OperationCanceledException ||
                        error is HttpRequestException { HttpRequestError: HttpRequestError.ConnectionError or HttpRequestError.NameResolutionError or HttpRequestError.ResponseEnded }))
                {
                    if (retry >= RetryDelays.Length)
                        throw new IOException("下载连接多次中断，可继续下载。" + (error is TemporaryDownloadException ? " " + error.Message : ""), error);
                    await Task.Delay(RetryDelays[retry++], token).ConfigureAwait(false);
                }
            }
        }
        finally { Gate.Release(); }
    }

    static readonly TimeSpan[] RetryDelays = [TimeSpan.FromSeconds(2), TimeSpan.FromSeconds(5), TimeSpan.FromSeconds(10)];
    sealed class InvalidResumeException() : IOException("服务器未确认续传范围，请重新下载。");
    sealed class TemporaryDownloadException(string message) : IOException(message);

    static async Task FetchAttempt(HttpClient client, WindowsReleaseCheck.Asset asset,
        IProgress<long> progress, CancellationToken token, string installer, string partial, string validator)
    {
        // Each retry starts at the official Release URL to refresh its redirect.
        long offset = File.Exists(partial) ? new FileInfo(partial).Length : 0;
        if (offset == asset.Length && await Publish(partial, validator, installer, asset, token).ConfigureAwait(false))
        { progress.Report(asset.Length); return; }
        EntityTagHeaderValue? tag = null;
        if (offset > 0 && offset < asset.Length && new FileInfo(validator) is { Exists: true, Length: <= 512 })
        {
            if (!EntityTagHeaderValue.TryParse(await File.ReadAllTextAsync(validator, token).ConfigureAwait(false), out tag)
                || tag.IsWeak || tag == EntityTagHeaderValue.Any) tag = null;
        }
        if (tag is null) offset = 0;
        using var response = await Open(client, asset.Address, offset, tag, token).ConfigureAwait(false);
        if (response.StatusCode == HttpStatusCode.OK) offset = 0;
        else if (response.StatusCode == HttpStatusCode.PartialContent)
        {
            var range = response.Content.Headers.ContentRange;
            if (offset == 0 || range?.Unit != "bytes" || range.From != offset || range.To != asset.Length - 1
                || range.Length != asset.Length || !Equals(tag, response.Headers.ETag))
            {
                File.Delete(validator);
                throw new InvalidResumeException();
            }
        }
        else
        {
            int status = (int)response.StatusCode;
            if (offset > 0 && status == 416)
            {
                File.Delete(validator);
                throw new InvalidResumeException();
            }
            if (status == 429)
                throw new IOException("下载服务暂时限流（HTTP 429），请稍后继续。");
            if (status is 403 or 408 or >= 500 and <= 599)
                throw new TemporaryDownloadException($"下载服务暂时不可用（HTTP {status}）。");
            throw new IOException($"安装包服务器响应失败（HTTP {status}）。");
        }
        if (response.Content.Headers.ContentEncoding.Any(c => !c.Equals("identity", StringComparison.OrdinalIgnoreCase))
            || response.Content.Headers.ContentLength is long length && length != asset.Length - offset)
        {
            if (offset > 0) File.Delete(validator);
            throw new IOException("服务器返回的安装包长度或编码不匹配。");
        }
        await using (var output = new FileStream(partial, offset == 0 ? FileMode.Create : FileMode.Open,
            FileAccess.Write, FileShare.None, 128 * 1024, FileOptions.Asynchronous))
        {
            if (output.Length != offset) throw new IOException("安装包下载进度已改变，请重试。");
            output.Position = offset;
            if (offset == 0)
            {
                File.Delete(validator);
                if (response.Headers.ETag is { IsWeak: false } accepted && accepted != EntityTagHeaderValue.Any)
                    await File.WriteAllTextAsync(validator, accepted.ToString(), token).ConfigureAwait(false);
            }
            await using var body = await response.Content.ReadAsStreamAsync(token).ConfigureAwait(false);
            byte[] buffer = new byte[128 * 1024];
            long total = offset, lastReported = -1;
            while (true)
            {
                using var idle = CancellationTokenSource.CreateLinkedTokenSource(token);
                idle.CancelAfter(TimeSpan.FromSeconds(25));
                int count = await body.ReadAsync(buffer, idle.Token).ConfigureAwait(false);
                if (count == 0) break;
                if (count > asset.Length - total) throw new IOException("安装包大于发布记录的长度。");
                await output.WriteAsync(buffer.AsMemory(0, count), token).ConfigureAwait(false);
                total += count;
                long percent = total * 100 / asset.Length;
                if (percent != lastReported) { lastReported = percent; progress.Report(total); }
            }
            if (total != asset.Length) throw new TemporaryDownloadException("安装包下载提前结束。");
            await output.FlushAsync(token).ConfigureAwait(false);
        }
        if (!await Publish(partial, validator, installer, asset, token).ConfigureAwait(false))
            throw new IOException("安装包 SHA-256 校验失败，请重新下载。");
    }

    static async Task<bool> Publish(string partial, string validator, string installer,
        WindowsReleaseCheck.Asset asset, CancellationToken token)
    {
        bool valid;
        await using (var file = Read(partial)) valid = await Verify(file, asset, token).ConfigureAwait(false);
        token.ThrowIfCancellationRequested();
        if (valid) File.Move(partial, installer, true);
        else File.Delete(partial);
        File.Delete(validator);
        return valid;
    }

    internal static Task Install(WindowsReleaseCheck.Asset asset) => Task.Run(async () =>
    {
        await Gate.WaitAsync().ConfigureAwait(false);
        try
        {
            string path = InstallerPath(DirectoryPath, asset);
            await using var file = Read(path);
            if (!await Verify(file, asset, CancellationToken.None).ConfigureAwait(false))
                throw new IOException("安装包内容已改变，请重新下载。");
            var start = new ProcessStartInfo(path) { WorkingDirectory = Path.GetDirectoryName(path)! };
            start.ArgumentList.Add("/DIR=" + CachePaths.InstallRoot);
            start.ArgumentList.Add("/NORESTART");
            start.ArgumentList.Add("/CLOSEAPPLICATIONS");
            using var installer = Process.Start(start) ?? throw new IOException("无法启动覆盖安装程序。");
        }
        finally { Gate.Release(); }
    });
}
