using System.Runtime.CompilerServices;

namespace Yingyu.Update;

public static class StartupResponsiveness
{
    static readonly StartupMaintenance Maintenance = new();
    static readonly ConditionalWeakTable<object, Clock> Clocks = new();
    sealed class Clock { public long Started = Environment.TickCount64, Last = Environment.TickCount64; }
    public static void Begin(object page)
    {
        Clocks.Remove(page); Clocks.Add(page, new());
        CachePaths.ReportMigrations((stage, elapsed) =>
            PlaybackTransport.Write("Info", "Startup.Stage", $"阶段={stage}，耗时={elapsed}ms。"));
        Mark(page, "page-initialize");
        PlaybackTransport.Write("Info", "Startup.Stage", $"阶段=cache-migration-queued，待处理={CachePaths.PendingMigrations}；迁移不阻塞主页。");
    }
    public static void Mark(object page, string stage)
    {
        var clock = Clocks.GetValue(page, _ => new());
        long now = Environment.TickCount64;
        PlaybackTransport.Write("Info", "Startup.Stage", $"阶段={stage}，累计={now - clock.Started}ms，分段={now - clock.Last}ms。");
        clock.Last = now;
    }
    public static Task SetStartupImageLimit(object cache, long maximum, CancellationToken token)
    {
        PlaybackTransport.Write("Info", "Startup.Stage", "阶段=image-maintenance-queued；缓存检查不阻塞主页。");
        return Maintenance.Schedule(ct => AndroidCacheImages.SetLimit(cache, maximum, ct),
            () => AndroidCacheRuntime.IsPaused, (stage, elapsed) =>
                PlaybackTransport.Write("Info", "Startup.Stage", $"阶段={stage}，耗时={elapsed}ms。"), token);
    }
}

public static partial class CachePaths
{
    static partial void InitializeMigrationObserver(CacheLayout layout)
        => layout.PictureImported = AndroidCacheImages.Touch;
}
