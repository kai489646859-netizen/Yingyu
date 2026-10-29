using System.Diagnostics;
using System.Runtime.InteropServices;

namespace Yingyu.Update;

// Process-wide counters only. Each snapshot closes its temporary process
// handle. Reuse the playback timer; no additional worker or media query.
internal static class ProcessResources
{
    internal static string Read()
    {
        try
        {
            using var process=Process.GetCurrentProcess();
            int handles=process.HandleCount,threads=process.Threads.Count;
            long privateBytes=process.PrivateMemorySize64,workingBytes=process.WorkingSet64;
            uint gdi=GetGuiResources(process.Handle,0),user=GetGuiResources(process.Handle,1);
            return $"scope=process; handles={handles}; threads={threads}; privateBytes={privateBytes}; workingSetBytes={workingBytes}; managedBytes={GC.GetTotalMemory(false)}; gdiObjects={gdi}; userObjects={user}";
        }
        catch(Exception error) when(error is System.ComponentModel.Win32Exception or InvalidOperationException or NotSupportedException)
        { return "scope=process; resourceQuery=unavailable; type="+error.GetType().Name; }
    }
    [DllImport("user32.dll")]static extern uint GetGuiResources(IntPtr process,uint flags);
}
