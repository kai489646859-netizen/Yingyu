namespace Yingyu.Update;

internal static class MissingArtworkPlan
{
    internal static IReadOnlyList<T> Filter<T>(IReadOnlyList<T> plan, Func<T, bool> hasValidCache, CancellationToken cancellation)
    {
        var missing = new List<T>();
        foreach (var entry in plan)
        {
            cancellation.ThrowIfCancellationRequested();
            if (!hasValidCache(entry)) missing.Add(entry);
        }
        cancellation.ThrowIfCancellationRequested();
        return missing;
    }
}
