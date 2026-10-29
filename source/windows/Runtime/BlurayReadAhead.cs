using System.Diagnostics;
using System.Net.Http;
using System.Runtime.ExceptionServices;

namespace Yingyu.Update;

// Validated ordered blocks retain the original single-reader fallback.
// Qualified continuous playback may overlap one bounded adjacent response.
internal sealed class BlurayReadAhead(long length,
    Func<long, long, CancellationToken, Task<HttpResponseMessage>> open,
    CancellationToken lifetime, Action<bool, long, int> measure) : IDisposable, IAsyncDisposable
{
    internal const int BlockBytes = 64 * 1024;
    internal const int RangeBytes = 256 * 1024 * 1024;
    internal const int MaximumRanges = 2;
    internal const int ParallelRangeBytes = 32 * 1024 * 1024;
    internal const int HighRateRangeBytes = 128 * 1024 * 1024;
    internal const int HighRateBytes = 192 * 1024 * 1024;
    internal const int MaximumBytes = 48 * 1024 * 1024;
    internal const int MaximumBlocks = MaximumBytes / BlockBytes;
    internal const int ProbeBytes = 4 * 1024 * 1024;
    int _maximumQueuedBlocks = MaximumBlocks;
    Session? _session;
    Task _retiring = Task.CompletedTask;
    long _next = -1, _sequential;
    bool _disposed;
    Func<bool>? _canParallel;
    Action<string>? _diagnostic;
    int _parallelDisabled;
    int _boosted, _highRateTrialUsed, _trialEpoch;
    ExceptionDispatchInfo? _terminalError;
    bool ParallelPhase => Volatile.Read(ref _maximumQueuedBlocks) == MaximumBlocks;
    bool Boosted => Volatile.Read(ref _boosted) != 0;
    int Capacity => Boosted ? HighRateBytes : MaximumBytes;
    int PartBytes => Boosted ? HighRateRangeBytes : ParallelRangeBytes;

    internal void Boost(bool enabled)
    {
        if (Interlocked.Exchange(ref _boosted, enabled ? 1 : 0) == (enabled ? 1 : 0)) return;
        if (enabled && Interlocked.Exchange(ref _highRateTrialUsed, 1) == 0)
        {
            // A 1x trial cannot decide the needs of later 3x playback forever.
            // Retry only a no-gain decision, once per media; never identity or IO failures.
            if (Interlocked.CompareExchange(ref _parallelDisabled, 0, 2) == 2)
                Diagnostic("event=parallel-retry; reason=high-rate-demand; oncePerMedia=true");
            Interlocked.Increment(ref _trialEpoch);
        }
        Volatile.Read(ref _session)?.Changed();
    }

    internal void Configure(Func<bool> canParallel, Action<string>? fixedDiagnostic = null)
    {
        ArgumentNullException.ThrowIfNull(canParallel);
        _diagnostic = fixedDiagnostic;
        Volatile.Write(ref _canParallel, canParallel);
    }

    // Keep a small running pipeline while MPV probes timestamps or seeks.
    // A probe may read sequentially and still discard its following data.
    // Existing complete blocks remain usable; the producer checks this bound
    // before each new block. An already in-flight block may finish.
    internal void LimitProbeReadAhead(bool probing)
    {
        int limit = probing ? ProbeBytes / BlockBytes : MaximumBlocks;
        if (Interlocked.Exchange(ref _maximumQueuedBlocks, limit) != limit)
            Volatile.Read(ref _session)?.Changed();
    }

    // Cached ISO blocks bypass Read. Retire a producer that cannot serve the
    // new position before those cache hits leave it reading obsolete bytes.
    // A ready forward target still reuses the existing ordered queue.
    internal void PrioritizeCached(long offset) => Retarget(offset, true);
    void Retarget(long offset, bool cached)
    {
        // libbluray commonly consumes one delivered 64 KiB block in smaller
        // calls. Those cache hits must not cancel its next-block producer.
        // Read itself still requires the original strict backward reset.
        if (_session != null && (_session.Cancelled
            || (offset < _next && (!cached || _next - offset > BlockBytes))
            || (offset - _next > 1024 * 1024
                && !_session.Ready(offset + Math.Min(BlockBytes, length - offset)))))
        {
            if (cached && Volatile.Read(ref _maximumQueuedBlocks) == ProbeBytes / BlockBytes && !_session.Cancelled)
            {
                // A seek may visit old directory/media blocks and then return
                // to this response's next byte. Stop speculative production,
                // but let the first actual cache miss decide whether a new
                // validated response is needed. Keep the same bounded queue.
                _session.PausePrefetch(); _sequential = 0;
            }
            else Reset();
        }
    }

    internal void Read(long offset, byte[] destination, CancellationToken token, bool allowPrefetch = true)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        token.ThrowIfCancellationRequested();
        Volatile.Read(ref _terminalError)?.Throw();
        if (offset < 0 || offset % BlockBytes != 0 || offset >= length
            || destination.Length != Math.Min(BlockBytes, length - offset))
            throw new IOException("Invalid bounded read");
        Retarget(offset, false);
        if (_session == null)
        {
            // Cached targets can retire an obsolete response without waiting.
            // A new response must wait for that response, its cancellation
            // callbacks and its entire buffer pool to be fully released.
            _retiring.WaitAsync(token).GetAwaiter().GetResult();
            token.ThrowIfCancellationRequested();
            _session = new Session(this, offset);
            _next = offset;
        }
        Session session = _session;
        // libbluray may drain several MiB just to reach one requested byte.
        // Those discarded packets are not evidence of sequential playback.
        // Keep the same validated response and ready blocks, but stop producing
        // beyond demand; an already in-flight block may finish normally.
        if (!allowPrefetch) session.PausePrefetch();
        using var cancel = token.Register(session.Cancel);
        try { session.Copy(offset, destination, token); }
        catch (OperationCanceledException) when (token.IsCancellationRequested)
        {
            // WaitAsync may wake this reader before the registered producer
            // callback runs. Do not let unregistering it lose cancellation.
            session.Cancel();
            throw;
        }
        _sequential = allowPrefetch ? (offset == _next ? _sequential + destination.Length : destination.Length) : 0;
        _next = offset + destination.Length;
        if (_sequential >= 1024 * 1024) session.Prefetch();
    }
    void Reset()
    {
        var previous = _session;
        _session = null; _next = -1; _sequential = 0;
        if (previous != null) _retiring = previous.RetireAsync();
    }
    internal void Stop() => Reset();
    public ValueTask DisposeAsync()
    {
        if (!_disposed) { _disposed = true; Reset(); }
        return new ValueTask(_retiring);
    }
    public void Dispose() => DisposeAsync().AsTask().GetAwaiter().GetResult();

    bool Qualified()
    {
        if (Volatile.Read(ref _parallelDisabled) != 0) return false;
        try { return Volatile.Read(ref _canParallel)?.Invoke() == true; }
        catch { DisableParallel("event=parallel-disabled; reason=qualification-unavailable"); return false; }
    }
    void DisableParallel(string reason, bool retryable = false)
    {
        if (Interlocked.CompareExchange(ref _parallelDisabled, retryable ? 2 : 1, 0) == 0) Diagnostic(reason);
    }
    void Diagnostic(string text) { try { _diagnostic?.Invoke(text); } catch { } }

    sealed class Session
    {
        readonly BlurayReadAhead _owner;
        readonly CancellationTokenSource _cancel;
        readonly CancellationTokenRegistration _lifetimeRegistration;
        readonly object _gate = new();
        readonly Queue<(long Start, byte[] Bytes)> _ready = new();
        readonly Stack<byte[]> _spares = new();
        readonly HashSet<Part> _parts = new();
        TaskCompletionSource _changed = Signal();
        readonly Task _work;
        Task? _cancelling, _retirement;
        Part? _secondary;
        long _demand, _published;
        int _leasedBytes, _allocatedBytes;
        int _memoryCeiling, _trialEpoch;
        long _singleBytes, _singleTicks, _trialBytes, _busyTicks, _networkBegan;
        int _networkCalls;
        bool _trialReviewed;
        bool _prefetch, _switched, _disposed;
        ExceptionDispatchInfo? _error, _fatal;
        static TaskCompletionSource Signal() => new(TaskCreationOptions.RunContinuationsAsynchronously);
        internal Session(BlurayReadAhead owner, long start)
        {
            _owner = owner;
            _memoryCeiling = owner.Capacity;
            _cancel = new CancellationTokenSource();
            _lifetimeRegistration = owner.Lifetime.Register(Cancel);
            _demand = Math.Min(start + BlockBytes, owner.Length); _published = start;
            _work = Fill(start, _cancel.Token);
        }
        internal bool Cancelled => _cancel.IsCancellationRequested;
        internal void Cancel()
        {
            lock (_gate)
            {
                if (_disposed) return;
                _cancelling ??= _cancel.CancelAsync();
                Pulse();
            }
        }
        internal bool Ready(long end) { lock (_gate) return end <= _published; }
        void Pulse() { _changed.TrySetResult(); _changed = Signal(); }
        internal void Changed() => PhaseChanged(_owner.ParallelPhase);
        void PhaseChanged(bool enabled)
        {
            Part? secondary;
            lock (_gate)
            {
                if (_disposed) return;
                _memoryCeiling = Math.Max(_memoryCeiling, _owner.Capacity);
                TrimSpares(); Pulse(); secondary = enabled ? null : _secondary;
            }
            secondary?.Stop(true);
        }
        internal void Prefetch() { lock (_gate) { _prefetch = true; Pulse(); } }
        internal void PausePrefetch() { lock (_gate) _prefetch = false; }
        bool WantsParallel() => _prefetch && _owner.ParallelPhase && _owner.Qualified();
        bool CanStartTrial() => WantsParallel() && _singleBytes >= 1024 * 1024
            && _singleTicks >= Stopwatch.Frequency / 4;
        void NetworkBegin()
        {
            lock (_gate) if (_networkCalls++ == 0) _networkBegan = Stopwatch.GetTimestamp();
        }
        void NetworkEnd()
        {
            lock (_gate) if (--_networkCalls == 0) _busyTicks += Stopwatch.GetTimestamp() - _networkBegan;
        }
        bool NoThroughputGain()
        {
            lock (_gate)
            {
                if (_trialReviewed || _trialBytes < 2 * _owner.PartBytes) return false;
                _trialReviewed = true;
                long busy = _busyTicks + (_networkCalls == 0 ? 0 : Stopwatch.GetTimestamp() - _networkBegan);
                return busy > 0 && (double)_trialBytes / busy < (double)_singleBytes / _singleTicks * 1.1;
            }
        }
        async Task Wait(long cursor, CancellationToken token)
            => await WaitBlock(cursor, null, (int)Math.Min(BlockBytes, _owner.Length - cursor), token, false).ConfigureAwait(false);

        async Task<byte[]?> WaitBlock(long cursor, Part? part, int count, CancellationToken token, bool acquire)
        {
            while (true)
            {
                token.ThrowIfCancellationRequested();
                Task pending;
                lock (_gate)
                {
                    // Future bytes cannot consume the current range's quota.
                    _memoryCeiling = Math.Max(_memoryCeiling, _owner.Capacity);
                    bool demanded = cursor < _demand && (part == null || part.Current);
                    int phaseBudget = _owner.ParallelPhase ? _owner.Capacity : ProbeBytes;
                    int currentReserve = _owner.Boosted ? 64 * 1024 * 1024 : ParallelRangeBytes;
                    int budget = part != null && !part.Current ? _owner.Capacity - currentReserve
                        : demanded ? _memoryCeiling : phaseBudget;
                    if (_leasedBytes <= budget - count && (_prefetch || demanded))
                        return acquire ? Acquire(count) : null;
                    pending = _changed.Task;
                }
                await pending.WaitAsync(token).ConfigureAwait(false);
            }
        }
        byte[] Acquire(int count)
        {
            // Caller holds _gate; reservation and allocation cannot race.
            byte[] bytes;
            if (count == BlockBytes && _spares.TryPop(out var spare)) bytes = spare;
            else
            {
                // Spares are part of the memory bound, including a short EOF block.
                while (_allocatedBytes > _memoryCeiling - count && _spares.TryPop(out var old))
                    _allocatedBytes -= old.Length;
                if (_allocatedBytes > _memoryCeiling - count) throw new IOException("Read-ahead budget exceeded");
                bytes = new byte[count]; _allocatedBytes += count;
            }
            _leasedBytes += count;
            return bytes;
        }
        void Recycle(byte[] bytes)
        {
            _leasedBytes -= bytes.Length;
            if (bytes.Length == BlockBytes) _spares.Push(bytes);
            else _allocatedBytes -= bytes.Length;
            TrimSpares();
        }
        void TrimSpares()
        {
            while (_allocatedBytes > _owner.Capacity && _spares.TryPop(out var old))
                _allocatedBytes -= old.Length;
        }
        async Task ReadBlock(Stream body, long cursor, int count, Part? part,
            BlurayReadDeadline deadline, CancellationToken token)
        {
            byte[] bytes = (await WaitBlock(cursor, part, count, token, true).ConfigureAwait(false))!;
            bool published = false;
            try
            {
                long began = Stopwatch.GetTimestamp();
                var readToken = deadline.Begin(token);
                if (part != null) NetworkBegin();
                try { await body.ReadExactlyAsync(bytes, readToken).ConfigureAwait(false); }
                finally { if (part != null) NetworkEnd(); deadline.End(); }
                token.ThrowIfCancellationRequested();
                long elapsed = Stopwatch.GetTimestamp() - began;
                _owner.Measure(false, elapsed, count);
                lock (_gate)
                {
                    if (part == null) { _singleBytes += count; _singleTicks += elapsed; }
                    else _trialBytes += count;
                    if (part == null || part.Current)
                    {
                        if (cursor != _published) throw new IOException("Unexpected publication position");
                        _ready.Enqueue((cursor, bytes)); _published += count;
                    }
                    else part.Pending.Enqueue((cursor, bytes));
                    if (part != null) part.Cursor = cursor + count;
                    published = true; Pulse();
                }
            }
            finally { if (!published) lock (_gate) { Recycle(bytes); Pulse(); } }
        }
        async Task Fill(long cursor, CancellationToken token)
        {
            try { await FillSingle(cursor, token).ConfigureAwait(false); }
            catch (Exception error)
            {
                if (error is IsoSourceChangedException) FailFatal(error);
                lock (_gate) { _error ??= ExceptionDispatchInfo.Capture(error); Pulse(); }
            }
            finally
            {
                Part[] remaining;
                lock (_gate) remaining = _parts.ToArray();
                foreach (var part in remaining) await FinishPart(part, true).ConfigureAwait(false);
            }
        }
        async Task FillSingle(long cursor, CancellationToken token)
        {
            while (cursor < _owner.Length)
            {
                await Wait(cursor, token).ConfigureAwait(false);
                long end = Math.Min(cursor + RangeBytes, _owner.Length);
                Part? warm = null;
                long began = Stopwatch.GetTimestamp();
                using (var headers = CancellationTokenSource.CreateLinkedTokenSource(token))
                {
                    headers.CancelAfter(TimeSpan.FromSeconds(20));
                    using var response = await _owner.Open(cursor, end - 1, headers.Token).ConfigureAwait(false);
                    _owner.Measure(true, Stopwatch.GetTimestamp() - began, (int)(end - cursor));
                    using var body = await response.Content.ReadAsStreamAsync(headers.Token).ConfigureAwait(false);
                    headers.CancelAfter(Timeout.InfiniteTimeSpan);
                    using var deadline = new BlurayReadDeadline();
                    while (cursor < end)
                    {
                        await Wait(cursor, token).ConfigureAwait(false);
                        if ((!_switched || _trialEpoch != Volatile.Read(ref _owner._trialEpoch))
                            && end < _owner.Length && CanStartTrial())
                        {
                            _switched = true;
                            _trialEpoch = Volatile.Read(ref _owner._trialEpoch);
                            lock (_gate) { _trialBytes = _busyTicks = 0; _trialReviewed = false; }
                            warm = StartPart(end, false, token);
                            _owner.Diagnostic($"event=parallel-enabled; ranges=2; segmentMiB={_owner.PartBytes / 1048576}; budgetMiB={_owner.Capacity / 1048576}");
                        }
                        int count = (int)Math.Min(BlockBytes, end - cursor);
                        await ReadBlock(body, cursor, count, null, deadline, token).ConfigureAwait(false);
                        cursor += count;
                    }
                }
                if (warm != null)
                {
                    if (Promote(warm))
                    {
                        await FillParallel(cursor, token, warm).ConfigureAwait(false);
                        return;
                    }
                    await FinishPart(warm, true).ConfigureAwait(false);
                    Volatile.Read(ref _owner._terminalError)?.Throw();
                }
            }
        }
        bool Promote(Part part)
        {
            lock (_gate)
            {
                if (part.Stopped || !WantsParallel()) return false;
                if (part.Start != _published) throw new IOException("Unexpected warm range");
                while (part.Pending.TryDequeue(out var block))
                {
                    if (block.Start != _published) throw new IOException("Unexpected warm block");
                    _ready.Enqueue(block); _published += block.Bytes.Length;
                }
                part.Current = true; _secondary = null; Pulse();
                return true;
            }
        }
        Part StartPart(long start, bool current, CancellationToken token)
        {
            var part = new Part(this, start, Math.Min(start + _owner.PartBytes, _owner.Length), current, token);
            lock (_gate)
            {
                _parts.Add(part);
                if (!current)
                {
                    _secondary = part;
                    // A phase change can win after qualification but before
                    // this lane is registered. Do not open its response then.
                    if (!WantsParallel()) part.Stop(true);
                }
            }
            part.Run(); return part;
        }
        async Task FillParallel(long cursor, CancellationToken token, Part? warmed = null)
        {
            Part? current = null, secondary = null;
            try
            {
                current = warmed ?? StartPart(cursor, true, token);
                while (true)
                {
                    token.ThrowIfCancellationRequested();
                    if (current.End < _owner.Length && WantsParallel()) secondary = StartPart(current.End, false, token);
                    await current.Work.ConfigureAwait(false);
                    ExceptionDispatchInfo? failure = current.Error;
                    cursor = current.Cursor;
                    await FinishPart(current, false).ConfigureAwait(false); current = null;
                    Volatile.Read(ref _owner._terminalError)?.Throw();
                    token.ThrowIfCancellationRequested();
                    if (failure != null)
                    {
                        if (secondary != null) { await FinishPart(secondary, true).ConfigureAwait(false); secondary = null; }
                        if (Volatile.Read(ref _owner._parallelDisabled) != 0)
                        { await FillSingle(cursor, token).ConfigureAwait(false); return; }
                        failure.Throw();
                    }
                    if (NoThroughputGain())
                        _owner.DisableParallel("event=parallel-disabled; reason=no-throughput-gain", retryable: true);
                    if (secondary == null || secondary.Stopped || !WantsParallel())
                    {
                        if (secondary != null)
                        {
                            bool retain;
                            lock (_gate) retain = _owner.ParallelPhase && !secondary.PhaseStopped
                                && Volatile.Read(ref _owner._parallelDisabled) != 0 && _published == secondary.Start;
                            if (retain)
                                cursor = await RetainCompletedPrefix(secondary, token).ConfigureAwait(false);
                            else await FinishPart(secondary, true).ConfigureAwait(false);
                            secondary = null;
                        }
                        if (_owner.ParallelPhase && !_owner.Qualified())
                            _owner.DisableParallel("event=parallel-disabled; reason=source-not-qualified");
                        await FillSingle(cursor, token).ConfigureAwait(false); return;
                    }
                    // Promotion publishes only the contiguous complete prefix;
                    // an unfinished future body becomes the new current body.
                    bool promote;
                    lock (_gate)
                    {
                        promote = !secondary.Stopped && _owner.ParallelPhase
                            && Volatile.Read(ref _owner._parallelDisabled) == 0;
                        if (promote)
                        {
                            if (secondary.Start != _published) throw new IOException("Unexpected adjacent range");
                            while (secondary.Pending.TryDequeue(out var block))
                            {
                                if (block.Start != _published) throw new IOException("Unexpected ordered block");
                                _ready.Enqueue(block); _published += block.Bytes.Length;
                            }
                            secondary.Current = true; _secondary = null; Pulse();
                        }
                    }
                    if (!promote)
                    {
                        await FinishPart(secondary, true).ConfigureAwait(false); secondary = null;
                        await FillSingle(cursor, token).ConfigureAwait(false); return;
                    }
                    current = secondary; secondary = null;
                }
            }
            finally
            {
                if (secondary != null) await FinishPart(secondary, true).ConfigureAwait(false);
                if (current != null) await FinishPart(current, true).ConfigureAwait(false);
            }
        }
        async Task FinishPart(Part part, bool stop)
        {
            if (stop) part.Stop(false);
            await part.Finish().ConfigureAwait(false);
            lock (_gate)
            {
                while (part.Pending.TryDequeue(out var block)) Recycle(block.Bytes);
                _parts.Remove(part);
                if (ReferenceEquals(_secondary, part)) _secondary = null;
                Pulse();
            }
        }
        async Task<long> RetainCompletedPrefix(Part part, CancellationToken token)
        {
            // Ordinary/no-gain fallback preserves already verified complete
            // future blocks; cancellation and source changes take precedence.
            part.Stop(false);
            await part.Finish().ConfigureAwait(false);
            Volatile.Read(ref _owner._terminalError)?.Throw();
            token.ThrowIfCancellationRequested();
            lock (_gate)
            {
                _fatal?.Throw();
                if (part.Start != _published) throw new IOException("Unexpected fallback prefix");
                while (part.Pending.TryDequeue(out var block))
                {
                    if (block.Start != _published) throw new IOException("Unexpected fallback block");
                    _ready.Enqueue(block); _published += block.Bytes.Length;
                }
                _parts.Remove(part);
                if (ReferenceEquals(_secondary, part)) _secondary = null;
                Pulse(); return _published;
            }
        }
        void FailFatal(Exception error)
        {
            var captured = ExceptionDispatchInfo.Capture(error);
            Interlocked.CompareExchange(ref _owner._terminalError, captured, null);
            lock (_gate) { _fatal ??= captured; Pulse(); }
            Cancel();
        }
        internal void Copy(long offset, byte[] destination, CancellationToken token)
        {
            lock (_gate) { _demand = Math.Max(_demand, offset + destination.Length); Pulse(); }
            while (true)
            {
                token.ThrowIfCancellationRequested();
                Task pending;
                lock (_gate)
                {
                    _fatal?.Throw();
                    while (_ready.TryPeek(out var old) && old.Start < offset)
                    { Recycle(_ready.Dequeue().Bytes); Pulse(); }
                    if (_ready.TryPeek(out var block))
                    {
                        if (block.Start != offset || block.Bytes.Length != destination.Length)
                            throw new IOException("Unexpected ordered block");
                        block.Bytes.CopyTo(destination, 0);
                        Recycle(_ready.Dequeue().Bytes); Pulse(); return;
                    }
                    _error?.Throw(); pending = _changed.Task;
                }
                pending.WaitAsync(token).GetAwaiter().GetResult();
            }
        }
        internal Task RetireAsync()
        {
            lock (_gate)
            {
                Cancel();
                return _retirement ??= DrainAsync();
            }
        }
        async Task DrainAsync()
        {
            try { await _work.ConfigureAwait(false); }
            finally
            {
                try
                {
                    Task? cancelling;
                    lock (_gate) cancelling = _cancelling;
                    if (cancelling != null) await cancelling.ConfigureAwait(false);
                }
                finally
                {
                    try { await _lifetimeRegistration.DisposeAsync().ConfigureAwait(false); }
                    finally
                    {
                        lock (_gate) { _disposed = true; _ready.Clear(); _spares.Clear(); _leasedBytes = _allocatedBytes = 0; }
                        _cancel.Dispose();
                    }
                }
            }
        }

        sealed class Part
        {
            readonly Session _session;
            readonly CancellationTokenSource _cancel;
            readonly object _cancelGate = new();
            readonly bool _beganSecondary;
            Task? _cancelling;
            bool _disposed;
            int _stopped;
            internal readonly long Start, End;
            internal long Cursor;
            internal bool Current;
            internal readonly Queue<(long Start, byte[] Bytes)> Pending = new();
            internal Task Work = Task.CompletedTask;
            internal ExceptionDispatchInfo? Error;
            internal bool Stopped => Volatile.Read(ref _stopped) != 0;
            internal bool PhaseStopped => Volatile.Read(ref _stopped) == 1;
            internal Part(Session session, long start, long end, bool current, CancellationToken token)
            {
                _session = session; Start = Cursor = start; End = end; Current = current;
                _beganSecondary = !current; _cancel = CancellationTokenSource.CreateLinkedTokenSource(token);
            }
            internal void Run() => Work = Fill();
            internal void Stop(bool phase)
            {
                lock (_session._gate)
                {
                    // Promotion and phase cancellation agree on the role.
                    if (phase && (Current || !ReferenceEquals(_session._secondary, this))) return;
                    Interlocked.CompareExchange(ref _stopped, phase ? 1 : 2, 0);
                    _session.Pulse();
                }
                lock (_cancelGate) { if (!_disposed) _cancelling ??= _cancel.CancelAsync(); }
            }
            async Task Fill()
            {
                CancellationToken token = _cancel.Token;
                using var headers = CancellationTokenSource.CreateLinkedTokenSource(token);
                bool awaitingHeaders = true;
                try
                {
                    long began = Stopwatch.GetTimestamp();
                    // This deadline only bounds the optional small-range trial.
                    // The original single response and all body deadlines stay 20s.
                    headers.CancelAfter(TimeSpan.FromSeconds(3));
                    HttpResponseMessage opened;
                    _session.NetworkBegin();
                    try { opened = await _session._owner.Open(Start, End - 1, headers.Token).ConfigureAwait(false); }
                    finally { _session.NetworkEnd(); }
                    using var response = opened;
                    _session._owner.Measure(true, Stopwatch.GetTimestamp() - began, (int)(End - Start));
                    // Recheck after the source has inspected these headers.
                    // A missing/weak identity must never publish parallel bytes.
                    if (!_session._owner.Qualified())
                    {
                        _session._owner.DisableParallel("event=parallel-disabled; reason=source-not-qualified");
                        Stop(false); return;
                    }
                    using var body = await response.Content.ReadAsStreamAsync(headers.Token).ConfigureAwait(false);
                    headers.CancelAfter(Timeout.InfiniteTimeSpan);
                    awaitingHeaders = false;
                    using var deadline = new BlurayReadDeadline();
                    while (Cursor < End)
                    {
                        int count = (int)Math.Min(BlockBytes, End - Cursor);
                        await _session.ReadBlock(body, Cursor, count, this, deadline, token).ConfigureAwait(false);
                    }
                }
                catch (Exception error)
                {
                    Error = ExceptionDispatchInfo.Capture(error);
                    if (error is IsoSourceChangedException) _session.FailFatal(error);
                    else if (!Stopped && !_session._cancel.IsCancellationRequested)
                    {
                        if (awaitingHeaders && error is OperationCanceledException
                            && headers.IsCancellationRequested && !token.IsCancellationRequested)
                        {
                            _session._owner.DisableParallel("event=parallel-disabled; reason=parallel-header-timeout");
                            Stop(false);
                        }
                        else if (_beganSecondary && error is IOException or HttpRequestException or OperationCanceledException)
                        {
                            _session._owner.DisableParallel("event=parallel-disabled; reason=secondary-read-failed");
                            Stop(false);
                        }
                        else _session.FailFatal(error);
                    }
                }
                finally { lock (_session._gate) _session.Pulse(); }
            }
            internal async Task Finish()
            {
                await Work.ConfigureAwait(false);
                Task? cancelling;
                lock (_cancelGate)
                {
                    if (_disposed) return;
                    _disposed = true; cancelling = _cancelling;
                }
                if (cancelling != null) await cancelling.ConfigureAwait(false);
                _cancel.Dispose();
            }
        }
    }
    long Length => length;
    CancellationToken Lifetime => lifetime;
    Task<HttpResponseMessage> Open(long start, long end, CancellationToken token) => open(start, end, token);
    void Measure(bool header, long ticks, int bytes) => measure(header, ticks, bytes);
}
