using FluentResults;

namespace Yingyu.Update;

// One outstanding control operation per MPV client. A failed operation must
// complete its own caller without poisoning later volume/speed/track requests.
internal sealed class SerialAudioQueue
{
    readonly object _gate = new();
    readonly Queue<Work> _pending = new();
    bool _running;
    sealed record Work(Func<Task<Result>> Run, TaskCompletionSource<Result> Completion);

    internal Task<Result> Enqueue(Func<Task<Result>> operation)
    {
        var completion = new TaskCompletionSource<Result>(TaskCreationOptions.RunContinuationsAsynchronously);
        bool start;
        lock (_gate)
        {
            _pending.Enqueue(new Work(operation, completion));
            start = !_running;
            _running = true;
        }
        if (start) _ = Task.Run(PumpAsync);
        return completion.Task;
    }

    async Task PumpAsync()
    {
        while (true)
        {
            Work work;
            lock (_gate)
            {
                if (_pending.Count == 0) { _running = false; return; }
                work = _pending.Dequeue();
            }
            try { work.Completion.TrySetResult(await work.Run().ConfigureAwait(false)); }
            catch (OperationCanceledException error) { work.Completion.TrySetCanceled(error.CancellationToken); }
            catch (Exception error) { work.Completion.TrySetException(error); }
        }
    }
}
