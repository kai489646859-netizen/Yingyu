using System.Runtime.CompilerServices;
using EmbyDesktop.Core.Services;
using Microsoft.UI.Xaml.Controls;

namespace Yingyu.Update;

public static class ArtworkInitializationReuse
{
    static readonly ConditionalWeakTable<object, State> States = new();
    sealed class State(IReadOnlyList<ArtworkInitializationEntry> original)
    {
        internal readonly IReadOnlyList<ArtworkInitializationEntry> Original = original;
        internal IReadOnlyList<ArtworkInitializationEntry>? Missing;
        internal int Reused;
        internal bool Applied;
    }
    internal static void Reset(object page) => States.Remove(page);

    public static Task Prepare(Task? indexTask, object page, IReadOnlyList<ArtworkInitializationEntry> plan, CancellationToken cancellation)
    {
        var state = new State(plan);
        States.Remove(page); States.Add(page, state);
        Access.Get<TextBlock>(page, "ArtworkInitializationStatusText").Text = "正在核对已有图片…";
        Access.Get<TextBlock>(page, "ArtworkInitializationCountText").Text = "有效缓存直接复用，只补缺失图片。";
        var cache = Access.Get<PosterCacheService>(page, "_posterCache");
        return PrepareCore(indexTask, cache, state, cancellation);
    }
    static async Task PrepareCore(Task? indexTask, PosterCacheService cache, State state, CancellationToken cancellation)
    {
        if (indexTask != null) await indexTask.WaitAsync(cancellation).ConfigureAwait(false);
        // Existing index registration must finish before testing the plan. The
        // original cache lookup retains ownership, LRU touches, exact image
        // tag/size keys and shared/work aliases, without downloading images.
        var missing = await Task.Run(() => MissingArtworkPlan.Filter(state.Original,
            entry => cache.TryGetCached(entry.CacheRequest) != null, cancellation), cancellation).ConfigureAwait(false);
        state.Reused = state.Original.Count - missing.Count;
        state.Missing = missing;
        PlaybackTransport.Write("Info", "Artwork.Initialize", $"增量核对完成；计划={state.Original.Count}，有效缓存复用={state.Reused}，待补={missing.Count}；核对阶段无图片下载。 ");
    }
    public static IReadOnlyList<ArtworkInitializationEntry> TakePlan(object page, IReadOnlyList<ArtworkInitializationEntry> original)
    {
        if (!States.TryGetValue(page, out var state) || !ReferenceEquals(original, state.Original) || state.Missing == null)
            throw new InvalidOperationException("增量图片核对尚未完成。");
        state.Applied = true;
        return state.Missing;
    }
    public static void Annotate(object page)
    {
        if (!States.TryGetValue(page, out var state) || !state.Applied) return;
        var count = Access.Get<TextBlock>(page, "ArtworkInitializationCountText");
        count.Text = $"已复用 {state.Reused:N0} 张 · 待补 {state.Missing!.Count:N0} 张\n" + count.Text;
    }
    internal static void Finish(object page)
    {
        if (!States.TryGetValue(page, out var state) || !state.Applied) return;
        var status = Access.Get<TextBlock>(page, "ArtworkInitializationSettingsText");
        status.Text += $"\n已复用有效缓存 {state.Reused:N0} 张；本次补图计划 {state.Missing!.Count:N0} 张。";
        States.Remove(page);
    }
}
