using System.Runtime.CompilerServices;
using Microsoft.UI.Xaml;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage;
using Windows.Storage.Pickers;
using Richasy.MpvKernel.Core;
using Richasy.MpvKernel.Core.Enums;
namespace Yingyu.Update;

internal static class DesktopSubtitles
{
    static readonly ConditionalWeakTable<object,State> States=new();
    static readonly string[] Extensions=[".srt",".ass",".ssa",".vtt",".sup",".idx"];
    internal static bool Supported(string path)=>Extensions.Contains(Path.GetExtension(path),StringComparer.OrdinalIgnoreCase);
    internal static void Bind(object session)
    {
        var overlay=Access.Get<FrameworkElement>(session,"_overlay");
        if(States.TryGetValue(overlay,out var previous))previous.Detach();
        States.Remove(overlay);States.Add(overlay,new State(session,overlay));
    }
    internal static async Task Pick(object session)
    {
        var overlay=Access.Get<FrameworkElement>(session,"_overlay");
        if(!States.TryGetValue(overlay,out var state))throw new InvalidOperationException("等待播放就绪后再加载字幕。");
        int generation=state.Generation;
        var picker=new FileOpenPicker();foreach(var extension in Extensions)picker.FileTypeFilter.Add(extension);
        object owner=Access.Get<object>(session,"_window");
        var hwnd=(IntPtr)owner.GetType().GetProperty("Handle")!.GetValue(owner)!;
        WinRT.Interop.InitializeWithWindow.Initialize(picker,hwnd);
        var file=await picker.PickSingleFileAsync();if(file!=null&&state.Current&&generation==state.Generation)await state.Load(file);
    }
    sealed class State
    {
        readonly object session;readonly FrameworkElement overlay;readonly MpvClient client;
        internal readonly int Generation;bool detached,busy;readonly bool oldAllowDrop;
        internal bool Current=>!detached&&!NativeDolby.IsClosing(session)&&Generation==Access.Get<int>(session,"_mediaGeneration")&&ReferenceEquals(client,Access.Get<MpvClient?>(session,"_mpvClient"));
        internal State(object session,FrameworkElement overlay)
        {
            this.session=session;this.overlay=overlay;client=Access.Get<MpvClient>(session,"_mpvClient");Generation=Access.Get<int>(session,"_mediaGeneration");oldAllowDrop=overlay.AllowDrop;
            overlay.AllowDrop=true;overlay.DragOver+=Over;overlay.Drop+=Drop;overlay.Unloaded+=Unload;
        }
        void Over(object sender,DragEventArgs e)
        {
            if(!Current||busy||!e.DataView.Contains(StandardDataFormats.StorageItems))return;
            e.AcceptedOperation=DataPackageOperation.Copy;e.DragUIOverride.Caption="松开加载外挂字幕";e.Handled=true;
        }
        async void Drop(object sender,DragEventArgs e)
        {
            if(!Current||!e.DataView.Contains(StandardDataFormats.StorageItems))return;
            var deferral=e.GetDeferral();e.Handled=true;
            try{
                var items=await e.DataView.GetStorageItemsAsync();if(!Current)return;
                if(items.Count!=1||items[0] is not StorageFile file||!Supported(file.Path))throw new InvalidOperationException("请每次拖入一个 SRT、ASS、SSA、VTT、SUP 或 IDX 字幕文件。");
                await Load(file);
            }catch(Exception error){if(Current)DolbyVision.ShowText(client,error is InvalidOperationException?error.Message:"字幕加载失败，请重试。");}
            finally{deferral.Complete();}
        }
        internal async Task Load(StorageFile file)
        {
            if(!Current||busy)throw new InvalidOperationException("正在加载字幕，请稍后再试。");
            if(!Supported(file.Path))throw new InvalidOperationException("不支持此字幕格式。");
            busy=true;
            try{
                var properties=await file.GetBasicPropertiesAsync();if(!Current)return;
                if(properties.Size==0||properties.Size>32*1024*1024)throw new InvalidOperationException("字幕文件为空或超过 32 MB。");
                if(!Access.Get<bool>(session,"_hasStartedPlayback"))throw new InvalidOperationException("等待影片开始播放后再加载字幕。");
                var before=await client.GetTracksAsync();if(!Current)return;
                if(!before.IsSuccess)throw new InvalidOperationException("暂时无法读取字幕轨道，请重试。");
                // Track IDs are only unique within their type (video 1 and sub 1 coexist).
                var ids=before.Value.Where(t=>t.Type==MpvTrackType.Subtitle).Select(t=>t.Id).ToHashSet();
                var manualBefore=Access.Get<int?>(session,"_manuallySelectedSubtitleId");int manualGeneration=Access.Get<int>(session,"_manualSubtitleGeneration");
                // Add without changing the current track until the new track is confirmed.
                if(DolbyVision.CommandAsync(client,"sub-add",file.Path,"auto",file.Name)<0)throw new InvalidOperationException("播放器未接受字幕文件。");
                for(int attempt=0;attempt<30;attempt++){
                    await Task.Delay(75);if(!Current)return;
                    var tracks=await client.GetTracksAsync();if(!Current)return;
                    var added=tracks.IsSuccess?tracks.Value.FirstOrDefault(t=>t.Type==MpvTrackType.Subtitle&&!ids.Contains(t.Id)&&MatchesFile(t.Id,file.Path)):null;
                    if(added==null)continue;
                    if(manualBefore!=Access.Get<int?>(session,"_manuallySelectedSubtitleId")||manualGeneration!=Access.Get<int>(session,"_manualSubtitleGeneration"))return;
                    await (Task)Access.Call(session,"SetSubtitleTrackAsync",(int?)added.Id)!;if(!Current)return;
                    await (Task)Access.Call(session,"RefreshTracksAsync")!;if(!Current)return;
                    if(PlaybackTransport.Get(client,"sid")!=added.Id.ToString(System.Globalization.CultureInfo.InvariantCulture))throw new InvalidOperationException("字幕已加载，但切换未被确认，请在字幕列表中选择。");
                    DolbyVision.ShowText(client,"已加载字幕："+file.Name);return;
                }
                throw new InvalidOperationException("播放器未识别新的字幕轨道；已加载的字幕可在列表中选择。");
            }finally{busy=false;}
        }
        bool MatchesFile(int id,string path)
        {
            if(!int.TryParse(PlaybackTransport.Get(client,"track-list/count"),out var count)||count>4096)return false;
            for(int i=0;i<count;i++)if(PlaybackTransport.Get(client,$"track-list/{i}/type")=="sub"&&PlaybackTransport.Get(client,$"track-list/{i}/id")==id.ToString(System.Globalization.CultureInfo.InvariantCulture))
                return string.Equals(PlaybackTransport.Get(client,$"track-list/{i}/external-filename"),path,StringComparison.OrdinalIgnoreCase);
            return false;
        }
        void Unload(object sender,RoutedEventArgs e)=>Detach();
        internal void Detach(){detached=true;overlay.DragOver-=Over;overlay.Drop-=Drop;overlay.Unloaded-=Unload;overlay.AllowDrop=oldAllowDrop;}
    }
}
