using System.Reflection;
using System.Runtime.CompilerServices;
using System.Text.Json;
using EmbyDesktop.Core.Models;
using EmbyDesktop.Core.Services;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;

namespace Yingyu.Update;

public static class DesktopPeople
{
    static readonly ConditionalWeakTable<object,State> States=new();
    static readonly Lazy<ActorDisk> Disk=new(()=>new ActorDisk(Path.Combine(CachePaths.CacheRoot,"Actors")));
    static string Preferences=>Path.Combine(CachePaths.UserDataRoot,"actor-cache-settings.json");
    static int? limit;
    public static int CacheGB
    {
        get
        {
            if(limit.HasValue)return limit.Value;
            try {var file=new FileInfo(Preferences);if(file.Exists&&file.Length<=4096){int value=JsonSerializer.Deserialize<int>(File.ReadAllText(Preferences));if(ActorDisk.IsChoice(value))return (limit=value).Value;}}catch(Exception e)when(e is IOException or UnauthorizedAccessException or JsonException){}
            return (limit=1).Value;
        }
    }
    public static void Configure(object page)=>Run(()=>States.GetValue(page,p=>new State(p)));
    public static void Detail(object page)=>Run(()=>States.GetValue(page,p=>new State(p)).Detail());
    public static void Search(object page)=>Run(()=>States.GetValue(page,p=>new State(p)).Search());
    public static void Edit(object page,bool clear)=>Run(()=>{if(States.TryGetValue(page,out var state))state.Edit(clear);});
    public static void Settings(object page)=>Run(()=>States.GetValue(page,p=>new State(p)).Settings());
    public static void Resume(object page)=>Run(()=>{if(States.TryGetValue(page,out var state))state.Resume();});
    static void Run(Action action){try{action();}catch(Exception e){Report(e);}}
    static void Report(Exception e){try{PlaybackTransport.Write("Warning","Emby.People","演员资料或图片暂不可用；"+e.GetType().Name);}catch(Exception){}}
    sealed class Slot
    {
        public volatile bool Visible;
        public bool Running,Queued,RetryPending;
        public int VisibilityVersion,Retries;
        public Image Image=new(){Width=84,Height=100,Stretch=Stretch.Uniform};
        public FrameworkElement Tile=null!;
        public EmbyPerson Person=null!;
        public EmbySession Session=null!;
        public EmbyApiClient Client=null!;
        public CancellationToken Token;
    }
    sealed class State
    {
        readonly object page;
        readonly FrameworkElement element;
        readonly StackPanel actors=new(){Spacing=12},searchActors=new(){Spacing=12},films=new(){Spacing=12};
        readonly List<Slot> slots=new();
        CancellationTokenSource? detailCts,searchCts,filmCts;
        EmbyItem? detailItem;
        EmbySession? detailOwner;
        EmbyApiClient? detailClient;
        bool detailDeferred;
        EmbySession? peopleOwner;EmbyApiClient? peopleClient;
        readonly Dictionary<string,(DateTimeOffset At,IReadOnlyList<EmbyPerson> People)> peopleCache=new();
        EmbyApiClient? searchClient;
        CancellationTokenSource? hostSearch;
        int detailGeneration=-1,peopleOffset,photoReports;
        CancellationToken photoRefreshToken;
        string? term;
        string? selectedPerson;
        bool settingsBuilt,searchAttached;
        readonly Dictionary<string,int> filmOffsets=new();
        readonly HashSet<string> filmIds=new(StringComparer.OrdinalIgnoreCase);
        readonly List<EmbyPerson> matchedPeople=new();
        StackPanel? actorRow;

        IReadOnlyList<EmbyItem> titleResults=Array.Empty<EmbyItem>(),titleMatches=Array.Empty<EmbyItem>();
        readonly List<EmbyItem> actorResults=new();

