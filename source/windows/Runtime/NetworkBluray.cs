using System.Collections.Concurrent;
using System.Diagnostics;
using System.Net.Http;
using System.Reflection;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using EmbyDesktop.Core.Services;
using EmbyDesktop.Core.Models;

namespace Yingyu.Update;

// User-mode, read-only fallback. The original WinFsp route remains available.
public static class NetworkBluray
{
    const string Protocol = "yingyu-bd";
    static readonly ConditionalWeakTable<NetworkIsoMount, Disc> Mounts = new();
    static readonly ConditionalWeakTable<object, object> Registered = new();
    internal static readonly ConcurrentDictionary<string, Disc> Active = new();
    static readonly OpenFn OpenCallback = Open;
    static readonly ReadFn ReadCallback = Read;
    static readonly SeekFn SeekCallback = Seek;
    static readonly SizeFn SizeCallback = Size;
    static readonly CloseFn CloseCallback = Close;
    static readonly CancelFn CancelCallback = Cancel;
    static readonly BlocksFn BlocksCallback = ReadBlocks;
    static readonly Lazy<Api> Native = new(() => new Api());
    static readonly BlurayMetadataStore MetadataStore = new(CachePaths.BlurayMetadata);

    public static bool NeedsFallback() => !File.Exists(Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86), "WinFsp", "bin", "winfsp-x64.dll"));
    public static bool IsFallback(NetworkIsoMount mount) => Mounts.TryGetValue(mount, out _);
    public static bool IsFallbackSession(object session) => Access.Get<Uri>(session, "_playbackUri").Scheme == Protocol;
    internal static int DiagnosticId(object session) => Active.TryGetValue(Access.Get<Uri>(session, "_playbackUri").ToString(), out var disc) ? disc.Trace.Id : 0;
    internal static string? SubtitleLanguage(Uri uri, ushort pid) => Active.TryGetValue(uri.ToString(), out var disc)
        && disc.SubtitleLanguages.TryGetValue(pid, out var language) ? language : null;
    public static Task<MediaUriResolution> Resolve(object session) => Task.FromResult(
        new MediaUriResolution(Access.Get<Uri>(session, "_playbackUri"), 0, true));
    public static Task Replay(object session) => (Task)Access.Call(session, "PlayCurrentItemAsync", Resolve(session), null)!;
    internal sealed record MenuTitle(uint Index,uint Playlist,double Seconds,bool Selected);
    internal sealed record MenuChapter(string Name,double Seconds);
    static Disc? MenuDisc(object session)=>Active.GetValueOrDefault(Access.Get<Uri>(session,"_playbackUri").ToString());
    internal static IReadOnlyList<MenuTitle> MenuTitles(object session)
    {var disc=MenuDisc(session);return disc==null?Array.Empty<MenuTitle>():Volatile.Read(ref disc.MenuTitleSnapshot).Select(t=>t with{Selected=t.Index==Volatile.Read(ref disc.SelectedTitle)}).ToArray();}
    internal static IReadOnlyList<MenuChapter> MenuChapters(object session)=>MenuDisc(session) is {} disc?Volatile.Read(ref disc.MenuChapterSnapshot):Array.Empty<MenuChapter>();
    internal static bool ConsumeMenuStart(object session)=>MenuDisc(session) is {} disc&&Interlocked.Exchange(ref disc.StartMenuTitle,0)!=0;
    internal static async Task SelectMenuTitle(object session,uint index)
    {
        var disc=MenuDisc(session)??throw new InvalidOperationException("当前原盘会话已经结束。");
        if(!await disc.MenuSelection.WaitAsync(0))throw new InvalidOperationException("正在切换播放列表，请稍候。");
        try
        {
            if(!ReferenceEquals(MenuDisc(session),disc)||disc.Lifetime.IsCancellationRequested||!MenuTitles(session).Any(t=>t.Index==index))throw new InvalidOperationException("原盘列表已改变，请重新打开菜单。");
            if(index==Volatile.Read(ref disc.SelectedTitle))return;
            int generation=Access.Get<int>(session,"_mediaGeneration");
            PlaybackFeatureLog.Write(session,"disc-title","requested",index);
            Volatile.Write(ref disc.RequestedTitle,checked((int)index));Interlocked.Exchange(ref disc.StartMenuTitle,1);
            Reader? prepared;lock(disc.Gate){prepared=disc.Prepared;disc.Prepared=null;}prepared?.Dispose();
            try
            {
                await Replay(session);
                if(generation!=Access.Get<int>(session,"_mediaGeneration")||!ReferenceEquals(MenuDisc(session),disc))throw new InvalidOperationException("播放会话已改变。");
                for(int i=0;i<40&&Volatile.Read(ref disc.SelectedTitle)!=index;i++){await Task.Delay(50,disc.Lifetime.Token);if(generation!=Access.Get<int>(session,"_mediaGeneration"))throw new InvalidOperationException("播放会话已改变。");}
                if(Volatile.Read(ref disc.SelectedTitle)!=index)throw new InvalidOperationException("播放列表切换未被原盘读取器确认。");
                PlaybackFeatureLog.Write(session,"disc-title","reader-confirmed",index);
            }
            catch{Interlocked.Exchange(ref disc.StartMenuTitle,0);Volatile.Write(ref disc.RequestedTitle,-1);throw;}
        }
        finally{disc.MenuSelection.Release();}
    }
    internal static Task? PendingPreparation(object session) => Active.TryGetValue(
        Access.Get<Uri>(session, "_playbackUri").ToString(), out var disc) ? disc.Preparation : null;
    internal static void Probing(object session, bool value)
    {
        if (Active.TryGetValue(Access.Get<Uri>(session, "_playbackUri").ToString(), out var disc))
        {
            // No Disc.Gate: a playback event must not wait behind network IO.
            Volatile.Write(ref disc.IsProbing, value ? 1 : 0);
            Volatile.Read(ref disc._readAhead)?.LimitProbeReadAhead(value);
        }
    }
    internal static void Speed(object session, double value)
    {
        if (!double.IsFinite(value) || value <= 0) return;
        if (Active.TryGetValue(Access.Get<Uri>(session, "_playbackUri").ToString(), out var disc))
        {
            bool high = value >= 3;
            Volatile.Write(ref disc.IsHighRate, high ? 1 : 0);
            Volatile.Read(ref disc._readAhead)?.Boost(high);
        }
    }
    internal static void CancelSessionReading(object session)
    {
        if (Active.TryGetValue(Access.Get<Uri>(session, "_playbackUri").ToString(), out var disc))
            disc.CancelReading();
    }

    public static async Task<NetworkIsoMount> StartAsync(Uri original, Uri prepared,
        IReadOnlyDictionary<string, string> headers, CancellationToken token)
    {
        _ = Native.Value;
        var source = await NetworkIsoSource.StartAsync(original, prepared, headers, token).ConfigureAwait(false);
        var disc = new Disc(source, original, headers);
        try
        {
            token.ThrowIfCancellationRequested();
            // Prepare the same directory/title in the background. The original
            // real player window is shown before its load boundary awaits this.
            disc.StartPreparation(token);
            // Preserve the existing session/mount ownership without creating a mount,
            // subprocess or drive letter. Only validated directory metadata is cached.
            var mount = (NetworkIsoMount)RuntimeHelpers.GetUninitializedObject(typeof(NetworkIsoMount));
            Access.Set(mount, "_source", source);
            Access.Set(mount, "<PlaybackUri>k__BackingField", disc.Uri);
            Access.Set(mount, "<DiscPath>k__BackingField", null);
            Access.Set(mount, "<StartupAttempts>k__BackingField", 1);
            Mounts.Add(mount, disc);
            Active[disc.Uri.ToString()] = disc;
            Log("Info", "未安装 WinFsp，启用内置网络蓝光分段读取；音视频交由原 mpv 解码。 ");
            Log("Info", "读取入口已就绪；入口准备耗时仅含来源探测，目录及标题准备完成另行记录，完成后才提交播放。 ");
            return mount;
        }
        catch { await disc.DisposeAsync(); throw; }
    }
    public static ValueTask DisposeAsync(NetworkIsoMount mount) => Mounts.GetValue(mount,
        _ => throw new InvalidOperationException()).DisposeAsync();

    public static void Register(object session)
    {
        if (!IsFallbackSession(session)) return;
        object client = Access.Get<object>(session, "_mpvClient");
        if (Registered.TryGetValue(client, out _)) return;
        object handle = client.GetType().GetProperty("Handle")!.GetValue(client)!;
        IntPtr pointer = (IntPtr)handle.GetType().GetProperty("Handle")!.GetValue(handle)!;
        IntPtr library = LoadLibraryEx(DolbyVision.CorePath(), IntPtr.Zero, 0x1100);
        if (library == IntPtr.Zero) throw new InvalidOperationException("无法读取原 mpv 组件。");
        try
        {
            var add = Marshal.GetDelegateForFunctionPointer<AddFn>(GetProcAddress(library, "mpv_stream_cb_add_ro"));
            int result = add(pointer, Protocol, IntPtr.Zero, OpenCallback);
            if (result < 0) throw new InvalidOperationException("无法注册网络蓝光读取接口：" + result);
            Registered.Add(client, new object());
        }
        finally { FreeLibrary(library); }
    }

    [StructLayout(LayoutKind.Sequential)] struct StreamInfo
    { public IntPtr Cookie, Read, Seek, Size, Close, Cancel; }
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int AddFn(IntPtr mpv, [MarshalAs(UnmanagedType.LPUTF8Str)] string protocol, IntPtr data, OpenFn open);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int OpenFn(IntPtr data, IntPtr uri, IntPtr info);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate long ReadFn(IntPtr cookie, IntPtr buffer, ulong size);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate long SeekFn(IntPtr cookie, long offset);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate long SizeFn(IntPtr cookie);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate void CloseFn(IntPtr cookie);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate void CancelFn(IntPtr cookie);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int BlocksFn(IntPtr cookie, IntPtr buffer, int lba, int count);
    static Reader From(IntPtr cookie) => (Reader)GCHandle.FromIntPtr(cookie).Target!;
    static int Open(IntPtr data, IntPtr uri, IntPtr info)
    {
        Reader? reader = null;
        try
        {
            string value = Marshal.PtrToStringUTF8(uri)!;
            if (!Active.TryGetValue(value, out var disc)) return -13;
            lock (disc.Gate) { reader = disc.Prepared; disc.Prepared = null; }
            reader ??= new Reader(disc);
            Marshal.StructureToPtr(new StreamInfo
            {
                Cookie = GCHandle.ToIntPtr(GCHandle.Alloc(reader)),
                Read = Marshal.GetFunctionPointerForDelegate(ReadCallback),
                Seek = Marshal.GetFunctionPointerForDelegate(SeekCallback),
                Size = Marshal.GetFunctionPointerForDelegate(SizeCallback),
                Close = Marshal.GetFunctionPointerForDelegate(CloseCallback),
                Cancel = Marshal.GetFunctionPointerForDelegate(CancelCallback)
            }, info, false);
            return 0;
        }
        catch (Exception e) { reader?.Dispose(); Log("Warning", "网络蓝光读取失败：" + e.GetType().Name); return -13; }
    }
    static long Read(IntPtr cookie, IntPtr buffer, ulong size)
    {
        try
        {
            var r = From(cookie); r.Token.ThrowIfCancellationRequested();
            if (size == 0) return 0;
            if (!r.PendingSeek.Resolve(r.ResolvePosition)) return -1;
            return ReadCore(r, buffer, size);
        }
        catch (OperationCanceledException) { return -1; }
        catch (Exception e) { try { From(cookie).Disc.Warn("蓝光正片读取异常：" + e.GetType().Name); } catch { } return -1; }
    }
    static long ReadCore(Reader r, IntPtr buffer, ulong size)
    {
        try
        {
            r.Token.ThrowIfCancellationRequested();
            if (!r.PositionValid) return -1;
            if (r.Position >= r.Size || size == 0) return 0;
            // MPV's 4 MiB seek-back buffer requests large refills even for
            // tiny timestamp probes. Return a complete smaller chunk promptly;
            // subsequent required reads still run, with the same byte position.
            ulong readLimit = Volatile.Read(ref r.Disc.IsProbing) != 0 ? 64 * 1024ul : 1024 * 1024ul;
            int requested = (int)Math.Min(Math.Min(size, readLimit), (ulong)(r.Size - r.Position));
            int prefix = 0;
            if (r.FirstByte is { } first)
            {
                Marshal.WriteByte(buffer, first); r.FirstByte = null; prefix = 1;
            }
            int read = requested > prefix ? Native.Value.Read(r.Handle, IntPtr.Add(buffer, prefix), requested - prefix) : 0;
            int result = read < 0 && prefix == 0 ? read : prefix + Math.Max(0, read);
            if (result > 0) r.Position += result;
            if (result < 0) r.Disc.Warn("蓝光正片读取返回错误");
            return result;
        }
        catch (OperationCanceledException) { return -1; }
        catch (Exception e) { try { r.Disc.Warn("蓝光正片读取异常：" + e.GetType().Name); } catch { } return -1; }
    }
    static long Seek(IntPtr cookie, long offset)
    {
        try
        {
            var reader = From(cookie); reader.Token.ThrowIfCancellationRequested();
            return reader.PendingSeek.Schedule(offset, reader.Size);
        }
        catch { return -1; }
    }
    static long MaterializeSeek(Reader reader, long offset)
    {
        long began = Stopwatch.GetTimestamp(), bytes = reader.Disc.Received,
            requests = reader.Disc.Requests, from = reader.Position;
        long result = -1;
        Interlocked.Increment(ref reader.Disc.SeekReads);
        try { return result = SeekCore(reader, offset); }
        finally
        {
            Interlocked.Decrement(ref reader.Disc.SeekReads);
            if (Interlocked.Increment(ref reader.SeekSamples) <= 16)
                PlaybackTelemetry.Emit($"scope=bluray-seek; event=resolved-byte-seek; elapsedMs={Stopwatch.GetElapsedTime(began).TotalMilliseconds:0}; " +
                    $"jumpBytes={offset - from}; readBytes={reader.Disc.Received - bytes}; ranges={reader.Disc.Requests - requests}; success={result == offset}");
        }
    }
    static long SeekCore(Reader r, long offset)
    {
        try
        {
            r.Token.ThrowIfCancellationRequested();
            if (offset < 0 || offset > r.Size) return -1;
            // Demuxers sometimes query/reapply the current position. Keep the
            // pending first byte and avoid reopening the same access point.
            if (r.PositionValid && offset == r.Position) return offset;
            // FFmpeg can probe a nearby forward position. Consume from the
            // current valid stream instead of rewinding libbluray to a CPI
            // access point and reading the same packets a second time.
            if (r.PositionValid && offset < r.Size && offset > r.Position && offset - r.Position <= 1024 * 1024)
            {
                IntPtr forward = Marshal.AllocHGlobal(64 * 1024);
                try
                {
                    while (r.Position < offset)
                    {
                        int requested = (int)Math.Min(64 * 1024, offset - r.Position);
                        if (ReadCore(r, forward, (ulong)requested) <= 0) { r.PositionValid = false; return -1; }
                    }
                    return offset;
                }
                finally { Marshal.FreeHGlobal(forward); }
            }
            r.FirstByte = null;
            // bd_seek refuses pos == title size, while a byte stream must allow EOF.
            if (offset == r.Size) { r.Disc.StopReadAhead(); r.Position = offset; r.PositionValid = true; return offset; }
            r.PositionValid = false;
            long actual = Native.Value.Seek(r.Handle, (ulong)offset);
            // bd_seek uses the CPI access point, not a 6144-byte byte alignment.
            // Drain from that valid point to the exact requested byte. The first
            // read may rewind PAT/PMT/PCR packets, so use bd_tell rather than n.
            if (actual < 0 || actual > offset) { r.Disc.Warn("蓝光访问点无法满足字节定位"); return -1; }
            IntPtr discard = Marshal.AllocHGlobal(64 * 1024);
            try
            {
                if (Native.Value.Read(r.Handle, discard, 1) != 1) return -1;
                actual = checked((long)Native.Value.Tell(r.Handle));
                if (actual == offset + 1) r.FirstByte = Marshal.ReadByte(discard);
                else
                {
                    if (actual > offset) return -1;
                    while (actual < offset)
                    {
                        r.Token.ThrowIfCancellationRequested();
                        int n = Native.Value.Read(r.Handle, discard, (int)Math.Min(64 * 1024, offset - actual));
                        long after = checked((long)Native.Value.Tell(r.Handle));
                        if (n <= 0 || after <= actual || after > offset) return -1;
                        actual = after;
                    }
                }
            }
            finally { Marshal.FreeHGlobal(discard); }
            r.Position = offset;
            r.PositionValid = true;
            return offset;
        }
        catch (OperationCanceledException) { return -1; }
        catch (Exception e) { try { r.Disc.Warn("蓝光定位异常：" + e.GetType().Name); } catch { } return -1; }
    }
    static long Size(IntPtr cookie) { try { return From(cookie).Size; } catch { return -1; } }
    static void Close(IntPtr cookie) { try { From(cookie).Dispose(); GCHandle.FromIntPtr(cookie).Free(); } catch { } }
    static void Cancel(IntPtr cookie) { try { From(cookie).Cancellation.Cancel(); } catch { } }
    static void Log(string level, string text)
    {
        try { Assembly.Load("Yingyu").GetType("EmbyDesktop.Services.AppLog")!.GetMethod(level,
            BindingFlags.Static | BindingFlags.Public | BindingFlags.NonPublic)!.Invoke(null, new object[] { "Playback.Iso", text }); }
        catch { }
    }
    static int ReadBlocks(IntPtr cookie, IntPtr buffer, int lba, int count)
    {
        try { var r = From(cookie); r.Disc.Copy(checked((long)(uint)lba * 2048), checked(count * 2048), buffer, r.Token); return count; }
        catch (OperationCanceledException) { return 0; }
        catch (Exception e) { try { From(cookie).Disc.Warn("ISO 分段读取异常：" + e.GetType().Name); } catch { } return 0; }
    }

    internal sealed class Disc
    {
        internal readonly object Gate = new();
        internal readonly NetworkIsoSource Source;
        internal readonly PlaybackIoTrace Trace = new();
        internal readonly CancellationTokenSource Lifetime = new();
        BlurayPreparationWork? _preparation;
        internal Task Preparation => _preparation?.Completion ?? Task.CompletedTask;
        internal readonly Uri Uri = new(Protocol + "://" + Guid.NewGuid().ToString("N"));
        internal Reader? Prepared;
        internal MenuTitle[] MenuTitleSnapshot=Array.Empty<MenuTitle>();
        internal MenuChapter[] MenuChapterSnapshot=Array.Empty<MenuChapter>();
        internal readonly SemaphoreSlim MenuSelection=new(1,1);
        internal uint SelectedTitle=uint.MaxValue;
        internal int RequestedTitle=-1,StartMenuTitle;
        internal IReadOnlyDictionary<ushort, string> SubtitleLanguages = new Dictionary<ushort, string>();
        internal IReadOnlyDictionary<ushort, string> AudioLanguages = new Dictionary<ushort, string>();
        readonly BlurayBlockCache _cache = new(MaxChunks);
        readonly BlurayReadDeadline _readDeadline = new();
        internal BlurayReadAhead? _readAhead;
        readonly BlurayRangeIdentity _rangeIdentity;
        bool _readAheadDisabled;
        internal int SeekReads;
        internal int IsProbing = 1;
        internal int IsHighRate;
        HttpResponseMessage? _response;
        Stream? _body;
        long _cursor, _end;
        long _requests, _received;
        internal long Requests => _requests;
        internal long Received => Interlocked.Read(ref _received);
        long _headerTicks, _readTicks, _maximumReadTicks;
        bool _preparing = true;
        int _mediaWindow = Window;
        readonly object _disposeGate = new();
        Task? _disposeTask;
        int _readErrors;
        internal void Warn(string text)
        {
            if (Interlocked.Increment(ref _readErrors) <= 3) Log("Warning", text + "；来源地址及请求头已隐藏。 ");
        }
        const int Chunk = 64 * 1024;
        // Only the response range is larger. Reads stay on demand, 64 KiB at
        // a time, with the same 32 MiB cache and original validation.
        const int Window = 256 * 1024 * 1024;
        const int PreviousWindow = 64 * 1024 * 1024;
        const int PreparationWindow = 4 * 1024 * 1024;
        const int MetadataFill = 4 * Chunk;
        const int MaxChunks = 32 * 1024 * 1024 / Chunk;
        readonly string? _preparationKey;
        internal void StartPreparation(CancellationToken launch)
            => _preparation = new BlurayPreparationWork(Lifetime, PrepareAsync, launch);
        async Task PrepareAsync(CancellationToken token)
        {
            Reader? reader = null;
            try
            {
                reader = await Task.Run(() => new Reader(this), token).ConfigureAwait(false);
                token.ThrowIfCancellationRequested();
                lock (Gate)
                {
                    token.ThrowIfCancellationRequested();
                    Prepared = reader; reader = null;
                    FinishPreparation();
                }
            }
            catch (Exception error) when (token.IsCancellationRequested)
            {
                // The native directory callback reports cancellation as EOF;
                // Reader may wrap that as a format/open error. Keep close
                // cancellation distinct from a real uncancelled open failure.
                throw new OperationCanceledException("Directory preparation cancelled", error, token);
            }
            finally { reader?.Dispose(); }
        }
        internal void CancelReading()
        {
            if (_preparation is { } preparation) _ = preparation.CancelAsync();
        }
        internal Disc(NetworkIsoSource source, Uri original, IReadOnlyDictionary<string, string> headers)
        {
            Source = source;
            _rangeIdentity = new BlurayRangeIdentity(original, source.Length, Access.Get<string?>(source, "_etag"),
                (start, end, token) => (Task<HttpResponseMessage>)Access.Call(Source, "OpenRangeAsync", start, end, token)!,
                message => PlaybackTelemetry.Emit("scope=bluray-range; " + message));
            try
            {
                string? etag = Access.Get<string?>(source, "_etag");
                _preparationKey = BlurayPreparationCache.Key(original, etag, source.Length, headers);
                foreach (string key in BlurayPreparationCache.LookupKeys(original, etag, source.Length, headers))
                    if (BlurayPreparationCache.Restore(key, _cache) || MetadataStore.Restore(key, _cache))
                    {
                        Log("Info", "本次已重新认证及探测，强ETag和长度一致，复用同一来源及认证范围内的蓝光目录块；仍重新打开目录并选择最长标题。 ");
                        break;
                    }
            }
            catch (Exception error) { Log("Warning", "目录块复用未完成，继续原按需读取；异常类型=" + error.GetType().Name); }
        }
        internal void Copy(long offset, int count, IntPtr destination, CancellationToken token)
        {
            if (offset < 0 || count < 0 || offset > Source.Length - count) throw new IOException("ISO range outside source");
            int copied = 0;
            while (copied < count)
            {
                token.ThrowIfCancellationRequested();
                long index = (offset + copied) / Chunk;
                byte[] bytes;
                lock (Gate)
                {
                    if (_cache.TryGetValue(index, out bytes!))
                    {
                        if (!_preparing) _readAhead?.PrioritizeCached(index * Chunk);
                    }
                    else
                    {
                        long start = index * Chunk;
                        // 0.5.8 bounded media pipeline; directory preparation
                        // and the original validated fallback remain below.
                        if (!_preparing && !_readAheadDisabled)
                        {
                            try
                            {
                                if (_readAhead == null)
                                {
                                    _readAhead = new BlurayReadAhead(Source.Length, OpenAheadRange, Lifetime.Token, MeasureAhead);
                                    _readAhead.Configure(() => _rangeIdentity.CanParallel,
                                        message => PlaybackTelemetry.Emit("scope=bluray-range; " + message));
                                    _readAhead.Boost(Volatile.Read(ref IsHighRate) != 0);
                                }
                                _readAhead.LimitProbeReadAhead(Volatile.Read(ref IsProbing) != 0);
                                bytes = _cache.Acquire((int)Math.Min(Chunk, Source.Length - start));
                                _readAhead.Read(start, bytes, token, allowPrefetch: Volatile.Read(ref SeekReads) == 0);
                                _cache.Publish(index, bytes);
                            }
                            catch (Exception error) when (!token.IsCancellationRequested
                                && error is not IsoSourceChangedException
                                && error is IOException or HttpRequestException or OperationCanceledException or EmbyApiException)
                            {
                                _readAhead?.Dispose(); _readAhead = null; _readAheadDisabled = true;
                                Log("Warning", "蓝光顺序预读未完成，退回原位置校验读取；异常类型=" + error.GetType().Name);
                            }
                        }
                        if (!_cache.TryGetValue(index, out bytes!))
                        {
                        // Nearby forward demuxer probes can consume the current
                        // response instead of reopening HTTP for every >64KiB
                        // gap. The skipped bytes remain bounded/cached; distant
                        // targets still start a validated Range at that target.
                        int gapLimit = 1024 * 1024;
                        if (_body == null || start < _cursor || start >= _end || start - _cursor > gapLimit)
                            OpenWindow(start, token);
                        // Sequential playback consumes the same Range response on demand.
                        // Random demuxer probes read only 64 KiB, never wait for the
                        // entire former 1 MiB block or the 4 MiB HTTP window to fill.
                        // Bounded directory read-ahead avoids reopening for the
                        // adjacent playlists/CLPI requested by libbluray. Media
                        // reads remain one 64 KiB block at a time.
                        long fillTo = _preparing ? Math.Min(start + MetadataFill, _end) : start + 1;
                        while (_cursor < fillTo)
                        {
                            long block = _cursor / Chunk;
                            bytes = ReadChunk(token);
                            _cache.Publish(block, bytes);
                        }
                        if (!_cache.TryGetValue(index, out bytes!)) throw new IOException("ISO block missing after complete read");
                        }
                    }
                    // Hold ownership through the native copy: another reader must
                    // not evict/reuse this array while it is being copied.
                    token.ThrowIfCancellationRequested();
                    int from = (int)((offset + copied) % Chunk);
                    int n = Math.Min(count - copied, bytes.Length - from);
                    Marshal.Copy(bytes, from, IntPtr.Add(destination, copied), n);
                    copied += n;
                }
            }
        }
        internal void StopReadAhead()
        {
            lock (Gate)
            {
                // Retain the owner so the next uncached read and final close
                // can collect its retired response before opening or freeing.
                _readAhead?.Stop();
            }
        }
        void OpenWindow(long start, CancellationToken token)
        {
            CloseWindow();
            using var deadline = CancellationTokenSource.CreateLinkedTokenSource(token);
            deadline.CancelAfter(TimeSpan.FromSeconds(20));
            long end = Math.Min(start + (_preparing ? PreparationWindow : _mediaWindow), Source.Length);
            long began = Stopwatch.GetTimestamp();
            try
            {
                while (true)
                {
                    try
                    {
                        _response = ((Task<HttpResponseMessage>)Access.Call(Source, "OpenRangeAsync", start, end - 1, deadline.Token)!).GetAwaiter().GetResult();
                        break;
                    }
                    catch (EmbyApiException error) when (!_preparing && _mediaWindow > PreparationWindow
                        && error.Message.StartsWith("原盘来源未正确支持分段读取，或文件已变化。", StringComparison.Ordinal))
                    {
                        // Preserve the proven 64 MiB compatibility step before
                        // reverting to 4 MiB. Every attempt still validates the
                        // exact Content-Range, total length and source identity.
                        _mediaWindow = _mediaWindow > PreviousWindow ? PreviousWindow : PreparationWindow;
                        end = Math.Min(start + _mediaWindow, Source.Length);
                        Log("Warning", $"较大 Range 未通过原校验，改用{_mediaWindow / 1024 / 1024}MiB窗口重新校验长度和ETag；未接受截断数据。 ");
                    }
                }
                _body = _response.Content.ReadAsStreamAsync(deadline.Token).GetAwaiter().GetResult();
                _cursor = start; _end = end; _requests++;
                long headerElapsed = Stopwatch.GetTimestamp() - began;
                _headerTicks += headerElapsed;
                Trace.Header(headerElapsed, end - start, _preparing);
            }
            catch { CloseWindow(); throw; }
        }
        byte[] ReadChunk(CancellationToken token)
        {
            // A long pause may leave the existing HTTP body closed upstream.
            // Retry only this undelivered chunk at its exact original position,
            // through the original Range/ETag/length validation. Partial bytes
            // are never returned to libbluray or appended twice to the TS stream.
            long start = _cursor;
            byte[] bytes = _cache.Acquire((int)Math.Min(Chunk, _end - _cursor));
            for (int attempt = 0; ; attempt++)
            {
                var readToken = _readDeadline.Begin(token);
                long began = Stopwatch.GetTimestamp();
                try
                {
                    _body!.ReadExactlyAsync(bytes, readToken).AsTask().GetAwaiter().GetResult();
                    _cursor += bytes.Length; _received += bytes.Length;
                    long elapsed = Stopwatch.GetTimestamp() - began;
                    _readTicks += elapsed; _maximumReadTicks = Math.Max(_maximumReadTicks, elapsed);
                    Trace.Read(elapsed, bytes.Length, _preparing);
                    if (_cursor == _end) CloseWindow();
                    return bytes;
                }
                catch (Exception error) when (!_preparing && attempt == 0 && !token.IsCancellationRequested
                    && error is IOException or HttpRequestException or OperationCanceledException)
                {
                    long retryElapsed = Stopwatch.GetTimestamp() - began;
                    _readTicks += retryElapsed;
                    Trace.Retry(retryElapsed);
                    CloseWindow();
                    token.ThrowIfCancellationRequested();
                    OpenWindow(start, token);
                    Log("Info", "蓝光网络读取短暂中断，已在未交付缓存块原位置重开一次经过校验的 Range；不跳过媒体字节。 ");
                }
                catch { CloseWindow(); throw; }
                finally { _readDeadline.End(); }
            }
        }
        void CloseWindow()
        {
            _body?.Dispose(); _body = null;
            _response?.Dispose(); _response = null;
        }
        internal void FinishPreparation()
        {
            lock (Gate)
            {
                try { BlurayPreparationCache.Save(_preparationKey, _cache); MetadataStore.Save(_preparationKey, _cache); }
                catch (Exception error) { Log("Warning", "目录块保留未完成，继续播放；异常类型=" + error.GetType().Name); }
                _preparing = false;
                Trace.Finish("metadata-ready", true);
                CloseWindow();
                Log("Info", $"蓝光目录准备完成；Range 请求={_requests}，读取={_received / 1024}KiB；请求头等待={_headerTicks * 1000 / Stopwatch.Frequency}ms，读取等待={_readTicks * 1000 / Stopwatch.Frequency}ms；媒体连续优先读取，来源校验后允许最多双路，合计预读上限48MiB，已读缓存32MiB，失败回退原校验读取。 ");
            }
        }
        internal ValueTask DisposeAsync()
        {
            lock (_disposeGate) return new ValueTask(_disposeTask ??= DisposeCoreAsync());
        }
        async Task DisposeCoreAsync()
        {
            Active.TryRemove(Uri.ToString(), out _);
            Exception? cancellationError = null;
            try { await (_preparation?.CancelAsync() ?? Lifetime.CancelAsync()).ConfigureAwait(false); }
            catch (Exception error) { cancellationError = error; }
            try { await Preparation.ConfigureAwait(false); }
            catch (OperationCanceledException) when (Lifetime.IsCancellationRequested) { }
            catch (Exception error) { Warn("原盘准备任务结束清理；异常类型=" + error.GetType().Name); }
            BlurayReadAhead? pipe;
            Reader? prepared;
            lock (Gate) { pipe = _readAhead; _readAhead = null; prepared = Prepared; Prepared = null; }
            try
            {
                // Retired producers can finish callbacks without waiting for
                // Disc.Gate. Join them before disposing their validated source.
                if (pipe != null) await pipe.DisposeAsync().ConfigureAwait(false);
            }
            finally
            {
                try
                {
                    try { prepared?.Dispose(); }
                    finally { lock (Gate) { Trace.Finish("source-dispose", _preparing); CloseWindow(); _readDeadline.Dispose(); _cache.Clear(); } }
                }
                finally
                {
                    try { await Source.DisposeAsync().ConfigureAwait(false); }
                    finally { _rangeIdentity.Dispose(); }
                }
            }
            Log("Info", $"内置蓝光分段读取已关闭；Range 请求={_requests}，按需读取={_received / 1024}KiB；请求头等待={_headerTicks * 1000 / Stopwatch.Frequency}ms，读取等待={_readTicks * 1000 / Stopwatch.Frequency}ms，最长块等待={_maximumReadTicks * 1000 / Stopwatch.Frequency}ms；预读最多48MiB和已读缓存32MiB，无整盘下载。 ");
            if (cancellationError != null) System.Runtime.ExceptionServices.ExceptionDispatchInfo.Capture(cancellationError).Throw();
            // Readers retain their cancellation source until mpv closes their stream.
        }
        Task<HttpResponseMessage> OpenAheadRange(long start, long end, CancellationToken token) =>
            _rangeIdentity.Open(start, end, token);
        void MeasureAhead(bool header, long ticks, int bytes)
        {
            lock (Trace)
            {
                if (header) { Interlocked.Increment(ref _requests); _headerTicks += ticks; Trace.Header(ticks, bytes, false); }
                else { Interlocked.Add(ref _received, bytes); _readTicks += ticks; _maximumReadTicks = Math.Max(_maximumReadTicks, ticks); Trace.Read(ticks, bytes, false); }
            }
        }
    }
    internal sealed class Reader : IDisposable
    {
        internal readonly Disc Disc;
        internal readonly CancellationTokenSource Cancellation;
        internal CancellationToken Token => Cancellation.Token;
        internal IntPtr Handle;
        internal long Size;
        internal long Position;
        internal bool PositionValid = true;
        internal byte? FirstByte;
        internal int SeekSamples;
        internal readonly DeferredByteSeek PendingSeek = new();
        internal readonly Func<long, long> ResolvePosition;
        internal long MaterializeSeek(long offset) => NetworkBluray.MaterializeSeek(this, offset);
        GCHandle _blockCookie;
        internal Reader(Disc disc)
        {
            Disc = disc;
            ResolvePosition = MaterializeSeek;
            Cancellation = CancellationTokenSource.CreateLinkedTokenSource(disc.Lifetime.Token);
            _blockCookie = GCHandle.Alloc(this);
            Handle = Native.Value.Init();
            long began = Stopwatch.GetTimestamp();
            IntPtr selectedInfo = IntPtr.Zero;
            try
            {
                if (Handle == IntPtr.Zero || Native.Value.Open(Handle, GCHandle.ToIntPtr(_blockCookie), BlocksCallback) == 0)
                    throw new EmbyApiException("无法读取网络蓝光 ISO，请确认资源完整且为可读取的蓝光原盘。");
                long opened = Stopwatch.GetTimestamp();
                uint count = Native.Value.Titles(Handle, 3, 0), best = 0;
                ulong longest = 0;int requested=Volatile.Read(ref disc.RequestedTitle);bool foundRequested=false;
                var menuTitles=new List<MenuTitle>();
                if (count == 0 || count > 10000) throw new EmbyApiException("未找到可播放的蓝光正片标题。");
                for (uint i = 0; i < count; i++)
                {
                    Token.ThrowIfCancellationRequested();
                    IntPtr info = Native.Value.Info(Handle, i, 0);
                    if (info == IntPtr.Zero) continue;
                    try
                    {
                        ulong duration = (ulong)Marshal.ReadInt64(info, 8);
                        menuTitles.Add(new(i,unchecked((uint)Marshal.ReadInt32(info,4)),duration/90000.0,false));
                        bool choose=requested>=0?i==(uint)requested:i==0||duration>longest;
                        if (choose)
                        {
                            if(requested>=0)foundRequested=true;
                            longest = duration; best = i;
                            if (selectedInfo != IntPtr.Zero) Native.Value.FreeInfo(selectedInfo);
                            selectedInfo = info; info = IntPtr.Zero;
                        }
                    }
                    finally { if (info != IntPtr.Zero) Native.Value.FreeInfo(info); }
                }
                if(requested>=0&&!foundRequested)throw new EmbyApiException("指定的原盘播放列表已经不存在，未回退到其他标题。");
                if (Native.Value.Select(Handle, best) == 0) throw new EmbyApiException("无法打开蓝光正片；请确认原盘已解密且未损坏。");
                Volatile.Write(ref disc.MenuTitleSnapshot,menuTitles.ToArray());Volatile.Write(ref disc.SelectedTitle,best);
                var chapters=new List<MenuChapter>();
                if(selectedInfo!=IntPtr.Zero){int countChapters=Marshal.ReadInt32(selectedInfo,24);IntPtr chapterData=Marshal.ReadIntPtr(selectedInfo,40);if(countChapters is >0 and <=2048&&chapterData!=IntPtr.Zero)for(int j=0;j<countChapters;j++){var chapter=IntPtr.Add(chapterData,checked(j*48));ulong start=unchecked((ulong)Marshal.ReadInt64(chapter,8));if(start<=longest)chapters.Add(new($"第 {j+1} 章",start/90000.0));}}
                Volatile.Write(ref disc.MenuChapterSnapshot,chapters.ToArray());
                if (selectedInfo != IntPtr.Zero) CaptureSubtitleLanguagesInfo(selectedInfo);
                else CaptureSubtitleLanguages(best);
                Log("Info", $"蓝光目录及正片选择；打开={Stopwatch.GetElapsedTime(began, opened).TotalMilliseconds:0}ms，标题处理={Stopwatch.GetElapsedTime(opened).TotalMilliseconds:0}ms，标题数={count}；沿用最长标题选择，不扫描整盘媒体。 ");
                Size = checked((long)Native.Value.Size(Handle));
                if (Size <= 0) throw new EmbyApiException("蓝光正片数据为空。");
            }
            catch { Dispose(); throw; }
            finally { if (selectedInfo != IntPtr.Zero) Native.Value.FreeInfo(selectedInfo); }
        }
        public void Dispose()
        {
            if (Handle != IntPtr.Zero) { Native.Value.Close(Handle); Handle = IntPtr.Zero; }
            if (_blockCookie.IsAllocated) _blockCookie.Free();
            Cancellation.Dispose();
        }
        void CaptureSubtitleLanguages(uint title)
        {
            IntPtr info = IntPtr.Zero;
            try
            {
                info = Native.Value.Info(Handle, title, 0);
                if (info == IntPtr.Zero) return;
                CaptureSubtitleLanguagesInfo(info);
            }
            catch (Exception e) { Disc.Warn("蓝光字幕语言元数据读取失败：" + e.GetType().Name); }
            finally { if (info != IntPtr.Zero) Native.Value.FreeInfo(info); }
        }
        void CaptureSubtitleLanguagesInfo(IntPtr info)
        {
            try
            {
                // ABI: bundled libbluray 1.5.0, Windows x64. Header offsets are
                // recorded in the delivery evidence, not inferred from track order.
                int count = Marshal.ReadInt32(info, 16);
                IntPtr clips = Marshal.ReadIntPtr(info, 32);
                if (count < 0 || count > 10000 || clips == IntPtr.Zero) return;
                var languages = new Dictionary<ushort, string>();
                var ambiguous = new HashSet<ushort>();
                for (int i = 0; i < count; i++)
                {
                    IntPtr clip = IntPtr.Add(clips, checked(i * 104));
                    int pgCount = Marshal.ReadByte(clip, 10);
                    IntPtr streams = Marshal.ReadIntPtr(clip, 32);
                    if (streams == IntPtr.Zero) continue;
                    for (int j = 0; j < pgCount; j++)
                    {
                        IntPtr stream = IntPtr.Add(streams, j * 16);
                        ushort pid = unchecked((ushort)Marshal.ReadInt16(stream, 8));
                        string lang = new(new[] { (char)Marshal.ReadByte(stream, 4),
                            (char)Marshal.ReadByte(stream, 5), (char)Marshal.ReadByte(stream, 6) });
                        if (pid == 0 || !lang.All(c => c is >= 'a' and <= 'z') || lang == "und") continue;
                        if (languages.TryGetValue(pid, out var old) && old != lang) ambiguous.Add(pid);
                        else languages[pid] = lang;
                    }
                }
                foreach (var pid in ambiguous) languages.Remove(pid);
                Disc.SubtitleLanguages = languages;
                Disc.AudioLanguages = DiscAudioLabels.ReadLanguages(info);
            }
            catch (Exception error) { Log("Warning", "蓝光字幕目录信息暂不可用：" + error.GetType().Name + "；音视频仍交由 mpv 处理。 "); }
        }
    }
    sealed class Api
    {
        internal readonly InitFn Init; internal readonly OpenBdFn Open; internal readonly TitlesFn Titles;
        internal readonly InfoFn Info; internal readonly FreeFn FreeInfo; internal readonly SelectFn Select;
        internal readonly BdReadFn Read; internal readonly BdSeekFn Seek; internal readonly BdSizeFn Size, Tell; internal readonly FreeFn Close;
        readonly IntPtr _library;
        internal Api()
        {
            _library = LoadLibraryEx(Path.Combine(AppContext.BaseDirectory, "Components", "NetworkBluray", "libbluray-3.dll"), IntPtr.Zero, 0x1100);
            if (_library == IntPtr.Zero) _library = LoadLibraryEx(Path.Combine(AppContext.BaseDirectory, "Components", "NetworkBluray", "libbluray-4.dll"), IntPtr.Zero, 0x1100);
            if (_library == IntPtr.Zero) throw new EmbyApiException("缺少内置网络蓝光读取组件，请重新覆盖安装映屿。错误=" + Marshal.GetLastWin32Error());
            T Get<T>(string name) where T : Delegate => Marshal.GetDelegateForFunctionPointer<T>(GetProcAddress(_library, name));
            Init=Get<InitFn>("bd_init"); Open=Get<OpenBdFn>("bd_open_stream"); Titles=Get<TitlesFn>("bd_get_titles");
            Info=Get<InfoFn>("bd_get_title_info"); FreeInfo=Get<FreeFn>("bd_free_title_info"); Select=Get<SelectFn>("bd_select_title");
            Read=Get<BdReadFn>("bd_read"); Seek=Get<BdSeekFn>("bd_seek"); Size=Get<BdSizeFn>("bd_get_title_size"); Tell=Get<BdSizeFn>("bd_tell"); Close=Get<FreeFn>("bd_close");
        }
    }
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate IntPtr InitFn();
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int OpenBdFn(IntPtr bd, IntPtr cookie, BlocksFn blocks);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate uint TitlesFn(IntPtr bd, byte flags, uint minLength);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate IntPtr InfoFn(IntPtr bd, uint title, uint angle);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate void FreeFn(IntPtr bd);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int SelectFn(IntPtr bd, uint title);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int BdReadFn(IntPtr bd, IntPtr buffer, int count);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate long BdSeekFn(IntPtr bd, ulong offset);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate ulong BdSizeFn(IntPtr bd);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern IntPtr LoadLibraryEx(string path, IntPtr file, uint flags);
    [DllImport("kernel32.dll", CharSet=CharSet.Ansi, ExactSpelling=true)] static extern IntPtr GetProcAddress(IntPtr module, string name);
    [DllImport("kernel32.dll")] static extern bool FreeLibrary(IntPtr library);
}
