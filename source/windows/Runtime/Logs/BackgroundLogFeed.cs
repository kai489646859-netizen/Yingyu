namespace Yingyu.LogCenter;

internal sealed record LogSnapshot(long Sequence, IReadOnlyList<LogRow> Rows, string Status);

// One background reader per main page. UI visibility never controls its cursor.
// Only parsed rows from the existing bounded local tail are retained.
internal sealed class BackgroundLogFeed
{
    readonly object _gate = new();
    readonly Func<CancellationToken, Task<TailBatch>> _read;
    readonly TimeSpan _interval;
    readonly Queue<(long Sequence, LogRow Row)> _rows = new();
    CancellationTokenSource? _lifetime;
    Task? _run;
    bool _wanted;
    long _sequence;
    string _status = "正在读取本机日志…";
    internal BackgroundLogFeed(Func<CancellationToken, Task<TailBatch>> read, TimeSpan? interval = null)
    { _read = read; _interval = interval ?? TimeSpan.FromSeconds(1); }
    internal void Start()
    {
        lock (_gate) { _wanted = true; if (_run == null) StartLocked(); }
    }
    void StartLocked()
    {
        var lifetime = _lifetime = new CancellationTokenSource();
        _run = Task.Run(() => RunAsync(lifetime));
    }
    internal void Stop()
    {
        lock (_gate) { _wanted = false; _lifetime?.Cancel(); }
    }
    internal LogSnapshot Snapshot(long after = -1)
    {
        lock (_gate)
        {
            // No rows were published since this consumer's snapshot. Return the
            // current status without scanning up to 10,000 retained entries.
            if (after == _sequence) return new(_sequence, Array.Empty<LogRow>(), _status);
            return new(_sequence, _rows.Where(x => x.Sequence > after).Select(x => x.Row).ToArray(), _status);
        }
    }
    async Task RunAsync(CancellationTokenSource lifetime)
    {
        try
        {
            while (!lifetime.IsCancellationRequested)
            {
                try
                {
                    var batch = await _read(lifetime.Token).ConfigureAwait(false);
                    // Once LocalLogTail has committed its cursor, publish its
                    // rows even if Stop was requested in the meantime.
                    lock (_gate)
                    {
                        foreach (var row in batch.Rows)
                        {
                            _rows.Enqueue((++_sequence, row));
                            if (_rows.Count > LocalLogTail.MaximumRows) _rows.Dequeue();
                        }
                        _status = batch.Status;
                    }
                }
                catch (OperationCanceledException) when (lifetime.IsCancellationRequested) { break; }
                catch (Exception error)
                {
                    lock (_gate) _status = "本地读取未完成，将自动重试。异常类型：" + error.GetType().Name;
                }
                await Task.Delay(_interval, lifetime.Token).ConfigureAwait(false);
            }
        }
        catch (OperationCanceledException) when (lifetime.IsCancellationRequested) { }
        finally
        {
            lock (_gate)
            {
                _run = null; _lifetime = null; lifetime.Dispose();
                // A reload while the previous read was cancelling resumes the
                // same tail, never starts a second concurrent file read.
                if (_wanted) StartLocked();
            }
        }
    }
}