        public State(object page)
        {
            this.page=page;element=(FrameworkElement)page;
            element.Unloaded+=(_,_)=>Cancel();
            element.GotFocus+=(_,_)=>Run(Resume);
            Find<Grid>("DetailView")?.RegisterPropertyChangedCallback(UIElement.VisibilityProperty,(_,_)=>{
                if(Find<Grid>("DetailView")?.Visibility!=Visibility.Visible){detailCts?.Cancel();detailItem=null;}
                else element.DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low,()=>Run(Detail));
            });
            Find<Grid>("LibraryView")?.RegisterPropertyChangedCallback(UIElement.VisibilityProperty,(_,_)=>{if(Find<Grid>("LibraryView")?.Visibility!=Visibility.Visible){searchCts?.Cancel();filmCts?.Cancel();}});
        }
        T? Find<T>(string name) where T:class=>element.GetType().GetField(name,BindingFlags.Instance|BindingFlags.NonPublic|BindingFlags.Public)?.GetValue(element) as T;
        EmbyApiClient? Client=>Access.Get<EmbyApiClient?>(page,"_client");
        EmbySession? Session=>Access.Get<EmbySession?>(page,"_session");
        bool Current(EmbyApiClient client,CancellationToken token,EmbySession session)=>!token.IsCancellationRequested&&ReferenceEquals(Client,client)&&ReferenceEquals(Session,session)&&!AndroidCacheRuntime.IsPaused;
        bool SearchCurrent(EmbyApiClient client,CancellationToken token,EmbySession session)=>Current(client,token,session)&&term==Access.Get<string?>(page,"_lastSearchTerm")&&Find<StackPanel>("SearchResultsPanel")?.Visibility==Visibility.Visible;
        void Cancel(){detailCts?.Cancel();searchCts?.Cancel();filmCts?.Cancel();foreach(var slot in slots)slot.Visible=false;slots.Clear();}
        public void Resume()
        {
            DetailArtwork.Resume(page);if(AndroidCacheRuntime.IsPaused)return;
            var refreshToken=Access.Get<CancellationTokenSource?>(page,"_posterLoadCts")?.Token??CancellationToken.None;
            bool refreshed=refreshToken!=photoRefreshToken;photoRefreshToken=refreshToken;
            if(detailDeferred){detailDeferred=false;detailItem=null;}Detail();
            foreach(var slot in slots.ToArray()){if(refreshed)slot.Retries=0;QueueSlot(slot);}
        }
        TextBlock Text(string value,double size=13)=>new(){Text=value,FontSize=size,TextWrapping=TextWrapping.Wrap,Foreground=DesktopVisuals.Brush(ReferenceSurfaces.Palette(element).Text)};
        static Button Action(string title,Action action){var b=new Button{Content=title};ReferenceSurfaces.Button(b);b.Click+=(_,_)=>Run(action);return b;}
        static StackPanel Row()=>new(){Orientation=Orientation.Horizontal,Spacing=12};
        static Border Card(UIElement child)=>new(){Child=child,Padding=new Thickness(18),Margin=new Thickness(0,16,0,12),CornerRadius=new CornerRadius(16),BorderThickness=new Thickness(1),BorderBrush=(Brush)Application.Current.Resources["CardOutlineBrush"]};
        void Status(StackPanel panel,string message,Action? retry=null){panel.Children.Clear();if(ReferenceEquals(panel,actors))panel.Children.Add(ActorText("演职人员（制作人员）",22));panel.Children.Add(ReferenceEquals(panel,actors)?ActorText(message):Text(message));if(retry!=null)panel.Children.Add(Action("重试",retry));}
        TextBlock ActorText(string value,double size=13){var text=Text(value,size);text.Foreground=DesktopVisuals.Brush(ReferenceSurfaces.Palette(element).Text);if(size>=20){text.FontWeight=Microsoft.UI.Text.FontWeights.Bold;DesktopContentBounds.Heading(text);}return text;}
        public void Detail()
        {
            if(AndroidCacheRuntime.IsPaused)return;
            var item=Access.Get<EmbyItem?>(page,"_currentDetailItem");var client=Client;var session=Session;
            if(item==null||client==null||session==null||Find<Grid>("DetailView")?.Visibility!=Visibility.Visible)return;
            int generation=Access.Get<int>(page,"_detailLoadVersion");
            if(ReferenceEquals(item,detailItem)&&ReferenceEquals(session,detailOwner)&&ReferenceEquals(client,detailClient)&&generation==detailGeneration&&detailCts is {IsCancellationRequested:false})return;
            detailCts?.Cancel();detailCts?.Dispose();detailCts=new();detailItem=item;detailGeneration=generation;detailOwner=session;detailClient=client;photoReports=0;
            slots.RemoveAll(s=>s.Token.IsCancellationRequested);
            if(actors.Parent==null&&Find<Grid>("DetailPageLayout") is {} grid)
            {
                if(grid.RowDefinitions.Count==0)grid.RowDefinitions.Add(new(){Height=GridLength.Auto});
                var card=Card(actors);card.Name="ReferenceActors";card.Margin=new(0,32,0,12);card.Padding=new(0);card.BorderThickness=new(0);card.Background=null;Grid.SetRow(card,grid.RowDefinitions.Count);Grid.SetColumnSpan(card,Math.Max(1,grid.ColumnDefinitions.Count));grid.RowDefinitions.Add(new(){Height=GridLength.Auto});grid.Children.Add(card);
            }
            _=LoadDetail(client,session,item,detailCts.Token);
        }
        async Task LoadDetail(EmbyApiClient client,EmbySession session,EmbyItem item,CancellationToken token)
        {
            try
            {
                Status(actors,"正在读取 Emby 演员资料…");
                // Cached cast metadata/photos remain independent. Only a metadata
                // miss joins the detail network priority chain below.
                if(!Current(client,token,session)||!ReferenceEquals(detailItem,item)){if(AndroidCacheRuntime.IsPaused)detailDeferred=true;return;}
                if(!ReferenceEquals(peopleOwner,session)||!ReferenceEquals(peopleClient,client))
                {peopleCache.Clear();peopleOwner=session;peopleClient=client;}
                IReadOnlyList<EmbyPerson> list;
                if(peopleCache.TryGetValue(item.Id,out var cached)&&DateTimeOffset.UtcNow-cached.At<(cached.People.Count==0?TimeSpan.FromSeconds(15):TimeSpan.FromMinutes(15)))list=cached.People;
                else
                {
                    await DetailArtwork.WaitForPriorityImages(page,token);
                    if(!Current(client,token,session)||!ReferenceEquals(detailItem,item))return;
                    list=await LocalMetadata.Detail(client,session.UserId,item.Id,token);
                    if(!Current(client,token,session)||!ReferenceEquals(detailItem,item)){if(AndroidCacheRuntime.IsPaused)detailDeferred=true;return;}
                    if(peopleCache.Count>=64)peopleCache.Remove(peopleCache.MinBy(pair=>pair.Value.At).Key);
                    peopleCache[item.Id]=(DateTimeOffset.UtcNow,list);
                }
                if(!Current(client,token,session)||!ReferenceEquals(detailItem,item)){if(AndroidCacheRuntime.IsPaused)detailDeferred=true;return;}
                PlaybackTransport.Write("Info","Emby.People",$"详情演员资料就绪；人数={list.Count}；带图片标记={list.Count(p=>p.ImageTag.Length>0)}；未记录姓名或身份。");
                actors.Children.Clear();actors.Children.Add(ActorText("演职人员（制作人员）",22));
                if(list.Count==0){actors.Children.Add(ActorText("Emby 暂未提供演员资料。"));return;}
                var strip=Row();int shown=0;
                var more=Action("显示更多演员",()=>{});
                void Append(){foreach(var person in list.Skip(shown).Take(24))strip.Children.Add(PersonTile(person,client,session,token));shown=Math.Min(list.Count,shown+24);more.Visibility=shown<list.Count?Visibility.Visible:Visibility.Collapsed;}
                more.Click+=(_,_)=>Run(Append);Append();
                actors.Children.Add(ArrowStrip(strip));
                actors.Children.Add(more);
            }
            catch(OperationCanceledException){if(AndroidCacheRuntime.IsPaused)detailDeferred=true;}
            catch(Exception e){if(Current(client,token,session))Status(actors,"演员资料暂不可用。",()=>{detailItem=null;Detail();});Report(e);}
        }
        UIElement ArrowStrip(StackPanel content)
        {
            var scroll=new ScrollViewer{Padding=new Thickness(2,4,2,4),Content=content,HorizontalScrollBarVisibility=ScrollBarVisibility.Hidden,VerticalScrollBarVisibility=ScrollBarVisibility.Disabled,HorizontalScrollMode=ScrollMode.Enabled,VerticalScrollMode=ScrollMode.Disabled};
            ReferenceSurfaces.Row(scroll);
            var grid=new Grid{ColumnSpacing=10};grid.ColumnDefinitions.Add(new(){Width=GridLength.Auto});grid.ColumnDefinitions.Add(new(){Width=new GridLength(1,GridUnitType.Star)});grid.ColumnDefinitions.Add(new(){Width=GridLength.Auto});
            var left=Action("‹",()=>scroll.ChangeView(Math.Max(0,scroll.HorizontalOffset-scroll.ViewportWidth*.8),null,null));var right=Action("›",()=>scroll.ChangeView(Math.Min(scroll.ScrollableWidth,scroll.HorizontalOffset+scroll.ViewportWidth*.8),null,null));
            left.VerticalAlignment=right.VerticalAlignment=VerticalAlignment.Center;DesktopReadability.Arrow(left,false);DesktopReadability.Arrow(right,true);
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(left,"上一组");Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(right,"下一组");
            Grid.SetColumn(scroll,1);Grid.SetColumn(right,2);grid.Children.Add(left);grid.Children.Add(scroll);grid.Children.Add(right);
            bool queued=false;
            void Update(){bool overflow=scroll.ScrollableWidth>1;left.Visibility=right.Visibility=overflow?Visibility.Visible:Visibility.Collapsed;grid.ColumnSpacing=overflow?10:0;left.IsEnabled=overflow&&scroll.HorizontalOffset>1;right.IsEnabled=overflow&&scroll.HorizontalOffset<scroll.ScrollableWidth-1;}
            void Queue(){if(queued)return;queued=true;scroll.DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low,()=>{queued=false;Run(Update);});}
            left.Visibility=right.Visibility=Visibility.Collapsed;scroll.Loaded+=(_,_)=>Queue();scroll.SizeChanged+=(_,_)=>Queue();content.SizeChanged+=(_,_)=>Queue();scroll.ViewChanged+=(_,_)=>Run(()=>{Update();foreach(var slot in slots.ToArray())QueueSlot(slot);});return grid;
        }
        UIElement PersonTile(EmbyPerson person,EmbyApiClient client,EmbySession session,CancellationToken token,bool search=false)
        {
            double tileWidth=search?128:177,tileHeight=search?192:266;
            var body=new StackPanel{Width=tileWidth,Spacing=6};var image=new Image{Width=tileWidth,Height=tileHeight,Stretch=search?Stretch.UniformToFill:Stretch.Uniform};
            var placeholder=new Grid{Width=tileWidth,Height=tileHeight};placeholder.Children.Add(new FontIcon{Glyph="\uE77B",FontSize=40,Foreground=DesktopVisuals.Brush(ReferenceSurfaces.Palette(element).Text)});placeholder.Children.Add(image);
            var frame=new Border{Child=placeholder,CornerRadius=new(11),Background=DesktopVisuals.Brush(ReferenceSurfaces.Palette(element).Hover)};
            var visual=Microsoft.UI.Xaml.Hosting.ElementCompositionPreview.GetElementVisual(placeholder);var geometry=visual.Compositor.CreateRoundedRectangleGeometry();geometry.Size=new((float)tileWidth,(float)tileHeight);geometry.CornerRadius=new(11,11);visual.Clip=visual.Compositor.CreateGeometricClip(geometry);
            body.Children.Add(frame);var name=Text(person.Name,14);name.TextWrapping=TextWrapping.NoWrap;name.TextTrimming=TextTrimming.CharacterEllipsis;name.TextAlignment=TextAlignment.Center;name.Foreground=DesktopVisuals.Brush(ReferenceSurfaces.Palette(element).Text);body.Children.Add(name);
            if(search||person.Role.Length>0){var role=Text(search?"演员":"饰演："+person.Role,13);role.TextWrapping=TextWrapping.NoWrap;role.TextTrimming=TextTrimming.CharacterEllipsis;role.TextAlignment=TextAlignment.Center;role.Foreground=DesktopVisuals.Brush(ReferenceSurfaces.Palette(element).Secondary);body.Children.Add(role);}
            var button=new Button{Content=body,Padding=new Thickness(0),Margin=new(0,0,7,0),Background=null,BorderThickness=new Thickness(0)};
            button.Click+=(_,_)=>Run(()=>{if(search)Select(person,client,session,token);else OpenPerson(person);});
            var slot=new Slot{Image=image,Tile=button,Person=person,Client=client,Session=session,Token=token};slots.Add(slot);
            button.EffectiveViewportChanged+=(_,_)=>QueueSlot(slot);
            button.SizeChanged+=(_,_)=>QueueSlot(slot);
            button.Loaded+=(_,_)=>{if(!slots.Contains(slot))slots.Add(slot);QueueSlot(slot);};
            button.Unloaded+=(_,_)=>{slot.Visible=false;slot.VisibilityVersion++;slots.Remove(slot);};return button;
        }
        void QueueSlot(Slot slot)
        {
            if(slot.Queued||slot.Token.IsCancellationRequested)return;slot.Queued=true;
            if(!element.DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low,()=>Run(()=>{
                slot.Queued=false;if(slot.Token.IsCancellationRequested)return;
                bool visible=VisibleTile(slot.Tile);if(slot.Visible!=visible){slot.Visible=visible;slot.VisibilityVersion++;if(visible)PhotoTrace(slot,"viewport-ready");}
                Load(slot);
            })))slot.Queued=false;
        }
        void PhotoTrace(Slot slot,string stage)
        {
            if(photoReports++<16)PlaybackTransport.Write("Info","Emby.People",$"图片阶段={stage}；可见={slot.Visible}；重试={slot.Retries}；代次={detailGeneration}；未记录来源或身份。");
        }
        async Task RetrySlot(Slot slot)
        {
            if(slot.RetryPending||slot.Retries>=2||!slot.Visible||slot.Image.Source!=null||!Current(slot.Client,slot.Token,slot.Session))return;
            slot.RetryPending=true;slot.Retries++;PhotoTrace(slot,"bounded-retry");
            try
            {
                var delay=AndroidCacheImages.Scheduler.RetryDelay(slot.Session.ServerId);
                await Task.Delay(delay>TimeSpan.FromSeconds(1)?delay:TimeSpan.FromSeconds(1),slot.Token);
                if(slot.Visible&&slot.Image.Source==null&&Current(slot.Client,slot.Token,slot.Session))QueueSlot(slot);
            }
            catch(OperationCanceledException){}
            finally{slot.RetryPending=false;}
        }
        static bool VisibleTile(FrameworkElement tile)
        {
            if(!tile.IsLoaded||tile.ActualWidth<=0||tile.ActualHeight<=0)return false;
            bool scroll=false;
            for(DependencyObject? node=tile;node!=null;node=VisualTreeHelper.GetParent(node))
            {
                if(node is UIElement{Visibility:not Visibility.Visible})return false;
                if(node is ScrollViewer viewer)
                {
                    scroll=true;
                    var bounds=tile.TransformToVisual(viewer).TransformBounds(new Windows.Foundation.Rect(0,0,tile.ActualWidth,tile.ActualHeight));
                    if(bounds.Right<=0||bounds.Bottom<=0||bounds.Left>=viewer.ActualWidth||bounds.Top>=viewer.ActualHeight)return false;
                }
            }
            return scroll;
        }
        async void Load(Slot slot)
        {
            if(slot.Running||slot.Token.IsCancellationRequested||slot.Person.ImageTag.Length==0||slot.Image.Source!=null||!Current(slot.Client,slot.Token,slot.Session))return;
            slot.Running=true;int visibilityVersion=slot.VisibilityVersion;
            try
            {
                var cache=Access.Get<PosterCacheService>(page,"_posterCache");var source=slot.Client.BuildImageUri(slot.Person.Id,slot.Person.ImageTag,160);
                var key=ActorDisk.Key(slot.Session.ServerId+"|"+slot.Session.ServerUrl,slot.Session.UserId,slot.Person.Id,slot.Person.ImageTag);
                var file=await Disk.Value.Get(key,async(path,t)=>{await DetailArtwork.WaitForPriorityImages(page,t);return await AndroidCacheImages.Scheduler.RunAsync(slot.Session.ServerId,
                    ct=>AndroidCacheImages.Download(cache,source,path,ct,PosterFetchPriority.Interactive,()=>slot.Visible),()=>slot.Visible,t);},()=>slot.Visible,(long)CacheGB*1024*1024*1024,slot.Token);
                if(file!=null&&Current(slot.Client,slot.Token,slot.Session)){
                    var bitmap=await (Task<BitmapImage?>)Access.Call(page,"LoadBitmapFromFileAsync",file,slot.Token)!;
                    if(bitmap!=null&&Current(slot.Client,slot.Token,slot.Session)){slot.Image.Source=bitmap;PhotoTrace(slot,"decoded-applied");}
                }
            }
            catch(OperationCanceledException){}
            catch(Exception e){Report(e);}
            finally
            {
                slot.Running=false;
                if(slot.Image.Source==null&&slot.Visible&&Current(slot.Client,slot.Token,slot.Session))
                {
                    if(slot.VisibilityVersion!=visibilityVersion)QueueSlot(slot);
                    else _=RetrySlot(slot);
                }
            }
        }
        void OpenPerson(EmbyPerson person)
        {
            Access.Set(page,"_searchResults",Array.Empty<EmbyItem>());((System.Collections.IList)Access.Call(page,"get_LatestItems")!).Clear();
            Access.Get<CancellationTokenSource?>(page,"_searchCancellation")?.Cancel();Access.Set(page,"_lastSearchLibraryId",null);Access.Set(page,"_lastSearchFavoritesOnly",false);Access.Call(page,"ShowLibraryView");Access.Set(page,"_activeSnapshotKey",null);Access.Set(page,"_lastSearchTerm",person.Name);
            Find<StackPanel>("SearchResultsPanel")!.Visibility=Visibility.Visible;
            Find<Grid>("BrowseResultsSection")?.SetValue(UIElement.VisibilityProperty,Visibility.Collapsed);
            Find<StackPanel>("ResumeSection")?.SetValue(UIElement.VisibilityProperty,Visibility.Collapsed);
            Find<ItemsControl>("HomeLibrarySectionsControl")?.SetValue(UIElement.VisibilityProperty,Visibility.Collapsed);
            if(Find<TextBlock>("PageTitleText") is {} title)title.Text=person.Name+"的作品";
            StartSearch(person.Name,true,person);
        }
        public void Search()
        {
            if(AndroidCacheRuntime.IsPaused)return;
            var source=Access.Get<CancellationTokenSource?>(page,"_searchCancellation");var current=Access.Get<string?>(page,"_lastSearchTerm");
            if(source==null||source.IsCancellationRequested||string.IsNullOrWhiteSpace(current)||Client==null)return;
            if(ReferenceEquals(hostSearch,source)&&term==current&&ReferenceEquals(searchClient,Client))return;
            hostSearch=source;StartSearch(current,false,null);
        }
        public void Edit(bool clear)
        {
            searchCts?.Cancel();filmCts?.Cancel();
            if(!clear)return;
            titleResults=titleMatches=Array.Empty<EmbyItem>();actorResults.Clear();matchedPeople.Clear();filmOffsets.Clear();filmIds.Clear();searchActors.Children.Clear();films.Children.Clear();
        }
        void StartSearch(string value,bool direct,EmbyPerson? person)
        {
            searchCts?.Cancel();searchCts?.Dispose();searchCts=direct?new():CancellationTokenSource.CreateLinkedTokenSource(hostSearch?.Token??CancellationToken.None);filmCts?.Cancel();
            var client=Client;var session=Session;if(client==null||session==null||AndroidCacheRuntime.IsPaused)return;
            searchClient=client;term=value;selectedPerson=null;peopleOffset=0;filmIds.Clear();filmOffsets.Clear();matchedPeople.Clear();actorResults.Clear();titleResults=titleMatches=Access.Get<IReadOnlyList<EmbyItem>>(page,"_searchResults");
            if(!searchAttached&&Find<StackPanel>("SearchResultsPanel") is {} target){target.Orientation=Orientation.Vertical;target.HorizontalAlignment=HorizontalAlignment.Stretch;target.Children.Add(searchActors);target.Children.Add(films);searchAttached=true;}
            films.Children.Clear();searchActors.Children.Clear();actorRow=null;
            if(direct&&person!=null){searchActors.Children.Add(Text(person.Name+"的作品",18));Select(person,client,session,searchCts.Token);}
            else _=FindPeople(client,session,value,false,searchCts.Token);
        }
        async Task FindPeople(EmbyApiClient client,EmbySession session,string value,bool append,CancellationToken token)
        {
            if(!append)Status(searchActors,"正在匹配本地演员资料…");
            try
            {
                var result=await LocalMetadata.Search(page,client,value,peopleOffset,token);
                if(!SearchCurrent(client,token,session)||term!=value)return;
                if(!append&&selectedPerson==null){
                    var extra=await LocalMetadata.SupplementTitles(page,client,value,token);
                    if(!SearchCurrent(client,token,session)||term!=value||selectedPerson!=null)return;
                    titleResults=titleMatches=titleMatches.Concat(extra).DistinctBy(i=>i.Id,StringComparer.OrdinalIgnoreCase)
                        .OrderByDescending(i=>Math.Max(SearchMatching.Score(i.Name,value),SearchMatching.Score(i.OriginalTitle,value)))
                        .ThenBy(i=>i.Name,StringComparer.CurrentCultureIgnoreCase).ToArray();Publish();
                }
                if(!append&&result.People.Count==0&&result.NextOffset>=result.Total){searchActors.Children.Clear();searchActors.Children.Add(Text("未匹配到演员"));films.Children.Clear();return;}
                if(!append){searchActors.Children.Clear();searchActors.Children.Add(Text("演员",18));}
                var row=actorRow??=Row();
                foreach(var person in result.People){if(matchedPeople.All(p=>p.Id!=person.Id)){matchedPeople.Add(person);row.Children.Add(PersonTile(person,client,session,token,true));}}
                if(result.People.Count>0&&row.Parent==null)searchActors.Children.Add(ArrowStrip(row));peopleOffset=result.NextOffset;
                if(peopleOffset<result.Total){var more=Action("加载更多演员",()=>{});more.Click+=async(_,_)=>{more.IsEnabled=false;await FindPeople(client,session,value,true,token);more.Visibility=Visibility.Collapsed;};searchActors.Children.Add(more);}

            }
            catch(OperationCanceledException){}
            catch(Exception e){if(SearchCurrent(client,token,session)){if(append){searchActors.Children.Add(Text("更多演员读取失败，已有结果保留。"));searchActors.Children.Add(Action("重试更多演员",()=>_=FindPeople(client,session,value,true,token)));}else Status(searchActors,"演员搜索暂不可用，片名结果保留。",()=>StartSearch(value,false,null));}Report(e);}
        }
        void Select(EmbyPerson? person,EmbyApiClient client,EmbySession session,CancellationToken token)
        {
            if(!SearchCurrent(client,token,session))return;
            filmCts?.Cancel();filmCts?.Dispose();filmCts=CancellationTokenSource.CreateLinkedTokenSource(token);selectedPerson=person?.Id;filmOffsets.Clear();filmIds.Clear();actorResults.Clear();titleResults=person==null?titleMatches:Array.Empty<EmbyItem>();films.Children.Clear();((System.Collections.IList)Access.Call(page,"get_LatestItems")!).Clear();Publish();
            if(person!=null)_=LoadFilms(person,client,session,filmCts.Token);
            else if(Find<TextBlock>("ContentSectionTitle") is {} heading)heading.Text="“"+term+"”的片名搜索结果";
        }
        void Publish()
        {
            var all=titleResults.Concat(actorResults).DistinctBy(i=>i.Id,StringComparer.OrdinalIgnoreCase).ToArray();
            var merged=all;var cards=(System.Collections.IList)Access.Call(page,"get_LatestItems")!;
            if(cards.Count>merged.Length||cards.Cast<object>().Where((card,i)=>!string.Equals((card.GetType().GetProperty("Item")?.GetValue(card) as EmbyItem)?.Id,merged[i].Id,StringComparison.OrdinalIgnoreCase)).Any())cards.Clear();
            Access.Set(page,"_searchResults",merged);Access.Call(page,"AppendSearchPage");
            if(Find<FrameworkElement>("EmptyState") is {} empty)empty.Visibility=merged.Length>0?Visibility.Collapsed:Visibility.Visible;
            if(Find<Grid>("BrowseResultsSection") is {} browse)browse.Visibility=Visibility.Visible;
        }
        async Task LoadFilms(EmbyPerson? person,EmbyApiClient client,EmbySession session,CancellationToken token)
        {
            if(!SearchCurrent(client,token,session))return;
            films.Children.Clear();
            if(person!=null)films.Children.Add(Action(person.Name+"的作品 · 返回片名结果",()=>{if(searchCts is {IsCancellationRequested:false})Select(null,client,session,searchCts.Token);}));
            if(person!=null&&Find<TextBlock>("ContentSectionTitle") is {} heading)heading.Text=person.Name+"的作品";
            var note=Text("正在读取演员作品…");films.Children.Add(note);
            try
            {
                var preferences=Access.Get<UserPreferences>(page,"_preferences");var exp=preferences.Experience??new ExperiencePreferences();
                string scope=(string)Access.Call(page,"get_HomeScope")!;
                var hidden=exp.HiddenHomeSections?.GetValueOrDefault(scope)??[];
                string? library=Access.Get<string?>(page,"_lastSearchLibraryId");bool favorites=Access.Get<bool>(page,"_lastSearchFavoritesOnly");
                var libraries=Access.Get<List<EmbyItem>>(page,"_libraryViews").Where(l=>!hidden.Contains(l.Id)&&(library==null||l.Id==library)).ToArray();
                var people=person!=null?new[]{person}:matchedPeople.ToArray();bool more=false;
                // One bounded page per actor and library. No catalogue crawl or per-card lookup.
                foreach(var actor in people)
                foreach(var lib in libraries)
                {
                    string key=actor.Id+"|"+lib.Id;int offset=filmOffsets.GetValueOrDefault(key);if(offset==-1)continue;
                    var result=await LocalMetadata.Films(page,client,actor.Id,lib.Id,offset,favorites,token);
                    if(!SearchCurrent(client,token,session)||selectedPerson!=person?.Id)return;
                    int next=offset+result.Items.Count;bool remaining=result.Items.Count>0&&next<result.Total;filmOffsets[key]=remaining?next:-1;more|=remaining;
                    var available=UnavailableMediaItemPolicy.Exclude(result.Items,Access.Get<HashSet<string>>(page,"_unavailableMediaKeys"));
                    foreach(var item in available.Where(i=>filmIds.Add(i.Id)))actorResults.Add(item);
                    Publish();
                }
                if(!SearchCurrent(client,token,session))return;films.Children.Remove(note);
                if(actorResults.Count==0&&titleResults.Count==0)films.Children.Add(Text("当前范围没有匹配的影视资源。"));
                if(more){var button=Action("加载更多作品",()=>{});button.Click+=async(_,_)=>{button.IsEnabled=false;await LoadFilms(person,client,session,token);};films.Children.Add(button);}
            }
            catch(OperationCanceledException){}
            catch(Exception e){if(SearchCurrent(client,token,session)){films.Children.Remove(note);films.Children.Add(Text("部分作品读取失败，已有结果保留。"));films.Children.Add(Action("重试",()=>_=LoadFilms(person,client,session,token)));}Report(e);}
        }
        public void Settings()
        {
            if(settingsBuilt||Find<Border>("CacheSettingsSection")?.Child is not StackPanel root)return;settingsBuilt=true;
            root.Children.Add(Text("影视名称、演员及作品关系保存在本地，随媒体库同步更新；季与选集按需保存，搜索优先使用本地文字资料。",12));
            root.Children.Add(Text("演员图片缓存",18));var combo=new ComboBox{Header="缓存容量",MinWidth=200};foreach(int gb in new[]{1,3,5})combo.Items.Add(gb+" GB");combo.SelectedIndex=Array.IndexOf(new[]{1,3,5},CacheGB);
            var status=Text("独立目录 Cache\\Actors；只缓存 Emby 演员照片，不占用海报和大图额度。",12);
            combo.SelectionChanged+=async(_,_)=>
            {
                int old=CacheGB;try{int selected=new[]{1,3,5}[Math.Max(0,combo.SelectedIndex)];Directory.CreateDirectory(Path.GetDirectoryName(Preferences)!);string tmp=Preferences+"."+Guid.NewGuid().ToString("N")+".tmp";try{await File.WriteAllTextAsync(tmp,JsonSerializer.Serialize(selected));File.Move(tmp,Preferences,true);}finally{if(File.Exists(tmp))File.Delete(tmp);}limit=selected;await Disk.Value.Trim((long)selected*1024*1024*1024);status.Text="演员缓存容量已保存。";}catch(Exception e){status.Text="保存或清理未完成："+e.GetType().Name;combo.SelectedIndex=Array.IndexOf(new[]{1,3,5},old);}
            };
            root.Children.Add(combo);root.Children.Add(status);var clear=new Button{Content="清理演员图片"};clear.Click+=async(_,_)=>{clear.IsEnabled=false;try{await Disk.Value.Clear();status.Text="演员图片已清理，其他缓存与个人资料保持。";}catch(Exception e){status.Text="清理未完成："+e.GetType().Name;}finally{clear.IsEnabled=true;}};root.Children.Add(clear);
        }
    }
}
