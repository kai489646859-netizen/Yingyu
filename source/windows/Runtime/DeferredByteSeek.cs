namespace Yingyu.Update;

// A byte seek changes the logical position. Only a subsequent non-empty read
// needs to materialize that position in libbluray. Superseded probes do no I/O.
internal sealed class DeferredByteSeek
{
    long? _pending;
    bool _failed;
    internal long Schedule(long offset, long length)
    {
        if (offset < 0 || offset > length) return -1;
        _pending = offset;
        _failed = false;
        return offset;
    }
    internal bool Resolve(Func<long, long> seek)
    {
        if (_pending is not { } target) return !_failed;
        _pending = null;
        _failed = true;
        if (seek(target) != target) return false;
        _failed = false;
        return true;
    }
}
