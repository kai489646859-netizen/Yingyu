using System.Globalization;
using System.Reflection;
using System.Runtime.CompilerServices;
using System.Text.Json;
using EmbyDesktop.Core.Models;
using EmbyDesktop.Core.Services;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Storage.Streams;
namespace Yingyu.Update;

internal static class SeekArtwork
{
    internal record Frame(long PositionTicks,string ImageTag);
    internal static Frame[] Parse(byte[] bytes)
    {
        using var doc=JsonDocument.Parse(bytes,new JsonDocumentOptions{MaxDepth=12});
        if(!doc.RootElement.TryGetProperty("Thumbnails",out var list)||list.ValueKind!=JsonValueKind.Array||list.GetArrayLength()>20000)return [];
        var frames=new List<Frame>();
        foreach(var row in list.EnumerateArray())if(row.TryGetProperty("PositionTicks",out var p)&&p.TryGetInt64(out var ticks)&&ticks>=0&&row.TryGetProperty("ImageTag",out var t)&&t.ValueKind==JsonValueKind.String&&t.GetString() is {Length:>0 and <=256} tag)frames.Add(new(ticks,tag));
        return frames.OrderBy(f=>f.PositionTicks).DistinctBy(f=>f.PositionTicks).ToArray();
    }
    internal static Frame? Select(Frame[] frames,double seconds)
    {
        if(!double.IsFinite(seconds)||seconds<0)return null;
        return frames.LastOrDefault(f=>f.PositionTicks/(double)TimeSpan.TicksPerSecond<=seconds);
    }
    static readonly ConditionalWeakTable<object,State> States=new();
    internal static void Bind(object session)
    {
        var overlay=Access.Get<FrameworkElement>(session,"_overlay");if(States.TryGetValue(overlay,out var prior))prior.Detach();
        States.Remove(overlay);States.Add(overlay,new(session,overlay));
    }
    sealed class State
    {
        readonly object session;readonly FrameworkElement overlay;readonly Slider slider;readonly Border bubble;readonly Image image=new(){Width=240,Height=135,Stretch=Stretch.Uniform,Visibility=Visibility.Collapsed};
        readonly EmbyApiClient api;readonly string item,source;readonly int generation;readonly Microsoft.UI.Dispatching.DispatcherQueueTimer debounce;
        readonly Dictionary<long,BitmapImage> cache=new();readonly HashSet<long> failed=new();readonly SemaphoreSlim serial=new(1,1);
        readonly UIElement oldChild;CancellationTokenSource? pending;Frame[]? frames;bool detached,hovering;long revision;
        bool Current=>!detached&&generation==Access.Get<int>(session,"_mediaGeneration")&&!NativeDolby.IsClosing(session)&&ReferenceEquals(api,Access.Get<EmbyApiClient>(session,"_embyClient"));
        internal State(object session,FrameworkElement overlay)
        {
            this.session=session;this.overlay=overlay;generation=Access.Get<int>(session,"_mediaGeneration");api=Access.Get<EmbyApiClient>(session,"_embyClient");item=Access.Get<EmbyItem>(session,"_item").Id;source=Access.Get<MediaSourceInfo>(session,"_source").Id;
            slider=Access.Get<Slider>(overlay,"PositionSlider");bubble=Access.Get<Border>(overlay,"SeekPreviewBubble");oldChild=bubble.Child;
            bubble.Child=null;var panel=new StackPanel{Spacing=6};panel.Children.Add(image);panel.Children.Add(oldChild);bubble.Child=panel;
            debounce=overlay.DispatcherQueue.CreateTimer();debounce.Interval=TimeSpan.FromMilliseconds(200);debounce.IsRepeating=false;debounce.Tick+=(_,_)=>Request();
            slider.AddHandler(UIElement.PointerMovedEvent,new PointerEventHandler(Move),true);slider.AddHandler(UIElement.PointerExitedEvent,new PointerEventHandler(Exit),true);overlay.Unloaded+=Unload;
        }
        void Move(object sender,PointerRoutedEventArgs e){if(!Current)return;hovering=true;revision++;pending?.Cancel();image.Visibility=Visibility.Collapsed;debounce.Stop();debounce.Start();}
        void Exit(object sender,PointerRoutedEventArgs e){hovering=false;revision++;pending?.Cancel();debounce.Stop();image.Visibility=Visibility.Collapsed;}
        async void Request()
        {
            if(!Current||!hovering||bubble.Visibility!=Visibility.Visible||!Access.Get<bool>(session,"_hasStartedPlayback"))return;
            string clock=Access.Get<TextBlock>(overlay,"SeekPreviewText").Text;
            if(!DesktopTime.TryParse(clock,out double seconds))return;
            long request=revision;var cancellation=new CancellationTokenSource(TimeSpan.FromSeconds(6));pending=cancellation;var token=cancellation.Token;bool locked=false;
            bool Valid()=>Current&&hovering&&!token.IsCancellationRequested&&revision==request;
            try{
                await serial.WaitAsync(token);locked=true;if(!Valid())return;
                if(frames==null){var bytes=await Fetch($"Items/{Uri.EscapeDataString(item)}/ThumbnailSet?Width=320&MediaSourceId={Uri.EscapeDataString(source)}",2*1024*1024,token);frames=Parse(bytes);}
                if(!Valid())return;var frame=Select(frames,seconds);if(frame==null||failed.Contains(frame.PositionTicks))return;
                if(!cache.TryGetValue(frame.PositionTicks,out var bitmap)){
                    var path=$"Items/{Uri.EscapeDataString(item)}/Images/Thumbnail?MaxWidth=320&Quality=80&PositionTicks={frame.PositionTicks.ToString(CultureInfo.InvariantCulture)}&MediaSourceId={Uri.EscapeDataString(source)}&Tag={Uri.EscapeDataString(frame.ImageTag)}";
                    try{
                        var bytes=await Fetch(path,2*1024*1024,token);if(!Valid())return;
                        using var stream=new InMemoryRandomAccessStream();using(var writer=new DataWriter(stream)){writer.WriteBytes(bytes);await writer.StoreAsync();writer.DetachStream();}stream.Seek(0);
                        var decoder=await Windows.Graphics.Imaging.BitmapDecoder.CreateAsync(stream);if(decoder.PixelWidth>4096||decoder.PixelHeight>4096||(long)decoder.PixelWidth*decoder.PixelHeight>4*1024*1024)throw new InvalidDataException();
                        stream.Seek(0);bitmap=new BitmapImage{DecodePixelWidth=240};await bitmap.SetSourceAsync(stream);if(!Valid())return;
                        if(cache.Count>=12)cache.Remove(cache.Keys.First());cache[frame.PositionTicks]=bitmap;
                    }catch(OperationCanceledException){throw;}catch{failed.Add(frame.PositionTicks);throw;}
                }
                if(!Valid())return;image.Source=bitmap;image.Visibility=Visibility.Visible;Access.Call(overlay,"UpdateSeekPreview");
            }catch(OperationCanceledException){}catch(Exception e){if(frames==null)frames=[];PlaybackTransport.Write("Info","Playback.Preview","预览图不可用，保留时间预览；"+e.GetType().Name);}
            finally{if(locked)serial.Release();if(ReferenceEquals(pending,cancellation))pending=null;cancellation.Dispose();}
        }
        async Task<byte[]> Fetch(string path,int maximum,CancellationToken token)
        {
            var coordinator=Access.Get<ServerRequestCoordinator>(api,"_requestCoordinator");
            using var lease=await coordinator.AcquireAsync(ServerRequestPriority.Background,token);
            var create=typeof(EmbyApiClient).GetMethods(BindingFlags.Instance|BindingFlags.NonPublic).Single(m=>m.Name=="CreateRequest"&&m.GetParameters()[1].ParameterType==typeof(string));
            using var request=(HttpRequestMessage)create.Invoke(api,[HttpMethod.Get,path,true])!;
            using var response=await ApiResponseGuard.SendAsync(Access.Get<HttpClient>(api,"_httpClient"),request,HttpCompletionOption.ResponseHeadersRead,token);
            response.EnsureSuccessStatusCode();await using var input=await response.Content.ReadAsStreamAsync(token);using var output=new MemoryStream();var buffer=new byte[16384];
            int count;while((count=await input.ReadAsync(buffer,token))>0){if(output.Length+count>maximum)throw new InvalidDataException();output.Write(buffer,0,count);}return output.ToArray();
        }
        void Unload(object sender,RoutedEventArgs e)=>Detach();
        internal void Detach(){detached=true;pending?.Cancel();debounce.Stop();slider.RemoveHandler(UIElement.PointerMovedEvent,new PointerEventHandler(Move));slider.RemoveHandler(UIElement.PointerExitedEvent,new PointerEventHandler(Exit));overlay.Unloaded-=Unload;cache.Clear();image.Source=null;if(bubble.Child is StackPanel panel){panel.Children.Clear();bubble.Child=oldChild;}}
    }
}
