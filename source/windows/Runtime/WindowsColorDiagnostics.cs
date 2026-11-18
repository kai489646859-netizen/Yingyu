using System.Globalization;
using System.Runtime.InteropServices;

namespace Yingyu.Update;

// Share the display-state classifier with playback. Diagnostics never write display settings.
internal static class WindowsColorDiagnostics
{
    internal static string Read(IntPtr hwnd)
    {
        try
        {
            if(hwnd==IntPtr.Zero||!IsWindow(hwnd))return "displayQuery=no-live-window; systemHdr=unknown";
            GetClientRect(hwnd,out var client);GetWindowRect(hwnd,out var outer);
            string window=$"windowState={(IsIconic(hwnd)?"minimized":IsZoomed(hwnd)?"maximized":"normal")}; windowVisible={IsWindowVisible(hwnd)}; clientWidth={Math.Max(0,client.R-client.L)}; clientHeight={Math.Max(0,client.B-client.T)}; outerWidth={Math.Max(0,outer.R-outer.L)}; outerHeight={Math.Max(0,outer.B-outer.T)}; windowDpi={GetDpiForWindow(hwnd)}; ";
            var display=WindowsHdrDisplay.ForWindow(hwnd,true);
            string mode=display.Mode switch{DisplayColorMode.Sdr=>"sdr",DisplayColorMode.Wcg=>"wcg",DisplayColorMode.Hdr=>"hdr",_=>"unknown"};
            if(display.Mode==DisplayColorMode.Unknown)return window+"displayQuery=unconfirmed; systemHdr=unknown";
            return window+$"displayQuery={(display.Modern?"ok":"legacy")}; systemColorMode={mode}; systemHdr={(display.HdrActive?"active":"inactive")}; "
                +$"hdrSupported={display.CanEnable||display.HdrActive}; hdrUserEnabled={display.UserEnabled}; displayBits={display.Bits}; displayEncoding={Encoding(display.Encoding)}; "
                +"systemSdrWhiteNits="+(display.SdrWhiteNits?.ToString("0.###",CultureInfo.InvariantCulture)??"unknown")+"; physicalLuminance=unmeasured";

        }
        catch(Exception e) when(e is ExternalException or ArgumentException or OverflowException or EntryPointNotFoundException or DllNotFoundException)
        {return "displayQuery=failed-"+e.GetType().Name+"; systemHdr=unknown";}
    }
    static string Encoding(uint x)=>x switch{0=>"rgb",1=>"ycbcr444",2=>"ycbcr422",3=>"ycbcr420",4=>"intensity",_=>"unknown"};
    [StructLayout(LayoutKind.Sequential)]struct Rect{public int L,T,R,B;}
    [DllImport("user32.dll")]static extern bool GetClientRect(IntPtr hwnd,out Rect rect);
    [DllImport("user32.dll")]static extern bool GetWindowRect(IntPtr hwnd,out Rect rect);
    [DllImport("user32.dll")]static extern bool IsIconic(IntPtr hwnd);
    [DllImport("user32.dll")]static extern bool IsZoomed(IntPtr hwnd);
    [DllImport("user32.dll")]static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")]static extern uint GetDpiForWindow(IntPtr hwnd);
    [DllImport("user32.dll")]static extern bool IsWindow(IntPtr hwnd);
}
