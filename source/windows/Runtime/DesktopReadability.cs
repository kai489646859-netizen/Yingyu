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
            ?Math.Clamp(data.PlaybackPositionTicks*100.0/item.RunTimeTicks.Value,0,100):0;
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
        button.Template=ArrowTemplate;string glyph=right?"\uE76C":"\uE76B";if(button.Content is not FontIcon current||current.Glyph!=glyph)button.Content=new FontIcon{Glyph=glyph,FontSize=20,IsTextScaleFactorEnabled=false};if(button.Content is FontIcon icon)icon.Foreground=DesktopVisuals.Brush(p.Text);
        button.Width=42;button.Height=54;button.MinWidth=42;button.MinHeight=54;button.MaxHeight=double.PositiveInfinity;
        button.Padding=new(0);button.CornerRadius=new(21);button.BorderThickness=new(1);
        button.Background=DesktopVisuals.Brush(p.Surface);button.BorderBrush=DesktopVisuals.Brush(DesktopMaterial.Mix(p.Outline,p.Accent,.4));button.Foreground=DesktopVisuals.Brush(p.Text);
        button.HorizontalContentAlignment=HorizontalAlignment.Center;button.VerticalContentAlignment=VerticalAlignment.Center;
        Positions.GetValue(button,b=>new ArrowPosition(b)).Queue();
    }
    // Move the existing button and hit region together. Its original parent,
    // Click handler, visibility, enabled state and horizontal position remain.
    sealed class ArrowPosition
    {
        readonly Button button;readonly Thickness originalMargin;
        Grid? row;ScrollViewer? scroll;FrameworkElement? content;
        bool queued,waiting;int retries;
        internal ArrowPosition(Button button)
        {
            this.button=button;originalMargin=button.Margin;button.Loaded+=(_,_)=>Queue();button.SizeChanged+=(_,_)=>Queue();
            button.Unloaded+=(_,_)=>Unbind();
        }
        void Unbind()
        {
            if(row!=null)row.SizeChanged-=Changed;
            button.LayoutUpdated-=Layout;
            if(scroll!=null){scroll.SizeChanged-=Changed;scroll.ViewChanged-=Scrolled;}
            if(content!=null)content.SizeChanged-=Changed;
            row=null;scroll=null;content=null;waiting=false;
        }
        void Changed(object sender,SizeChangedEventArgs args)=>Queue();
        void Scrolled(object? sender,ScrollViewerViewChangedEventArgs args)=>Queue();
        internal void Queue(bool external=true)
        {
            // XBF Loaded can arrive before IsLoaded flips. Enqueue first and
            // check readiness in Paint after the framework finishes that event.
            if(external)retries=6;if(queued)return;queued=true;
            if(!button.DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Normal,()=>{
                queued=false;try{Paint();}catch(Exception error){PlaybackTransport.Write("Warning","Desktop.Row","海报翻页按钮位置未完成；"+error.GetType().Name);}
            }))queued=false;
        }
        void Layout(object? sender,object args)
        {if(--retries<=0){button.LayoutUpdated-=Layout;waiting=false;return;}Queue(false);}
        void WaitForLayout(){if(!waiting&&retries>0){waiting=true;button.LayoutUpdated+=Layout;}}
        void Paint()
        {
            if(!button.IsLoaded)return;
            Grid? parent=null;ScrollViewer? strip=null;
            for(var node=VisualTreeHelper.GetParent(button);node!=null;node=VisualTreeHelper.GetParent(node))
                if(node is Grid grid&&(strip=grid.Children.OfType<ScrollViewer>().FirstOrDefault(v=>v.VerticalScrollBarVisibility==ScrollBarVisibility.Disabled))!=null){parent=grid;break;}
            if(parent==null||strip==null){WaitForLayout();return;}
            if(!ReferenceEquals(row,parent)||!ReferenceEquals(scroll,strip)||!ReferenceEquals(content,strip.Content))
            {
                Unbind();row=parent;scroll=strip;content=strip.Content as FrameworkElement;
                row.SizeChanged+=Changed;scroll.SizeChanged+=Changed;scroll.ViewChanged+=Scrolled;if(content!=null)content.SizeChanged+=Changed;
            }
            var viewport=scroll.TransformToVisual(row).TransformBounds(new Rect(0,0,scroll.ActualWidth,scroll.ActualHeight));
            var images=UiElements.Descendants(scroll).OfType<Image>().Where(im=>im.IsLoaded&&im.Visibility==Visibility.Visible&&im.ActualWidth>30&&im.ActualHeight>30)
                .Select(im=>im.TransformToVisual(row).TransformBounds(new Rect(0,0,im.ActualWidth,im.ActualHeight)))
                .Where(b=>b.Right>viewport.Left&&b.Left<viewport.Right).OrderBy(b=>b.Left).ToArray();
            if(images.Length==0)
            {
                // Empty/failed posters keep a real image aperture too. Never
                // wait for downloading pixels just to position an arrow.
                images=UiElements.Descendants(scroll).OfType<Grid>().Where(g=>g.IsLoaded&&g.Name=="PosterCardRoot")
                    .SelectMany(g=>g.Children.OfType<FrameworkElement>().Where(e=>Grid.GetRow(e)==0&&e.ActualWidth>30&&e.ActualHeight>30).Take(1))
                    .Select(e=>e.TransformToVisual(row).TransformBounds(new Rect(0,0,e.ActualWidth,e.ActualHeight)))
                    .Where(b=>b.Right>viewport.Left&&b.Left<viewport.Right).OrderBy(b=>b.Left).ToArray();
            }
            if(images.Length==0||button.ActualHeight<=0)
            {WaitForLayout();return;}
            if(waiting){button.LayoutUpdated-=Layout;waiting=false;}
            // Move the layout and hit region together. Balanced vertical
            // margins preserve the row's desired height and coexist with the
            // host's Scale/Translation resets and original press feedback.
            if(VisualTreeHelper.GetParent(button) is not FrameworkElement layoutParent)return;
            var area=layoutParent.TransformToVisual(row).TransformBounds(new Rect(0,0,layoutParent.ActualWidth,layoutParent.ActualHeight));
            double naturalCenter=button.VerticalAlignment switch
            {
                VerticalAlignment.Top=>area.Top+originalMargin.Top+button.ActualHeight/2,
                VerticalAlignment.Bottom=>area.Bottom-originalMargin.Bottom-button.ActualHeight/2,
                _=>area.Top+(area.Height+originalMargin.Top-originalMargin.Bottom)/2,
            };
            double offset=images[0].Y+images[0].Height/2-naturalCenter;
            if(double.IsFinite(offset))
            {
                var target=new Thickness(originalMargin.Left,originalMargin.Top+offset,originalMargin.Right,originalMargin.Bottom-offset);
                if(button.Margin!=target)button.Margin=target;
            }
        }
    }
    internal static void Arrows(FrameworkElement view)
    {Discoveries.GetValue(view,v=>new ContentDiscovery(v));PaintArrows(view);}
    static void PaintArrows(FrameworkElement view)
    {
        foreach(var button in UiElements.Descendants(view).OfType<Button>())
        {
            if(DesktopCardSurface.Owns(button))continue;
            string name=button.Name;string label=Microsoft.UI.Xaml.Automation.AutomationProperties.GetName(button);
            bool? direction=name is "HomeRowPreviousButton"?false:name is "HomeRowNextButton"?true:label=="上一组"?false:label=="下一组"?true:button.Content is string text&&text=="‹"?false:button.Content is string text2&&text2=="›"?true:null;
            if(direction==null&&VisualTreeHelper.GetParent(button) is Grid row&&row.Children.OfType<ScrollViewer>().FirstOrDefault(s=>s.VerticalScrollBarVisibility==ScrollBarVisibility.Disabled) is {} strip)
            {
                if(button.Content is FontIcon arrow&&arrow.Glyph is "\uE76B" or "\uE76C" or "\uE0E2" or "\uE0E3")direction=Grid.GetColumn(button)>Grid.GetColumn(strip);
            }
            if(direction is {} right)Arrow(button,right);
        }
    }
}
