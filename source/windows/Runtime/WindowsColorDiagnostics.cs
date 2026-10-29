using System.Globalization;
using System.Runtime.InteropServices;

namespace Yingyu.Update;

// Read-only display metadata. No SetDisplayConfig, HDR toggle, registry, EDID,
// display name/serial persistence, screenshots, or physical color measurement.
internal static class WindowsColorDiagnostics
{
    [StructLayout(LayoutKind.Sequential)] struct Luid { public uint Low;public int High; }
    [StructLayout(LayoutKind.Sequential)] struct Header { public uint Type,Size;public Luid Adapter;public uint Id; }
    [StructLayout(LayoutKind.Sequential)] struct Color2 { public Header Header;public uint Flags,Encoding,Bits,Mode; }
    [StructLayout(LayoutKind.Sequential)] struct Color1 { public Header Header;public uint Flags,Encoding,Bits; }
    [StructLayout(LayoutKind.Sequential)] struct White { public Header Header;public uint Level; }
    [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)] struct SourceName
    { public Header Header;[MarshalAs(UnmanagedType.ByValTStr,SizeConst=32)]public string Name; }
    [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)] struct MonitorInfo
    { public uint Size;public int L,T,R,B,WL,WT,WR,WB;public uint Flags;[MarshalAs(UnmanagedType.ByValTStr,SizeConst=32)]public string Name; }
    internal static string Read(IntPtr hwnd)
    {
        try
        {
            if(hwnd==IntPtr.Zero||!IsWindow(hwnd))return "displayQuery=no-live-window; systemHdr=unknown";
            GetClientRect(hwnd,out var client);GetWindowRect(hwnd,out var outer);
            string window=$"windowState={(IsIconic(hwnd)?"minimized":IsZoomed(hwnd)?"maximized":"normal")}; windowVisible={IsWindowVisible(hwnd)}; clientWidth={Math.Max(0,client.R-client.L)}; clientHeight={Math.Max(0,client.B-client.T)}; outerWidth={Math.Max(0,outer.R-outer.L)}; outerHeight={Math.Max(0,outer.B-outer.T)}; windowDpi={GetDpiForWindow(hwnd)}; ";
            var monitor=MonitorFromWindow(hwnd,2);var info=new MonitorInfo{Size=(uint)Marshal.SizeOf<MonitorInfo>(),Name=""};
            if(monitor==IntPtr.Zero||!GetMonitorInfo(monitor,ref info))return "displayQuery=monitor-unavailable; systemHdr=unknown";
            int error=GetDisplayConfigBufferSizes(2,out uint paths,out uint modes);
            if(error!=0)return "displayQuery=size-error-"+error+"; systemHdr=unknown";
            if(paths is 0 or >64||modes>256)return "displayQuery=topology-limit; systemHdr=unknown";
            // SDK DISPLAYCONFIG_PATH_INFO = 72, MODE_INFO = 64, header = 20.
            IntPtr pathBuffer=Marshal.AllocHGlobal(checked((int)paths*72));
            IntPtr modeBuffer=Marshal.AllocHGlobal(checked(Math.Max(1,(int)modes)*64));
            try
            {
                error=QueryDisplayConfig(2,ref paths,pathBuffer,ref modes,modeBuffer,IntPtr.Zero);
                if(error!=0)return "displayQuery=topology-error-"+error+"; systemHdr=unknown";
                var matches=new List<(Luid Adapter,uint Id)>();
                for(int i=0;i<paths;i++)
                {
                    IntPtr p=IntPtr.Add(pathBuffer,i*72);
                    var source=new SourceName{Header=new(){Type=1,Size=(uint)Marshal.SizeOf<SourceName>(),Adapter=Marshal.PtrToStructure<Luid>(p),Id=(uint)Marshal.ReadInt32(p,8)},Name=""};
                    if(DisplayConfigGetDeviceInfo(ref source)!=0||!string.Equals(source.Name,info.Name,StringComparison.OrdinalIgnoreCase))continue;
                    matches.Add((Marshal.PtrToStructure<Luid>(IntPtr.Add(p,20)),(uint)Marshal.ReadInt32(p,28)));
                }
                if(matches.Count!=1)return $"displayQuery={(matches.Count>1?"cloned-target-ambiguous":"target-unmatched")}; systemHdr=unknown";
                var target=matches[0];var color=new Color2{Header=new(){Type=15,Size=(uint)Marshal.SizeOf<Color2>(),Adapter=target.Adapter,Id=target.Id}};
                int modern=DisplayConfigGetDeviceInfo(ref color);string result;
                if(modern==0)
                {
                    string mode=color.Mode switch{0=>"sdr",1=>"wcg",2=>"hdr",_=>"unknown"};
                    result=$"displayQuery=ok; systemColorMode={mode}; systemHdr={(mode=="hdr"?"active":mode=="unknown"?"unknown":"inactive")}; hdrSupported={(color.Flags&16)!=0}; hdrUserEnabled={(color.Flags&32)!=0}; displayBits={color.Bits}; displayEncoding={Encoding(color.Encoding)}";
                }
                else
                {
                    var legacy=new Color1{Header=new(){Type=9,Size=(uint)Marshal.SizeOf<Color1>(),Adapter=target.Adapter,Id=target.Id}};
                    int old=DisplayConfigGetDeviceInfo(ref legacy);
                    result=old==0?$"displayQuery=legacy; modernQueryCode={modern}; advancedColorSupported={(legacy.Flags&1)!=0}; advancedColorEnabled={(legacy.Flags&2)!=0}; systemHdr=unknown-legacy-hdr-wcg-not-separated; displayBits={legacy.Bits}; displayEncoding={Encoding(legacy.Encoding)}":$"displayQuery=color-error-{old}; modernQueryCode={modern}; systemHdr=unknown";
                }
                var white=new White{Header=new(){Type=11,Size=(uint)Marshal.SizeOf<White>(),Adapter=target.Adapter,Id=target.Id}};
                int whiteError=DisplayConfigGetDeviceInfo(ref white);
                return window+result+"; systemSdrWhiteNits="+(whiteError==0&&white.Level>0?(white.Level*.08).ToString("0.###",CultureInfo.InvariantCulture):"unknown")+$"; sdrWhiteQueryCode={whiteError}; physicalLuminance=unmeasured";
            }
            finally{Marshal.FreeHGlobal(pathBuffer);Marshal.FreeHGlobal(modeBuffer);}
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
    [DllImport("user32.dll")]static extern IntPtr MonitorFromWindow(IntPtr hwnd,uint flags);
    [DllImport("user32.dll",EntryPoint="GetMonitorInfoW",CharSet=CharSet.Unicode)]static extern bool GetMonitorInfo(IntPtr monitor,ref MonitorInfo info);
    [DllImport("user32.dll")]static extern int GetDisplayConfigBufferSizes(uint flags,out uint paths,out uint modes);
    [DllImport("user32.dll")]static extern int QueryDisplayConfig(uint flags,ref uint paths,IntPtr pathArray,ref uint modes,IntPtr modeArray,IntPtr topology);
    [DllImport("user32.dll",EntryPoint="DisplayConfigGetDeviceInfo")]static extern int DisplayConfigGetDeviceInfo(ref SourceName data);
    [DllImport("user32.dll",EntryPoint="DisplayConfigGetDeviceInfo")]static extern int DisplayConfigGetDeviceInfo(ref Color2 data);
    [DllImport("user32.dll",EntryPoint="DisplayConfigGetDeviceInfo")]static extern int DisplayConfigGetDeviceInfo(ref Color1 data);
    [DllImport("user32.dll",EntryPoint="DisplayConfigGetDeviceInfo")]static extern int DisplayConfigGetDeviceInfo(ref White data);
}
