using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Markup;
using System.Runtime.CompilerServices;

namespace Yingyu.Update;

// A template instance is prepared before its first render, independently of
// image completion, page discovery, and dispatcher queue availability.
public static class HomeRowPresentation
{
    static readonly ConditionalWeakTable<FrameworkElement, object> Roots=new();
    static readonly ConditionalWeakTable<GridView, object> Panels=new();
    public static void Connect(object page, int connectionId, object target)
    {
        if(target is Button button && connectionId is 14 or 251 or 252 or 254)
        {
            if(Roots.TryGetValue(button,out _))return;Roots.Add(button,new());
            button.Loaded+=(_,_)=>{
                if(connectionId is 14 or 251)DesktopRefinement.Heading(button,ReferenceSurfaces.Palette(button),true);
                else DesktopReadability.Arrow(button,connectionId==254);
            };
            return;
        }
        if(connectionId!=13 || target is not StackPanel root || Roots.TryGetValue(root,out _))return;
        Roots.Add(root,new());
        root.Loaded+=(_,_)=>Prepare(page,root);
    }
    static void Prepare(object page,StackPanel root)
    {
        var nodes=UiElements.Descendants(root).ToArray();
        foreach(var heading in root.Children.OfType<Button>().ToArray())
            DesktopRefinement.Heading(heading,ReferenceSurfaces.Palette(root));
        foreach(var grid in nodes.OfType<GridView>())
        {
            if(Panels.TryGetValue(grid,out _))continue;Panels.Add(grid,new());
            grid.ItemsPanel=(ItemsPanelTemplate)XamlReader.Load("<ItemsPanelTemplate xmlns=\"http://schemas.microsoft.com/winfx/2006/xaml/presentation\"><StackPanel Orientation=\"Horizontal\"/></ItemsPanelTemplate>");
        }
        foreach(var card in nodes.OfType<Grid>().Where(g=>g.Name=="PosterCardRoot"))DesktopTheme.Card(page,card);
        DesktopReadability.Arrows(root);
    }
}
