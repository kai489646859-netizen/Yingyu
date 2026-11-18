using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;

namespace Yingyu.Update;

internal enum DisplayColorMode { Unknown, Sdr, Wcg, Hdr }
internal readonly record struct HdrDisplay(string? Key, DisplayColorMode Mode, bool CanEnable,
    bool? UserEnabled, uint Bits, uint Encoding, bool Modern, double? SdrWhiteNits = null, int? PeakNits = null)
{
    internal bool HdrActive => Mode == DisplayColorMode.Hdr;
}

internal static class WindowsHdrDisplay
{
    const uint ActivePaths = 2;
    const int InsufficientBuffer = 122;

    internal static IntPtr Window(object session)
        => Access.Get<object?>(session, "_window") is {} window
            && window.GetType().GetProperty("Handle")?.GetValue(window) is IntPtr handle ? handle : IntPtr.Zero;

    internal static HdrDisplay ForWindow(IntPtr window) => ForWindow(window, false);

    internal static HdrDisplay ForWindow(IntPtr window, bool includeSdrWhite)
    {
        if (window == IntPtr.Zero || !IsWindow(window)) return default;
        IntPtr monitor = MonitorFromWindow(window, 2);
        var info = new MonitorInfo { Size = (uint)Marshal.SizeOf<MonitorInfo>(), Name = "" };
        if (monitor == IntPtr.Zero || !GetMonitorInfo(monitor, ref info)) return default;
        var matches = Paths().Where(path => StringComparer.OrdinalIgnoreCase.Equals(Source(path), info.Name)).Distinct().ToArray();
        // A clone group has more than one physical target and no single HDR state.
        if (matches.Length != 1) return default;
        var display = Describe(matches[0]);
        if (!includeSdrWhite) return display;
        var white = new White { Header = Request<White>(11,matches[0].Target) };
        return DisplayConfigGetDeviceInfo(ref white) == 0 && white.Level > 0
            ? display with { SdrWhiteNits = white.Level * .08 } : display;
    }

    internal static int? ReadHdrPeak(IntPtr window, string expectedDisplay)
    {
        if (window == IntPtr.Zero || !IsWindow(window)) return null;
        IntPtr monitor = MonitorFromWindow(window, 0);
        var info = new MonitorInfo { Size = (uint)Marshal.SizeOf<MonitorInfo>(), Name = "" };
        if (monitor == IntPtr.Zero || !GetMonitorInfo(monitor, ref info)) return null;
        var matches = Paths().Where(path => StringComparer.OrdinalIgnoreCase.Equals(Source(path), info.Name))
            .Distinct().ToArray();
        if (matches.Length != 1 || Key(matches[0].Target) != expectedDisplay) return null;
        var target = matches[0].Target;
        return ReadDxgiPeak(monitor, new AdapterLuid(target.AdapterLow,target.AdapterHigh));
    }

    // IDXGIFactory4::EnumAdapterByLuid resolves the output even when the
    // renderer itself uses a composition swap chain or another render GPU.
    static int? ReadDxgiPeak(IntPtr monitor, AdapterLuid luid)
    {
        Guid factoryId = new("1bc6ea02-ef36-464f-bf0c-21ca39e5168a");
        Guid adapterId = new("2411e7e1-12ac-4ccf-bd14-9798e8534dc0");
        Guid outputId = new("068346e8-aaec-4b84-add7-137f513f77a1");
        if (CreateDXGIFactory1(ref factoryId,out var factory) < 0 || factory == IntPtr.Zero) return null;
        try
        {
            const int enumAdapterByLuid = 26, enumOutputs = 7, getDesc1 = 27;
            if (Method<EnumAdapter>(factory,enumAdapterByLuid)(factory,luid,ref adapterId,out var adapter) < 0
                || adapter == IntPtr.Zero) return null;
            try
            {
                var enumerate = Method<EnumOutput>(adapter,enumOutputs);
                for (uint index = 0; index < 64; index++)
                {
                    if (enumerate(adapter,index,out var output) < 0 || output == IntPtr.Zero) break;
                    try
                    {
                        if (Marshal.QueryInterface(output,in outputId,out var output6) < 0) continue;
                        try
                        {
                            if (Method<GetOutputDesc>(output6,getDesc1)(output6,out var desc) >= 0
                                && desc.Monitor == monitor && desc.Attached != 0)
                                return HdrPeak(desc.ColorSpace,desc.MaxLuminance);
                        }
                        finally { Marshal.Release(output6); }
                    }
                    finally { Marshal.Release(output); }
                }
            }
            finally { Marshal.Release(adapter); }
        }
        finally { Marshal.Release(factory); }
        return null;
    }

