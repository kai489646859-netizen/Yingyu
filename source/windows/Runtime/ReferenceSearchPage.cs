using EmbyDesktop.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Foundation;

namespace Yingyu.Update;

internal static partial class ReferenceAppearance
{
    sealed partial class State
    {
        readonly Grid searchPage=new(){Name="ReferenceSearchPage",Visibility=Visibility.Collapsed,VerticalAlignment=VerticalAlignment.Top};
        readonly StackPanel searchBody=new(){HorizontalAlignment=HorizontalAlignment.Center};
        readonly StackPanel suggestions=new(){Name="ReferenceSearchSuggestions",Spacing=10,Margin=new(0,30,0,20)};
        readonly TextBlock searchTitle=new(){Name="ReferenceSearchTitle",Text="搜索",FontSize=24,FontWeight=Microsoft.UI.Text.FontWeights.Bold,VerticalAlignment=VerticalAlignment.Center,Visibility=Visibility.Collapsed};
        readonly Button searchClose=new(){Name="ReferenceSearchClose",Content=new FontIcon{Glyph="\uE8BB",FontSize=20},HorizontalAlignment=HorizontalAlignment.Right,VerticalAlignment=VerticalAlignment.Top,Visibility=Visibility.Collapsed};
        readonly Dictionary<FrameworkElement,Visibility> searchOrigin=new();
        string[] suggestionNames=Array.Empty<string>();
        double suggestionWidth;
        DesktopThemePalette suggestionPalette;
        bool enteredResults,returningSearch;int searchEpoch;double originOffset;object? originOwner;Thickness originLibraryPadding;
        Grid? returnLayer;
        object? originNavigation;string? originLibrary;EmbyItem? originDetail;
        object? Field(string name)=>page.GetType().GetField(name,Flags)?.GetValue(page)??page.GetType().GetProperty(name,Flags)?.GetValue(page);
        internal bool InlineSearch()
        {
            if(searchExpanded||Find<Grid>("DetailView")?.Visibility==Visibility.Visible||Find<Grid>("SettingsView")?.Visibility==Visibility.Visible)return false;
            var navigation=Field("_activeNavigation")?.ToString();
            if(string.IsNullOrWhiteSpace(navigation)&&!string.IsNullOrWhiteSpace(Field("_lastSearchTerm") as string))navigation=Field("_searchOriginNavigation")?.ToString();
            return navigation is "Library" or "Favorites" or "History" or "Collection";
        }
        void PlaceInlineSearch()
        {
            if(Find<AutoSuggestBox>("SearchBox") is {} input)input.PlaceholderText=InlineSearch()?"搜索当前库的片名或演员":"搜索片名或演员…";
            if(InlineSearch()&&Find<Grid>("LibraryHeaderGrid") is {} header)
            {
                if(!header.Children.Contains(searchHost)){DesktopShellActions.Detach(page,searchHost);header.Children.Add(searchHost);}
                while(header.RowDefinitions.Count<2)header.RowDefinitions.Add(new(){Height=GridLength.Auto});
                Grid.SetRow(searchHost,1);Grid.SetColumn(searchHost,0);Grid.SetColumnSpan(searchHost,Math.Max(1,header.ColumnDefinitions.Count));
                searchHost.Visibility=Visibility.Visible;searchHost.Width=double.NaN;searchHost.HorizontalAlignment=HorizontalAlignment.Stretch;searchHost.Margin=new(0,16,0,4);
            }
            else if(!searchBody.Children.Contains(searchHost))
            {
                DesktopShellActions.Detach(page,searchHost);searchBody.Children.Insert(0,searchHost);Grid.SetRow(searchHost,0);Grid.SetColumn(searchHost,0);Grid.SetColumnSpan(searchHost,1);searchHost.HorizontalAlignment=HorizontalAlignment.Center;
            }
        }
        void AttachSearchPage(Grid shell)
        {
            searchBody.Children.Add(searchHost);searchBody.Children.Add(suggestions);
            searchPage.Children.Add(new ScrollViewer{Content=searchBody,HorizontalScrollBarVisibility=ScrollBarVisibility.Disabled,VerticalScrollBarVisibility=ScrollBarVisibility.Auto});
            Grid.SetColumn(searchPage,0);Grid.SetColumnSpan(searchPage,Math.Max(1,shell.ColumnDefinitions.Count));Grid.SetRow(searchPage,0);Grid.SetRowSpan(searchPage,Math.Max(1,shell.RowDefinitions.Count));Canvas.SetZIndex(searchPage,12);shell.Children.Add(searchPage);
            Grid.SetColumnSpan(searchClose,Math.Max(1,shell.ColumnDefinitions.Count));Grid.SetRowSpan(searchClose,Math.Max(1,shell.RowDefinitions.Count));Canvas.SetZIndex(searchClose,45);shell.Children.Add(searchClose);searchClose.Click+=async(_,_)=>await ReturnFromSearch();
            page.Unloaded+=(_,_)=>{searchEpoch++;RemoveReturnLayer();};
            page.PreviewKeyDown+=(_,args)=>{if(args.Handled||!searchExpanded||args.Key!=Windows.System.VirtualKey.Escape||Find<Grid>("DetailView")?.Visibility==Visibility.Visible)return;if(page.XamlRoot!=null&&VisualTreeHelper.GetOpenPopupsForXamlRoot(page.XamlRoot).Any(p=>p.IsOpen))return;args.Handled=true;_ = ReturnFromSearch();};
            ToolTipService.SetToolTip(searchClose,"关闭搜索，返回原页面");Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(searchClose,"关闭搜索，返回原页面");
            foreach(var name in new[]{"HomeNavButton","FavoritesNavButton","CollectionNavButton","SettingsButton"})if(Find<Button>(name) is {} button)button.Click+=(_,_)=>CloseSearchPage(false);
            Find<Grid>("DetailView")?.RegisterPropertyChangedCallback(UIElement.VisibilityProperty,(_,_)=>{if(searchExpanded)Queue();});
            Find<StackPanel>("SearchResultsPanel")?.RegisterPropertyChangedCallback(UIElement.VisibilityProperty,(_,_)=>{if(searchExpanded&&Find<StackPanel>("SearchResultsPanel")?.Visibility==Visibility.Visible){enteredResults=true;Queue();}});
        }
        void OpenSearchPage()
        {
            if(returningSearch){searchEpoch++;RemoveReturnLayer();DesktopSceneMotion.Enter(searchPage);}
            if(!attached){Apply();if(!attached)return;}
            bool opening=!searchExpanded;
            if(!searchExpanded)
            {
                originLibraryPadding=Find<Grid>("LibraryView")?.Padding??new Thickness(0);
                searchEpoch++;originOwner=Field("_session");originOffset=(Access.Call(page,"GetActiveVerticalScrollViewer") as ScrollViewer)?.VerticalOffset??0;
                originNavigation=Field("_activeNavigation");originLibrary=Field("_activeLibraryId") as string;originDetail=Find<Grid>("DetailView")?.Visibility==Visibility.Visible?Field("_currentDetailItem") as EmbyItem:null;
                searchOrigin.Clear();foreach(var name in new[]{"LibraryView","DetailView","CollectionView","SettingsView"})if(Find<FrameworkElement>(name) is {} view){searchOrigin[view]=view.Visibility;view.Visibility=name=="LibraryView"?Visibility.Visible:Visibility.Collapsed;}
                suggestionNames=Suggestions();suggestionWidth=0;enteredResults=Find<StackPanel>("SearchResultsPanel")?.Visibility==Visibility.Visible;
                searchExpanded=true;
            }
            Apply();int epoch=searchEpoch;page.DispatcherQueue.TryEnqueue(()=>{try{if(!searchExpanded||epoch!=searchEpoch)return;if(opening)DesktopSceneMotion.Enter(searchPage);page.DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low,()=>{try{if(!searchExpanded||epoch!=searchEpoch)return;page.UpdateLayout();if(Find<AutoSuggestBox>("SearchBox") is {} input)DesktopSearch.Focus(input);}catch(Exception error){Warn(error);}});}catch(Exception error){Warn(error);}});
        }
        void CloseSearchPage(bool restore,bool keepReturnLayer=false)
        {
            DesktopSearch.Cancel(page);
            if(!keepReturnLayer&&returnLayer!=null){searchEpoch++;RemoveReturnLayer();}
            if(!searchExpanded)return;searchEpoch++;DesktopSceneMotion.Reset(searchPage);searchExpanded=false;
            if(restore)foreach(var pair in searchOrigin)pair.Key.Visibility=pair.Value;
            else if(Find<Grid>("LibraryView") is {} library)library.Visibility=Visibility.Visible;
            if(Find<Grid>("LibraryView") is {} libraryRoot)libraryRoot.Padding=originLibraryPadding;
            if(Find<ScrollViewer>("MainContentScrollViewer") is {} main){main.Opacity=1;main.IsHitTestVisible=true;main.Visibility=Visibility.Visible;}
            if(Find<Grid>("LibraryHeaderGrid") is {} header)header.Visibility=Visibility.Visible;
            searchPage.Visibility=searchTitle.Visibility=searchClose.Visibility=Visibility.Collapsed;
            if(Find<Button>("DetailBackButton") is {} back)back.Visibility=Find<Grid>("DetailView")?.Visibility==Visibility.Visible?Visibility.Visible:Visibility.Collapsed;
            if(restore&&Find<Grid>("DetailView")?.Visibility==Visibility.Visible)DesktopPeople.Detail(page);
            Queue();
        }
        async Task ReturnFromSearch()
        {
            if(returningSearch||!searchExpanded)return;DesktopSearch.Cancel(page);returningSearch=true;
            int epoch=++searchEpoch;var owner=originOwner;var navigationBefore=originNavigation;var libraryBefore=originLibrary;var detailBefore=originDetail;double offset=originOffset;bool hadResults=enteredResults;
            Grid? outgoing=null;
            bool collectionBefore=searchOrigin.Any(pair=>pair.Key.Name=="CollectionView"&&pair.Value==Visibility.Visible);
            try
            {
                // Hold the outgoing scene while the existing origin is restored.
                // The subsequent fade reveals already laid-out content, not a blank root.
                if(Find<Grid>("ShellGrid") is {} shell){
                    try{
                    var bitmap=new RenderTargetBitmap();await bitmap.RenderAsync(shell);
                    if(epoch!=searchEpoch||!searchExpanded||!ReferenceEquals(owner,Field("_session")))return;
                    outgoing=returnLayer=new Grid{Name="ReferenceSearchReturnOverlay",Background=Fallback(),IsHitTestVisible=false};
                    outgoing.Children.Add(new Image{Source=bitmap,Stretch=Stretch.Fill});
                    Grid.SetColumnSpan(outgoing,Math.Max(1,shell.ColumnDefinitions.Count));Grid.SetRowSpan(outgoing,Math.Max(1,shell.RowDefinitions.Count));Canvas.SetZIndex(outgoing,90);shell.Children.Add(outgoing);
                    }catch(Exception error){Warn(error);}
                }
                if(epoch!=searchEpoch||!searchExpanded||!ReferenceEquals(owner,Field("_session")))return;
                CloseSearchPage(true,true);
                epoch=searchEpoch;
                Access.Call(page,"ClearSearchContext");
                if(!ReferenceEquals(owner,Field("_session")))return;
                if(!hadResults){/* The original controls and data still exist. */}
                else if(detailBefore!=null){if(hadResults||!ReferenceEquals(detailBefore,Field("_currentDetailItem")))await (Task)Access.Call(page,"ShowDetailAsync",detailBefore,null,null,null,null)!;}
                else if(collectionBefore){await (Task)Access.Call(page,"ShowCollectionAsync",Field("_collectionFavorites") is true)!;}
                else
                {
                    Access.Call(page,"ShowLibraryView");
                    var library=(Field("_libraryViews") as IEnumerable<EmbyItem>)?.FirstOrDefault(i=>i.Id==libraryBefore);
                    if(navigationBefore?.ToString()=="History")await (Task)Access.Call(page,"LoadHistoryAsync")!;
                    else if(navigationBefore?.ToString()=="Library"&&library!=null)
                    {
                        Access.Set(page,"_activeLibraryName",library.Name);Access.Call(page,"SetActiveNavigation",navigationBefore,library.Id);
                        var key="library:"+library.Id;Access.Set(page,"_activeSnapshotKey",key);
                        if(Access.Call(page,"TryShowLibrarySnapshot",key,library.Name) is not true)
                        {
                            var type=page.GetType().GetMethod("GetLibraryItemTypes",Flags|System.Reflection.BindingFlags.Static)!.Invoke(null,new object[]{library});
                            await (Task)Access.Call(page,"LoadFilteredAsync",type,library.Name,false,library.Id,false)!;
                        }
                    }
                    else if(navigationBefore?.ToString()=="Favorites")
                    {
                        Access.Set(page,"_activeLibraryName",null);Access.Call(page,"SetActiveNavigation",navigationBefore,null);Access.Set(page,"_activeSnapshotKey","favorites");
                        if(Access.Call(page,"TryShowLibrarySnapshot","favorites","收藏") is not true)await (Task)Access.Call(page,"LoadFilteredAsync",null,"收藏",true,null,false)!;
                    }
                    else
                    {
                        var nav=Enum.Parse(page.GetType().GetNestedType("NavigationSection",Flags)!,"Home");Access.Set(page,"_activeLibraryName",null);
                        Access.Call(page,"SetActiveNavigation",nav,null);Access.Set(page,"_activeSnapshotKey","home");
                        if(Field("_homeSnapshot") is {} home)Access.Call(page,"ShowHomeSnapshot",home);else await (Task)Access.Call(page,"LoadHomeAsync",false)!;
                    }
                }
                if(epoch!=searchEpoch||searchExpanded||!ReferenceEquals(owner,Field("_session")))return;
                Apply();
                void RestoreOffset(int attempt)
                {
                    try
                    {
                    if(epoch!=searchEpoch||searchExpanded||!ReferenceEquals(owner,Field("_session"))||!page.IsLoaded)return;
                    if(Access.Call(page,"GetActiveVerticalScrollViewer") is ScrollViewer{IsLoaded:true,ViewportHeight:>0} scroll)
                        scroll.ChangeView(null,Math.Clamp(offset,0,Math.Max(0,scroll.ScrollableHeight)),null,true);
                    else if(attempt==0)page.DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low,()=>RestoreOffset(1));
                    }
                    catch(Exception error){Warn(error);}
                }
                page.DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low,()=>RestoreOffset(0));
                var ready=new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
                if(page.DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low,()=>{page.UpdateLayout();ready.TrySetResult(true);}))await ready.Task;
                if(epoch!=searchEpoch||searchExpanded||!ReferenceEquals(owner,Field("_session")))return;
                if(outgoing!=null)await DesktopSceneMotion.Exit(outgoing);
            }
            catch(Exception error){Warn(error);}
            finally{if(outgoing!=null)RemoveReturnLayer(outgoing);returningSearch=false;Queue();}
        }
        void RemoveReturnLayer(Grid? expected=null)
        {
            var layer=expected??returnLayer;if(layer==null)return;
            DesktopSceneMotion.Reset(layer);foreach(var image in layer.Children.OfType<Image>())image.Source=null;
            (layer.Parent as Panel)?.Children.Remove(layer);if(ReferenceEquals(layer,returnLayer))returnLayer=null;
        }
        string[] Suggestions()
        {
            // Read the already loaded, account-scoped catalogue; no new request.
            var items=new List<EmbyItem>();
            if((page.GetType().GetField("_localSearchIndex",Flags)?.GetValue(page) ?? page.GetType().GetProperty("_localSearchIndex",Flags)?.GetValue(page)) is {} index&&index.GetType().GetProperty("Entries")?.GetValue(index) is System.Collections.IEnumerable entries)
                foreach(var entry in entries)if(entry?.GetType().GetProperty("Item")?.GetValue(entry) is EmbyItem item)items.Add(item);
            if(Access.Call(page,"GetCurrentlyCachedEntries") is System.Collections.IEnumerable cached)
                foreach(var entry in cached)if(entry?.GetType().GetProperty("Item")?.GetValue(entry) is EmbyItem item)items.Add(item);
            var names=items.Where(i=>i.Type is "Movie" or "Series").Select(i=>i.Name).Where(n=>!string.IsNullOrWhiteSpace(n)).Distinct().ToArray();
            Random.Shared.Shuffle(names);return names.Take(42).ToArray();
        }
        void SearchLayout(double inset)
        {
            if(!searchExpanded){searchPage.Visibility=searchTitle.Visibility=searchClose.Visibility=Visibility.Collapsed;return;}
            if(Find<Grid>("SettingsView")?.Visibility==Visibility.Visible){CloseSearchPage(false);return;}
            if(Find<Grid>("DetailView")?.Visibility==Visibility.Visible){searchPage.Visibility=searchTitle.Visibility=searchClose.Visibility=Visibility.Collapsed;if(Find<Button>("DetailBackButton") is {} detailBack)detailBack.Visibility=Visibility.Visible;return;}
            bool results=Find<StackPanel>("SearchResultsPanel")?.Visibility==Visibility.Visible;enteredResults|=results;
            // Library grids use a separate browse viewport outside the home
            // ScrollViewer. Hide the whole underlying view on the landing page.
            if(Find<Grid>("LibraryView") is {} library){library.Visibility=results?Visibility.Visible:Visibility.Collapsed;library.Padding=new(originLibraryPadding.Left,originLibraryPadding.Top+(results?138:0),originLibraryPadding.Right,originLibraryPadding.Bottom);}
            searchPage.Visibility=searchClose.Visibility=Visibility.Visible;searchTitle.Visibility=Visibility.Collapsed;Icon(searchClose);searchClose.Foreground=Brush(Palette.Text);
            searchClose.HorizontalAlignment=HorizontalAlignment.Right;searchClose.Margin=new(0,12,32,0);DesktopCloseButton.Apply(searchClose,Palette);
            if(Find<Button>("DetailBackButton") is {} back)back.Visibility=Visibility.Collapsed;
            double width=Math.Min(866,Math.Max(240,page.ActualWidth-80));searchBody.Width=width;searchHost.Width=width;searchHost.Margin=new(0,64,0,0);searchHost.Visibility=Visibility.Visible;
            searchPage.Height=results?126:Math.Max(100,page.ActualHeight);suggestions.Visibility=results?Visibility.Collapsed:Visibility.Visible;
            if(Find<Grid>("LibraryHeaderGrid") is {} header)header.Visibility=Visibility.Collapsed;
            if(Find<ScrollViewer>("MainContentScrollViewer") is {} main){main.Opacity=results?1:0;main.Visibility=results?Visibility.Visible:Visibility.Collapsed;main.IsHitTestVisible=results;main.Padding=new(inset,0,inset,32);}
            if(Math.Abs(suggestionWidth-width)>1||suggestionPalette!=Palette)
            {
                suggestionWidth=width;suggestionPalette=Palette;suggestions.Children.Clear();suggestions.Children.Add(new TextBlock{Text="猜你喜欢",FontSize=23,FontWeight=Microsoft.UI.Text.FontWeights.Bold,Foreground=Brush(Palette.Text),HorizontalAlignment=HorizontalAlignment.Center,Margin=new(0,0,0,10)});
                StackPanel? row=null;double used=0;double available=width-24;
                foreach(string name in suggestionNames)
                {
                    var chip=new Button{Content=new TextBlock{Text=name,FontSize=13,TextTrimming=TextTrimming.CharacterEllipsis},MaxWidth=available,HorizontalAlignment=HorizontalAlignment.Center};ReferenceSurfaces.Button(chip);chip.MinHeight=32;chip.Padding=new(14,5,14,5);chip.BorderThickness=new(0);chip.Background=Brush(Palette.Hover);ToolTipService.SetToolTip(chip,name);
                    var label=(TextBlock)chip.Content;label.Measure(new Size(available-28,80));double size=Math.Min(available,label.DesiredSize.Width+28);chip.Width=size;
                    if(row==null||used+10+size>available){row=new(){Orientation=Orientation.Horizontal,Spacing=10,HorizontalAlignment=HorizontalAlignment.Center};suggestions.Children.Add(row);used=0;}
                    row.Children.Add(chip);used+=size+(used>0?10:0);
                    chip.Click+=async(_,_)=>{try{if(Find<AutoSuggestBox>("SearchBox") is {} box)box.Text=name;if(string.IsNullOrWhiteSpace(Field("_lastSearchTerm") as string)){Access.Set(page,"_searchOriginNavigation",originNavigation);Access.Set(page,"_searchOriginLibraryId",originLibrary);Access.Set(page,"_searchOriginVerticalOffset",Find<ScrollViewer>("MainContentScrollViewer")?.VerticalOffset??0d);}await (Task)Access.Call(page,"LoadSearchAsync",name,originNavigation?.ToString()=="Library"?originLibrary:null,originNavigation?.ToString()=="Favorites")!;Queue();}catch(Exception error){Warn(error);}};
                }
                if(suggestionNames.Length==0)suggestions.Children.Add(new TextBlock{Text="输入片名或演员开始搜索",Foreground=Brush(Palette.Secondary),HorizontalAlignment=HorizontalAlignment.Center});
            }
        }
    }
}
