using System.Runtime.CompilerServices;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.System;
namespace Yingyu.Update;

internal static class DesktopShellActions
{
    static readonly ConditionalWeakTable<FrameworkElement,State> States=new();
    internal static void Apply(FrameworkElement page,DesktopThemeOptions options,DesktopThemePalette p)
        =>States.GetValue(page,e=>new State(e)).Update(options,p);
    internal static bool Detach(DependencyObject root,UIElement target)
    {
        if(root is Panel panel){if(panel.Children.Contains(target)){panel.Children.Remove(target);return true;}foreach(var child in panel.Children.ToArray())if(Detach(child,target))return true;}
        object? childContent=root switch{Border b=>b.Child,ContentControl c=>c.Content,ContentPresenter c=>c.Content,UserControl u=>u.Content,_=>null};
        if(ReferenceEquals(childContent,target)){switch(root){case Border b:b.Child=null;break;case ContentControl c:c.Content=null;break;case ContentPresenter c:c.Content=null;break;case UserControl u:u.Content=null;break;}return true;}
        return childContent is DependencyObject nested&&Detach(nested,target);
    }
    sealed class State
    {
        readonly FrameworkElement page;bool headerReady;readonly StackPanel actions=new(){Name="DesktopAccountActions",Orientation=Orientation.Horizontal,Spacing=8,HorizontalAlignment=HorizontalAlignment.Right,VerticalAlignment=VerticalAlignment.Center};
        public State(FrameworkElement page){this.page=page;page.PreviewKeyDown+=Key;page.PreviewKeyUp+=SearchSpace;page.SizeChanged+=(_,_)=>PlaceAccount();}
        T? Find<T>(string name) where T:class=>page.FindName(name) as T;
        public void Update(DesktopThemeOptions options,DesktopThemePalette p)
        {
            if(Find<Grid>("ShellGrid") is not {} shell)return;
            if(!headerReady&&Find<Button>("SettingsButton") is {} settings&&Find<Button>("ProfileSwitchButton") is {} profile)
            {
                if(Detach(shell,settings)&&Detach(shell,profile)){
                    if(shell.RowDefinitions.Count==0)shell.RowDefinitions.Add(new(){Height=new(1,GridUnitType.Star)});
                    shell.RowDefinitions.Insert(0,new(){Height=GridLength.Auto});foreach(var child in shell.Children.OfType<FrameworkElement>())Grid.SetRow(child,Grid.GetRow(child)+1);
                    Label(settings,"设置");ToolTipService.SetToolTip(profile,"账号与服务器");Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(profile,"账号与服务器");actions.Children.Add(settings);actions.Children.Add(profile);
                    var bar=new Border{Name="DesktopAccountToolbar",Padding=new(24,6,24,6),BorderThickness=new(0,0,0,1),Child=actions};Grid.SetColumnSpan(bar,Math.Max(1,shell.ColumnDefinitions.Count));Canvas.SetZIndex(bar,30);shell.Children.Add(bar);
                    if(Find<Grid>("AccountPanelOverlay") is {} account){Grid.SetRow(account,0);Grid.SetRowSpan(account,shell.RowDefinitions.Count);Grid.SetColumn(account,0);Grid.SetColumnSpan(account,Math.Max(1,shell.ColumnDefinitions.Count));Canvas.SetZIndex(account,20);account.RegisterPropertyChangedCallback(UIElement.VisibilityProperty,(_,_)=>page.DispatcherQueue.TryEnqueue(PlaceAccount));}
                    profile.SizeChanged+=(_,_)=>PlaceAccount();headerReady=true;
                }
            }
            foreach(var button in actions.Children.OfType<Button>()){DesktopInputBehavior.Toolbar(button);button.Width=double.NaN;button.Height=double.NaN;button.MinHeight=40;button.MaxHeight=double.PositiveInfinity;button.MinWidth=0;button.Margin=new(0);button.Padding=new(12,6,12,6);button.HorizontalAlignment=HorizontalAlignment.Stretch;button.HorizontalContentAlignment=HorizontalAlignment.Stretch;button.VerticalAlignment=VerticalAlignment.Center;button.Foreground=DesktopVisuals.Brush(p.Text);}
            foreach(var bar in shell.Children.OfType<Border>().Where(b=>b.Name=="DesktopAccountToolbar")){bar.Background=DesktopMaterial.Surface(options,p);bar.BorderBrush=DesktopVisuals.Brush(p.Outline);}
            if(Find<Grid>("AccountPanelOverlay") is {} overlay)foreach(var border in overlay.Children.OfType<Border>()){border.Background=DesktopMaterial.Surface(options,p);border.BorderBrush=DesktopVisuals.Brush(p.Outline);border.CornerRadius=new(16);if(border.Child is UIElement content&&content is not ScrollViewer){border.Child=null;border.Child=new ScrollViewer{Content=content,VerticalScrollBarVisibility=ScrollBarVisibility.Auto,HorizontalScrollBarVisibility=ScrollBarVisibility.Disabled};}}
            PlaceAccount();
            // Reconnect and a failed-page retry have different effects.
            if(Find<Button>("GlobalRefreshButton") is {} global)ToolTipService.SetToolTip(global,"重新连接并刷新");
            if(Find<Button>("RefreshLibraryButton") is {} retry)ToolTipService.SetToolTip(retry,"重新加载当前页面");
        }
        void PlaceAccount()
        {
            if(!headerReady||Find<Grid>("ShellGrid") is not {} shell||Find<Button>("ProfileSwitchButton") is not {} profile||Find<Grid>("AccountPanelOverlay") is not {} overlay||profile.ActualWidth<=0||shell.ActualWidth<=0)return;
            var anchor=profile.TransformToVisual(shell).TransformBounds(new Windows.Foundation.Rect(0,0,profile.ActualWidth,profile.ActualHeight));
            foreach(var border in overlay.Children.OfType<Border>()){
                double width=Math.Min(320,Math.Max(1,shell.ActualWidth-32));double left=Math.Clamp(anchor.Right-width,16,Math.Max(16,shell.ActualWidth-width-16));double top=Math.Min(anchor.Bottom+8,Math.Max(0,shell.ActualHeight-12));
                border.HorizontalAlignment=HorizontalAlignment.Left;border.VerticalAlignment=VerticalAlignment.Top;border.Width=width;border.MaxHeight=Math.Max(1,shell.ActualHeight-top-12);border.Margin=new(left,top,0,0);
            }
        }
        static void Label(Button button,string label)
        {
            var content=button.Content;if(content is FrameworkElement existing&&UiElements.Descendants(existing).OfType<TextBlock>().Any(t=>t.Text==label))return;
            button.Content=null;var line=new Grid{ColumnSpacing=10};line.ColumnDefinitions.Add(new(){Width=GridLength.Auto});line.ColumnDefinitions.Add(new(){Width=new(1,GridUnitType.Star)});if(content is UIElement ui)line.Children.Add(ui);else if(content!=null)line.Children.Add(new TextBlock{Text=content.ToString()});var text=new TextBlock{Text=label,FontSize=14,TextWrapping=TextWrapping.Wrap,VerticalAlignment=VerticalAlignment.Center};Grid.SetColumn(text,1);line.Children.Add(text);button.Content=line;
        }
        void Key(object sender,KeyRoutedEventArgs e)
        {
            SearchSpace(sender,e);if(e.Handled)return;
            try{
                if(e.Handled||page.XamlRoot==null||VisualTreeHelper.GetOpenPopupsForXamlRoot(page.XamlRoot).Any(p=>p.IsOpen))return;
                bool control=Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Control).HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);
                if(control&&e.Key==VirtualKey.F){if(Find<Grid>("SettingsView")?.Visibility==Visibility.Visible)Find<TextBox>("ExperienceSettingsSearch")?.Focus(FocusState.Keyboard);else ReferenceAppearance.FocusSearch(page);e.Handled=true;}
                if(e.Key==VirtualKey.Escape){if(Find<Grid>("AccountPanelOverlay")?.Visibility==Visibility.Visible){Access.Call(page,"CloseAccountPanel");e.Handled=true;}else if(Find<Grid>("SettingsView")?.Visibility==Visibility.Visible){Access.Call(page,"CloseSettingsButton_Click",Find<Button>("CloseSettingsButton"),new RoutedEventArgs());e.Handled=true;}}
            }catch(Exception error){try{PlaybackTransport.Write("Warning","Desktop.Input","页面快捷键未完成；"+error.GetType().Name);}catch(Exception){}}
        }
        void SearchSpace(object sender,KeyRoutedEventArgs e)
        {
            try
            {
                if(e.Handled||e.Key!=VirtualKey.Space||page.XamlRoot==null||Find<Grid>("DetailView")?.Visibility==Visibility.Visible
                    ||VisualTreeHelper.GetOpenPopupsForXamlRoot(page.XamlRoot).Any(p=>p.IsOpen))return;
                bool search=Find<StackPanel>("SearchResultsPanel")?.Visibility==Visibility.Visible||!string.IsNullOrWhiteSpace(Access.Get<string?>(page,"_lastSearchTerm"));
                if(!search)return;
                bool media=false;
                for(var node=FocusManager.GetFocusedElement(page.XamlRoot) as DependencyObject;node!=null;node=VisualTreeHelper.GetParent(node))
                {
                    if(node is TextBox or PasswordBox or RichEditBox)return;
                    if(node is GridViewItem||node is FrameworkElement{Name:"PosterCardRoot" or "ReferenceSearchSuggestions" or "SearchResultsPanel"})media=true;
                }
                if(media)e.Handled=true;
            }
            catch(Exception error){try{PlaybackTransport.Write("Warning","Desktop.Input","搜索键盘焦点核对未完成；"+error.GetType().Name);}catch(Exception){}}
        }
    }
}
