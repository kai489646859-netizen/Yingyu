namespace Yingyu.Update;

// Own the original directory preparation until it finishes or the real player
// closes. Cancellation callbacks run off the caller and are joined at disposal.
internal sealed class BlurayPreparationWork
{
    readonly CancellationTokenSource _lifetime;
    readonly object _gate = new();
    Task? _cancellation;
    internal Task Completion { get; }

    internal BlurayPreparationWork(CancellationTokenSource lifetime,
        Func<CancellationToken, Task> prepare, CancellationToken launch)
    {
        _lifetime = lifetime;
        Completion = Run(prepare, launch);
    }
    async Task Run(Func<CancellationToken, Task> prepare, CancellationToken launch)
    {
        using var registration = launch.Register(() => { _ = CancelAsync(); });
        _lifetime.Token.ThrowIfCancellationRequested();
        await prepare(_lifetime.Token).ConfigureAwait(false);
    }
    internal Task CancelAsync()
    {
        lock (_gate) return _cancellation ??= _lifetime.CancelAsync();
    }
}
