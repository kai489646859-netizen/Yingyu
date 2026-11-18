namespace Yingyu.Update;

// Owns only an HDR switch we initiated while Windows reported the user toggle off.
// The marker survives a crash or an unplugged monitor, and one owner holds it at a time.
internal sealed class WindowsHdrLease(string marker, Func<IntPtr, HdrDisplay> forWindow,
    Func<string, HdrDisplay> byKey, Func<string, bool, bool> setHdr)
{
    readonly object gate = new();
    readonly HashSet<string> attempted = new(StringComparer.Ordinal);
    FileStream? markerLock;
    string? owned;
    long changedAt;
    bool restoring;
    object? current;

    internal readonly record struct Result(HdrDisplay Display, bool Changed);

    internal void Begin(object owner)
    {
        lock (gate)
        {
            current = owner;
            attempted.Clear();
        }
    }

    internal bool HasOwned { get { lock (gate) return owned is not null; } }

    internal Result Prepare(object owner, IntPtr window, bool? hdrMedia, bool allowChange, Func<bool> valid)
    {
        lock (gate)
        {
            HdrDisplay display = forWindow(window);
            if (!ReferenceEquals(current, owner) || !valid()) return new(display, false);
            bool keepHdr = hdrMedia != false && allowChange;
            // An unavailable topology is common during an OS mode change. Retain
            // the journal until the same endpoint or a different endpoint is known.
            bool moved = display.Key is not null && display.Key != owned;
            bool changed = owned is not null && (!keepHdr || moved) && Restore();
            if (changed) display = forWindow(window);
            if (owned == display.Key && owned is not null && display.UserEnabled == false && Settled())
                Forget(restoring);
            if (!allowChange || hdrMedia != true || owned is not null || !display.CanEnable || display.HdrActive
                || display.UserEnabled != false || display.Key is not { } key || !attempted.Add(key))
                return new(display, changed);

            if (!Arm(key)) return new(display, changed);
            // Re-resolve the current endpoint and user setting right before writing.
            var latest = forWindow(window);
            if (!valid() || latest.Key != key || !latest.CanEnable || latest.HdrActive || latest.UserEnabled != false)
            {
                Forget();
                return new(latest, changed);
            }
            changedAt = Environment.TickCount64;
            bool enabled = setHdr(key, true);
            // Keep the journal until a read after settling can distinguish a
            // rejected change from a driver that applied it despite an error.
            return new(forWindow(window), changed || enabled);
        }
    }

    internal void End(object owner)
    {
        lock (gate)
        {
            if (!ReferenceEquals(current, owner)) return;
            current = null;
            Restore();
        }
    }

    internal void Recover()
    {
        lock (gate)
        {
            // Do not run this from a second process while the first owns the journal.
            if (!File.Exists(marker) || !LockMarker()) return;
            try
            {
                if (new FileInfo(marker).Length != 64) return;
                string key = File.ReadAllText(marker);
                if (key.Length != 64 || !key.All(char.IsAsciiHexDigit)) return;
                owned = key;
                Restore();
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
            finally { if (owned is null) Unlock(); }
        }
    }

    bool Restore()
    {
        if (owned is not { } key) return false;
        var display = byKey(key);
        if (display.UserEnabled == false && (restoring || Settled()))
        {
            Forget(restoring);
            return false;
        }
        if (display.UserEnabled != true || (restoring && !Settled())) return false;
        if (!setHdr(key, false)) return false;
        restoring = true;
        changedAt = Environment.TickCount64;
        if (byKey(key).UserEnabled == false) Forget(true);
        return true;
    }

    bool Settled() => changedAt == 0 || Environment.TickCount64 - changedAt >= 1000;

    bool Arm(string key)
    {
        if (!LockMarker()) return false;
        string temporary = marker + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            using (var output = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write,
                FileShare.None, 4096, FileOptions.WriteThrough))
            {
                output.Write(System.Text.Encoding.ASCII.GetBytes(key));
                output.Flush(flushToDisk: true);
            }
            File.Move(temporary, marker);
            owned = key;
            return true;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            Unlock();
            return false;
        }
        finally { Delete(temporary); }
    }

    bool LockMarker()
    {
        if (markerLock is not null) return true;
        try
        {
            markerLock = new FileStream(marker + ".lock", FileMode.OpenOrCreate, FileAccess.ReadWrite,
                FileShare.None, 4096, FileOptions.DeleteOnClose);
            return true;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { return false; }
    }

    void Forget(bool retryOnReturn = false)
    {
        if (!Delete(marker)) return;
        if (retryOnReturn && owned is { } key) attempted.Remove(key);
        owned = null;
        changedAt = 0;
        restoring = false;
        Unlock();
    }

    static bool Delete(string file)
    {
        try { File.Delete(file); return true; }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { return false; }
    }

    void Unlock()
    {
        markerLock?.Dispose();
        markerLock = null;
    }
}
