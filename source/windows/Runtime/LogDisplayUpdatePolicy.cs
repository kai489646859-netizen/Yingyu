using System.Collections.ObjectModel;

namespace Yingyu.Update;

// WinUI's collection bridge uses single-index change notifications. Keep each
// UI transaction small, retain the same source/items, and settle its viewport
// before yielding; never use Reset or a multi-item notification to trim it.
internal static class LogDisplayUpdatePolicy
{
    internal const int RowsPerSlice = 32;
    internal static int Apply<T>(ObservableCollection<T> visible, IReadOnlyList<T> incoming, ref int next, int maximum)
    {
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(maximum);
        ArgumentOutOfRangeException.ThrowIfNegative(next);
        if (next > incoming.Count) throw new ArgumentOutOfRangeException(nameof(next));
        int end = next + Math.Min(RowsPerSlice, incoming.Count - next);
        while (next < end)
        {
            // Removal and prepend are in the same UI turn. The UI source never
            // exceeds the user's capacity, even inside a change callback.
            if (visible.Count == maximum) visible.RemoveAt(visible.Count-1);
            int beforeAdd = visible.Count;
            try { visible.Insert(0,incoming[next]); }
            finally
            {
                // ObservableCollection changes its items before notifying UI.
                // A notification failure must still consume an inserted row;
                // an Add rejected before mutation must retain its cursor.
                // A failed Remove leaves next unchanged and count below the
                // limit, so a retry fills that vacancy instead of trimming again.
                if (visible.Count == beforeAdd + 1) next++;
            }
        }
        return next;
    }
}
