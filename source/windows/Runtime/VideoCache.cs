using System.Collections.Concurrent;
using System.Net;
using System.Net.Http;
using System.Reflection;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using EmbyDesktop.Core.Models;
using EmbyDesktop.Core.Services;
using Richasy.MpvKernel.Core;
using Richasy.MpvKernel.Core.Models;

namespace Yingyu.Update;

public static class VideoCache
{
    const string Protocol = "yingyu-video";
    static readonly ConditionalWeakTable<object, Owner> Owners = new();
    static readonly ConditionalWeakTable<MpvClient, object> Registered = new();
    static readonly ConcurrentDictionary<string, Owner> Active = new();
    static readonly object RegistrationGate = new();
    static readonly AsyncLocal<string?> IsoIdentity = new();
    static readonly OpenFn OpenCallback = Open;
    static readonly ReadFn ReadCallback = Read;
    static readonly SeekFn SeekCallback = Seek;
    static readonly SizeFn SizeCallback = Size;
    static readonly CloseFn CloseCallback = Close;
    static readonly CancelFn CancelCallback = Cancel;
    internal static string? CurrentIsoScope => IsoIdentity.Value;

    public static Task PlayAsync(MpvClient client, string address, MpvPlayOptions options, object session)
        =>EpisodePlaybackIntent.Play(session,()=>DolbyHdrFallback.Play(session,()=>PlayWithCache(client,address,options,session)));
    static Task PlayWithCache(MpvClient client, string address, MpvPlayOptions options, object session)
    {
        if(NetworkBluray.ConsumeMenuStart(session))options.StartPosition=0;
        Stop(session);
        var source = Access.Get<MediaSourceInfo>(session, "_source");
        if (VideoCacheSettings.LimitGB == 0 || source.IsInfiniteStream == true ||
            !Uri.TryCreate(address, UriKind.Absolute, out var uri) || uri.Scheme is not ("http" or "https") ||
            new[] { "m3u8", "m3u", "mpd" }.Contains((source.Container ?? "").TrimStart('.'), StringComparer.OrdinalIgnoreCase))
            return client.PlayAsync(address, options);
        var api = Access.Get<EmbyApiClient>(session, "_embyClient");
        string user = Access.Get<string>(api, "_userId");
        if (string.IsNullOrEmpty(user) || string.IsNullOrEmpty(source.Id)) return client.PlayAsync(address, options);
        var item = Access.Get<EmbyItem>(session, "_item");
        string scope = VideoCacheStore.Hash(api.ServerUrl, user, item.Id, source.Id);
        Owner owner;
        try
        {
            Register(client);
            var headers = new Dictionary<string, string>(options.HttpHeaders ?? new(), StringComparer.OrdinalIgnoreCase);
            if (!string.IsNullOrWhiteSpace(options.UserAgent)) headers["User-Agent"] = options.UserAgent;
            string proxy = Access.Get<string>(session, "_proxyAddress");
            owner = new Owner(uri, scope, headers, proxy, VideoCacheSettings.Store);
            Owners.Add(session, owner); Active[owner.Address] = owner;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or System.ComponentModel.Win32Exception)
        {
            VideoCacheSettings.Warning = "视频缓存暂不可用，继续直接播放";
            return client.PlayAsync(address, options);
        }
        return PlayCore(client, owner, options);
    }
    static async Task PlayCore(MpvClient client, Owner owner, MpvPlayOptions options)
    {
        try { await client.PlayAsync(owner.Address, options).ConfigureAwait(false); }
        catch { owner.Dispose(); Active.TryRemove(owner.Address, out _); throw; }
    }
    public static void Stop(object session)
    {
        if (!Owners.TryGetValue(session, out var owner)) return;
        Owners.Remove(session); Active.TryRemove(owner.Address, out _); owner.Dispose();
    }
    // Preserve the existing ISO opener, preflight, redirects and cancellation.
    // AsyncLocal binds the source created by this operation to its account.
    public static async Task<NetworkIsoMount> PrepareIso(Uri original, Uri prepared,
        IReadOnlyDictionary<string, string> required, string cacheDirectory, string rclonePath,
        CancellationToken token, EmbyApiClient client)
    {
        string? previous = IsoIdentity.Value;
        try
        {
            IsoIdentity.Value = VideoCacheSettings.LimitGB == 0 ? null : VideoCacheStore.Hash(client.ServerUrl,
                Access.Get<string>(client, "_userId"), original.AbsoluteUri);
            return await MediaRequestIdentity.PrepareIso(original, prepared, required, cacheDirectory, rclonePath, token, client).ConfigureAwait(false);
        }
        finally { IsoIdentity.Value = previous; }
    }
    static void Register(MpvClient client)
    {
        lock (RegistrationGate)
        {
            if (Registered.TryGetValue(client, out _)) return;
            IntPtr library = LoadLibraryEx(DolbyVision.CorePath(), IntPtr.Zero, 0x1100);
            if (library == IntPtr.Zero) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            try
            {
                var add = Marshal.GetDelegateForFunctionPointer<AddFn>(GetProcAddress(library, "mpv_stream_cb_add_ro"));
                int status = add(PlaybackTransport.Handle(client), Protocol, IntPtr.Zero, OpenCallback);
                if (status < 0) throw new IOException("无法注册视频片段读取接口：" + status);
                Registered.Add(client, new object());
            }
            finally { FreeLibrary(library); }
        }
    }
    sealed class Owner(Uri initial, string scope, Dictionary<string, string> headers, string proxy, VideoCacheStore store) : IDisposable
    {
        internal string Address { get; } = Protocol + "://" + Guid.NewGuid().ToString("N");
        readonly HashSet<VideoCacheReader> _readers = new();
        readonly object _gate = new();
        bool _disposed;
        internal VideoCacheReader Create()
        {
            lock (_gate)
            {
                ObjectDisposedException.ThrowIf(_disposed, this);
                var handler = new HttpClientHandler { AllowAutoRedirect = false, AutomaticDecompression = DecompressionMethods.None, UseCookies = true };
                if (!string.IsNullOrWhiteSpace(proxy)) handler.Proxy = new PolicyProxy(proxy);
                // Default .NET system proxy is disabled where existing policy
                // explicitly asks the media destination to bypass a proxy.
                else handler.UseProxy = false;
                var http = new HttpClient(handler) { Timeout = Timeout.InfiniteTimeSpan };
                var reader = new VideoCacheReader(http, initial, scope, store,
                    target => EmbyApiClient.BuildEffectivePlaybackHeaders(initial, target, headers));
                _readers.Add(reader); return reader;
            }
        }
        internal void Release(VideoCacheReader reader) { lock (_gate) _readers.Remove(reader); reader.Dispose(); }
        public void Dispose()
        {
            VideoCacheReader[] readers;
            lock (_gate) { if (_disposed) return; _disposed = true; readers = _readers.ToArray(); _readers.Clear(); }
            foreach (var reader in readers) reader.Cancel();
            foreach (var reader in readers) reader.Dispose();
        }
    }
    sealed class PolicyProxy(string address) : IWebProxy
    {
        readonly WebProxy _proxy = new(address);
        public ICredentials? Credentials { get => _proxy.Credentials; set => _proxy.Credentials = value; }
        public bool IsBypassed(Uri host) => !LocalProxyPolicy.ShouldUseProxy(host, address);
        public Uri? GetProxy(Uri destination) => IsBypassed(destination) ? destination : _proxy.GetProxy(destination);
    }
    sealed record Cookie(Owner Owner, VideoCacheReader Reader);
    [StructLayout(LayoutKind.Sequential)] struct StreamInfo { public IntPtr Cookie, Read, Seek, Size, Close, Cancel; }
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int AddFn(IntPtr mpv, [MarshalAs(UnmanagedType.LPUTF8Str)] string protocol, IntPtr data, OpenFn open);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int OpenFn(IntPtr data, IntPtr uri, IntPtr info);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate long ReadFn(IntPtr cookie, IntPtr buffer, ulong size);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate long SeekFn(IntPtr cookie, long offset);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate long SizeFn(IntPtr cookie);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate void CloseFn(IntPtr cookie);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate void CancelFn(IntPtr cookie);
    static Cookie From(IntPtr value) => (Cookie)GCHandle.FromIntPtr(value).Target!;
    static int Open(IntPtr data, IntPtr uri, IntPtr info)
    {
        VideoCacheReader? reader = null; Owner? owner = null;
        try
        {
            if (!Active.TryGetValue(Marshal.PtrToStringUTF8(uri)!, out owner)) return -13;
            reader = owner.Create(); reader.Initialize();
            var cookie = GCHandle.Alloc(new Cookie(owner, reader));
            try
            {
                Marshal.StructureToPtr(new StreamInfo { Cookie = GCHandle.ToIntPtr(cookie), Read = Marshal.GetFunctionPointerForDelegate(ReadCallback),
                    Seek = Marshal.GetFunctionPointerForDelegate(SeekCallback), Size = Marshal.GetFunctionPointerForDelegate(SizeCallback),
                    Close = Marshal.GetFunctionPointerForDelegate(CloseCallback), Cancel = Marshal.GetFunctionPointerForDelegate(CancelCallback) }, info, false);
                return 0;
            }
            catch { cookie.Free(); throw; }
        }
        catch (Exception e)
        { if (reader != null) owner!.Release(reader); Report(e); return -13; }
    }
    static long Read(IntPtr cookie, IntPtr buffer, ulong requested)
    {
        try
        {
            int count = (int)Math.Min(requested, (ulong)VideoCacheStore.BlockBytes);
            if (count == 0) return 0;
            byte[] bytes = new byte[count]; int n = From(cookie).Reader.Read(bytes, 0, count);
            Marshal.Copy(bytes, 0, buffer, n); return n;
        }
        catch (OperationCanceledException) { return -1; }
        catch (Exception e) { Report(e); return -1; }
    }
    static long Seek(IntPtr cookie, long offset) { try { return From(cookie).Reader.Seek(offset); } catch { return -1; } }
    static long Size(IntPtr cookie) { try { return From(cookie).Reader.Length; } catch { return -1; } }
    static void Close(IntPtr cookie) { try { var value = From(cookie); value.Owner.Release(value.Reader); } catch { } finally { try { GCHandle.FromIntPtr(cookie).Free(); } catch { } } }
    static void Cancel(IntPtr cookie) { try { From(cookie).Reader.Cancel(); } catch { } }
    static void Report(Exception error)
    {
        // Never put URLs, account identifiers, HTTP bodies or headers in logs.
        try { PlaybackTelemetry.Emit("scope=video-cache; event=read-failure; exception=" + error.GetType().Name); } catch { }
    }
    [DllImport("kernel32", CharSet = CharSet.Unicode, SetLastError = true)] static extern IntPtr LoadLibraryEx(string path, IntPtr file, uint flags);
    [DllImport("kernel32", CharSet = CharSet.Ansi)] static extern IntPtr GetProcAddress(IntPtr module, string name);
    [DllImport("kernel32")] static extern bool FreeLibrary(IntPtr module);
}
