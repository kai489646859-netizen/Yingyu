using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace Yingyu.LogCenter;

internal sealed record TailBatch(bool Reset, IReadOnlyList<LogRow> Rows, string Status);

// Only the existing local log is opened. No media handle or network source
// is accessed; the file is shared with the original log writer.
internal sealed class LocalLogTail
{
    internal static readonly string DirectoryPath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "映屿", "日志");
    internal const int MaximumRows = 10_000;
    internal const int InitialBytes = 4 * 1024 * 1024;
    internal const int IncrementBytes = 256 * 1024;
    readonly BoundedLines _lines = new();
    readonly ChineseLogParser _parser = new();
    long _offset;
    string? _identity;
    public void Reset() { _identity = null; _offset = 0; _lines.Reset(false); _parser.Reset(); }
    internal async Task<TailBatch> ReadAsync(CancellationToken token)
    {
        string path = Path.Combine(DirectoryPath, "映屿.log");
        FileStream file;
        try { file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, 64 * 1024, FileOptions.Asynchronous | FileOptions.SequentialScan); }
        catch (FileNotFoundException) { return new(false, [], "尚未发现本机日志，等待软件记录。 "); }
        catch (DirectoryNotFoundException) { return new(false, [], "尚未发现本机日志目录，等待软件记录。 "); }
        await using (file)
        {
            string identity = Identity(file, path);
            long length = file.Length;
            bool firstRead = _identity == null;
            bool changedFile = _identity != identity || length < _offset;
            // Stage the cursor until reading succeeds. A canceled first read
            // or rotation must not consume the file identity/history position.
            long readOffset = changedFile ? (firstRead ? Math.Max(0, length - InitialBytes) : 0) : _offset;
            file.Position = readOffset;
            int limit = firstRead ? InitialBytes : IncrementBytes;
            var bytes = new byte[(int)Math.Min(limit, Math.Max(0, length - readOffset))];
            int used = 0;
            while (used < bytes.Length)
            {
                int count = await file.ReadAsync(bytes.AsMemory(used), token).ConfigureAwait(false);
                if (count == 0) break;
                used += count;
            }
            token.ThrowIfCancellationRequested();
            if (changedFile)
            {
                _identity = identity;
                // Rotation/truncation starts from zero and appends to the
                // same visible collection; only initial history skips a prefix.
                _lines.Reset(readOffset > 0); _parser.Reset();
            }
            // Capacity is only storage, not the retained-row limit below.
            // Idle/small reads need no 10,000-entry allocation every second.
            var rows = new Queue<LogRow>(Math.Min(MaximumRows, used));
            foreach (string line in _lines.Feed(bytes.AsSpan(0, used)))
            {
                // Parsing and cursor commit have no await/cancellation gap.
                // Once bytes enter the parser, return their rows together so
                // hiding the page cannot lose them and force a history reset.
                if (_parser.Parse(line) is not { } row) continue;
                rows.Enqueue(row);
                if (rows.Count > MaximumRows) rows.Dequeue();
            }
            _offset = readOffset + used;
            return new(firstRead, rows.ToArray(), _offset < length ? "正在补充本地新增记录。" : "本地日志已更新。");
        }
    }
    static string Identity(FileStream file, string path)
    {
        if (GetFileInformationByHandle(file.SafeFileHandle, out var info))
            return $"{info.VolumeSerialNumber:X8}:{info.FileIndexHigh:X8}:{info.FileIndexLow:X8}";
        return File.GetCreationTimeUtc(path).Ticks.ToString(System.Globalization.CultureInfo.InvariantCulture);
    }
    [StructLayout(LayoutKind.Sequential)] struct FileInformation
    {
        public uint Attributes;
        public System.Runtime.InteropServices.ComTypes.FILETIME Creation, Access, Write;
        public uint VolumeSerialNumber, SizeHigh, SizeLow, Links, FileIndexHigh, FileIndexLow;
    }
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetFileInformationByHandle(SafeFileHandle handle, out FileInformation information);
}

// Partial UTF-8 characters and lines survive refreshes. Oversized lines are
// discarded through their newline so malformed input cannot grow indefinitely.
internal sealed class BoundedLines
{
    internal const int MaxLineCharacters = 16 * 1024;
    Decoder _decoder = Encoding.UTF8.GetDecoder();
    readonly StringBuilder _partial = new();
    bool _discard;
    internal void Reset(bool discardFirst) { _decoder = Encoding.UTF8.GetDecoder(); _partial.Clear(); _discard = discardFirst; }
    internal IReadOnlyList<string> Feed(ReadOnlySpan<byte> bytes)
    {
        char[] chars = new char[Encoding.UTF8.GetMaxCharCount(bytes.Length)];
        int count = _decoder.GetChars(bytes, chars, false);
        var lines = new List<string>();
        for (int i = 0; i < count; i++)
        {
            char c = chars[i];
            if (c == '\n')
            {
                if (!_discard) lines.Add(_partial.ToString().TrimEnd('\r'));
                _partial.Clear(); _discard = false;
            }
            else if (!_discard)
            {
                if (_partial.Length >= MaxLineCharacters) { _partial.Clear(); _discard = true; lines.Add("日志中心：一条超长记录已省略，原日志保留。"); }
                else _partial.Append(c);
            }
        }
        return lines;
    }
    internal string? Finish()
    {
        if (_discard || _partial.Length == 0) return null;
        string last = _partial.ToString().TrimEnd('\r'); _partial.Clear(); return last;
    }
}
