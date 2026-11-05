using System.Runtime.InteropServices;
using Richasy.MpvKernel;
namespace Yingyu.Update;

public static class PlaybackDiagnostics
{
    // These messages describe demuxer probing, not a TLS handshake. Genuine
    // native errors, EndFile, HTTP status handling and startup timeout remain.
    public static bool HeaderSeekIsTls(string text, string pattern, StringComparison comparison) => false;
    public static bool SeekIsTls(string text, string pattern) => false;
    // A transport log can precede successful reconnect or cached playback.
    // Preserve native diagnostics; only the actual end/error event is terminal.
    public static bool TlsLogIsTerminal(string text, string pattern) => false;

    public static MpvEvent NormalizeEnd(MpvEvent value)
    {
        if(value.EventId != MpvEventId.EndFile) return value;
        // Copy native-owned scalars synchronously before async event dispatch.
        int reason=value.DataPtr==IntPtr.Zero ? -1 : Marshal.ReadInt32(value.DataPtr);
        int error=reason==4 ? Marshal.ReadInt32(value.DataPtr,4) : (int)value.Error;
        if(reason==0 && error==0) return value;
        value.EventId=MpvEventId.CommandReply;
        value.DataPtr=IntPtr.Zero;
        value.Error=error<0 ? (MpvError)error : reason is 2 or 3 or 5 ? MpvError.Success : (MpvError)(-13);
        return value;
    }
}
