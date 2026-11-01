using System.Runtime.InteropServices;
using Richasy.MpvKernel;

namespace Yingyu.Update;

// Own every allocation immediately, including failures while building argv.
internal sealed class NativeArguments : IDisposable
{
    readonly IntPtr[] strings;
    internal IntPtr Pointer { get; private set; }
    internal NativeArguments(string[] values)
    {
        ArgumentNullException.ThrowIfNull(values);
        strings = new IntPtr[values.Length];
        try
        {
            Pointer = Marshal.AllocHGlobal(checked(IntPtr.Size * (values.Length + 1)));
            for (int i = 0; i < values.Length; i++)
            {
                strings[i] = Marshal.StringToCoTaskMemUTF8(values[i]);
                Marshal.WriteIntPtr(Pointer, i * IntPtr.Size, strings[i]);
            }
            Marshal.WriteIntPtr(Pointer, values.Length * IntPtr.Size, IntPtr.Zero);
        }
        catch { Dispose(); throw; }
    }
    public void Dispose()
    {
        for (int i = 0; i < strings.Length; i++)
        { Marshal.FreeCoTaskMem(strings[i]); strings[i] = IntPtr.Zero; }
        Marshal.FreeHGlobal(Pointer); Pointer = IntPtr.Zero;
    }
}

public static class NativeCommands
{
    public static MpvError Send(MpvInteropHandle handle, string[] values, Func<MpvInteropHandle, IntPtr, MpvError> invoke)
    {
        using var arguments = new NativeArguments(values);
        return invoke(handle, arguments.Pointer);
    }
}
