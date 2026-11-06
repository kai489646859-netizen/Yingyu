using System.Collections.Specialized;
using System.Runtime.CompilerServices;
using EmbyDesktop.Core.Models;
using EmbyDesktop.Core.Services;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace Yingyu.Update;

// Browsing never replaces the session queue. Selecting a real item uses the
// existing manual request pipeline, including its normal GetItem fallback.
public static class PlayerSeasonPanel
{
    const int VisibleRows = 10;
    const int Columns = 5;
    const double TileHeight = 44;
    const double TileSpacing = 6;
    const double RowPitch = TileHeight + TileSpacing;
    const int RangeSize = VisibleRows * Columns;

    // The original GridView measures each cell with its spacing.
    internal const double OriginalViewportHeight = VisibleRows * RowPitch;
    const double AlternateViewportHeight = OriginalViewportHeight - TileSpacing;
    const double DrawerChromeHeight = 116;

    public static void SizeDrawer(object overlay)
    {
        var drawer = Access.Get<Border>(overlay, "EpisodeDrawer");
        if (drawer == null) return;
        double windowHeight = ((FrameworkElement)overlay).ActualHeight;
        const double preferredHeight = OriginalViewportHeight + DrawerChromeHeight;
        double height = windowHeight > 0 ? Math.Clamp(windowHeight - 84, 120, preferredHeight) : preferredHeight;
        drawer.MinHeight = 0;
        drawer.MaxHeight = height;
        drawer.Height = height;
    }

    public static IReadOnlyList<EpisodeRange> CreateRanges(int count)
        => EpisodeRangePolicy.Create(count, RangeSize);

    static int VisibleRange(ScrollViewer viewer, int firstVisible, int count)
    {
        // The final range can be shorter than a viewport. At the end of the
        // list its first row may never reach the top edge.
        if (viewer.ScrollableHeight > 0 && viewer.ScrollableHeight - viewer.VerticalOffset < 0.5)
            return (count - 1) / RangeSize;
        return firstVisible / RangeSize;
    }

    static void DisplayRange(ComboBox combo, string label)
    {
        if (combo.PlaceholderText != label) combo.PlaceholderText = label;
    }

    static readonly ConditionalWeakTable<object,Owner> Owners=new();

    // These hooks retain the original current-season grid, including preview,
    // item click handling and its XAML bindings.
    public static EpisodeRange VisibleEpisodes(int count, EpisodeRange selected)
        => count > RangeSize ? new EpisodeRange(0, count) : EpisodeRangePolicy.ResolveVisibleRange(count, selected);

    public static bool NavigateOriginalRange(object overlay)
    {
        if (Access.Get<bool>(overlay, "_settingEpisodeRange")) return true;
        var grid = Access.Get<GridView>(overlay, "EpisodeGrid");
        if (grid.Items.Count <= RangeSize) return false;
        if (Access.Get<ComboBox>(overlay, "EpisodeRangeCombo").SelectedIndex >= 0)
        {
            Access.Call(overlay, "ClearEpisodePreview", false);
            JumpOriginal(overlay);
        }
        return true;
    }

    static void JumpOriginal(object overlay)
    {
        var grid = Access.Get<GridView>(overlay, "EpisodeGrid");
        var combo = Access.Get<ComboBox>(overlay, "EpisodeRangeCombo");
        if (grid.Items.Count <= RangeSize || combo.SelectedItem is not { } range) return;
        int start = combo.SelectedIndex * RangeSize;
        if (start >= grid.Items.Count) return;
        grid.ScrollIntoView(grid.Items[start], ScrollIntoViewAlignment.Leading);
        // Keep the last range label and allow choosing that range again.
        DisplayRange(combo, (string)Access.Call(range, "get_Label")!);
        combo.SelectedIndex = -1;
    }
    sealed class Owner { internal object? Session; }

    public static Windows.UI.Color EpisodeColor(bool playing)
        => DesktopMaterial.Color(playing
            ? DesktopThemePalette.Resolve(DesktopTheme.Options, false).Accent : 0x34FFFFFF);

    public static bool CanPickOriginal(object overlay, ItemClickEventArgs args)
        => args.ClickedItem is {} episode
            && CanPick(overlay, Access.Call(episode, "get_ItemId") as string);

