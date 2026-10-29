namespace Yingyu.Update;

// All operations, including copying bytes to libbluray, run under Disc.Gate.
// Reuse the oldest storage only after removing its key. Failed/partial reads
// never publish a key; the next complete read overwrites the whole buffer.
internal sealed class BlurayBlockCache(int capacity)
{
    readonly Dictionary<long, byte[]> _blocks = new();
    readonly Queue<long> _order = new();
    internal bool TryGetValue(long index, out byte[] bytes) => _blocks.TryGetValue(index, out bytes!);
    internal byte[] Acquire(int length)
    {
        if (_blocks.Count >= capacity)
        {
            long oldest = _order.Dequeue();
            byte[] buffer = _blocks[oldest];
            _blocks.Remove(oldest);
            if (buffer.Length == length) return buffer;
        }
        return new byte[length];
    }
    internal void Publish(long index, byte[] complete)
    {
        if (_blocks.ContainsKey(index)) return;
        if (_blocks.Count >= capacity) _blocks.Remove(_order.Dequeue());
        _blocks.Add(index, complete); _order.Enqueue(index);
    }
    internal void Clear() { _blocks.Clear(); _order.Clear(); }
    internal Dictionary<long, byte[]>? Snapshot(int maximumBytes)
    {
        if (_blocks.Values.Sum(b => (long)b.Length) > maximumBytes) return null;
        return _blocks.ToDictionary(p => p.Key, p => (byte[])p.Value.Clone());
    }
}
