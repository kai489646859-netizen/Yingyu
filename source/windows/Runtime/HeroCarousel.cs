using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Animation;
using Microsoft.UI.Xaml.Markup;
namespace Yingyu.Update;

// The five models are loaded by HomePresentation independently of which slide is visible.
internal sealed class HeroCarousel
{
    static readonly System.Runtime.CompilerServices.ConditionalWeakTable<Button,Grid> TapAnchors=new();
    internal static FrameworkElement? TapAnchor(Button button)=>TapAnchors.TryGetValue(button,out var anchor)?anchor:null;
    internal readonly Grid Root=new(){Name="HomeRecommendationCarousel"};
    readonly Grid viewport=new(){Background=DesktopVisuals.Brush(0)};
    readonly Grid artwork=new();
    readonly Border frame=new();
    // One transparent hit surface covers dots, gaps and the space to the bottom edge.
    // Gaps block poster clicks, while hover belongs to the whole carousel.
    readonly Grid navigation=new(){Name="HomeRecommendationNavigation",Height=48,VerticalAlignment=VerticalAlignment.Bottom,Background=DesktopVisuals.Brush(0)};
    static readonly ControlTemplate DotTemplate=(ControlTemplate)XamlReader.Load("""
        <ControlTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" TargetType="Button">
          <Grid Background="Transparent">
            <ContentPresenter Content="{TemplateBinding Content}" HorizontalAlignment="Center" VerticalAlignment="Center" />
          </Grid>
        </ControlTemplate>
        """);
    readonly StackPanel dots=new(){Name="HomeRecommendationDots",Orientation=Orientation.Horizontal,HorizontalAlignment=HorizontalAlignment.Center,VerticalAlignment=VerticalAlignment.Bottom,Margin=new(0,0,0,8),Spacing=2};
    readonly DispatcherQueueTimer timer;
    Button[] slides=[];int index;bool keyboardNavigation,active;Storyboard? motion;int revision;
    internal HeroCarousel(DispatcherQueue queue)
    {
        viewport.Children.Add(artwork);frame.Child=viewport;Root.Children.Add(frame);navigation.Children.Add(dots);Root.Children.Add(navigation);
        // Keep one hover/press transform alive across slide changes. Both slides
        // move inside the same scaled artwork, so the next one never grows anew.
        Root.Background=DesktopVisuals.Brush(0);
        PosterMotion.Attach(Root,artwork);
        // Stop animations after layout, not inside SizeChanged: collapsing the
        // animated slides during layout can trigger a native WinUI failure.
        viewport.SizeChanged+=(_,_)=>{viewport.Clip=new RectangleGeometry{Rect=new(0,0,viewport.ActualWidth,viewport.ActualHeight)};int generation=revision;viewport.DispatcherQueue.TryEnqueue(()=>{if(generation==revision)Finish();});};
        timer=queue.CreateTimer();
        timer.Interval=TimeSpan.FromSeconds(3);
        timer.IsRepeating=true;
        timer.Tick+=(_,_)=>Rotate();
        Root.GettingFocus+=(_,e)=>keyboardNavigation=e.InputDevice is FocusInputDeviceKind.Keyboard or FocusInputDeviceKind.GameController;
        Root.PreviewKeyDown+=(_,_)=>keyboardNavigation=true;
        Root.Unloaded+=(_,_)=>{
            timer.Stop();
            Finish();
            keyboardNavigation=false;
            queue.TryEnqueue(DispatcherQueuePriority.Low,EnsureTimer);
        };
        Root.Loaded+=(_,_)=>queue.TryEnqueue(DispatcherQueuePriority.Low,EnsureTimer);
    }
    bool CanRotate=>active&&Root.IsLoaded&&Root.XamlRoot is not null&&slides.Length>1;

    bool HasNavigationFocus()
    {
        if(!keyboardNavigation||Root.XamlRoot is not {} root)return false;
        if(FocusManager.GetFocusedElement(root) is not Control {FocusState:FocusState.Keyboard} control)return false;
        for(DependencyObject? node=control;node is not null;node=VisualTreeHelper.GetParent(node))
            if(node==Root)return true;
        return false;
    }