    static bool CanPick(object overlay, string? id)
    {
        if (string.IsNullOrWhiteSpace(id) || !Owners.TryGetValue(overlay, out var owner)
            || owner.Session is not {} session) return false;
        return !Same(id, Access.Get<EmbyItem>(session, "_item").Id)
            && !Access.Get<bool>(session, "_switching") && !Access.Get<bool>(session, "_manualSwitchPending")
            && session.GetType().GetProperty("CanSwitch")?.GetValue(session) is true;
    }
    internal static void Bind(object session,object overlay)
    {
        Owners.GetValue(overlay,key=>{
            var button=Access.Get<Button>(key,"EpisodeDrawerButton");
            button.RegisterPropertyChangedCallback(UIElement.VisibilityProperty,(_,_)=>{
                if(button.Visibility==Visibility.Collapsed)button.DispatcherQueue.TryEnqueue(()=>OfferSingleEpisode(key));
            });
            return new Owner();
        }).Session=session;
        if(overlay is FrameworkElement element)element.DispatcherQueue.TryEnqueue(()=>OfferSingleEpisode(overlay));
    }
    internal static void Ready(object session)
    {
        if(Access.Get<object?>(session,"_overlay") is FrameworkElement element)
            element.DispatcherQueue.TryEnqueue(()=>OfferSingleEpisode(element));
    }
    static void OfferSingleEpisode(object overlay)
    {
        if(overlay is not FrameworkElement {IsLoaded:true}||!Owners.TryGetValue(overlay,out var owner)||owner.Session is not {} session)return;
        if(ReferenceEquals(overlay,Access.Get<object?>(session,"_overlay"))&&Access.Get<bool>(session,"_hasStartedPlayback")&&!NativeDolby.IsClosing(session)
            &&Access.Get<System.Collections.IDictionary>(overlay,"_compactVisibility").Count==0
            &&Access.Get<EmbyItem>(session,"_item") is {Type:"Episode",SeriesId.Length:>0})
            Access.Get<Button>(overlay,"EpisodeDrawerButton").Visibility=Visibility.Visible;
    }
    internal static void Attach(object overlay,Border drawer,Flyout flyout)
    {
        if(drawer.Child is not FrameworkElement original)return;
        try{_=new View(overlay,drawer,original,flyout);}
        catch(Exception e){PlaybackTransport.Write("Warning","Playback.Menu","季度栏未能显示；"+e.GetType().Name);}
    }
    static bool Same(string? a,string? b)=>string.Equals(a,b,StringComparison.OrdinalIgnoreCase);
    sealed class View
    {
        readonly object overlay;readonly Border drawer;readonly FrameworkElement original;
        readonly Flyout flyout;
        readonly INotifyCollectionChanged originalEpisodes;
        bool currentJumpQueued;
        readonly StackPanel tabs=new(){Orientation=Orientation.Horizontal,Spacing=8};
        readonly Grid layout=new(){RowSpacing=8,RequestedTheme=ElementTheme.Dark};
        readonly TextBlock note=new(){FontSize=12,Foreground=DesktopVisuals.Brush(0xFFBEBEC1),TextWrapping=TextWrapping.Wrap,Visibility=Visibility.Collapsed};
        readonly Grid alternatives=new(){RowSpacing=8,Visibility=Visibility.Collapsed};
        readonly ComboBox ranges=new(){MinWidth=0,MaxWidth=128,HorizontalAlignment=HorizontalAlignment.Right};
        readonly ScrollViewer scrolling,seasonStrip;
        readonly GridView originalGrid;
        readonly ComboBox originalRanges;
        ScrollViewer? originalScrolling;
        EmbyItem[] shown=[],gridItems=[];
        IReadOnlyList<EmbyItem>? currentQueue;
        int currentQueueCount;
        Grid? episodeTiles;
        string? tilesPlayingId;
        bool settingRanges;
        CancellationTokenSource? pending;
        EmbyItem[] seasons=[];
        readonly Dictionary<string,EmbyItem[]> episodes=new(StringComparer.OrdinalIgnoreCase);
        object? session;EmbyApiClient? client;EmbyItem? current;
        string? user,credential,chosen;
        int generation, rangeJump, seasonJump;
        bool catalogLoaded;
        internal View(object overlay,Border drawer,FrameworkElement original,Flyout flyout)
        {
            this.overlay=overlay;this.drawer=drawer;this.original=original;this.flyout=flyout;
            originalEpisodes=(INotifyCollectionChanged)Access.Call(overlay,"get_Episodes")!;
            originalGrid=Access.Get<GridView>(overlay,"EpisodeGrid");
            originalRanges=Access.Get<ComboBox>(overlay,"EpisodeRangeCombo");
            layout.RowDefinitions.Add(new(){Height=GridLength.Auto});layout.RowDefinitions.Add(new(){Height=GridLength.Auto});layout.RowDefinitions.Add(new(){Height=new(1,GridUnitType.Star)});
            // WinUI overlays its expanded horizontal bar on the content edge.
            seasonStrip=new ScrollViewer{Content=new Border{Child=tabs,Padding=new(0,0,0,18)},HorizontalScrollMode=ScrollMode.Enabled,HorizontalScrollBarVisibility=ScrollBarVisibility.Auto,VerticalScrollMode=ScrollMode.Disabled,VerticalScrollBarVisibility=ScrollBarVisibility.Disabled};
            layout.Children.Add(seasonStrip);Grid.SetRow(note,1);layout.Children.Add(note);
            alternatives.RowDefinitions.Add(new(){Height=GridLength.Auto});
            alternatives.RowDefinitions.Add(new(){Height=new(1,GridUnitType.Star)});
            var header=new Grid{ColumnSpacing=8};
            header.ColumnDefinitions.Add(new(){Width=new(1,GridUnitType.Star)});
            header.ColumnDefinitions.Add(new(){Width=GridLength.Auto});header.ColumnDefinitions.Add(new(){Width=GridLength.Auto});
            header.Children.Add(new TextBlock{Text="选集",FontSize=17,VerticalAlignment=VerticalAlignment.Center});
            Grid.SetColumn(ranges,1);header.Children.Add(ranges);
            var close=new Button{Content="×",MinWidth=32,Padding=new(6),Background=DesktopVisuals.Brush(0)};
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(close,"关闭选集");
            close.Click+=(_,_)=>Access.Call(overlay,"CloseEpisodeDrawer");
            Grid.SetColumn(close,2);header.Children.Add(close);alternatives.Children.Add(header);
            scrolling=new ScrollViewer
            {
                MaxHeight=AlternateViewportHeight,
                VerticalScrollMode=ScrollMode.Enabled, VerticalScrollBarVisibility=ScrollBarVisibility.Auto,
                HorizontalScrollBarVisibility=ScrollBarVisibility.Disabled
            };
            Grid.SetRow(scrolling,1);alternatives.Children.Add(scrolling);
            Grid.SetRow(alternatives,2);layout.Children.Add(alternatives);
            ranges.SelectionChanged+=(_,_)=>{if(!settingRanges)JumpRange();};
            drawer.Child=null;
            try{Grid.SetRow(original,2);layout.Children.Add(original);drawer.Child=layout;}
            catch{layout.Children.Remove(original);Grid.SetRow(original,0);drawer.Child=original;throw;}
            flyout.Opening+=(_,_)=>_=Open();
            scrolling.ViewChanged+=(_,_)=>UpdateAlternateRange();
            flyout.Opened+=(_,_)=>ObserveOriginal();
            flyout.Closed+=(_,_)=>{StopObservingOriginal();Cancel();Restore();};
        }
        void ObserveOriginal()
        {
            StopObservingOriginal();
            QueueSelectedSeason();
            originalGrid.ApplyTemplate();
            originalScrolling=UiElements.Descendants(originalGrid).OfType<ScrollViewer>().FirstOrDefault();
            if (originalScrolling != null) originalScrolling.ViewChanged += UpdateOriginalRange;
            originalEpisodes.CollectionChanged += EpisodesChanged;
            if (original.Visibility == Visibility.Visible)
                QueueCurrentEpisode();
            else if (Same(chosen,current?.SeasonId))
            {
                int index=Array.FindIndex(shown,item=>Same(item.Id,current?.Id));
                if (index>=0) QueueAlternateJump(index);
            }
        }

