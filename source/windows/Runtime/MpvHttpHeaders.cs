using System.Runtime.InteropServices;
using Richasy.MpvKernel;

namespace Yingyu.Update;

// http-header-fields is a string-list, not a newline-delimited string option.
// Use the existing MpvNative resolver so this handle stays on the same core.
public static class MpvHttpHeaders
{
    public static Task<MpvError> SetAsync(MpvInteropHandle handle, Dictionary<string, string> headers)
    {
        var fields = BuildFields(headers);
        if (fields == null) return Task.FromResult(MpvError.InvalidParameter);
        return Task.Run(() => Apply(handle, fields, MpvNative.SetOption));
    }

    internal static string[]? BuildFields(Dictionary<string, string> headers)
    {
        ArgumentNullException.ThrowIfNull(headers);
        var fields = new string[headers.Count];
        int index = 0;
        foreach (var pair in headers)
        {
            // Reject injected line boundaries without logging names or values.
            // Commas, backslashes, quotes and UTF-8 remain literal node contents.
            if (string.IsNullOrEmpty(pair.Key) || pair.Key.Contains(':') ||
                HasControlBoundary(pair.Key) || HasControlBoundary(pair.Value)) return null;
            fields[index++] = pair.Key + ": " + pair.Value;
        }
        return fields;
    }

    static bool HasControlBoundary(string? value) => value != null && value.IndexOfAny(['\r', '\n', '\0']) >= 0;

    internal delegate MpvError NodeSetter(MpvInteropHandle handle, string name, MpvFormat format, ref MpvNode data);

    internal static MpvError Apply(MpvInteropHandle handle, string[] fields, NodeSetter setter)
    {
        using var buffer = new NodeBuffer(fields);
        var node = buffer.Root;
        // The top-level format is NODE; the root itself is NODE_ARRAY.
        // mpv copies option input during this call, before the buffer is freed.
        return setter(handle, "http-header-fields", MpvFormat.Node, ref node);
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct ListLayout
    {
        public int Count;
        public IntPtr Values;
        public IntPtr Keys;
    }

    [StructLayout(LayoutKind.Explicit, Size = 16)]
    internal struct NodeLayout
    {
        [FieldOffset(0)] public IntPtr Pointer;
        [FieldOffset(8)] public MpvFormat Format;
    }

    internal sealed class NodeBuffer : IDisposable
    {
        readonly List<IntPtr> _strings = new();
        internal IntPtr Nodes { get; private set; }
        internal IntPtr List { get; private set; }
        internal MpvNode Root { get; private set; }

        internal NodeBuffer(string[] fields)
        {
            try
            {
                // Reserve tracking storage before unmanaged allocation so an
                // Add failure cannot leave an allocated UTF-8 string untracked.
                _strings.EnsureCapacity(fields.Length);
                int nodeSize = Marshal.SizeOf<MpvNode>();
                if (fields.Length != 0) Nodes = Marshal.AllocHGlobal(checked(nodeSize * fields.Length));
                for (int index = 0; index < fields.Length; index++)
                {
                    var value = Marshal.StringToCoTaskMemUTF8(fields[index]);
                    _strings.Add(value);
                    // Write the native union without mutating MpvNode's readonly
                    // pointer/integer fields or using reflection on that type.
                    var child = new NodeLayout { Pointer = value, Format = MpvFormat.String };
                    Marshal.StructureToPtr(child, IntPtr.Add(Nodes, checked(index * nodeSize)), false);
                }
                List = Marshal.AllocHGlobal(Marshal.SizeOf<ListLayout>());
                Marshal.StructureToPtr(new ListLayout { Count = fields.Length, Values = Nodes, Keys = IntPtr.Zero }, List, false);
                var root = Marshal.AllocHGlobal(nodeSize);
                try
                {
                    Marshal.StructureToPtr(new NodeLayout { Pointer = List, Format = MpvFormat.NodeArray }, root, false);
                    Root = Marshal.PtrToStructure<MpvNode>(root);
                }
                finally { Marshal.FreeHGlobal(root); }
            }
            catch
            {
                Dispose();
                throw;
            }
        }

        public void Dispose()
        {
            foreach (var value in _strings) Marshal.FreeCoTaskMem(value);
            _strings.Clear();
            if (Nodes != IntPtr.Zero) Marshal.FreeHGlobal(Nodes);
            if (List != IntPtr.Zero) Marshal.FreeHGlobal(List);
            Nodes = IntPtr.Zero;
            List = IntPtr.Zero;
            Root = default;
        }
    }
}
