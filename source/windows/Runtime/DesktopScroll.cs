using System.Runtime.CompilerServices;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using System.Diagnostics;
namespace Yingyu.Update;

public static class DesktopScroll
{
    sealed class TopStyle { public DesktopThemeOptions? Options;public DesktopThemePalette Palette;public object? Background; }
    static readonly ConditionalWeakTable<object,TopStyle> Styles=new();
    static readonly ConditionalWeakTable<object,SaveState> Saves=new();
    public static void QueueRemember(object page)=>Saves.GetValue(page,p=>new SaveState(p)).Queue();
    sealed class SaveState
    {
        readonly object page;readonly Microsoft.UI.Dispatching.DispatcherQueueTimer timer;
        object? owner;string? scope;CancellationTokenSource? generation;bool pending;
        internal SaveState(object page)
        {
            this.page=page;var element=(FrameworkElement)page;
            timer=element.DispatcherQueue.CreateTimer();timer.IsRepeating=false;timer.Interval=TimeSpan.FromMilliseconds(180);timer.Tick+=(_,_)=>Flush();
            element.Unloaded+=(_,_)=>Flush();
        }
        internal void Queue(){owner=Access.Get<object?>(page,"_session");scope=Access.Get<string?>(page,"_activeSnapshotKey");generation=Access.Get<CancellationTokenSource?>(page,"_posterLoadCts");pending=true;timer.Stop();timer.Start();}
        void Flush()
        {
            timer.Stop();if(!pending)return;pending=false;
            if(generation?.IsCancellationRequested==true||!ReferenceEquals(generation,Access.Get<CancellationTokenSource?>(page,"_posterLoadCts"))||!ReferenceEquals(owner,Access.Get<object?>(page,"_session"))||scope!=Access.Get<string?>(page,"_activeSnapshotKey"))return;
            try{Access.Call(page,"RememberBrowseOffset");}catch(Exception error){Warn(error);}
        }
    }
    public static bool IsAnimating(object page)=>Access.Get<bool>(page,"_alphabetScrollInProgress");
    public static TimeSpan Duration(double distance,double viewportHeight)=>TimeSpan.FromMilliseconds(Math.Clamp(500+Math.Abs(distance)/Math.Max(1,viewportHeight)*45,550,3600));
    public static void Start(object page,ScrollViewer scroll,double target)=>DesktopJumpPresentation.Start(page,scroll,target);
    internal static void Jump(object page,ScrollViewer scroll,int index,string letter)=>DesktopJumpPresentation.Start(page,scroll,DesktopNavigation.RowOffset(page,scroll,index),index,letter);
    public static void Cancel(object page,bool resume)=>DesktopJumpPresentation.Cancel(page,resume);
    // ABI retained. The continuous scroll owner subscribes its bounded frame work.
    public static void Frame(object page) { }
    public static void Top(object page)
    {
        try{if(Access.Call(page,"GetActiveVerticalScrollViewer") is ScrollViewer scroll)Access.Call(page,"StartAlphabetScrollAnimation",scroll,0d);}
        catch(Exception error){Warn(error);}
    }
    public static void StyleTop(object page)
    {
        try{
            if(page is not FrameworkElement element||element.FindName("BackToTopButton") is not Button button)return;
            if(button.Width!=44)button.Width=44;if(button.Height!=44)button.Height=44;
            if(button.MinWidth!=44)button.MinWidth=44;if(button.MinHeight!=44)button.MinHeight=44;
            var options=DesktopTheme.Options;var palette=DesktopThemePalette.Resolve(options,element.ActualTheme==ElementTheme.Dark);
            var state=Styles.GetOrCreateValue(page);if(state.Options==options&&state.Palette==palette&&ReferenceEquals(button.Background,state.Background))return;
            button.Padding=new(8);button.CornerRadius=new(22);button.BorderThickness=new(1);
            button.Background=DesktopMaterial.Surface(options,palette);button.Foreground=DesktopVisuals.Brush(palette.Text);button.BorderBrush=DesktopVisuals.Brush(palette.Outline);
            ToolTipService.SetToolTip(button,"回到顶部");Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button,"回到顶部");
            state.Options=options;state.Palette=palette;state.Background=button.Background;
        }catch(Exception error){Warn(error);}
    }
    static void Warn(Exception error){try{PlaybackTransport.Write("Warning","Navigation.Scroll","滚动操作未完成；"+error.GetType().Name);}catch(Exception){}}
}
