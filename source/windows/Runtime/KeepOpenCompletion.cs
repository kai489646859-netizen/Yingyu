using System.Reflection;
using System.Runtime.CompilerServices;
using Microsoft.UI.Dispatching;
using Richasy.MpvKernel;
using Richasy.MpvKernel.Core;
using Richasy.MpvKernel.Core.Enums;
using Richasy.MpvKernel.Core.Models;

namespace Yingyu.Update;

// With keep-open, EOF keeps the loaded file alive and does not emit EndFile.
// Reuse the existing completion/countdown only after rechecking native EOF.
public static class KeepOpenCompletion
{
    sealed class State
    {
        public int Epoch;
        public bool Loaded, Terminal, Cancelled, Pending;
    }
    static readonly ConditionalWeakTable<MpvClient, State> States = new();
    const BindingFlags Flags = BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic;

    public static void Bind(MpvClient client)
    {
        var state = States.GetOrCreateValue(client);
        lock (state) { state.Epoch++; state.Loaded = state.Terminal = state.Cancelled = state.Pending = false; }
    }

    // Before the original async native handler: never retain native DataPtr.
    public static void NativeEvent(MpvClient client, MpvEvent value)
    {
        if (!States.TryGetValue(client, out var state)) return;
        lock (state)
        {
            if (value.EventId == MpvEventId.StartFile)
            {
                state.Epoch++; state.Loaded = true;
                state.Terminal = state.Cancelled = state.Pending = false;
            }
            else if (value.EventId is MpvEventId.EndFile or MpvEventId.Shutdown)
            {
                // All EndFile reasons stay owned by the existing reason/error
                // filter. A queued keep-open completion cannot race that path.
                state.Epoch++; state.Terminal = true; state.Pending = false;
            }
        }
    }

    public static void Cancel(object session)
    {
        var client = Access.Get<MpvClient?>(session, "_mpvClient");
        if (client == null || !States.TryGetValue(client, out var state)) return;
        lock (state) { state.Epoch++; state.Cancelled = true; state.Pending = false; }
    }

    static bool Ready(object session, MpvClient client, int generation) =>
        ReferenceEquals(client, Access.Get<MpvClient?>(session, "_mpvClient"))
        && generation == Access.Get<int>(session, "_mediaGeneration")
        && !(bool)session.GetType().GetProperty("_isClosing", Flags)!.GetValue(session)!
        && Access.Get<bool>(session, "_acceptPlaybackEvents")
        && Access.Get<bool>(session, "_currentFileLoaded")
        && Access.Get<bool>(session, "_hasStartedPlayback")
        && !Access.Get<bool>(session, "_switching")
        && !Access.Get<bool>(session, "_manualSwitchPending")
        && !Access.Get<bool>(session, "_endReached")
        && Access.Get<int>(session, "_fileEndHandling") == 0
        && DateTimeOffset.UtcNow >= Access.Get<DateTimeOffset>(session, "_fileEndSuppressionUntil");

    public static void Notify(object session, MpvClientNotifyEventArgs e)
    {
        if (e.Id != MpvClientEventId.StateChanged) return;
        var client = Access.Get<MpvClient?>(session, "_mpvClient");
        if (client == null || !States.TryGetValue(client, out var state)) return;
        if (e.Data is MpvPlayerState.Playing)
        {
            int observed;
            lock (state) { if (!state.Cancelled) return; observed = state.Epoch; }
            // A delayed Playing notification from before a seek/cancel must not
            // rearm the still-held EOF. Rearm only after native EOF clears.
            if (PlaybackTransport.Get(client, "eof-reached") != "no") return;
            lock (state) { if (state.Epoch == observed) state.Cancelled = false; }
            return;
        }
        if (e.Data is not MpvPlayerState.End) return;
        int generation = Access.Get<int>(session, "_mediaGeneration"), epoch;
        if (!Ready(session, client, generation)) return;
        lock (state)
        {
            if (!state.Loaded || state.Terminal || state.Cancelled || state.Pending) return;
            epoch = state.Epoch; state.Pending = true;
        }
        bool Current()
        {
            lock (state) return state.Epoch == epoch && state.Loaded && !state.Terminal && !state.Cancelled;
        }
        bool queued = Access.Get<DispatcherQueue>(session, "_dispatcher").TryEnqueue(() =>
        {
            try
            {
                if (!Current() || !Ready(session, client, generation)) return;
                // Query only the current local MPV instance, never the server.
                if (PlaybackTransport.Get(client, "keep-open") is not ("yes" or "always")
                    || PlaybackTransport.Get(client, "eof-reached") != "yes"
                    || PlaybackTransport.Get(client, "idle-active") != "no"
                    || PlaybackTransport.Get(client, "seeking") != "no") return;
                if (!Current() || !Ready(session, client, generation)) return;
                PlaybackTransport.Write("Info", "Playback.End", "内核保留末帧并确认 EOF，进入原有播放完成流程。");
                _ = Access.Call(session, "RunSafelyAsync", (Func<Task>)(() => (Task)Access.Call(session, "HandleFileEndAsync")!));
            }
            catch (Exception)
            {
                PlaybackTransport.Write("Warning", "Playback.End", "末帧结束状态核对失败，保留当前媒体，不自动换集。");
            }
            finally { lock (state) { if (state.Epoch == epoch) state.Pending = false; } }
        });
        if (!queued) { lock (state) { if (state.Epoch == epoch) state.Pending = false; } }
    }
}