        void StopObservingOriginal()
        {
            if (originalScrolling != null) originalScrolling.ViewChanged -= UpdateOriginalRange;
            originalScrolling=null;
            originalEpisodes.CollectionChanged -= EpisodesChanged;
        }

        void EpisodesChanged(object? sender, NotifyCollectionChangedEventArgs args) => QueueCurrentEpisode();

        void QueueCurrentEpisode()
        {
            if (currentJumpQueued) return;
            currentJumpQueued=originalGrid.DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () =>
            {
                currentJumpQueued=false;
                if(!flyout.IsOpen||!Current()||current is not {} item)return;
                if(original.Visibility!=Visibility.Visible)
                {
                    var queue=Access.Get<IReadOnlyList<EmbyItem>>(session!,"_playlist");
                    if(Same(chosen,item.SeasonId)&&(!ReferenceEquals(queue,currentQueue)||queue.Count!=currentQueueCount))
                        ShowCurrent();
                    return;
                }
                string id=item.Id;
                for (int index=0;index<originalGrid.Items.Count;index++)
                {
                    var option=originalGrid.Items[index];
                    if(!Same(Access.Call(option,"get_ItemId") as string,id))continue;
                    originalGrid.UpdateLayout();
                    originalGrid.ScrollIntoView(option,ScrollIntoViewAlignment.Leading);
                    int range=index/RangeSize;
                    if (originalGrid.Items.Count>RangeSize && range<originalRanges.Items.Count)
                    {
                        DisplayRange(originalRanges,(string)Access.Call(originalRanges.Items[range],"get_Label")!);
                        originalRanges.SelectedIndex=-1;
                    }
                    break;
                }
            });
        }

