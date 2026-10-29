namespace Yingyu.Update;

/// <summary>One deferred maintenance job; scheduling never joins its disk work.</summary>
public sealed class StartupMaintenance
{
    readonly object gate = new();
    Task? completion;
    public Task Completion { get { lock (gate) return completion ?? Task.CompletedTask; } }
    public Task Schedule(Func<CancellationToken, Task> work, Func<bool> paused, Action<string, long> report,
        CancellationToken token)
    {
        lock (gate)
        {
            completion ??= Task.Run(async () =>
            {
                var started = Environment.TickCount64;
                try
                {
                    await Task.Delay(500, token).ConfigureAwait(false);
                    while (paused()) await Task.Delay(100, token).ConfigureAwait(false);
                    report("image-maintenance-start", Environment.TickCount64 - started);
                    await work(token).ConfigureAwait(false);
                    report("image-maintenance-complete", Environment.TickCount64 - started);
                }
                catch (OperationCanceledException) { report("image-maintenance-cancelled", Environment.TickCount64 - started); }
                catch (Exception) { report("image-maintenance-incomplete", Environment.TickCount64 - started); }
            });
        }
        return Task.CompletedTask;
    }
}
