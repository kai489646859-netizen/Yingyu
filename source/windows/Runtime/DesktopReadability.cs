using EmbyDesktop.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Markup;
using Microsoft.UI.Xaml.Media;
using System.Runtime.CompilerServices;
using Windows.Foundation;

namespace Yingyu.Update;

// Contrast belongs to each control's final paint pass, not the page gradient.
internal static class DesktopReadability
{
    internal static uint Progress(DesktopThemePalette p)=>p.Accent==p.Text?p.Text:DesktopTheme.Options.Accent switch
    {6=>0xFFF09D8D,7=>0xFF65D79A,9=>0xFF62D0ED,_=>0xFFBE9AF4};
    internal static double Percentage(EmbyItem item,double original,bool resume)
    {
        if(!resume)return double.IsFinite(original)?Math.Clamp(original,0,100):0;
        // Played records can still have a partial rewatch. Do not use the
        // host's completed=100 shortcut, or invent a denominator when unknown.
        return item.RunTimeTicks is >0&&item.UserData is {PlaybackPositionTicks:>=0} data
            ?Math.Clamp(data.PlaybackPositionTicks*100.0/item.RunTimeTicks.Value,0,100):item.UserData is {PlaybackPositionTicks:>0,PlayedPercentage:>0 and <100} partial?partial.PlayedPercentage.Value:0;
    }
    internal static void Search(Control input,DesktopThemePalette p)
    {
        uint background=p.Background==p.Surface&&p.Accent==p.Text?p.Surface:ReferenceSurfaces.Dark(input)?0xFF272B35:0xFFFFFFFF;
        input.Background=DesktopVisuals.Brush(background);input.Foreground=DesktopVisuals.Brush(p.Text);
        input.BorderBrush=DesktopVisuals.Brush(DesktopMaterial.Mix(p.Outline,p.Accent,.38));input.BorderThickness=new(1);
        foreach(string suffix in new[]{"","PointerOver","Pressed","Focused","Disabled"})
        {
            input.Resources["ButtonBackground"+suffix]=DesktopVisuals.Brush(background);
            input.Resources["ButtonForeground"+suffix]=DesktopVisuals.Brush(p.Text);
            input.Resources["TextControlBackground"+suffix]=DesktopVisuals.Brush(background);
            input.Resources["TextControlForeground"+suffix]=DesktopVisuals.Brush(p.Text);
            input.Resources["TextControlPlaceholderForeground"+suffix]=DesktopVisuals.Brush(p.Secondary);
            input.Resources["TextControlBorderBrush"+suffix]=input.BorderBrush;
        }
        if(input is AutoSuggestBox box)foreach(var text in UiElements.Descendants(box).OfType<TextBox>())Search(text,p);
    }
    static readonly ControlTemplate ArrowTemplate=(ControlTemplate)XamlReader.Load(DesktopVisuals.ActionXaml);
    static readonly ConditionalWeakTable<Button,ArrowPosition> Positions=new();
    static readonly ConditionalWeakTable<FrameworkElement,ContentDiscovery> Discoveries=new();
    sealed class ContentDiscovery
    {
        readonly FrameworkElement view;bool queued;
        internal ContentDiscovery(FrameworkElement view)
        {
            this.view=view;view.Loaded+=(_,_)=>Queue();view.SizeChanged+=(_,_)=>Queue();
            foreach(string name in new[]{"HomeLibrarySectionsControl","ResumeSection","ResumeItemsControl","DetailEpisodeStripItems"})
                if(view.FindName(name) is FrameworkElement content)
                {
                    content.Loaded+=(_,_)=>Queue();content.SizeChanged+=(_,_)=>Queue();
                    if(content is ItemsControl items)items.Items.VectorChanged+=(_,_)=>Queue();
                }
        }
        void Queue()
        {
            if(queued)return;queued=true;
            if(!view.DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Normal,()=>{
                queued=false;if(view.IsLoaded)PaintArrows(view);
            }))queued=false;
        }
    }
    internal static void Arrow(Button button,bool right)
    {
        var p=ReferenceSurfaces.Palette(button);
        button.Template=ArrowTemplate;string glyph=right?"\uE76C":"\uE76B";if(button.Content is not FontIcon current||current.Glyph!=glyph)button.Content=new FontIcon{Glyph=glyph,FontSize=12,IsTextScaleFactorEnabled=false};if(button.Content is FontIcon icon)icon.Foreground=DesktopVisuals.Brush(p.Text);
        button.Width=34;button.Height=34;button.MinWidth=34;button.MinHeight=34;button.MaxHeight=double.PositiveInfinity;
        button.Padding=new(0);button.CornerRadius=new(17);button.BorderThickness=new(1);
        button.Background=DesktopVisuals.Brush(p.Surface);button.BorderBrush=DesktopVisuals.Brush(DesktopMaterial.Mix(p.Outline,p.Accent,.4));button.Foreground=DesktopVisuals.Brush(p.Text);
        button.HorizontalContentAlignment=HorizontalAlignment.Center;button.VerticalContentAlignment=VerticalAlignment.Center;
        Positions.GetValue(button,b=>new ArrowPosition(b,right)).Initialize();
    }
    // Keep original buttons, handlers and row parent. Put the existing heading
    // and both controls in a header row; the original viewport spans below it.
    static readonly ConditionalWeakTable<Grid,object> HeaderRows=new();
    sealed class ArrowPosition
    {
        readonly Button button;readonly bool right;
        Grid? row;ScrollViewer? scroll;bool queued;
        internal ArrowPosition(Button button,bool right)
        {
            this.button=button;this.right=right;button.Loaded+=(_,_)=>Initialize();button.Unloaded+=(_,_)=>Unbind();
        }
        internal void Initialize(){if(button.IsLoaded)Paint();else Queue();}
        void Unbind(){if(row!=null)row.SizeChanged-=Changed;if(scroll!=null){scroll.ViewChanged-=Scrolled;scroll.SizeChanged-=Changed;if(scroll.Content is FrameworkElement content)content.SizeChanged-=Changed;}row=null;scroll=null;}
        void Changed(object sender,SizeChangedEventArgs args)=>Queue();
        void Scrolled(object? sender,ScrollViewerViewChangedEventArgs args)=>Queue();
        internal void Queue()
        {
            if(queued)return;queued=true;
            if(!button.DispatcherQueue.TryEnqueue(()=>{queued=false;try{Paint();}catch(Exception e){PlaybackTransport.Write("Warning","Desktop.Row","栏目翻页布局未完成；"+e.GetType().Name);}}))queued=false;
        }
        void Paint()
        {
            if(!button.IsLoaded)return;
            if(button.Parent is not Grid parent)return;
            var strip=parent.Children.OfType<ScrollViewer>().FirstOrDefault(v=>v.VerticalScrollBarVisibility==ScrollBarVisibility.Disabled);
            if(strip==null)return;
            if(!ReferenceEquals(row,parent)){Unbind();row=parent;scroll=strip;row.SizeChanged+=Changed;scroll.ViewChanged+=Scrolled;scroll.SizeChanged+=Changed;if(scroll.Content is FrameworkElement content)content.SizeChanged+=Changed;}
            if(!HeaderRows.TryGetValue(parent,out _))
            {
                HeaderRows.Add(parent,new object());
                FrameworkElement? heading=null;
                if(parent.Parent is StackPanel host){int at=host.Children.IndexOf(parent);if(at>0&&host.Children[at-1] is FrameworkElement candidate&&candidate is not ScrollViewer&& !UiElements.Descendants(candidate).OfType<ScrollViewer>().Any()){heading=candidate;host.Children.RemoveAt(at-1);}}
                parent.RowDefinitions.Clear();parent.RowDefinitions.Add(new(){Height=GridLength.Auto,MinHeight=40});parent.RowDefinitions.Add(new(){Height=GridLength.Auto});parent.RowSpacing=10;
                int columns=Math.Max(1,parent.ColumnDefinitions.Count);Grid.SetRow(strip,1);Grid.SetColumn(strip,0);Grid.SetColumnSpan(strip,columns);
                if(heading!=null){Grid.SetRow(heading,0);Grid.SetColumn(heading,0);Grid.SetColumnSpan(heading,columns);heading.Margin=new(heading.Margin.Left-4,heading.Margin.Top,heading.Margin.Right+90,heading.Margin.Bottom);heading.VerticalAlignment=VerticalAlignment.Center;parent.Children.Insert(0,heading);}
            }
            // Keep the original inset that protects poster hover scaling, but
            // place that transparent gutter outside the common leading edge.
            var card=UiElements.Descendants(strip).OfType<Grid>().FirstOrDefault(g=>g.RowDefinitions.Count==3&&g.DataContext?.GetType().Name=="MediaCardViewModel"&&g.IsLoaded);
            if(card!=null&&UiElements.Descendants(card).OfType<Image>().FirstOrDefault(im=>im.IsLoaded&&im.ActualWidth>30) is {} artwork)
            {
                double inset=artwork.TransformToVisual(card).TransformPoint(new(0,0)).X;
                if(double.IsFinite(inset)&&inset>=0&&inset<50&&Math.Abs(strip.Margin.Left+inset)>.2)strip.Margin=new(-inset,strip.Margin.Top,strip.Margin.Right,strip.Margin.Bottom);
            }
            Grid.SetRow(button,0);Grid.SetColumn(button,0);Grid.SetColumnSpan(button,Math.Max(1,parent.ColumnDefinitions.Count));button.HorizontalAlignment=HorizontalAlignment.Right;button.VerticalAlignment=VerticalAlignment.Center;button.Margin=new(0,0,right?0:44,0);
        }
    }
    internal static void Arrows(FrameworkElement view)
    {Discoveries.GetValue(view,v=>new ContentDiscovery(v));PaintArrows(view);}
    static void PaintArrows(FrameworkElement view)
    {
        foreach(var button in UiElements.Descendants(view).OfType<Button>().ToArray())
        {
            if(DesktopCardSurface.Owns(button))continue;
            string name=button.Name;string label=Microsoft.UI.Xaml.Automation.AutomationProperties.GetName(button);
            bool? direction=name is "HomeRowPreviousButton"?false:name is "HomeRowNextButton"?true:label=="上一组"?false:label=="下一组"?true:button.Content is string text&&text=="‹"?false:button.Content is string text2&&text2=="›"?true:null;
            if(direction==null&&VisualTreeHelper.GetParent(button) is Grid row&&row.Children.OfType<ScrollViewer>().FirstOrDefault(s=>s.VerticalScrollBarVisibility==ScrollBarVisibility.Disabled) is {} strip)
            {
                if(button.Content is FontIcon arrow&&arrow.Glyph is "\uE76B" or "\uE76C" or "\uE0E2" or "\uE0E3")direction=arrow.Glyph is "\uE76C" or "\uE0E3";
            }
            if(direction is {} right)Arrow(button,right);
        }
    }
}
