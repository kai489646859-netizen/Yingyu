namespace Yingyu.Update;

// Only add the PlaybackInfo identity to the server's static original-file route.
// Redirect targets, signed external URLs, local files and disc callbacks retain
// their exact address. The original escaped query is never reconstructed.
public static class PlaybackRouteIdentityPolicy
{
    public static Uri WithSession(Uri uri, Uri origin, string? sessionId) => WithParameter(uri, origin, "PlaySessionId", sessionId);
    public static Uri WithDevice(Uri uri, Uri origin, string? deviceId) => WithParameter(uri, origin, "DeviceId", deviceId);
    public static bool IsOriginalRoute(Uri uri, Uri origin)
    {
        if (!uri.IsAbsoluteUri || !origin.IsAbsoluteUri
            || uri.Scheme is not ("http" or "https")
            || !uri.Scheme.Equals(origin.Scheme, StringComparison.OrdinalIgnoreCase)
            || !uri.Host.Equals(origin.Host, StringComparison.OrdinalIgnoreCase) || uri.Port != origin.Port)
            return false;
        var path = uri.AbsolutePath.Split('/', StringSplitOptions.RemoveEmptyEntries);
        if (path.Length < 3 || !path[^3].Equals("Videos", StringComparison.OrdinalIgnoreCase)
            || !(path[^1].Equals("stream", StringComparison.OrdinalIgnoreCase)
                || path[^1].StartsWith("stream.", StringComparison.OrdinalIgnoreCase))) return false;
        bool staticFile = false;
        foreach (string pair in uri.Query.TrimStart('?').Split('&', StringSplitOptions.RemoveEmptyEntries))
        {
            int separator = pair.IndexOf('=');
            string name = Uri.UnescapeDataString(separator < 0 ? pair : pair[..separator]);
            if (!name.Equals("static", StringComparison.OrdinalIgnoreCase)) continue;
            string value = separator < 0 ? "" : Uri.UnescapeDataString(pair[(separator + 1)..]);
            if (!value.Equals("true", StringComparison.OrdinalIgnoreCase)) return false;
            staticFile = true;
        }
        return staticFile;
    }
    static Uri WithParameter(Uri uri, Uri origin, string parameter, string? value)
    {
        if (string.IsNullOrWhiteSpace(value) || !IsOriginalRoute(uri, origin)) return uri;
        foreach (string pair in uri.Query.TrimStart('?').Split('&', StringSplitOptions.RemoveEmptyEntries))
        {
            int separator = pair.IndexOf('=');
            string name = Uri.UnescapeDataString(separator < 0 ? pair : pair[..separator]);
            if (name.Equals(parameter, StringComparison.OrdinalIgnoreCase)) return uri;
        }
        string text = uri.AbsoluteUri;
        int fragment = text.IndexOf('#');
        string address = fragment < 0 ? text : text[..fragment];
        string suffix = fragment < 0 ? "" : text[fragment..];
        string separatorText = address.EndsWith('&') || address.EndsWith('?') ? "" : "&";
        return new Uri(address + separatorText + parameter + "=" + Uri.EscapeDataString(value) + suffix);
    }
}
