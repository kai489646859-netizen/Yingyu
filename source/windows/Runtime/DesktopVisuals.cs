using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Markup;
using Microsoft.UI.Xaml.Media;
using Windows.UI;

namespace Yingyu.Update;

// Local visual changes only. Existing buttons, commands, bindings and flyouts
// retain their identity; neither input nor the video surface is intercepted.
internal static class DesktopVisuals
{
    static ControlTemplate? actionTemplate;
    internal static SolidColorBrush Brush(uint c) => new(Color.FromArgb((byte)(c>>24),(byte)(c>>16),(byte)(c>>8),(byte)c));
    internal const string ActionXaml = """
        <ControlTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" TargetType="Button">
          <Grid x:Name="Root">
            <VisualStateManager.VisualStateGroups><VisualStateGroup x:Name="CommonStates">
              <VisualState x:Name="Normal" />
              <VisualState x:Name="PointerOver"><VisualState.Setters><Setter Target="Interaction.Opacity" Value="0.09" /></VisualState.Setters></VisualState>
              <VisualState x:Name="Pressed"><VisualState.Setters><Setter Target="Interaction.Opacity" Value="0.16" /></VisualState.Setters></VisualState>
              <VisualState x:Name="Disabled"><VisualState.Setters><Setter Target="Root.Opacity" Value="0.45" /></VisualState.Setters></VisualState>
            </VisualStateGroup></VisualStateManager.VisualStateGroups>
            <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="{TemplateBinding CornerRadius}" />
            <Border x:Name="Interaction" Background="{TemplateBinding Foreground}" CornerRadius="{TemplateBinding CornerRadius}" Opacity="0" IsHitTestVisible="False" />
            <ContentPresenter Content="{TemplateBinding Content}" ContentTemplate="{TemplateBinding ContentTemplate}" ContentTransitions="{TemplateBinding ContentTransitions}" Padding="{TemplateBinding Padding}" HorizontalContentAlignment="{TemplateBinding HorizontalContentAlignment}" VerticalContentAlignment="{TemplateBinding VerticalContentAlignment}" Foreground="{TemplateBinding Foreground}" />
          </Grid>
        </ControlTemplate>
        """;
    internal static void Action(Button button,DesktopThemePalette palette,bool primary,bool icon,bool dark)
    {
        button.Template=actionTemplate??=(ControlTemplate)XamlReader.Load(ActionXaml);
        button.Height=44;button.MinHeight=44;button.MaxHeight=double.PositiveInfinity;
        button.Width=icon?44:double.NaN;button.MinWidth=icon?44:116;button.MaxWidth=double.PositiveInfinity;
        button.Padding=icon?new Thickness(0):new Thickness(18,10,18,10);
        button.HorizontalContentAlignment=HorizontalAlignment.Center;button.VerticalContentAlignment=VerticalAlignment.Center;
        button.Background=Brush(primary?palette.Accent:palette.Surface);
        uint foreground=primary?(dark?palette.Background:0xFFFFFFFF):palette.Text;
        button.Foreground=Brush(foreground);button.BorderBrush=Brush(primary?palette.Accent:palette.Outline);button.BorderThickness=new Thickness(1);
        button.UseSystemFocusVisuals=true;
        if(button.Content is FrameworkElement content)
        {content.Width=double.NaN;content.Height=double.NaN;content.MinWidth=0;content.MaxWidth=double.PositiveInfinity;content.Margin=new Thickness(0);}
        var contentElements = button.Content is DependencyObject contentRoot ? Logical(contentRoot).Concat(UiElements.Descendants(button)).Distinct().ToArray() : UiElements.Descendants(button).ToArray();
        foreach(var text in contentElements.OfType<TextBlock>())text.Foreground=Brush(foreground);
        foreach(var glyph in contentElements.OfType<FontIcon>())
        {glyph.Foreground=Brush(foreground);glyph.Width=double.NaN;glyph.Height=double.NaN;glyph.Margin=new Thickness(0);if(icon)glyph.FontSize=20;}
    }
    static IEnumerable<DependencyObject> Logical(DependencyObject root)
    {
        yield return root;
        IEnumerable<DependencyObject> children=root switch { Panel p=>p.Children, Border b when b.Child!=null=>new[]{b.Child}, ContentControl c when c.Content is DependencyObject d=>new[]{d}, _=>Array.Empty<DependencyObject>() };
        foreach(var child in children)foreach(var nested in Logical(child))yield return nested;
    }
    internal static void Artwork(FrameworkElement element)
    {
        foreach(var surface in new[]{element}.Concat(UiElements.Descendants(element)).OfType<Border>()
            .Where(b=>b.Name is "PosterArtworkSurface" or "ResumeArtworkSurface" or "CollectionArtworkSurface"))
        {
            surface.Width=double.NaN;surface.Height=double.NaN;surface.MaxWidth=double.PositiveInfinity;
            surface.HorizontalAlignment=HorizontalAlignment.Stretch;surface.VerticalAlignment=VerticalAlignment.Stretch;
            foreach(var image in UiElements.Descendants(surface).OfType<Image>())
            {image.Stretch=Stretch.Uniform;image.Width=double.NaN;image.Height=double.NaN;image.MaxWidth=double.PositiveInfinity;image.HorizontalAlignment=HorizontalAlignment.Stretch;image.VerticalAlignment=VerticalAlignment.Stretch;}
        }
        // Existing progress binding and accessible value remain native. Reduce
        // the old heavy bottom panel to an inset track with rounded endpoints.
        foreach(var progress in UiElements.Descendants(element).OfType<ProgressBar>())
        {
            progress.Height=4;progress.MinHeight=4;progress.MaxHeight=4;
            progress.Margin=new Thickness(10,0,10,10);progress.CornerRadius=new CornerRadius(2);
            progress.VerticalAlignment=VerticalAlignment.Bottom;progress.IsHitTestVisible=false;
            progress.Foreground=Brush(0xFFF5F5FA);progress.Background=Brush(0x66000000);
            progress.Resources["ProgressBarTrackFill"]=progress.Background;
            progress.Resources["ProgressBarIndicatorFill"]=progress.Foreground;
            if(VisualTreeHelper.GetParent(progress) is Border parent)
            {parent.Background=Brush(0x00000000);parent.BorderThickness=new Thickness(0);parent.Padding=new Thickness(0);parent.MinHeight=0;parent.Height=double.NaN;}
            else if(VisualTreeHelper.GetParent(progress) is Grid { Children.Count: 1 } panel)
            {panel.Background=Brush(0x00000000);panel.MinHeight=0;panel.Height=double.NaN;}
        }
    }
}
