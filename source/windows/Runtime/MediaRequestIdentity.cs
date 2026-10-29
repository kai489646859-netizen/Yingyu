using System.Net.Http;
using System.Reflection;
using System.Runtime.ExceptionServices;
using EmbyDesktop.Core.Services;

namespace Yingyu.Update;

// Construct the same local user-authentication message as the existing API.
// Sending, redirects and native media reading remain in their original paths.
public static class MediaRequestIdentity
{
    static readonly MethodInfo AuthRequest = typeof(EmbyApiClient).GetMethod("CreateRequest",
        BindingFlags.Instance | BindingFlags.NonPublic, binder: null,
        types: new[] { typeof(HttpMethod), typeof(Uri), typeof(bool) }, modifiers: null)
        ?? throw new MissingMethodException(typeof(EmbyApiClient).FullName, "CreateRequest(HttpMethod,Uri,bool)");

    public static Dictionary<string, string> BuildHeaders(Uri original, Uri target,
        IReadOnlyDictionary<string, string>? required, EmbyApiClient client)
    {
        var headers = EmbyApiClient.BuildEffectivePlaybackHeaders(original, target, required);
        if (!Uri.TryCreate(client.ServerUrl, UriKind.Absolute, out var server)
            || !SameOrigin(original, server) || !SameOrigin(target, server)
            || (headers.ContainsKey("X-Emby-Authorization") && headers.ContainsKey("X-Emby-Token")))
            return headers;

        using var request = CreateAuthenticatedRequest(client, target);
        foreach (string name in new[] { "X-Emby-Authorization", "X-Emby-Token" })
        {
            // BuildEffectivePlaybackHeaders uses an ordinal-ignore-case copy,
            // so a valid custom media header always retains its precedence.
            if (!headers.ContainsKey(name) && request.Headers.TryGetValues(name, out var values))
                headers[name] = string.Join(", ", values);
        }
        return headers;
    }

    // The existing ISO source receives both original and prepared addresses.
    // Store server authentication against original; its shared header filter
    // removes sensitive fields before any external redirect destination.
    public static Task<NetworkIsoMount> PrepareIso(Uri original, Uri prepared,
        IReadOnlyDictionary<string, string> required, string cacheDirectory, string rclonePath,
        CancellationToken cancellationToken, EmbyApiClient client) =>
        NetworkIsoMount.StartAsync(original, prepared, BuildHeaders(original, original, required, client),
            cacheDirectory, rclonePath, cancellationToken);

    static bool SameOrigin(Uri a, Uri b) => a.IsAbsoluteUri && b.IsAbsoluteUri
        && (a.Scheme.Equals(Uri.UriSchemeHttp, StringComparison.OrdinalIgnoreCase)
            || a.Scheme.Equals(Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase))
        && a.Scheme.Equals(b.Scheme, StringComparison.OrdinalIgnoreCase)
        && a.Host.Equals(b.Host, StringComparison.OrdinalIgnoreCase) && a.Port == b.Port;

    static HttpRequestMessage CreateAuthenticatedRequest(EmbyApiClient client, Uri uri)
    {
        try
        {
            return (HttpRequestMessage?)AuthRequest.Invoke(client, new object[] { HttpMethod.Get, uri, true })
                ?? throw new InvalidOperationException("Existing API request factory returned no request.");
        }
        catch (TargetInvocationException error) when (error.InnerException is { } original)
        {
            ExceptionDispatchInfo.Capture(original).Throw();
            throw;
        }
    }
}