    void Rotate()
    {
        if(!CanRotate){timer.Stop();return;}
        // A focus pause skips one tick. It does not consume the timer.
        if(!HasNavigationFocus())Show((index+1)%slides.Length,true);
    }

    internal void Active(bool value)
    {
        if(active&&!value){Finish();keyboardNavigation=false;}
        active=value;
        EnsureTimer();
    }

    void EnsureTimer()
    {
        if(!CanRotate){timer.Stop();return;}
        if(!timer.IsRunning)timer.Start();
    }

    void RestartTimer()
    {
        timer.Stop();
        EnsureTimer();
    }

    internal void Set(Button[] values)
    {
        timer.Stop();Finish();keyboardNavigation=false;artwork.Children.Clear();dots.Children.Clear();slides=values;index=0;frame.CornerRadius=new(Math.Min(DesktopTheme.Options.Radius,14));
        for(int i=0;i<slides.Length;i++){
            var slide=slides[i];TapAnchors.Remove(slide);TapAnchors.Add(slide,Root);PosterMotion.OwnButton(slide);slide.Visibility=i==0?Visibility.Visible:Visibility.Collapsed;artwork.Children.Add(slide);
            int at=i;var dot=new Button{Name="RecommendationDot"+i,Template=DotTemplate,UseSystemFocusVisuals=true,Width=28,Height=28,MinWidth=0,MinHeight=0,Padding=new(0),BorderThickness=new(0),Background=DesktopVisuals.Brush(0),HorizontalContentAlignment=HorizontalAlignment.Center,VerticalContentAlignment=VerticalAlignment.Center,Content=new Border{Width=8,Height=8,CornerRadius=new(4)}};
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(dot,$"第 {i+1} 张推荐");ToolTipService.SetToolTip(dot,$"第 {i+1} 张");
            dot.Click+=(_,_)=>Show(at,false);dots.Children.Add(dot);
        }
        navigation.Visibility=dots.Visibility=slides.Length>1?Visibility.Visible:Visibility.Collapsed;Paint();EnsureTimer();
    }
    void Paint(){for(int i=0;i<dots.Children.Count;i++){var dot=(Button)dots.Children[i];var mark=(Border)dot.Content;mark.Width=i==index?20:8;mark.Background=DesktopVisuals.Brush(i==index?0xFFFFFFFF:0x88FFFFFF);Microsoft.UI.Xaml.Automation.AutomationProperties.SetItemStatus(dot,i==index?"当前推荐":"");}}
    void Finish(){revision++;motion?.Stop();motion=null;for(int i=0;i<slides.Length;i++){slides[i].RenderTransform=null;slides[i].Visibility=i==index?Visibility.Visible:Visibility.Collapsed;slides[i].IsHitTestVisible=i==index;}}
    internal void Show(int next,bool automatic=false)
    {
        if(next<0||next>=slides.Length)return;
        Finish();if(next==index){RestartTimer();return;}int previous=index;int direction=automatic?1:Math.Sign(next-previous);index=next;Paint();
        if(DesktopTheme.Options.ReducedMotion||viewport.ActualWidth<1){Finish();RestartTimer();return;}
        var old=slides[previous];var current=slides[next];old.Visibility=current.Visibility=Visibility.Visible;old.IsHitTestVisible=current.IsHitTestVisible=true;
        var outgoing=new TranslateTransform();var incoming=new TranslateTransform{X=direction*viewport.ActualWidth};old.RenderTransform=outgoing;current.RenderTransform=incoming;
        int generation=revision;var transition=motion=new Storyboard();
        void Move(TranslateTransform target,double from,double to){var animation=new DoubleAnimation{From=from,To=to,Duration=new Duration(TimeSpan.FromMilliseconds(280)),EasingFunction=new CubicEase{EasingMode=EasingMode.EaseInOut}};Storyboard.SetTarget(animation,target);Storyboard.SetTargetProperty(animation,"X");transition.Children.Add(animation);}
        Move(outgoing,0,-direction*viewport.ActualWidth);Move(incoming,direction*viewport.ActualWidth,0);
        transition.Completed+=(_,_)=>{if(generation==revision)Finish();};transition.Begin();RestartTimer();
    }
}
