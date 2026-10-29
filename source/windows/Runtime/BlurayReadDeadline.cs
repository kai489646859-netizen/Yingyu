namespace Yingyu.Update;

// Disc.Gate serializes access. Reuse an unexpired deadline across 64 KiB
// reads; never reset a cancelled source or remove cancellation propagation.
internal sealed class BlurayReadDeadline : IDisposable
{
    readonly TimeSpan _timeout;
    CancellationTokenSource? _deadline;
    CancellationToken _parent;
    internal BlurayReadDeadline() : this(TimeSpan.FromSeconds(20)) { }
    internal BlurayReadDeadline(TimeSpan timeout) => _timeout = timeout;
    internal CancellationToken Begin(CancellationToken parent)
    {
        parent.ThrowIfCancellationRequested();
        if (_deadline == null || _deadline.IsCancellationRequested || parent != _parent)
        {
            _deadline?.Dispose();
            _parent = parent;
            _deadline = CancellationTokenSource.CreateLinkedTokenSource(parent);
        }
        _deadline.CancelAfter(_timeout);
        return _deadline.Token;
    }
    internal void End() => _deadline?.CancelAfter(Timeout.InfiniteTimeSpan);
    public void Dispose() { _deadline?.Dispose(); _deadline = null; }
}
