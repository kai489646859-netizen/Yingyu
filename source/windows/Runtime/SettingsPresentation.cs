using System.Runtime.CompilerServices;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Markup;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Data;

namespace Yingyu.Update;

// Keep each existing control instance, binding, Header and event handler.
internal static class SettingsPresentation
{
    static readonly ConditionalWeakTable<FrameworkElement,object> Wrapped=new();
    static readonly DataTemplate HiddenHeader=(DataTemplate)XamlReader.Load("<DataTemplate xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation'><Grid Visibility='Collapsed'/></DataTemplate>");
    internal static void Apply(FrameworkElement page)
    {
        var p=ReferenceSurfaces.Palette(page);
        if(Access.Get<object?>(page,"AlphabeticalLibraryNavigationToggle") is ToggleSwitch alphabetical){
            alphabetical.Visibility=Visibility.Collapsed;
            for(var parent=VisualTreeHelper.GetParent(alphabetical);parent!=null;parent=VisualTreeHelper.GetParent(parent))
                if(parent is Border{Name:"SettingsRowSurface"} card){card.Visibility=Visibility.Collapsed;break;}
        }
        AboutPresentation.Apply(page,p);
        foreach(var name in new[]{"AccountSettingsSection","AppearanceSettingsSection","ExperienceSettingsSection","CacheSettingsSection","DiagnosticsSettingsSection","AboutSettingsSection"})
        {
            if(Access.Get<object?>(page,name) is not Border section)continue;
            section.Background=DesktopVisuals.Brush(0);section.BorderThickness=new(0);section.Padding=new(0);section.CornerRadius=new(0);
            foreach(var panel in UiElements.Descendants(section).OfType<Panel>().ToArray())
            {
                if(InControl(panel,section))continue;
                foreach(var child in panel.Children.OfType<FrameworkElement>().ToArray())
                {
                    if(child.Visibility==Visibility.Collapsed||Wrapped.TryGetValue(child,out _))continue;
                    FrameworkElement? row=null;
                    if(child is Grid grid&&grid.Children.Any(IsEditor)&&grid.Children.Any(c=>c is TextBlock or StackPanel)){
                        row=child;var editor=grid.Children.OfType<FrameworkElement>().First(IsEditor);int column=Grid.GetColumn(editor);
                        if(grid.ColumnDefinitions.Count==2&&Grid.GetColumnSpan(editor)==1){grid.ColumnDefinitions[column].Width=new(230);grid.ColumnDefinitions[1-column].Width=new(1,GridUnitType.Star);grid.ColumnSpacing=20;editor.HorizontalAlignment=HorizontalAlignment.Stretch;grid.SizeChanged+=(_,e)=>{bool narrow=e.NewSize.Width<480;grid.RowSpacing=narrow?8:0;editor.HorizontalAlignment=narrow?HorizontalAlignment.Left:HorizontalAlignment.Right;grid.ColumnDefinitions[1-column].Width=new(1,GridUnitType.Star);grid.ColumnDefinitions[column].Width=new(narrow?0:230);Grid.SetColumn(editor,narrow?1-column:column);Grid.SetRow(editor,narrow?1:0);if(narrow&&grid.RowDefinitions.Count<2){grid.RowDefinitions.Add(new(){Height=GridLength.Auto});grid.RowDefinitions.Add(new(){Height=GridLength.Auto});}};}
                    }
                    else if(child is StackPanel block&&block.Children.Count>1&&block.Children.Count(c=>c is ComboBox or NumberBox or Slider)==1&&block.Children.All(c=>c is TextBlock or ComboBox or NumberBox or Slider))
                    {
                        var editor=block.Children.OfType<Control>().Single();var labels=block.Children.OfType<TextBlock>().ToArray();
                        if(editor.Visibility==Visibility.Collapsed)continue;
                        block.Children.Clear();var layout=new Grid{ColumnSpacing=20,RowSpacing=0};layout.ColumnDefinitions.Add(new(){Width=new(1,GridUnitType.Star)});layout.ColumnDefinitions.Add(new(){Width=new(230)});layout.RowDefinitions.Add(new(){Height=GridLength.Auto});layout.RowDefinitions.Add(new(){Height=GridLength.Auto});
                        var text=new StackPanel{Spacing=4,VerticalAlignment=VerticalAlignment.Center};foreach(var label in labels){label.TextWrapping=TextWrapping.Wrap;text.Children.Add(label);}layout.Children.Add(text);Grid.SetColumn(editor,1);editor.VerticalAlignment=VerticalAlignment.Center;layout.Children.Add(editor);block.Children.Add(layout);
                        layout.SizeChanged+=(_,e)=>{bool narrow=e.NewSize.Width<500;layout.RowSpacing=narrow?8:0;layout.ColumnDefinitions[1].Width=new(narrow?0:230);Grid.SetColumn(editor,narrow?0:1);Grid.SetRow(editor,narrow?1:0);};row=block;
                    }
                    else if(child is ToggleSwitch toggle&&toggle.Header is {} headerValue)
                    {
                        var layout=new Grid{Name="SettingsToggleRow",ColumnSpacing=20,RowSpacing=0};
                        layout.ColumnDefinitions.Add(new(){Width=new(1,GridUnitType.Star)});layout.ColumnDefinitions.Add(new(){Width=GridLength.Auto});
                        layout.RowDefinitions.Add(new(){Height=GridLength.Auto});layout.RowDefinitions.Add(new(){Height=GridLength.Auto});
                        var text=new StackPanel{Spacing=4,VerticalAlignment=VerticalAlignment.Center};
                        var headers=headerValue is DependencyObject node?HeaderTexts(node).ToArray():[];
                        if(headers.Any(t=>t.Inlines.OfType<Microsoft.UI.Xaml.Documents.Hyperlink>().Any()))continue;
                        if(headers.Length==0)text.Children.Add(new TextBlock{Text=headerValue.ToString(),FontSize=15,TextWrapping=TextWrapping.Wrap});
                        else foreach(var original in headers){var label=new TextBlock{FontSize=Math.Clamp(original.FontSize,12,15),FontWeight=original.FontWeight,TextWrapping=TextWrapping.Wrap};label.SetBinding(TextBlock.TextProperty,new Binding{Source=original,Path=new("Text"),Mode=BindingMode.OneWay});text.Children.Add(label);}
                        layout.Children.Add(text);
                        int at=panel.Children.IndexOf(toggle);panel.Children.RemoveAt(at);panel.Children.Insert(at,layout);toggle.HeaderTemplate=HiddenHeader;toggle.Loaded+=(_,_)=>HideHeader(toggle);HideHeader(toggle);toggle.Height=double.NaN;toggle.MinHeight=32;toggle.MinWidth=0;toggle.Margin=new(0);toggle.Padding=new(0);toggle.VerticalAlignment=VerticalAlignment.Center;Grid.SetColumn(toggle,1);layout.Children.Add(toggle);
                        layout.SizeChanged+=(_,e)=>{bool narrow=e.NewSize.Width<480;layout.RowSpacing=narrow?8:0;Grid.SetColumn(toggle,narrow?0:1);Grid.SetRow(toggle,narrow?1:0);toggle.HorizontalAlignment=narrow?HorizontalAlignment.Left:HorizontalAlignment.Right;};
                        row=layout;
                    }
                    if(row==null)continue;
                    row.Margin=new(0);row.MinHeight=0;row.Height=double.NaN;if(row is Grid rowGrid)rowGrid.Padding=new(0);
                    foreach(var editor in UiElements.Descendants(row).OfType<Control>().Where(c=>c is ComboBox or NumberBox or TextBox or PasswordBox)){editor.Height=editor is TextBox or PasswordBox?double.NaN:32;editor.MinHeight=editor is TextBox or PasswordBox?36:32;if(editor is TextBox or PasswordBox){editor.Width=double.NaN;editor.Padding=new(10,6,10,6);}editor.Margin=new(0);editor.MaxWidth=230;editor.MinWidth=0;editor.HorizontalAlignment=HorizontalAlignment.Right;}
                    foreach(var toggle in UiElements.Descendants(row).OfType<ToggleSwitch>().Where(t=>t.Header==null||ReferenceEquals(t.HeaderTemplate,HiddenHeader))){toggle.Height=double.NaN;toggle.MinHeight=32;toggle.MinWidth=0;toggle.HorizontalAlignment=HorizontalAlignment.Right;toggle.Margin=new(0);toggle.Padding=new(0);HideHeader(toggle);}
                    Own(row);
                    int index=panel.Children.IndexOf(row);panel.Children.RemoveAt(index);
                    int rowIndex=Grid.GetRow(row),columnIndex=Grid.GetColumn(row),rowSpan=Grid.GetRowSpan(row),columnSpan=Grid.GetColumnSpan(row);Grid.SetRow(row,0);Grid.SetRowSpan(row,1);Grid.SetColumnSpan(row,1);
                    var frame=new Grid{Name="SettingsCardLayout",ColumnSpacing=18};frame.ColumnDefinitions.Add(new(){Width=new(28)});frame.ColumnDefinitions.Add(new(){Width=new(1,GridUnitType.Star)});
                    var icon=new FontIcon{Name="SettingsCardIcon",Glyph=Glyph(Labels(row)),FontSize=21,VerticalAlignment=VerticalAlignment.Center};frame.Children.Add(icon);Grid.SetColumn(row,1);frame.Children.Add(row);
                    var card=new Border{Name="SettingsRowSurface",Child=frame,Padding=new(16,10,16,10),MinHeight=56,CornerRadius=new(10),BorderThickness=new(1),HorizontalAlignment=HorizontalAlignment.Stretch};
                    card.SetBinding(UIElement.VisibilityProperty,new Binding{Source=row,Path=new("Visibility"),Mode=BindingMode.OneWay});
                    Grid.SetRow(card,rowIndex);Grid.SetColumn(card,columnIndex);Grid.SetRowSpan(card,rowSpan);Grid.SetColumnSpan(card,columnSpan);
                    panel.Children.Insert(index,card);
                }
            }
            foreach(var card in UiElements.Descendants(section).OfType<Border>().Where(b=>b.Name=="SettingsRowSurface"))
            {
                if(card.Parent is Grid parent&&parent.RowDefinitions.Count>0){parent.RowSpacing=0;card.Margin=new(0,0,0,14);}
                foreach(var toggle in UiElements.Descendants(card).OfType<ToggleSwitch>().Where(t=>t.Header==null||ReferenceEquals(t.HeaderTemplate,HiddenHeader)))HideHeader(toggle);
                card.Background=DesktopVisuals.Brush(p.Surface);card.BorderBrush=DesktopVisuals.Brush(p.Outline);
                foreach(var icon in UiElements.Descendants(card).OfType<FontIcon>().Where(i=>i.Name=="SettingsCardIcon"))icon.Foreground=DesktopVisuals.Brush(p.Accent);
                foreach(var text in UiElements.Descendants(card).OfType<TextBlock>().Where(t=>!WithinEditor(t,card)))text.Foreground=DesktopVisuals.Brush(p.Text);
            }
        }
    }
    static bool WithinEditor(DependencyObject node,DependencyObject boundary){
        for(var parent=VisualTreeHelper.GetParent(node);parent!=null&&!ReferenceEquals(parent,boundary);parent=VisualTreeHelper.GetParent(parent))
            if(parent is ComboBox or TextBox or PasswordBox or NumberBox or Slider or ToggleSwitch or Button)return true;
        return false;
    }
    static void HideHeader(ToggleSwitch toggle){
        toggle.ApplyTemplate();foreach(var header in UiElements.Descendants(toggle).OfType<ContentPresenter>().Where(p=>p.Name=="HeaderContentPresenter"))header.Visibility=Visibility.Collapsed;
        // The retained WinUI template has fixed 10-DIP top/bottom switch gutters.
        // Compact only that recognized template; keep its states and hit targets.
        foreach(var grid in UiElements.Descendants(toggle).OfType<Grid>().Where(g=>g.RowDefinitions.Count==3&&g.RowDefinitions[0].Height.IsAbsolute&&g.RowDefinitions[2].Height.IsAbsolute&&g.RowDefinitions[0].Height.Value==10&&g.RowDefinitions[2].Height.Value==10&&UiElements.Descendants(g).OfType<FrameworkElement>().Any(e=>e.Name=="SwitchKnobBounds"))){grid.RowDefinitions[0].Height=new(6);grid.RowDefinitions[2].Height=new(6);}
    }
    static void Own(FrameworkElement element)
    {
        Wrapped.GetValue(element,_=>new object());
        if(element is Panel panel)foreach(var child in panel.Children.OfType<FrameworkElement>())Own(child);
        else if(element is Border{Child:FrameworkElement child})Own(child);
    }
    static bool IsEditor(UIElement element)=>element is ComboBox or NumberBox or Slider or ToggleSwitch or TextBox or PasswordBox || element is Button b&&b.Name.StartsWith("ShortcutCapture",StringComparison.Ordinal);
    static IEnumerable<TextBlock> HeaderTexts(DependencyObject node)
    {
        if(node is TextBlock text)yield return text;
        else if(node is Panel panel)foreach(var child in panel.Children)foreach(var label in HeaderTexts(child))yield return label;
        else if(node is Border{Child:{} child})foreach(var label in HeaderTexts(child))yield return label;
    }
    static string Labels(DependencyObject node)=>node switch
    {
        TextBlock text=>text.Text,
        Panel panel=>string.Join(" ",panel.Children.Select(Labels)),
        Border border when border.Child!=null=>Labels(border.Child),
        _=>""
    };
    static string Glyph(string label)=>label.Contains("主题")||label.Contains("配色")?"\uE790":label.Contains("音")?"\uE767":label.Contains("字幕")?"\uE8D2":label.Contains("缓存")?"\uE8B7":label.Contains("窗口")?"\uE737":label.Contains("播放")||label.Contains("倍速")?"\uE714":"\uE713";
    static bool InControl(DependencyObject element,DependencyObject boundary)
    {
        for(DependencyObject? n=element;n!=null&&!ReferenceEquals(n,boundary);n=(n as FrameworkElement)?.Parent??VisualTreeHelper.GetParent(n))
        {
            if(n is FrameworkElement fe&&(Wrapped.TryGetValue(fe,out _)||fe.Name is "SettingsRowSurface" or "SettingsCardLayout"))return true;
            if(!ReferenceEquals(n,element)&&n is Control)return true;
        }
        return false;
    }
}
