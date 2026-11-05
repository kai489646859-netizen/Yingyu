using System.Runtime.CompilerServices;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.UI;

namespace Yingyu.Update;

public static class PlaybackStateFeedback
{
    static readonly ConditionalWeakTable<object, State> States=new();
    public static void Paused(object overlay, bool visible) => Changed(overlay);
    // State notifications during seek/refill must not summon hidden chrome.
    public static void StateControls(object overlay,bool visible)
    {if(Access.Get<bool>(overlay,"_controlsVisible"))Access.Call(overlay,"SetControlsVisible",visible);}
    public static void StateTemporarily(object overlay)
    {if(Access.Get<bool>(overlay,"_controlsVisible"))Access.Call(overlay,"ShowControlsTemporarily");}
    public static void Changed(object overlay)
    {
        if(Access.Get<bool>(overlay,"_controlsVisible"))
            Access.Call(overlay,"ShowControlsTemporarily");
        States.GetValue(overlay,x=>new State(x)).Show(Access.Get<bool>(overlay,"_isPlaying"));
    }
    sealed class State
    {
        readonly FrameworkElement owner;
        readonly Grid layer=new(){IsHitTestVisible=false};
        readonly FontIcon icon=new(){FontSize=36,Foreground=new SolidColorBrush(Color.FromArgb(255,255,255,255))};
        readonly Border panel;
        readonly Microsoft.UI.Dispatching.DispatcherQueueTimer timer;
        Grid? root;
        internal State(object overlay)
        {
            owner=(FrameworkElement)overlay;
            panel=new Border{Name="PlaybackStateFeedbackIcon",HorizontalAlignment=HorizontalAlignment.Center,VerticalAlignment=VerticalAlignment.Center,Padding=new Thickness(20),CornerRadius=new CornerRadius(38),Background=new SolidColorBrush(Color.FromArgb(90,30,30,30)),Child=icon,Visibility=Visibility.Collapsed,IsHitTestVisible=false};
            layer.Children.Add(panel);timer=owner.DispatcherQueue.CreateTimer();timer.Interval=TimeSpan.FromSeconds(1);timer.IsRepeating=false;timer.Tick+=(_,_)=>Hide();
            owner.Unloaded+=(_,_)=>Hide();
        }
        internal void Show(bool playing)
        {
            if(!owner.IsLoaded)return;
            if(root==null){root=Access.Get<Grid>(owner,"RootGrid");Grid.SetRowSpan(layer,Math.Max(1,root.RowDefinitions.Count));Grid.SetColumnSpan(layer,Math.Max(1,root.ColumnDefinitions.Count));root.Children.Add(layer);}
            icon.Glyph=playing?"\ue769":"\ue768";
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(panel,playing?"正在播放":"已暂停");
            panel.Visibility=Visibility.Visible;timer.Stop();timer.Start();
        }
        internal void Hide(){timer.Stop();panel.Visibility=Visibility.Collapsed;root?.Children.Remove(layer);root=null;}
    }
}
