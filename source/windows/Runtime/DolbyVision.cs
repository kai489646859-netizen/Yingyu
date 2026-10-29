using System.Reflection;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using EmbyDesktop.Core.Models;

namespace Yingyu.Update;

public static class DolbyVision
{
    // Use one native core consistently: cached P/Invoke entry points cannot safely
    // be switched between two mpv libraries in the same process.
    static string CoreFile => Path.Combine(AppContext.BaseDirectory, "Components", "NativeDolby", "libmpv-2.dll");
    public static string CorePath() { _ = Native.Value; return CoreFile; }
    static readonly Lazy<Api> Native = new(() => new Api());
    static readonly ConditionalWeakTable<object, object> Configured = new();
    public static IntPtr Handle(object session)
    {
        object client = Access.Get<object>(session, "_mpvClient");
        object handle = client.GetType().GetProperty("Handle")!.GetValue(client)!;
        return (IntPtr)handle.GetType().GetProperty("Handle")!.GetValue(handle)!;
    }
    public static void Configure(object session)
    {
        PlaybackTransport.Configure(session);
        PlayerPresentation.Configure(session);
        object? client = Access.Get<object?>(session, "_mpvClient");
        if (client == null || Configured.TryGetValue(client, out _)) return;
        // This core already enables RPU and enhancement-layer processing by default.
        // Avoid adding a filter to ordinary SDR/HDR media or changing hardware frames.
        Configured.Add(client, new object());
        if(PlaybackTransport.Set((Richasy.MpvKernel.Core.MpvClient)client,"load-stats-overlay","yes")<0)
            PlaybackTransport.Write("Warning","Playback.Info","MPV 原生统计脚本未能启用。");
        Log("按 HDR（测试）设置输出 SDR 或 HDR；保留 RPU/增强层处理，原生杜比信令已停用。 ");
    }
    internal static int ShowText(Richasy.MpvKernel.Core.MpvClient client,string text)
        =>CommandAsync(client,"show-text",text,"3000");
    internal static int CommandAsync(Richasy.MpvKernel.Core.MpvClient client,params string[] values)
    {
        var strings=values.Select(Marshal.StringToCoTaskMemUTF8).ToArray();
        IntPtr argv=Marshal.AllocHGlobal(IntPtr.Size*(strings.Length+1));
        try{for(int i=0;i<strings.Length;i++)Marshal.WriteIntPtr(argv,i*IntPtr.Size,strings[i]);Marshal.WriteIntPtr(argv,strings.Length*IntPtr.Size,IntPtr.Zero);return Native.Value.CommandAsync(PlaybackTransport.Handle(client),0,argv);}
        finally{foreach(var value in strings)Marshal.FreeCoTaskMem(value);Marshal.FreeHGlobal(argv);}
    }
    internal static int SignalUi(Richasy.MpvKernel.Core.MpvClient client,bool safe)
    {
        int value=safe?1:0;
        return Native.Value.SetAsync(PlaybackTransport.Handle(client),0,"native-dolby-ui-safe",3,ref value);
    }
    public static void Report(object session) => MediaNotice.Refresh(session);
    internal static void Log(string text)
    {
        try { Assembly.Load("Yingyu").GetType("EmbyDesktop.Services.AppLog")!.GetMethod("Info",
            BindingFlags.Static | BindingFlags.Public | BindingFlags.NonPublic)!.Invoke(null, new object[] { "Playback.DolbyVision", text }); }
        catch { }
    }
    static bool Closing(object session) => (bool)session.GetType().GetProperty("_isClosing",
        BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic)!.GetValue(session)!;
    sealed class Api
    {
        readonly IntPtr _library;
        readonly GetFn _get;
        readonly FreeFn _free;
        internal readonly CommandFn Command;
        internal readonly SetAsyncFn SetAsync;
        internal readonly CommandAsyncFn CommandAsync;
        internal Api()
        {
            // Explicitly search this component's folder for the bundled Vulkan
            // loader before Richasy resolves its cached native entry points.
            _library = LoadLibraryEx(CoreFile, IntPtr.Zero, 0x1100);
            if (_library == IntPtr.Zero) throw new InvalidOperationException("杜比播放组件加载失败，错误=" + Marshal.GetLastWin32Error());
            T Get<T>(string name) where T : Delegate => Marshal.GetDelegateForFunctionPointer<T>(GetProcAddress(_library, name));
            Command=Get<CommandFn>("mpv_command_string"); _get=Get<GetFn>("mpv_get_property_string"); _free=Get<FreeFn>("mpv_free");
            SetAsync=Get<SetAsyncFn>("mpv_set_property_async");
            CommandAsync=Get<CommandAsyncFn>("mpv_command_async");
        }
        internal string Get(IntPtr handle, string property)
        {
            IntPtr text = _get(handle, property);
            if (text == IntPtr.Zero) return "";
            try { return Marshal.PtrToStringUTF8(text) ?? ""; }
            finally { _free(text); }
        }
    }
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int CommandFn(IntPtr handle, [MarshalAs(UnmanagedType.LPUTF8Str)] string command);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate IntPtr GetFn(IntPtr handle, [MarshalAs(UnmanagedType.LPUTF8Str)] string property);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate void FreeFn(IntPtr text);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] internal delegate int SetAsyncFn(IntPtr handle,ulong userdata,[MarshalAs(UnmanagedType.LPUTF8Str)] string property,int format,ref int value);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] internal delegate int CommandAsyncFn(IntPtr handle,ulong userdata,IntPtr arguments);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern IntPtr LoadLibraryEx(string path, IntPtr file, uint flags);
    [DllImport("kernel32.dll", CharSet=CharSet.Ansi, ExactSpelling=true)] static extern IntPtr GetProcAddress(IntPtr module, string name);
}
