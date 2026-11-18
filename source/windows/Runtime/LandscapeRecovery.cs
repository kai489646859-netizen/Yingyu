namespace Yingyu.Update;

internal static class LandscapeRecovery
{
    // Three bounded in-place checks. The second check passes the cache
    // service's 30-second per-file cooldown after a failed network request.
    internal static TimeSpan Delay(int retry,TimeSpan serverDelay)
    {
        var interval=retry switch
        {
            0=>TimeSpan.FromSeconds(4),
            1=>TimeSpan.FromSeconds(31),
            2=>TimeSpan.FromSeconds(45),
            _=>TimeSpan.Zero
        };
        if(interval==TimeSpan.Zero||serverDelay>TimeSpan.FromMinutes(2))return TimeSpan.Zero;
        return interval>=serverDelay?interval:serverDelay;
    }

    internal static Uri? Original(Uri source)
    {
        if (source.Scheme is not ("http" or "https")) return null;
        var path = source.AbsolutePath.Split('/', StringSplitOptions.RemoveEmptyEntries);
        int suffix = path.Length - 1;
        if (suffix >= 0 && int.TryParse(path[suffix], out int index) && index >= 0) suffix--;
        if (suffix < 1 || !path[suffix - 1].Equals("Images", StringComparison.OrdinalIgnoreCase)
            || (!path[suffix].Equals("Backdrop", StringComparison.OrdinalIgnoreCase)
                && !path[suffix].Equals("Thumb", StringComparison.OrdinalIgnoreCase)
                && !path[suffix].Equals("Primary", StringComparison.OrdinalIgnoreCase))) return null;
        var query=source.Query.TrimStart('?').Split('&',StringSplitOptions.RemoveEmptyEntries);
        static string Name(string parameter)=>parameter.Split('=',2)[0];
        if(!query.Any(part=>part.StartsWith("maxWidth=",StringComparison.OrdinalIgnoreCase)
            &&int.TryParse(part.AsSpan("maxWidth=".Length),out int width)&&width>=960))return null;
        var kept=query.Where(part=>!Name(part).Equals("maxWidth",StringComparison.OrdinalIgnoreCase)
            &&!Name(part).Equals("quality",StringComparison.OrdinalIgnoreCase)
            &&!Name(part).Equals("format",StringComparison.OrdinalIgnoreCase)).ToArray();
        return new Uri(source.GetLeftPart(UriPartial.Path)+(kept.Length==0?"":"?"+string.Join('&',kept)));
    }

    internal static double CompactGap(double current)=>current>18?Math.Max(18,current-12):current;
}