        void UpdateOriginalRange(object? sender, ScrollViewerViewChangedEventArgs? args)
        {
            if (originalScrolling is not { } viewer || original.Visibility != Visibility.Visible
                || originalRanges.SelectedIndex >= 0 || originalGrid.Items.Count <= RangeSize
                || Access.Get<bool>(overlay, "_settingEpisodeRange")
                || originalGrid.ItemsPanelRoot is not ItemsWrapGrid { FirstVisibleIndex: >= 0 } panel) return;

            int index = VisibleRange(viewer, panel.FirstVisibleIndex, originalGrid.Items.Count);
            if (index < originalRanges.Items.Count)
                DisplayRange(originalRanges, (string)Access.Call(originalRanges.Items[index], "get_Label")!);
        }

        void UpdateAlternateRange()
        {
            if (alternatives.Visibility != Visibility.Visible || ranges.Visibility != Visibility.Visible
                || scrolling.Content is null || settingRanges || ranges.SelectedIndex >= 0) return;

            int firstVisible = (int)(scrolling.VerticalOffset / RowPitch) * Columns;
            int index = VisibleRange(scrolling, firstVisible, shown.Length);
            if (index < ranges.Items.Count && ranges.Items[index] is ComboBoxItem { Content: string label })
                DisplayRange(ranges, label);
        }

