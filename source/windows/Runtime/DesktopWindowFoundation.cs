// Copyright (c) Richasy. All rights reserved.
// Licensed under the MIT License.
// Adapted from winui-kernel WindowBase and AppTitleBar.UpdateTheme,
// commit 3f1086f6cfa8c1e0c3a64b930a8577dc5496c616.
using System.Runtime.CompilerServices;
using System.Reflection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.UI.Windowing;
using Windows.UI;
using Microsoft.UI;

namespace Yingyu.Update;

internal static class DesktopWindowFoundation
{
    static readonly ConditionalWeakTable<Window,State> Windows=new();
    internal static void Apply(Window window,Grid root,Brush background,bool reducedTransparency,bool highContrast)
        =>Windows.GetValue(window,w=>new(w,root)).Apply(background,reducedTransparency,highContrast);
    sealed class State
    {
        readonly Window window;readonly Grid root;readonly Grid title;bool? material;bool highContrast;
        internal State(Window window,Grid root)
        {
            this.window=window;this.root=root;
            var original=window.GetType().GetField("AppTitleBar",BindingFlags.Instance|BindingFlags.Public|BindingFlags.NonPublic)?.GetValue(window) as TitleBar
                ??throw new InvalidOperationException("Missing original title bar");
            var parent=original.Parent as Panel??throw new InvalidOperationException("Missing title wrapper");
            title=new Grid{Name="DesktopNativeTitleRegion",Height=32,Background=new SolidColorBrush(Colors.Transparent)};
            title.ColumnDefinitions.Add(new(){Width=new(1,GridUnitType.Star)});
            title.ColumnDefinitions.Add(new(){Width=new(0)});
            var content=new StackPanel{Orientation=Orientation.Horizontal,Spacing=12,Margin=new(16,0,0,0),VerticalAlignment=VerticalAlignment.Center};
            content.Children.Add(new Image{Source=new BitmapImage(new Uri(Path.Combine(AppContext.BaseDirectory,"Assets","AppIconSource.png"))),Width=16,Height=16});
            content.Children.Add(new TextBlock{Text=original.Title,FontSize=12,VerticalAlignment=VerticalAlignment.Center});
            if(!string.IsNullOrEmpty(original.Subtitle))content.Children.Add(new TextBlock{Text=original.Subtitle,FontSize=12,VerticalAlignment=VerticalAlignment.Center});
            title.Children.Add(content);
            parent.Background=new SolidColorBrush(Colors.Transparent);
            foreach(var rule in parent.Children.OfType<Border>()){rule.BorderThickness=new(0);rule.Background=new SolidColorBrush(Colors.Transparent);}
            int index=parent.Children.IndexOf(original);parent.Children.Remove(original);parent.Children.Insert(index,title);
            window.SetTitleBar(title);
            title.SizeChanged+=TitleSize;title.Loaded+=TitleLoaded;
            window.AppWindow.TitleBar.ExtendsContentIntoTitleBar=true;
            window.AppWindow.TitleBar.IconShowOptions=IconShowOptions.HideIconAndSystemMenu;
            root.ActualThemeChanged+=ThemeChanged;window.Activated+=Activated;window.Closed+=Closed;
        }
        internal void Apply(Brush background,bool reducedTransparency,bool highContrast)
        {
            this.highContrast=highContrast;title.Background=background;
            bool enabled=!reducedTransparency;
            if(material!=enabled){window.SystemBackdrop=enabled?new MicaBackdrop():null;material=enabled;}
            UpdateTheme();UpdatePadding();
        }
        void TitleLoaded(object sender,RoutedEventArgs args){window.SetTitleBar(title);UpdateTheme();UpdatePadding();}
        void TitleSize(object sender,SizeChangedEventArgs args)=>UpdatePadding();
        void UpdatePadding()
        {
            double scale=title.XamlRoot?.RasterizationScale??1;
            title.ColumnDefinitions[1].Width=new(window.AppWindow.TitleBar.RightInset/scale);
        }
        void ThemeChanged(FrameworkElement sender,object args)=>UpdateTheme();
        void Activated(object sender,WindowActivatedEventArgs args)=>UpdateTheme();
        void Closed(object sender,WindowEventArgs args)
        {root.ActualThemeChanged-=ThemeChanged;window.Activated-=Activated;window.Closed-=Closed;title.SizeChanged-=TitleSize;title.Loaded-=TitleLoaded;}
        void UpdateTheme()
        {
            var titleBar=window.AppWindow.TitleBar;
            bool light=root.ActualTheme!=ElementTheme.Dark;
            // The inherited host assigned its own non-client title colors.
            // WindowBase leaves these to the shared system backdrop.
            titleBar.BackgroundColor=null;titleBar.InactiveBackgroundColor=null;
            titleBar.ForegroundColor=null;titleBar.InactiveForegroundColor=null;
            titleBar.ButtonBackgroundColor=Colors.Transparent;
            titleBar.ButtonInactiveBackgroundColor=Colors.Transparent;
            if(highContrast)
            {
                titleBar.ButtonHoverBackgroundColor=null;titleBar.ButtonPressedBackgroundColor=null;
                titleBar.ButtonForegroundColor=null;titleBar.ButtonHoverForegroundColor=null;
                titleBar.ButtonPressedForegroundColor=null;titleBar.ButtonInactiveForegroundColor=null;
                return;
            }
            titleBar.ButtonHoverBackgroundColor=light?Colors.LightGray:Colors.Black;
            titleBar.ButtonForegroundColor=light?Colors.Black:Colors.White;
            titleBar.ButtonHoverForegroundColor=light?Colors.Black:Colors.White;
            titleBar.ButtonPressedForegroundColor=light?Colors.Black:Colors.White;
            titleBar.ButtonInactiveForegroundColor=light?Colors.Gray:Colors.LightGray;
            titleBar.ButtonPressedBackgroundColor=null;
        }
    }
}

