using System.Numerics;
using System.Runtime.CompilerServices;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Hosting;
using Microsoft.UI.Composition;
namespace Yingyu.Update;
public static class PosterMotion
{
    public const double Scale=InteractionPolicy.HoverScale;
    public const int FeedbackMilliseconds=140;
    // Reserve room inside the measured cell instead of expanding into its clip.
    public static double Inset(double width,double height)=>InteractionPolicy.Inset(width,height);
    static readonly ConditionalWeakTable<FrameworkElement,State> Entries=new();
    public static void Attach(FrameworkElement hit,FrameworkElement artwork)
    {
        try { Entries.GetValue(hit,_=>new State(hit,artwork)); }
        catch(Exception error){Report(error);}
    }
    static void Report(Exception error)
    {try{PlaybackTransport.Write("Warning","Poster.Motion","海报悬停效果未能应用，保留图片；异常类型="+error.GetType().Name);}catch(Exception){}}
    sealed class State
    {
        readonly FrameworkElement hit,art;
        readonly Visual visual;
        bool reported,hovered,pressed;
        public State(FrameworkElement hit,FrameworkElement art)
        {
            this.hit=hit;this.art=art;
            // The rounded image already owns a composition visual. XAML
            // CenterPoint/Scale/ScaleTransition cannot be mixed with that API.
            visual=ElementCompositionPreview.GetElementVisual(art);
            hit.PointerEntered+=Enter;
            // Exit coordinates may still lie on the old edge during re-layout.
            // Also observe handled exits from the retained favorite button.
            hit.AddHandler(UIElement.PointerExitedEvent,new PointerEventHandler(Exit),true);
            hit.AddHandler(UIElement.PointerPressedEvent,new PointerEventHandler((_,e)=>{if(e.Pointer.PointerDeviceType==Microsoft.UI.Input.PointerDeviceType.Mouse&&e.GetCurrentPoint(hit).Properties.IsLeftButtonPressed)Safe(Press);}),true);
            hit.AddHandler(UIElement.PointerReleasedEvent,new PointerEventHandler((_,e)=>Safe(()=>Release(Inside(e)))),true);
            hit.PointerCanceled+=(_,_)=>Safe(Reset);
            hit.PointerCaptureLost+=(_,_)=>Safe(()=>{bool canceled=pressed;pressed=false;Set(canceled?false:hovered,false);});
            hit.Unloaded+=(_,_)=>Safe(Reset);
            hit.DataContextChanged+=(_,_)=>Safe(Reset);
            PosterPointerScope.Watch(hit,()=>Safe(Reset));
            art.SizeChanged+=(_,_)=>Safe(Center);
        }
        void Enter(object sender,PointerRoutedEventArgs args)
        {
            if(args.Pointer.PointerDeviceType!=Microsoft.UI.Input.PointerDeviceType.Mouse)return;
            Safe(()=>Set(true,true));
        }
        bool Inside(PointerRoutedEventArgs args){var p=args.GetCurrentPoint(hit).Position;return p.X>=0&&p.Y>=0&&p.X<hit.ActualWidth&&p.Y<hit.ActualHeight;}
        void Exit(object sender,PointerRoutedEventArgs args){if(args!=null&&!ReferenceEquals(args.OriginalSource,hit)&&Inside(args))return;Safe(Reset);}
        void Press(){pressed=true;Set(hovered,false);}
        void Release(bool inside){pressed=false;Set(inside,true);}
        void Reset(){pressed=false;Set(false,false);}
        void Center()=>visual.CenterPoint=new((float)(art.ActualWidth/2),(float)(art.ActualHeight/2),0);
        void Set(bool hovered,bool animate)
        {
            this.hovered=hovered;
            Center();
            var target=hovered&&!pressed?new Vector3((float)Scale,(float)Scale,1):Vector3.One;
            if(!hovered||!animate||DesktopTheme.Options.ReducedMotion||!art.IsLoaded)
            {visual.StopAnimation("Scale");visual.Scale=target;return;}
            using var animation=visual.Compositor.CreateVector3KeyFrameAnimation();
            animation.InsertKeyFrame(1,target);animation.Duration=TimeSpan.FromMilliseconds(FeedbackMilliseconds);
            visual.StartAnimation("Scale",animation);
        }
        void Safe(Action action)
        {
            try{action();}
            catch(Exception error)
            {
                if(!reported){reported=true;Report(error);}
                try{visual.StopAnimation("Scale");visual.Scale=Vector3.One;}catch(Exception){}
            }
        }
    }
}