        void Cancel(){var old=pending;pending=null;old?.Cancel();}
        void Restore(){original.Visibility=Visibility.Visible;alternatives.Visibility=Visibility.Collapsed;scrolling.Content=null;Message(null);}
        void Message(string? text){note.Text=text??"";note.Visibility=text is null?Visibility.Collapsed:Visibility.Visible;}
        bool Current()=>session!=null&&client!=null&&current!=null&&Owners.TryGetValue(overlay,out var owner)&&ReferenceEquals(owner.Session,session)
            &&!NativeDolby.IsClosing(session)&&drawer.Visibility==Visibility.Visible
            &&generation==Access.Get<int>(session,"_mediaGeneration")&&ReferenceEquals(current,Access.Get<EmbyItem>(session,"_item"))
            &&ReferenceEquals(client,Access.Get<EmbyApiClient>(session,"_embyClient"))
            &&user==Access.Get<string?>(client,"_userId")&&credential==Access.Get<string?>(client,"_accessToken");
        CancellationTokenSource Request()
        {
            Cancel();var token=CancellationTokenSource.CreateLinkedTokenSource((CancellationToken)session!.GetType().GetProperty("ClosingToken")!.GetValue(session)!);
            token.CancelAfter(TimeSpan.FromSeconds(10));return pending=token;
        }
        bool Owns(CancellationTokenSource token)=>ReferenceEquals(pending,token)&&Current();
        async Task Open()
        {
            try{
                Cancel();Restore();tabs.Children.Clear();
                if(!Owners.TryGetValue(overlay,out var owner)||owner.Session is not {} next)return;
                var item=Access.Get<EmbyItem>(next,"_item");var api=Access.Get<EmbyApiClient>(next,"_embyClient");
                if(api is null||item.Type!="Episode"||string.IsNullOrWhiteSpace(item.SeriesId)||string.IsNullOrWhiteSpace(item.SeasonId))return;
                int epoch=Access.Get<int>(next,"_mediaGeneration");
                string? account=Access.Get<string?>(api,"_userId"),auth=Access.Get<string?>(api,"_accessToken");
                if(!ReferenceEquals(session,next)||!ReferenceEquals(client,api)||generation!=epoch||account!=user||auth!=credential)
                {episodes.Clear();seasons=[];catalogLoaded=false;episodeTiles=null;gridItems=[];}
                session=next;client=api;current=item;generation=epoch;user=account;credential=auth;chosen=item.SeasonId;
                Tabs();ShowCurrent();
                if(catalogLoaded||!Current())return;
                using var token=Request();
                try{
                    var result=await api.GetSeasonsAsync(item.SeriesId,token.Token);
                    if(!Owns(token)||token.IsCancellationRequested)return;
                    seasons=result.Items.Where(s=>s.Type=="Season"&&!string.IsNullOrWhiteSpace(s.Id)
                        &&(string.IsNullOrEmpty(s.SeriesId)||Same(s.SeriesId,item.SeriesId)))
                        .DistinctBy(s=>s.Id,StringComparer.OrdinalIgnoreCase).OrderBy(s=>s.IndexNumber??int.MaxValue).ToArray();
                    catalogLoaded=true;Tabs();
                }catch(Exception){if(Owns(token))Message("暂未读取到其他季度，当前选集仍可使用");}
                finally{if(ReferenceEquals(pending,token))pending=null;}
            }catch(Exception e){PlaybackTransport.Write("Warning","Playback.Menu","季度资料暂不可用；"+e.GetType().Name);}
        }
        void Tabs()
        {
            tabs.Children.Clear();if(current?.SeasonId is not {} currentId)return;
            foreach(var season in seasons)
            {
                string label=season.IndexNumber is >0&&(string.IsNullOrWhiteSpace(season.Name)||season.Name.StartsWith("Season ",StringComparison.OrdinalIgnoreCase))
                    ?$"第{season.IndexNumber}季":string.IsNullOrWhiteSpace(season.Name)?"特别篇":season.Name;
                Tab(season.Id,label);
            }
            if(!seasons.Any(s=>Same(s.Id,currentId)))Tab(currentId,current.ParentIndexNumber is >0?$"第{current.ParentIndexNumber}季":"当前季");
            QueueSelectedSeason();
        }

