using System.Runtime.CompilerServices;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Animation;
using Microsoft.UI.Xaml.Media.Imaging;

namespace Yingyu.Update;

// One bounded app-owned render per explicit theme change; only opacity is animated.
// The overlay never accepts input, persists data, or touches a media/native window.
internal static class ThemeTransition
{
    sealed class State{internal int Epoch;internal Image? Overlay;internal Storyboard? Animation;}
    static readonly ConditionalWeakTable<FrameworkElement,State> States=new();
    internal static async void Change(FrameworkElement page,Action apply){
        var state=States.GetValue(page,_=>new());int epoch=++state.Epoch;
        Grid? root=null;for(DependencyObject? at=page;at!=null;at=VisualTreeHelper.GetParent(at))if(at is Grid grid)root=grid;
        void Remove(){state.Animation?.Stop();state.Animation=null;if(state.Overlay is {} old){old.Source=null;if(old.Parent is Panel parent)parent.Children.Remove(old);}state.Overlay=null;}
        bool applied=false;
        async Task Deadline(){await Task.Delay(600);if(epoch!=state.Epoch||applied)return;Remove();applied=true;apply();}
        try{
            if(root==null||!page.IsLoaded||root.ActualWidth<1||root.ActualHeight<1||DesktopTheme.Options.ReducedMotion||new Windows.UI.ViewManagement.AccessibilitySettings().HighContrast){Remove();applied=true;apply();return;}
            _=Deadline();
            // Coalesce a quick sequence of mode selections before allocating a render.
            await Task.Delay(35);if(epoch!=state.Epoch)return;
            state.Animation?.Pause();
            var bitmap=new RenderTargetBitmap();double scale=Math.Min(1,Math.Min(1920/root.ActualWidth,1440/root.ActualHeight));
            await bitmap.RenderAsync(root,Math.Max(1,(int)(root.ActualWidth*scale)),Math.Max(1,(int)(root.ActualHeight*scale)));
            if(epoch!=state.Epoch||applied)return;
            Remove();
            var image=new Image{Name="DesktopThemeTransitionLayer",Source=bitmap,Stretch=Stretch.Fill,IsHitTestVisible=false,HorizontalAlignment=HorizontalAlignment.Stretch,VerticalAlignment=VerticalAlignment.Stretch};
            if(root.Name=="WindowRoot")image.Clip=new RectangleGeometry{Rect=new Windows.Foundation.Rect(0,32,root.ActualWidth,Math.Max(0,root.ActualHeight-32))};
            Grid.SetRowSpan(image,Math.Max(1,root.RowDefinitions.Count));Grid.SetColumnSpan(image,Math.Max(1,root.ColumnDefinitions.Count));state.Overlay=image;root.Children.Add(image);
            applied=true;apply();
            // Let resource and template updates settle beneath the stable old frame.
            var ready=new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            if(!page.DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low,()=>ready.TrySetResult()))ready.TrySetResult();
            await ready.Task;
            if(epoch!=state.Epoch)return;
            var fade=new DoubleAnimation{From=1,To=0,Duration=new Duration(TimeSpan.FromMilliseconds(320)),EasingFunction=new SineEase{EasingMode=EasingMode.EaseInOut}};Storyboard.SetTarget(fade,image);Storyboard.SetTargetProperty(fade,"Opacity");
            var animation=new Storyboard();animation.Children.Add(fade);state.Animation=animation;animation.Completed+=(_,_)=>{if(epoch==state.Epoch)Remove();};animation.Begin();
            // Composition may pause for an inactive/minimized window. Never retain the overlay indefinitely.
            await Task.Delay(420);if(epoch==state.Epoch)Remove();
        }catch(Exception){if(epoch==state.Epoch){Remove();if(!applied)apply();}}
    }
}
