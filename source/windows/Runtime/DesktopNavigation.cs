using System.Runtime.CompilerServices;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Markup;
namespace Yingyu.Update;
public static class DesktopNavigation
{
    static ControlTemplate? alphabetTemplate;
    internal static bool Owns(Button button)=>alphabetTemplate!=null&&ReferenceEquals(button.Template,alphabetTemplate);
    const string AlphabetXaml="""
        <ControlTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" TargetType="Button">
          <Grid x:Name="Root">
            <VisualStateManager.VisualStateGroups><VisualStateGroup x:Name="CommonStates">
              <VisualState x:Name="Normal" />
              <VisualState x:Name="PointerOver"><VisualState.Setters><Setter Target="Hover.Opacity" Value="0.09" /></VisualState.Setters></VisualState>
              <VisualState x:Name="Pressed"><VisualState.Setters><Setter Target="Hover.Opacity" Value="0.16" /></VisualState.Setters></VisualState>
              <VisualState x:Name="Disabled"><VisualState.Setters><Setter Target="Root.Opacity" Value="0.45" /></VisualState.Setters></VisualState>
            </VisualStateGroup></VisualStateManager.VisualStateGroups>
            <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="{TemplateBinding CornerRadius}" />
            <Border x:Name="Hover" Background="{TemplateBinding Foreground}" CornerRadius="{TemplateBinding CornerRadius}" Opacity="0" IsHitTestVisible="False" />
            <ContentPresenter Content="{TemplateBinding Content}" Foreground="{TemplateBinding Foreground}" HorizontalContentAlignment="Center" VerticalContentAlignment="Center" />
          </Grid>
        </ControlTemplate>
        """;
    static readonly ConditionalWeakTable<object,State> States=new();
    public static string? Current(IEnumerable<KeyValuePair<string,int>> sections,int index)
        =>InteractionPolicy.Current(sections,index);
    internal static GridView BrowseGrid(object page)=>Access.Get<GridView>(page,"LatestGrid");
    internal static (int Columns,double Height) Metrics(object page)
    {
        var metrics=Access.Get<object>(page,"_posterGridMetrics");
        return (Math.Max(1,(int)metrics.GetType().GetProperty("ColumnCount")!.GetValue(metrics)!),Math.Max(1,(double)metrics.GetType().GetProperty("ItemHeight")!.GetValue(metrics)!));
    }
    internal static double RowOffset(object page,ScrollViewer scroll,int index)
    {
        var grid=BrowseGrid(page);var metrics=Metrics(page);double origin=0;
        if(grid.ContainerFromIndex(index) is FrameworkElement target&&target.IsLoaded)
            return Math.Max(0,scroll.VerticalOffset+target.TransformToVisual(scroll).TransformPoint(new(0,0)).Y-scroll.Padding.Top);
        if(grid.ItemsPanelRoot is {} panel)
            foreach(var cell in panel.Children.OfType<GridViewItem>().Where(c=>c.IsLoaded&&c.ActualHeight>0))
            {
                int at=grid.IndexFromContainer(cell);if(at<0)continue;
                origin=scroll.VerticalOffset+cell.TransformToVisual(scroll).TransformPoint(new(0,0)).Y-scroll.Padding.Top-(at/metrics.Columns)*metrics.Height;break;
            }
        return Math.Max(0,origin+(index/metrics.Columns)*metrics.Height);
    }
    public static void Jump(object page,object? sender)
    {
        try
        {
            if(sender is not Button{IsEnabled:true,Content:string key})return;
            var indices=Access.Get<Dictionary<string,int>>(page,"_alphabetNavigationIndices");var grid=BrowseGrid(page);
            if(!indices.TryGetValue(key,out int index)||index<0||index>=grid.Items.Count)return;
            var scroll=Access.Get<ScrollViewer?>(page,"_browseResultsScrollViewer")??UiElements.Descendants(grid).OfType<ScrollViewer>().FirstOrDefault();
            if(scroll==null||scroll.ViewportHeight<=0)return;
            DesktopScroll.Jump(page,scroll,index,key);
        }
        catch(Exception e){try{PlaybackTransport.Write("Warning","Navigation.Alphabet","字母定位未完成；"+e.GetType().Name);}catch(Exception){}}
    }
    internal static void Commit(object page,string? letter,int index,double offset)
    {var state=States.GetValue(page,p=>new(p));state.pinned=letter;state.pinnedIndex=index;state.pinnedOffset=offset;state.pinnedScope=Access.Get<string?>(page,"_activeSnapshotKey");state.pinnedSession=Access.Get<object?>(page,"_session");state.Update();}
    public static void Update(object page)
    {
        try{if(!DesktopScroll.IsAnimating(page))States.GetValue(page,p=>new State(p)).Update();}
        catch(Exception e){try{PlaybackTransport.Write("Warning","Navigation.Alphabet","索引反馈未更新；"+e.GetType().Name);}catch(Exception){}}
    }
    sealed class State(object page)
    {
        readonly HashSet<Button> attached=new(),hovered=new();
        readonly Dictionary<Button,(SolidColorBrush Text,SolidColorBrush Background,SolidColorBrush Border)> brushes=new();
        string? current;DesktopThemePalette palette;bool initialized;Button? tools;
        internal string? pinned;internal int pinnedIndex;internal double pinnedOffset;
        internal string? pinnedScope;internal object? pinnedSession;
        public void Update()
        {
            if(page is not FrameworkElement element)return;
            if(element.FindName("CollectionNavButton") is UIElement collection)collection.Visibility=Visibility.Collapsed;
            if(tools==null&&element.FindName("ShellGrid") is Grid shell)
                tools=shell.Children.OfType<FrameworkElement>().Where(e=>Grid.GetColumn(e)==0).SelectMany(UiElements.Descendants).OfType<Button>().FirstOrDefault(b=>b.Content?.ToString() is "工具与清单" or "工具清单" || UiElements.Descendants(b).OfType<TextBlock>().Any(t=>t.Text is "工具与清单" or "工具清单"));
            if(tools!=null)tools.Visibility=Visibility.Collapsed;
            var buttons=Access.Get<Dictionary<string,Button>>(page,"_alphabetNavigationButtons");
            var indices=Access.Get<Dictionary<string,int>>(page,"_alphabetNavigationIndices");
            var scroll=Access.Get<ScrollViewer?>(page,"_browseResultsScrollViewer");
            var metrics=Metrics(page);int columns=metrics.Columns;double h=metrics.Height;
            int top=scroll!=null?Math.Max(0,(int)Math.Floor(scroll.VerticalOffset/h)*columns):0;
            var grid=BrowseGrid(page);
            if(scroll!=null&&grid.ItemsPanelRoot is {} panel)
            {
                var visible=panel.Children.OfType<GridViewItem>().Where(c=>c.IsLoaded&&c.ActualHeight>0)
                    .Select(c=>(Index:grid.IndexFromContainer(c),Y:c.TransformToVisual(scroll).TransformPoint(new(0,0)).Y,Height:c.ActualHeight))
                    .Where(c=>c.Index>=0&&c.Y+c.Height>1.5&&c.Y<scroll.ViewportHeight-1.5).OrderBy(c=>c.Y).ThenBy(c=>c.Index).FirstOrDefault((Index:-1,Y:0d,Height:0d));
                // A partially clipped leading row still owns the position.
                // Mixed-letter rows use the first visible item, not the last
                // column (which could already belong to the next section).
                if(visible.Index>=0)top=visible.Index;
            }
            if(scroll!=null&&scroll.VerticalOffset<=1.5)top=0;
            string? next=Current(indices,Math.Clamp(top,0,Math.Max(0,grid.Items.Count-1)));
            if(pinned!=null&&scroll!=null&&pinnedScope==Access.Get<string?>(page,"_activeSnapshotKey")&&ReferenceEquals(pinnedSession,Access.Get<object?>(page,"_session"))
                &&indices.TryGetValue(pinned,out int target)&&target==pinnedIndex&&Math.Abs(scroll.VerticalOffset-pinnedOffset)<=1.5)next=pinned;
            else pinned=null;
            var p=DesktopThemePalette.Resolve(DesktopTheme.Options,element.ActualTheme==ElementTheme.Dark);
            uint Color(string key,uint fallback)
            {
                if(!element.Resources.ContainsKey(key)||element.Resources[key] is not SolidColorBrush brush)return fallback;
                var c=brush.Color;return (uint)c.A<<24|(uint)c.R<<16|(uint)c.G<<8|c.B;
            }
            p=p with{Background=Color("AppBackgroundBrush",p.Background),Text=Color("PrimaryTextBrush",p.Text),Accent=Color("AccentBrush",p.Accent),Selection=Color("SidebarSelectionBrush",p.Selection),Hover=Color("ToolbarButtonHoverBrush",p.Hover)};
            bool repaint=!initialized||p!=palette||current!=next;palette=p;current=next;initialized=true;
            foreach(var pair in buttons)
            {
                var b=pair.Value;
                if(attached.Add(b))
                {
                    // Keep hover geometry and the template resource graph fixed.
                    // Pointer callbacks only update brushes owned by this rail.
                    b.Template=alphabetTemplate??=(ControlTemplate)XamlReader.Load(AlphabetXaml);
                    b.MinWidth=0;b.Padding=new Thickness(0);b.CornerRadius=new(6);b.BorderThickness=new Thickness(1);
                    var colors=(DesktopVisuals.Brush(p.Text),DesktopVisuals.Brush(0),DesktopVisuals.Brush(0));brushes.Add(b,colors);
                    b.Foreground=colors.Item1;b.Background=colors.Item2;b.BorderBrush=colors.Item3;
                    b.PointerEntered+=(_,_)=>Safe(()=>{hovered.Add(b);Paint(b,pair.Key);});
                    b.PointerExited+=(_,_)=>Safe(()=>{hovered.Remove(b);Paint(b,pair.Key);});
                    b.PointerCanceled+=(_,_)=>Safe(()=>{hovered.Remove(b);Paint(b,pair.Key);});
                    b.PointerCaptureLost+=(_,_)=>Safe(()=>{hovered.Remove(b);Paint(b,pair.Key);});
                    b.Unloaded+=(_,_)=>hovered.Remove(b);repaint=true;
                }
                if(repaint)Paint(b,pair.Key);
            }
        }
        void Paint(Button button,string key)
        {
            bool selected=current==key&&button.IsEnabled;
            bool hover=hovered.Contains(button)&&button.IsEnabled;
            var colors=brushes[button];
            void Color(SolidColorBrush brush,uint value){var color=Windows.UI.Color.FromArgb((byte)(value>>24),(byte)(value>>16),(byte)(value>>8),(byte)value);if(brush.Color!=color)brush.Color=color;}
            Color(colors.Text,selected?palette.Background:button.IsEnabled?palette.Accent:palette.Secondary);Color(colors.Background,selected?palette.Accent:hover?palette.Hover:0);
            Color(colors.Border,selected||hover?palette.Accent:0);
            var weight=selected?Microsoft.UI.Text.FontWeights.SemiBold:Microsoft.UI.Text.FontWeights.Normal;
            if(button.FontWeight.Weight!=weight.Weight)button.FontWeight=weight;
            string name=selected?key+"，当前位置":key;
            if(Microsoft.UI.Xaml.Automation.AutomationProperties.GetName(button)!=name)Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button,name);
        }
        static void Safe(Action action){try{action();}catch(Exception error){try{PlaybackTransport.Write("Warning","Navigation.Alphabet","索引悬停反馈未完成；"+error.GetType().Name);}catch(Exception){}}}
    }
}