    // DXGI_COLOR_SPACE_RGB_FULL_G2084_NONE_P2020 is Windows' HDR desktop
    // mode. Reject SDR defaults, invalid descriptor values, and future modes
    // whose luminance semantics have not been verified.
    internal static int? HdrPeak(uint colorSpace, float maximum)
        => colorSpace == 12 && float.IsFinite(maximum) && maximum is >= 100 and <= 10000
            ? (int)Math.Round(maximum) : null;

    static T Method<T>(IntPtr instance, int slot) where T : Delegate
        => Marshal.GetDelegateForFunctionPointer<T>(Marshal.ReadIntPtr(Marshal.ReadIntPtr(instance), slot * IntPtr.Size));

    [StructLayout(LayoutKind.Sequential)] readonly record struct AdapterLuid(uint Low, int High);
    // DXGI_OUTPUT_DESC1 layout for the x64 installer runtime. The 8 float
    // chromaticity coordinates precede the three luminance values.
    [StructLayout(LayoutKind.Explicit, Size = 152)] struct OutputDescription
    {
        [FieldOffset(80)] public int Attached;
        [FieldOffset(88)] public IntPtr Monitor;
        [FieldOffset(100)] public uint ColorSpace;
        [FieldOffset(140)] public float MaxLuminance;
    }
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    delegate int EnumAdapter(IntPtr self, AdapterLuid luid, ref Guid iid, out IntPtr adapter);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    delegate int EnumOutput(IntPtr self, uint index, out IntPtr output);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    delegate int GetOutputDesc(IntPtr self, out OutputDescription description);
    [DllImport("dxgi.dll")] static extern int CreateDXGIFactory1(ref Guid iid, out IntPtr factory);

    internal static HdrDisplay ByKey(string key)
    {
        var targets = FindTargets(key);
        return targets.Length == 1 ? Describe(targets[0], key) : default;
    }

    internal static bool SetHdr(string key, bool enable)
    {
        var targets = FindTargets(key);
        if (targets.Length != 1) return false;
        var display = Describe(targets[0], key);
        if (display.Mode == DisplayColorMode.Unknown || (enable && !display.CanEnable)
            || display.UserEnabled != !enable) return false;
        // Use the HDR-specific packet when Windows exposes the API that separates
        // WCG from HDR. The legacy packet is used only on the old, distinguishable path.
        var packet = new SetColor { Header = Request<SetColor>(display.Modern ? 16u : 10u, targets[0].Target),
            Enable = enable ? 1u : 0u };
        int result = DisplayConfigSetDeviceInfo(ref packet);
        if (result != 0)
            PlaybackTransport.Write("Warning", "Playback.HDR", "Windows HDR 切换未获系统接受；代码=" + result);
        return result == 0;
    }

    static Path[] FindTargets(string key)
        => Paths().Where(path => StringComparer.Ordinal.Equals(Key(path.Target), key))
            .GroupBy(path => path.Target).Select(group => group.First()).ToArray();

    static HdrDisplay Describe(Path path, string? key = null)
    {
        key ??= Key(path.Target);
        var modern = new Color2 { Header = Request<Color2>(15, path.Target) };
        if (DisplayConfigGetDeviceInfo(ref modern) == 0)
            return ModernState(key, modern.Flags, modern.Mode, modern.Bits, modern.Encoding);
        var legacy = new Color1 { Header = Request<Color1>(9, path.Target) };
        return DisplayConfigGetDeviceInfo(ref legacy) == 0
            ? LegacyState(key, legacy.Flags, legacy.Bits, legacy.Encoding) : default;
    }

    internal static HdrDisplay ModernState(string? key, uint flags, uint mode, uint bits, uint encoding)
        => new(key, mode switch { 0 => DisplayColorMode.Sdr, 1 => DisplayColorMode.Wcg,
            2 => DisplayColorMode.Hdr, _ => DisplayColorMode.Unknown },
            (flags & 16) != 0 && (flags & 8) == 0, (flags & 32) != 0, bits, encoding, true);

    internal static HdrDisplay LegacyState(string? key, uint flags, uint bits, uint encoding)
    {
        // Legacy bit 2 is wideColorEnforced. Some older WDDM versions cannot
        // distinguish ACM from HDR: reject ambiguous or inconsistent flag sets.
        bool supported = (flags & 1) != 0, active = (flags & 2) != 0, wcg = (flags & 4) != 0;
        var mode = wcg ? DisplayColorMode.Wcg : active
            ? supported ? DisplayColorMode.Hdr : DisplayColorMode.Unknown : DisplayColorMode.Sdr;
        return new(key, mode, supported && !wcg && (flags & 8) == 0,
            mode == DisplayColorMode.Unknown ? null : mode == DisplayColorMode.Hdr, bits, encoding, false);
    }

