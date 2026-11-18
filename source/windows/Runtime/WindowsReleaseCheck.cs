using System.Net.Http.Headers;
using System.Reflection;
using System.Text.Json;

namespace Yingyu.Update;

internal static class WindowsReleaseCheck
{
    const string Repository = "kai489646859-netizen/Yingyu";
    const string Prefix = "windows-v";
    static readonly HttpClient Client = new(new HttpClientHandler { AllowAutoRedirect = false })
    {
        Timeout = TimeSpan.FromSeconds(10),
        MaxResponseContentBufferSize = 2 * 1024 * 1024
    };
    internal sealed record Asset(string Name, Uri Address, long Length, string Sha256);
    internal sealed record Release(Version Version, Uri Page, Asset? Installer);

    internal static async Task<Release?> Check()
    {
        using var request = new HttpRequestMessage(HttpMethod.Get,
            $"https://api.github.com/repos/{Repository}/releases?per_page=30");
        request.Headers.UserAgent.ParseAdd("Yingyu-Windows");
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/vnd.github+json"));
        request.Headers.Add("X-GitHub-Api-Version", "2022-11-28");
        using var response = await Client.SendAsync(request).ConfigureAwait(false);
        if ((int)response.StatusCode is 403 or 429)
            throw new InvalidOperationException("GitHub 暂时限制了更新查询，请稍后重试。");
        response.EnsureSuccessStatusCode();
        using var json = JsonDocument.Parse(await response.Content.ReadAsByteArrayAsync().ConfigureAwait(false));
        string installed = typeof(WindowsReleaseCheck).Assembly
            .GetCustomAttribute<AssemblyInformationalVersionAttribute>()!.InformationalVersion.Split('+')[0];
        return FindNewer(json.RootElement, Version.Parse(installed));
    }

    internal static Release? FindNewer(JsonElement releases, Version installed)
    {
        Release? best = null;
        foreach (var release in releases.EnumerateArray())
        {
            if (!release.TryGetProperty("draft", out var draft) || draft.ValueKind != JsonValueKind.False
                || !release.TryGetProperty("prerelease", out var preview) || preview.ValueKind != JsonValueKind.False
                || !release.TryGetProperty("tag_name", out var tag) || tag.ValueKind != JsonValueKind.String
                || tag.GetString() is not {} name || !name.StartsWith(Prefix, StringComparison.Ordinal)
                || !Version.TryParse(name[Prefix.Length..], out var version) || version <= installed
                || best is not null && version <= best.Version
                || !release.TryGetProperty("assets", out var assets) || assets.ValueKind != JsonValueKind.Array)
                continue;
            string installer = $"Yingyu-Setup-x64-{version}.exe";
            string releasePath = $"https://github.com/{Repository}/releases";
            var address = new Uri($"{releasePath}/download/{name}/{installer}");
            foreach (var asset in assets.EnumerateArray())
            {
                if (!asset.TryGetProperty("name", out var file) || file.ValueKind != JsonValueKind.String
                    || file.GetString() != installer) continue;
                Asset? verified = null;
                if (asset.TryGetProperty("state", out var state) && state.ValueKind == JsonValueKind.String
                    && state.GetString() == "uploaded" && asset.TryGetProperty("size", out var size)
                    && size.ValueKind == JsonValueKind.Number && size.TryGetInt64(out long length)
                    && length is > 0 and <= 2L * 1024 * 1024 * 1024
                    && asset.TryGetProperty("digest", out var digest) && digest.ValueKind == JsonValueKind.String
                    && digest.GetString() is { Length: 71 } hash && hash.StartsWith("sha256:", StringComparison.Ordinal)
                    && hash[7..].All(Uri.IsHexDigit)
                    && asset.TryGetProperty("browser_download_url", out var url) && url.ValueKind == JsonValueKind.String
                    && url.GetString() == address.AbsoluteUri)
                    verified = new(installer, address, length, hash[7..].ToLowerInvariant());
                best = new(version, new Uri($"{releasePath}/tag/{name}"), verified);
                break;
            }
        }
        return best;
    }
}
