using System.Runtime.CompilerServices;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Animation;
namespace Yingyu.Update;

// Only an owned content container animates. Buttons retain their native
// XAML input feedback and are never claimed by this transition helper.
internal static class DesktopSceneMotion
{
    static readonly ConditionalWeakTable<FrameworkElement,State> States=new();
    internal static void Enter(FrameworkElement element)
    {
        if(element is Control)return;
        try{States.GetValue(element,e=>new(e)).Enter();}catch(Exception error){Warn(error);}
    }
    internal static Task<bool> Exit(FrameworkElement element)
    {
        if(element is Control)return Task.FromResult(true);
        try{return States.GetValue(element,e=>new(e)).Exit();}catch(Exception error){Warn(error);return Task.FromResult(true);}
    }
    internal static void Reset(FrameworkElement element){if(States.TryGetValue(element,out var state))state.Stop();}
    sealed class State
    {
        readonly FrameworkElement element;Storyboard? active;Transform? original;int epoch;
        TaskCompletionSource<bool>? completion;
        internal State(FrameworkElement element){this.element=element;element.Unloaded+=(_,_)=>Stop();}
        internal void Stop()
        {
            epoch++;completion?.TrySetResult(false);completion=null;try{active?.Stop();active=null;element.Opacity=1;element.RenderTransform=original??new MatrixTransform();}catch(Exception error){Warn(error);}
        }
        internal Task<bool> Exit()
        {
            Stop();if(!element.IsLoaded||DesktopTheme.Options.ReducedMotion||!new Windows.UI.ViewManagement.UISettings().AnimationsEnabled)return Task.FromResult(true);
            original=element.RenderTransform;var shift=new TranslateTransform();element.RenderTransform=shift;int ticket=epoch;
            var done=completion=new(TaskCreationOptions.RunContinuationsAsynchronously);var storyboard=active=new Storyboard();var duration=new Duration(TimeSpan.FromMilliseconds(180));
            var fade=new DoubleAnimation{From=1,To=0,Duration=duration};Storyboard.SetTarget(fade,element);Storyboard.SetTargetProperty(fade,"Opacity");storyboard.Children.Add(fade);
            var slide=new DoubleAnimation{From=0,To=14,Duration=duration,EnableDependentAnimation=true,EasingFunction=new CubicEase{EasingMode=EasingMode.EaseIn}};
            Storyboard.SetTarget(slide,shift);Storyboard.SetTargetProperty(slide,"Y");storyboard.Children.Add(slide);
            storyboard.Completed+=(_,_)=>{if(ticket==epoch){completion=null;Stop();done.TrySetResult(true);}};storyboard.Begin();return done.Task;
        }
        internal void Enter()
        {
            Stop();if(!element.IsLoaded||DesktopTheme.Options.ReducedMotion||!new Windows.UI.ViewManagement.UISettings().AnimationsEnabled)return;
            original=element.RenderTransform;var shift=new TranslateTransform();element.RenderTransform=shift;int ticket=epoch;
            var storyboard=active=new Storyboard();var duration=new Duration(TimeSpan.FromMilliseconds(180));
            var fade=new DoubleAnimation{From=0,To=1,Duration=duration};Storyboard.SetTarget(fade,element);Storyboard.SetTargetProperty(fade,"Opacity");storyboard.Children.Add(fade);
            var slide=new DoubleAnimation{From=14,To=0,Duration=duration,EnableDependentAnimation=true,EasingFunction=new CubicEase{EasingMode=EasingMode.EaseOut}};
            Storyboard.SetTarget(slide,shift);Storyboard.SetTargetProperty(slide,"Y");storyboard.Children.Add(slide);
            storyboard.Completed+=(_,_)=>{if(ticket==epoch)Stop();};storyboard.Begin();
        }
    }
    static void Warn(Exception error){try{PlaybackTransport.Write("Warning","Navigation.Motion","内容过渡未完成；"+error.GetType().Name);}catch(Exception){}}
}
