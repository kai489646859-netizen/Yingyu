using EmbyDesktop.Core.Models;
using EmbyDesktop.Core.Services;

namespace Yingyu.Update;

public static class PlaybackRouteIdentity
{
    sealed record Scope(EmbyApiClient Client, string? SessionId);
    static readonly AsyncLocal<Scope?> Preparation = new();

    // Each caller supplies the same PlaybackInfoResponse used by playback
    // reports and source selection. Do not generate another session identity.
    public static Uri Build(EmbyApiClient client, string itemId, MediaSourceInfo source,
        bool forceTranscode, PlaybackInfoResponse playbackInfo)
    {
        // Retain the original static-file, authentication and refusal behavior.
        // This never consumes TranscodingUrl or an unverified DirectStreamUrl.
        Uri original;
        var previous = Preparation.Value;
        // An explicitly supplied response takes precedence even when called
        // from an outer preparation scope for the same client.
        Preparation.Value = null;
        try { original = client.BuildPlaybackUri(itemId, source, forceTranscode); }
        finally { Preparation.Value = previous; }
        return Apply(original, client, playbackInfo?.PlaySessionId);
    }

    // The original preparation method constructs its own fallback URI before
    // the optional redirect check. Carry this call's metadata into that exact
    // construction so the probe and its fallback share one session identity.
    public static async Task<Uri> Prepare(EmbyApiClient client, string itemId, MediaSourceInfo source,
        CancellationToken cancellationToken, TimeSpan? maximumWait, PlaybackInfoResponse playbackInfo)
    {
        var previous = Preparation.Value;
        Preparation.Value = new Scope(client, playbackInfo?.PlaySessionId);
        try { return await client.PreparePlaybackUriAsync(itemId, source, cancellationToken, maximumWait).ConfigureAwait(false); }
        finally { Preparation.Value = previous; }
    }

    public static Uri WithCurrent(Uri original, EmbyApiClient client)
    {
        Uri identified = WithClient(original, client);
        return Preparation.Value is { } scope && ReferenceEquals(scope.Client, client)
            ? Apply(identified, client, scope.SessionId) : identified;
    }

    static Uri WithClient(Uri original, EmbyApiClient client)
    {
        if (!Uri.TryCreate(client.ServerUrl, UriKind.Absolute, out var origin)
            || !PlaybackRouteIdentityPolicy.IsOriginalRoute(original, origin)) return original;
        var identified = (Uri)Access.Call(client, "AddClientIdentity", original)!;
        return PlaybackRouteIdentityPolicy.WithDevice(identified, origin, client.DeviceId);
    }

    static Uri Apply(Uri original, EmbyApiClient client, string? sessionId)
    {
        Uri result = original;
        if (Uri.TryCreate(client.ServerUrl, UriKind.Absolute, out var origin))
            result = PlaybackRouteIdentityPolicy.WithSession(original, origin, sessionId);
        PlaybackTransport.Write("Info", "Playback.RouteIdentity",
            "服务器原始播放路线；播放会话编号=" + (ReferenceEquals(result, original)
                ? (string.IsNullOrWhiteSpace(sessionId) ? "元数据未提供" : "原样保留") : "已补齐")
            + "；未记录编号或片源地址。 ");
        return result;
    }
}