        void QueueSelectedSeason()
        {
            int jump=++seasonJump;
            seasonStrip.DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low,()=>
            {
                if(jump!=seasonJump||!flyout.IsOpen||!Current())return;
                var tab=tabs.Children.OfType<Button>().FirstOrDefault(button=>Same(button.Tag as string,chosen));
                if(tab is null)return;
                seasonStrip.UpdateLayout();
                double viewport=seasonStrip.ViewportWidth;
                if(viewport<=0)return;
                double left=tab.TransformToVisual(tabs).TransformPoint(new Windows.Foundation.Point(0,0)).X;
                double offset=seasonStrip.HorizontalOffset;
                if(left<offset)offset=left;
                else if(left+tab.ActualWidth>offset+viewport)offset=left+tab.ActualWidth-viewport;
                else return;
                seasonStrip.ChangeView(Math.Clamp(offset,0,seasonStrip.ScrollableWidth),null,null,true);
            });
        }

        void PaintTabs()
        {
            foreach (var button in tabs.Children.OfType<Button>())
            {
                bool selected = Same(chosen, button.Tag as string);
                button.Foreground = DesktopVisuals.Brush(selected ? 0xFF3ED4D9 : 0xFFCECED1);
                Microsoft.UI.Xaml.Automation.AutomationProperties.SetItemStatus(button, selected ? "当前浏览季度" : "");
            }
        }

        void Tab(string id,string label)
        {
            var button=new Button{Content=label,Tag=id,MaxWidth=140,MinHeight=32,MinWidth=0,Padding=new(8,4,8,4),CornerRadius=new(6),BorderThickness=new(0),
                Background=DesktopVisuals.Brush(0),Foreground=DesktopVisuals.Brush(Same(chosen,id)?0xFF3ED4D9:0xFFCECED1),FontSize=13};
            button.Click+=async(_,_)=>await Select(id);tabs.Children.Add(button);ToolTipService.SetToolTip(button,label);
            if(Same(chosen,id))Microsoft.UI.Xaml.Automation.AutomationProperties.SetItemStatus(button,"当前浏览季度");
        }
        void ShowCurrent()
        {
            Restore();
            if(session==null||current==null)return;
            var queue=Access.Get<IReadOnlyList<EmbyItem>>(session,"_playlist");
            currentQueue=queue;
            currentQueueCount=queue.Count;
            var visible=queue.Where(i=>Same(i.Id,current.Id)||Same(i.SeasonId,current.SeasonId)
                ||string.IsNullOrEmpty(i.SeasonId)&&i.ParentIndexNumber==current.ParentIndexNumber)
                .Select(i=>Same(i.Id,current.Id)?current:i).ToList();
            if(!visible.Any(i=>Same(i.Id,current.Id)))visible.Add(current);
            // Use the standard grid when it has the correct item and numbering.
            // A missing index or explicit season/episode in the metadata title
            // must never be interpreted as the item's last position in the list.
            bool corrected=visible.Any(i=>EpisodeLabels.Index(i)!=i.IndexNumber);
            bool stale=!Same(Access.Get<string?>(overlay,"_currentPlaylistItemId"),current.Id);
            if(corrected||stale||visible.Count!=queue.Count)
                Show(visible.OrderBy(i=>EpisodeLabels.Index(i)??int.MaxValue).ToArray());
            else if(flyout.IsOpen)QueueCurrentEpisode();
        }
        async Task Select(string id)
        {
            try{
                if(!Current()||current is not {} item||client is not {} api)return;
                if(Same(chosen,id)&&(Same(id,item.SeasonId)||episodes.ContainsKey(id)||pending!=null))return;
                PlayerMenus.KeepEpisodePanelAtPointer(overlay);
                Cancel();chosen=id;PaintTabs();
                if(Same(id,item.SeasonId)){ShowCurrent();return;}
                if(episodes.TryGetValue(id,out var cached)){Show(cached);return;}
                original.Visibility=Visibility.Collapsed;alternatives.Visibility=Visibility.Visible;
                ranges.Visibility=Visibility.Collapsed;scrolling.Content=null;Message("正在读取分集…");
                using var token=Request();
                try{
                    var result=await api.GetEpisodesAsync(item.SeriesId!,id,token.Token);
                    if(!Owns(token)||!Same(chosen,id))return;
                    token.Token.ThrowIfCancellationRequested();
                    var rows=result.Items.Where(i=>i.Type=="Episode"&&!string.IsNullOrWhiteSpace(i.Id)
                        &&(string.IsNullOrEmpty(i.SeriesId)||Same(i.SeriesId,item.SeriesId))
                        &&(string.IsNullOrEmpty(i.SeasonId)||Same(i.SeasonId,id)))
                        .DistinctBy(i=>i.Id,StringComparer.OrdinalIgnoreCase).OrderBy(i=>EpisodeLabels.Index(i)??int.MaxValue).ToArray();
                    if(episodes.Count>=6)episodes.Clear();episodes[id]=rows;
                    PlayerMenus.KeepEpisodePanelAtPointer(overlay);
                    Show(rows);
                }catch(Exception){if(Owns(token))Message("分集暂不可用，点击季度重试");}
                finally
                {
                    if (ReferenceEquals(pending,token))
                    {
                        PlayerMenus.KeepEpisodePanelAtPointer(overlay);
                        pending=null;
                    }
                }
            }catch(Exception e){PlaybackTransport.Write("Warning","Playback.Menu","分集资料暂不可用；"+e.GetType().Name);}
        }
        void Show(EmbyItem[] items)
        {
            original.Visibility=Visibility.Collapsed;alternatives.Visibility=Visibility.Visible;
            shown=items;
            var slices=CreateRanges(items.Length);
            int currentIndex=Array.FindIndex(items,item=>Same(item.Id,current?.Id));
            settingRanges=true;
            try
            {
                ranges.Items.Clear();
                foreach(var slice in slices)
                {
                    string first=EpisodeLabels.Number(items[slice.StartIndex],slice.StartIndex+1);
                    string last=EpisodeLabels.Number(items[slice.EndExclusive-1],slice.EndExclusive);
                    ranges.Items.Add(new ComboBoxItem{Tag=slice,Content=EpisodeLabels.Range(first,last,slice.StartIndex,slice.Count)+" 集"});
                }
                ranges.SelectedIndex=slices.Count==0?-1:Math.Max(0,EpisodeRangePolicy.FindRangeIndex(currentIndex,slices));
                ranges.Visibility=slices.Count>1?Visibility.Visible:Visibility.Collapsed;
            }
            finally{settingRanges=false;}
            Message(items.Length==0?"本季暂无可选分集":null);
            BuildEpisodeGrid();
            JumpRange(currentIndex);
        }

        void JumpRange(int episodeIndex = -1)
        {
            if (ranges.SelectedItem is not ComboBoxItem { Tag: EpisodeRange slice, Content: string label }) return;
            if (ranges.Visibility == Visibility.Visible)
            {
                DisplayRange(ranges, label);
                ranges.SelectedIndex = -1;
            }
            QueueAlternateJump(episodeIndex >= 0 ? episodeIndex : slice.StartIndex);
        }

        void QueueAlternateJump(int target)
        {
            var content = scrolling.Content;
            int jump = ++rangeJump;
            scrolling.DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () =>
            {
                if (jump != rangeJump || !ReferenceEquals(scrolling.Content, content)) return;
                scrolling.UpdateLayout();
                scrolling.ChangeView(null, (target / Columns) * RowPitch, null, true);
            });
        }

        void BuildEpisodeGrid()
        {
            if(episodeTiles is {} cached&&Same(tilesPlayingId,current?.Id)&&shown.SequenceEqual(gridItems))
            {
                scrolling.Content=cached;
                return;
            }
            var grid=new Grid{ColumnSpacing=TileSpacing,RowSpacing=TileSpacing};
            for(int column=0;column<Columns;column++)grid.ColumnDefinitions.Add(new(){Width=new(1,GridUnitType.Star)});
            for(int i=0;i<shown.Length;i++)
            {
                var item=shown[i];
                bool playing=Same(item.Id,current?.Id);
                var tile=new Button
                {
                    Content=EpisodeLabels.Number(item,i+1),IsTabStop=!playing,MinWidth=0,Height=TileHeight,Padding=new(3),
                    CornerRadius=new(12),BorderThickness=new(0),HorizontalAlignment=HorizontalAlignment.Stretch,
                    HorizontalContentAlignment=HorizontalAlignment.Center,
                    Background=new SolidColorBrush(EpisodeColor(playing)),Foreground=DesktopVisuals.Brush(0xFFF4F4F4)
                };
                if (playing)
                {
                    tile.Resources["ButtonBackgroundPointerOver"]=tile.Background;
                    tile.Resources["ButtonBackgroundPressed"]=tile.Background;
                    tile.Resources["ButtonForegroundPointerOver"]=tile.Foreground;
                    tile.Resources["ButtonForegroundPressed"]=tile.Foreground;
                    Microsoft.UI.Xaml.Automation.AutomationProperties.SetItemStatus(tile,"正在播放");
                }
                else tile.Click+=(_,_)=>Play(item.Id);
                ToolTipService.SetToolTip(tile,EpisodeLabels.Display(item));
                int row=i/Columns;
                if(row>=grid.RowDefinitions.Count)grid.RowDefinitions.Add(new(){Height=GridLength.Auto});
                Grid.SetRow(tile,row);Grid.SetColumn(tile,i%Columns);grid.Children.Add(tile);
            }
            scrolling.Content=grid;
        }
        void Play(string id)
        {
            try{
                if(!Current()||session is null||!CanPick(overlay,id))return;
                Access.Call(overlay,"CloseEpisodeDrawer");Access.Call(session,"OnEpisodeRequested",overlay,id);
            }catch(Exception e){PlaybackTransport.Write("Warning","Playback.Menu","换集请求未完成；"+e.GetType().Name);}
        }
    }
}