    static string? Source(Path path)
    {
        var request = new SourceName { Header = Request<SourceName>(1, path.Source), Name = "" };
        return DisplayConfigGetDeviceInfo(ref request) == 0 ? request.Name : null;
    }

    static string? Key(Endpoint target)
    {
        var request = new TargetName { Header = Request<TargetName>(2, target), FriendlyName = "", DevicePath = "" };
        if (DisplayConfigGetDeviceInfo(ref request) != 0 || string.IsNullOrWhiteSpace(request.DevicePath)) return null;
        return Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(request.DevicePath.ToUpperInvariant())));
    }

    static Path[] Paths()
    {
        for (int attempt = 0; attempt < 3; attempt++)
        {
            if (GetDisplayConfigBufferSizes(ActivePaths, out uint paths, out uint modes) != 0
                || paths is 0 or > 64 || modes > 256) return [];
            var pathBuffer = new PathInfo[paths];
            var modeBuffer = new ModeInfo[Math.Max(1, modes)];
            int status = QueryDisplayConfig(ActivePaths, ref paths, pathBuffer, ref modes, modeBuffer, IntPtr.Zero);
            if (status == InsufficientBuffer) continue;
            if (status != 0 || paths > pathBuffer.Length) return [];
            return pathBuffer.Take((int)paths).Select(path => new Path(path.Source, path.Target)).ToArray();
        }
        return [];
    }

    static Header Request<T>(uint type, Endpoint endpoint) where T : struct
        => new() { Type = type, Size = (uint)Marshal.SizeOf<T>(), Endpoint = endpoint };

    [StructLayout(LayoutKind.Sequential)] readonly record struct Endpoint(uint AdapterLow, int AdapterHigh, uint Id);
    readonly record struct Path(Endpoint Source, Endpoint Target);
    [StructLayout(LayoutKind.Sequential)] struct Header { public uint Type, Size; public Endpoint Endpoint; }
    [StructLayout(LayoutKind.Sequential)] struct Color2 { public Header Header; public uint Flags, Encoding, Bits, Mode; }
    [StructLayout(LayoutKind.Sequential)] struct Color1 { public Header Header; public uint Flags, Encoding, Bits; }
    [StructLayout(LayoutKind.Sequential)] struct White { public Header Header; public uint Level; }
    [StructLayout(LayoutKind.Sequential)] struct SetColor { public Header Header; public uint Enable; }
    [StructLayout(LayoutKind.Explicit, Size = 72)] struct PathInfo
    { [FieldOffset(0)] public Endpoint Source; [FieldOffset(20)] public Endpoint Target; }
    [StructLayout(LayoutKind.Explicit, Size = 64)] struct ModeInfo { [FieldOffset(0)] public long Alignment; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] struct SourceName
    { public Header Header; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string Name; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] struct TargetName
    {
        public Header Header;
        public uint Flags, Technology;
        public ushort EdidManufacturer, EdidProduct;
        public uint ConnectorInstance;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string FriendlyName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DevicePath;
    }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] struct MonitorInfo
    {
        public uint Size;
        public int Left, Top, Right, Bottom, WorkLeft, WorkTop, WorkRight, WorkBottom;
        public uint Flags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string Name;
    }
    [DllImport("user32.dll")] static extern bool IsWindow(IntPtr window);
    [DllImport("user32.dll")] static extern IntPtr MonitorFromWindow(IntPtr window, uint flags);
    [DllImport("user32.dll", EntryPoint = "GetMonitorInfoW", CharSet = CharSet.Unicode)] static extern bool GetMonitorInfo(IntPtr monitor, ref MonitorInfo info);
    [DllImport("user32.dll")] static extern int GetDisplayConfigBufferSizes(uint flags, out uint paths, out uint modes);
    [DllImport("user32.dll")] static extern int QueryDisplayConfig(uint flags, ref uint paths, [Out] PathInfo[] pathArray,
        ref uint modes, [Out] ModeInfo[] modeArray, IntPtr topology);
    [DllImport("user32.dll")] static extern int DisplayConfigGetDeviceInfo(ref Color2 data);
    [DllImport("user32.dll")] static extern int DisplayConfigGetDeviceInfo(ref Color1 data);
    [DllImport("user32.dll")] static extern int DisplayConfigGetDeviceInfo(ref SourceName data);
    [DllImport("user32.dll")] static extern int DisplayConfigGetDeviceInfo(ref TargetName data);
    [DllImport("user32.dll")] static extern int DisplayConfigGetDeviceInfo(ref White data);
    [DllImport("user32.dll")] static extern int DisplayConfigSetDeviceInfo(ref SetColor data);
}
