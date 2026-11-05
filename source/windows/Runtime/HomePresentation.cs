using System.Collections;
using System.Collections.Specialized;
using System.Runtime.CompilerServices;
using EmbyDesktop.Core.Models;
using EmbyDesktop.Core.Services;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Data;
using Microsoft.UI.Xaml.Media;

namespace Yingyu.Update;

// Discovery uses already synchronized local metadata. Only the two selected
// tiles join the existing viewport/cache image pipeline; no metadata fetches.
internal static class HomePresentation
{
    static readonly ConditionalWeakTable<FrameworkElement,State> States=new();
    internal static void Apply(FrameworkElement page,DesktopThemePalette palette)=>States.GetValue(page,p=>new State(p)).Apply(palette);
    internal static void Refresh(FrameworkElement page){if(States.TryGetValue(page,out var state))state.Refresh();}
    internal static void Header(FrameworkElement page){if(States.TryGetValue(page,out var state))state.Header();}
    internal static Task<EmbyItem[]> Choose(IEnumerable<EmbyItem> items,string path,CancellationToken token)=>ChooseCached(items,path,token,null);
    internal static Task<EmbyItem[]> ChooseCached(IEnumerable<EmbyItem> items,string path,CancellationToken token,Func<EmbyItem,bool>? cached)=>Task.Run(async()=>{
        token.ThrowIfCancellationRequested();var seen=new HashSet<string>(StringComparer.OrdinalIgnoreCase);var picks=new List<EmbyItem>(4);var warm=new List<EmbyItem>(4);int count=0,warmCount=0;
        foreach(var item in items){token.ThrowIfCancellationRequested();if(item.Type is not ("Movie" or "Series")||string.IsNullOrWhiteSpace(item.Id)||!AndroidCacheCards.HasLandscape(item)||!seen.Add(item.Id))continue;bool hit=cached?.Invoke(item)==true;var pool=hit?warm:picks;int total=hit?++warmCount:++count;if(pool.Count<4)pool.Add(item);else{int at=Random.Shared.Next(total);if(at<4)pool[at]=item;}}
        picks=warm.Concat(picks.Take(4-warm.Count)).ToList();
        for(int i=picks.Count-1;i>0;i--){int at=Random.Shared.Next(i+1);(picks[i],picks[at])=(picks[at],picks[i]);}
        string[] previous=[];try{if(File.Exists(path))previous=JsonSerializer.Deserialize<string[]>(await File.ReadAllTextAsync(path,token))??[];}catch(Exception e)when(e is IOException or JsonException or UnauthorizedAccessException){}
        if(picks.Count>1&&picks.Select(i=>i.Id).SequenceEqual(previous,StringComparer.OrdinalIgnoreCase)){var first=picks[0];picks.RemoveAt(0);picks.Add(first);}
        token.ThrowIfCancellationRequested();try{Directory.CreateDirectory(Path.GetDirectoryName(path)!);string temp=path+"."+Guid.NewGuid().ToString("N")+".tmp";try{await File.WriteAllTextAsync(temp,JsonSerializer.Serialize(picks.Select(i=>i.Id)),token);token.ThrowIfCancellationRequested();File.Move(temp,path,true);}finally{if(File.Exists(temp))File.Delete(temp);}}catch(Exception e)when(e is IOException or UnauthorizedAccessException){}
        return picks.ToArray();
    },token);
    internal static Func<EmbyItem,bool> CachedInventory(PosterCacheService cache,EmbySession session,CancellationToken token)
    {
        var paths=new HashSet<string>(StringComparer.OrdinalIgnoreCase);var directories=new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach(string root in new[]{CachePaths.Artwork,CachePaths.Posters}){
            if(!Directory.Exists(root))continue;
            try{foreach(string file in Directory.EnumerateFiles(root,"*.image",new EnumerationOptions{RecurseSubdirectories=true,AttributesToSkip=FileAttributes.ReparsePoint,IgnoreInaccessible=true})){
                token.ThrowIfCancellationRequested();var info=new FileInfo(file);if(info.Exists&&info.Length>0){paths.Add(info.FullName);directories.Add(info.DirectoryName!);}
            }}catch(Exception e)when(e is IOException or UnauthorizedAccessException){}
        }
        return item=>{
            token.ThrowIfCancellationRequested();if(paths.Count==0)return false;
            foreach(var c in MediaArtworkPolicy.GetLandscapeCandidates(item).Where(c=>c.ImageType is "Thumb" or "Backdrop"))
            foreach(int width in new[]{1280,360,480,700,720,960,1920,2560})
            foreach(int quality in new[]{85,90})
            foreach(var retention in new[]{PosterCacheRetention.Detail,PosterCacheRetention.Browse}){
                var request=new PosterCacheRequest(session.ServerId,session.UserId,c.ItemId,c.ImageType,c.ImageTag,width,quality,retention);
                if(!directories.Contains(AndroidCacheImages.DirectoryFor(cache,request)))continue;
                var exact=(string?)Access.Call(cache,"BuildExactPath",request);if(exact!=null&&paths.Contains(exact))return true;
            }
            return false;
        };
    }
    internal static Task WaitForHero(object page,CancellationToken token){
        if(page is not FrameworkElement element)return Task.CompletedTask;
        var state=States.GetValue(element,p=>new State(p));
        state.Apply(DesktopThemePalette.Resolve(DesktopTheme.Options,element.ActualTheme==ElementTheme.Dark));
        return state.WaitForHero(token);
    }
    sealed class State
    {
        const int DisplayCount=6;
        readonly StackPanel recommendation=new(){Name="HomeDailyRecommendation",Spacing=10};
        readonly TextBlock heading=new(){Text="今日精选",FontSize=20,FontWeight=Microsoft.UI.Text.FontWeights.SemiBold};
        readonly HeroCarousel carousel;
        readonly Microsoft.UI.Dispatching.DispatcherQueueTimer midnight;
        DateTime day=DateTime.Today;
        readonly FrameworkElement page;
        readonly Grid mosaic=new(){Name="HomeCinemaMosaic",ColumnSpacing=14,RowSpacing=14,Margin=new(0,4,0,28),Visibility=Visibility.Collapsed};
        object[] models=[];object[]? discoveries;readonly HashSet<object> owned=new(ReferenceEqualityComparer.Instance);
        CancellationTokenSource? selection;object? selectionOwner;object? owner;DesktopThemePalette last;bool queued;
        bool bootstrapStarted,bootstrapDone,planningStarted,planningRunning,freshRunning,freshAttempted,resetScroll;volatile bool visible;
        TaskCompletionSource<bool> heroReady=new(TaskCreationOptions.RunContinuationsAsynchronously);
        internal async Task WaitForHero(CancellationToken token){if(!visible)return;try{await heroReady.Task.WaitAsync(TimeSpan.FromSeconds(3),token);}catch(TimeoutException){}}
        void Reset(){heroReady.TrySetResult(true);heroReady=new(TaskCreationOptions.RunContinuationsAsynchronously);}
        void Select(IEnumerable<EmbyItem> items){
            if(discoveries is {Length:>0})return;
            var selected=items.Where(AndroidCacheCards.HasLandscape).DistinctBy(i=>i.Id,StringComparer.OrdinalIgnoreCase).Take(DisplayCount).ToArray();
            if(selected.Length==0)return;
            discoveries=selected.Select(item=>Model(item,new Microsoft.UI.Xaml.Media.Imaging.BitmapImage())).ToArray();
            fresh=selected;freshCards=discoveries.Cast<object?>().ToArray();freshAttempted=false;Queue();
        }
        HomeStartupDeck.Entry[] pool=[];EmbyItem[] fresh=[];object?[] freshCards=[];object? posterGeneration;readonly SemaphoreSlim saveGate=new(1,1);
        T? Find<T>(string name) where T:class=>Access.Get<object?>(page,name) as T;
        IEnumerable<object> Values(string name)=>(Access.Call(page,"get_"+name) as IEnumerable)?.Cast<object>()??[];
        public State(FrameworkElement page)
        {
            this.page=page;
            carousel=new HeroCarousel(page.DispatcherQueue);recommendation.Children.Add(heading);recommendation.Children.Add(mosaic);
            midnight=page.DispatcherQueue.CreateTimer();midnight.IsRepeating=false;
            midnight.Tick+=(_,_)=>{CheckDay();ScheduleMidnight();};

            foreach(string name in new[]{"ResumeItems","HomeLibrarySections"})if(Access.Call(page,"get_"+name) is INotifyCollectionChanged source)source.CollectionChanged+=(_,_)=>Queue();
            page.Unloaded+=(_,_)=>{midnight.Stop();carousel.Active(false);visible=false;heroReady.TrySetResult(true);selection?.Cancel();selection?.Dispose();selection=null;bootstrapStarted=bootstrapDone=planningStarted=planningRunning=freshRunning=freshAttempted=false;discoveries=null;owned.Clear();pool=[];fresh=[];freshCards=[];models=[];mosaic.Children.Clear();mosaic.Visibility=Visibility.Collapsed;owner=selectionOwner=null;};
            page.Loaded+=(_,_)=>{CheckDay();ScheduleMidnight();Queue();};
        }
        void ScheduleMidnight(){midnight.Stop();if(!page.IsLoaded)return;var delay=DateTime.Today.AddDays(1)-DateTime.Now;midnight.Interval=TimeSpan.FromMilliseconds(Math.Clamp(delay.TotalMilliseconds,50,60000));midnight.Start();}
        void CheckDay(){if(day==DateTime.Today)return;day=DateTime.Today;selection?.Cancel();selection?.Dispose();selectionOwner=null;selection=null;carousel.Active(false);Queue();}
        internal void Refresh()=>Queue();
        void Queue()
        {
            if(queued||!page.IsLoaded)return;queued=true;
            if(!page.DispatcherQueue.TryEnqueue(()=>{queued=false;if(page.IsLoaded)Apply(last);}))queued=false;
        }
        bool IsHome=>Access.Get<object?>(page,"_activeNavigation")?.ToString()=="Home"&&Access.Get<string?>(page,"_activeSnapshotKey")=="home"
                &&Find<Grid>("LibraryView")?.Visibility==Visibility.Visible&&Find<Grid>("DetailView")?.Visibility!=Visibility.Visible&&Find<Grid>("SettingsView")?.Visibility!=Visibility.Visible
                &&Find<StackPanel>("SearchResultsPanel")?.Visibility!=Visibility.Visible;
        internal void Header()
        {
            // SizeChanged must only normalize the title, never refresh the page layout.
            if(IsHome&&Find<TextBlock>("PageTitleText") is {} title){
                if(title.Text!="首页")title.Text="首页";
                if(title.FontSize!=32)title.FontSize=32;
            }
        }
        internal void Apply(DesktopThemePalette p)
        {
            CheckDay();ScheduleMidnight();bool home=IsHome;heading.Foreground=DesktopVisuals.Brush(p.Text);
            bool paletteChanged=last!=p;last=p;bool entered=home&&!visible;visible=home;
            var account=Access.Get<object?>(page,"_session");
            if(!ReferenceEquals(selectionOwner,account)){
                resetScroll|=selectionOwner is EmbySession&&account is EmbySession;
                selection?.Cancel();selection?.Dispose();selection=account==null?null:new();selectionOwner=account;Reset();
                bootstrapStarted=bootstrapDone=planningStarted=planningRunning=freshRunning=freshAttempted=false;discoveries=null;owned.Clear();pool=[];fresh=[];freshCards=[];models=[];mosaic.Children.Clear();
            }
            if(entered||!ReferenceEquals(posterGeneration,Access.Get<object?>(page,"_posterLoadCts"))){freshAttempted=false;if(home&&(discoveries==null||discoveries.Any(card=>!Ready(card))))Reset();posterGeneration=Access.Get<object?>(page,"_posterLoadCts");}
            if(page.IsLoaded&&account is EmbySession session&&selection!=null&&!bootstrapStarted){bootstrapStarted=true;_=Bootstrap(session,selection.Token);}
            var snapshot=(LocalSearchIndexSnapshot?)Access.Call(page,"get__localSearchIndex");
            if(bootstrapDone&&!planningStarted&&!AndroidCacheRuntime.IsPaused&&account is EmbySession planning&&selection!=null&&snapshot is {} local&&local.ServerId==planning.ServerId&&local.UserId==planning.UserId&&local.Entries.Count>0){
                planningStarted=true;_=Plan(local,planning,selection.Token);
            }
            if(!home){carousel.Active(false);recommendation.Visibility=Visibility.Collapsed;heroReady.TrySetResult(true);mosaic.Visibility=Visibility.Collapsed;if(!ReferenceEquals(account,owner)){models=[];mosaic.Children.Clear();owner=account;}return;}
            // Content is available before WinUI establishes the first visual parent.
            // Membership also prevents duplicate insertion during that initial layout.
            if(Find<ScrollViewer>("MainContentScrollViewer") is not {Content:StackPanel host} scroll)return;
            if(resetScroll){resetScroll=false;scroll.ChangeView(null,0,null,true);}
            if(!host.Children.Contains(recommendation))
            {
                int anchor=Find<StackPanel>("ResumeSection") is {} resume?host.Children.IndexOf(resume):-1;
                if(anchor<0&&Find<ItemsControl>("HomeLibrarySectionsControl") is {} sections)anchor=host.Children.IndexOf(sections);
                if(anchor>=0)host.Children.Insert(anchor,recommendation);
                else return;
            }
            recommendation.Visibility=Visibility.Visible;
            var available=(Find<StackPanel>("ResumeSection")?.Visibility==Visibility.Visible?Values("ResumeItems"):[]).Concat(Find<ItemsControl>("HomeLibrarySectionsControl")?.Visibility==Visibility.Visible?Values("HomeLibrarySections").SelectMany(section=>(section.GetType().GetProperty("Items")?.GetValue(section) as IEnumerable)?.Cast<object>()??[]):[])
                .Where(card=>card.GetType().GetProperty("Item")?.GetValue(card) is EmbyItem{Type:"Movie" or "Series" or "Episode"})
                .DistinctBy(card=>((EmbyItem)card.GetType().GetProperty("Item")!.GetValue(card)!).Id).ToArray();
            // Commit each slot's identity before loading. No temporary films or later promotion.
            if(bootstrapDone&&!planningRunning&&!Access.Get<bool>(page,"_profileSwitchInProgress")&&discoveries is not {Length:>0}&&available.Length>0){
                // First-use fallback commits the original visible cards once. Later catalogue sync never swaps them.
                var candidates=available.Select(CardItem).Where(i=>i.Type is "Movie" or "Series").OrderBy(_=>Random.Shared.Next()).ToArray();
                Select(candidates);if(account is EmbySession fallback&&selection!=null)_=SaveFallback(fallback,selection.Token);
            }
            if(discoveries!=null&&discoveries.Any(card=>!owned.Contains(card))){
                discoveries=discoveries.Where(card=>owned.Contains(card)||available.Contains(card)).ToArray();
            }
            if(fresh.Length>0&&!freshRunning&&!freshAttempted&&account is EmbySession active&&selection!=null&&!AndroidCacheRuntime.IsPaused){freshRunning=freshAttempted=true;_=LoadFresh(active,selection.Token);}
            var cards=discoveries??[];bool rebuild=!ReferenceEquals(owner,account);owner=account;
            double height=Math.Clamp((page.ActualWidth-260)*.22,200,360);if(Math.Abs(mosaic.Height-height)>.5||double.IsNaN(mosaic.Height))mosaic.Height=height;
            if(rebuild){mosaic.Children.Clear();models=[];}
            bool changed=!cards.SequenceEqual(models);
            if(rebuild||changed||mosaic.Children.Count==0){
                mosaic.Children.Clear();
                mosaic.Children.Add(cards.Length>0?Tile(cards[0],p,true):new Border{Name="HomeCinemaPlaceholder",CornerRadius=new(14),Background=DesktopVisuals.Brush(p.Surface),IsHitTestVisible=false});
                if(cards.Length>1){carousel.Set(cards.Skip(1).Select(c=>Tile(c,p,false)).ToArray());mosaic.Children.Add(carousel.Root);}
                else{carousel.Set([]);mosaic.Children.Add(new Border{Name="HomeCinemaPlaceholder",CornerRadius=new(14),Background=DesktopVisuals.Brush(p.Surface),IsHitTestVisible=false});}
                mosaic.ColumnDefinitions.Clear();mosaic.ColumnDefinitions.Add(new(){Width=new(41,GridUnitType.Star)});mosaic.ColumnDefinitions.Add(new(){Width=new(59,GridUnitType.Star)});
                Grid.SetColumn((FrameworkElement)mosaic.Children[0],0);Grid.SetColumn((FrameworkElement)mosaic.Children[1],1);
                models=cards;
            }
            foreach(var placeholder in mosaic.Children.OfType<Border>())placeholder.Background=DesktopVisuals.Brush(p.Surface);
            foreach(var tile in UiElements.Descendants(mosaic).OfType<Button>().Where(b=>b.DataContext!=null))tile.CornerRadius=new(Math.Min(DesktopTheme.Options.Radius,14));
            mosaic.Visibility=Visibility.Visible;carousel.Active(true);
            if(Find<Grid>("LibraryHeaderGrid") is {} header)header.Margin=new(32,20,32,14);
            if(Find<TextBlock>("PageTitleText") is {} title){title.Text="首页";title.FontSize=32;title.FontWeight=Microsoft.UI.Text.FontWeights.SemiBold;}
            if(Find<ScrollViewer>("MainContentScrollViewer") is {} content)content.Padding=new(32,0,32,32);
            if(Find<Grid>("ShellGrid") is {} shell&&shell.Children.OfType<Border>().FirstOrDefault(b=>b.Name=="DesktopAccountToolbar") is {} bar){bar.Background=DesktopVisuals.Brush(0);bar.BorderThickness=new(0);}
        }
        static EmbyItem CardItem(object card)=>(EmbyItem)card.GetType().GetProperty("Item")!.GetValue(card)!;
        static string ItemKey(object card){var item=CardItem(card);return item.Type is "Episode" or "Season"&&!string.IsNullOrWhiteSpace(item.SeriesId)?item.SeriesId!:item.Id;}
        static bool Ready(object card)=>card.GetType().GetProperty("Poster")!.GetValue(card) is Microsoft.UI.Xaml.Media.Imaging.BitmapSource{PixelWidth:>0,PixelHeight:>0};
        bool Current(EmbySession session,CancellationToken token)=>!token.IsCancellationRequested&&ReferenceEquals(session,Access.Get<object?>(page,"_session"))&&page.IsLoaded;
        object Model(EmbyItem item,Microsoft.UI.Xaml.Media.Imaging.BitmapImage image){var card=Activator.CreateInstance(page.GetType().Assembly.GetType("EmbyDesktop.ViewModels.MediaCardViewModel",true)!)!;card.GetType().GetProperty("Item")!.SetValue(card,item);card.GetType().GetProperty("PreferLandscapeArtwork")!.SetValue(card,true);card.GetType().GetProperty("Poster")!.SetValue(card,image);owned.Add(card);return card;}
        void Warn(Exception e){try{PlaybackTransport.Write("Warning","Home.Startup","本地首页准备未完成，保留现有图片；"+e.GetType().Name);}catch(Exception){}}
        async Task Bootstrap(EmbySession session,CancellationToken token){
            try{
                var cache=Access.Get<PosterCacheService>(page,"_posterCache");var ready=await HomeStartupDeck.Read(cache,session,token);if(!Current(session,token))return;
                pool=ready.Pool;
                if(ready.SameDay)Select(ready.Picks.Select(e=>e.Item));
                // Prefer the already available catalogue, without waiting for network or decoding.
                var snapshot=(LocalSearchIndexSnapshot?)Access.Call(page,"get__localSearchIndex");
                if(snapshot is {} local&&local.ServerId==session.ServerId&&local.UserId==session.UserId&&local.Entries.Count>0){planningStarted=true;await Plan(local,session,token);}
                else {Select(ready.Picks.Select(e=>e.Item));await Save(session,token);}
            }catch(OperationCanceledException){}catch(Exception e){Warn(e);}
            finally{if(Current(session,token)){bootstrapDone=true;Queue();}}
        }
        async Task Plan(LocalSearchIndexSnapshot snapshot,EmbySession session,CancellationToken token){
            planningRunning=true;
            try{
                var shown=(discoveries??[]).Select(ItemKey).ToHashSet(StringComparer.OrdinalIgnoreCase);var cache=Access.Get<PosterCacheService>(page,"_posterCache");
                var plan=await HomeStartupDeck.Build(cache,session,snapshot,shown,token);if(!Current(session,token))return;
                pool=plan.Pool;Select(plan.Fresh);await Save(session,token);Queue();
            }catch(OperationCanceledException){}catch(Exception e){Warn(e);}
            finally{if(Current(session,token)){planningRunning=false;if(discoveries is not {Length:>0})heroReady.TrySetResult(true);Queue();}}
        }
        async Task SaveFallback(EmbySession session,CancellationToken token){try{await Save(session,token);}catch(OperationCanceledException){}catch(Exception e){Warn(e);}}
        async Task Save(EmbySession session,CancellationToken token){
            var cache=Access.Get<PosterCacheService>(page,"_posterCache");var entries=(discoveries??[]).Select(CardItem).Select(HomeStartupDeck.Candidate).OfType<HomeStartupDeck.Entry>().Concat(pool).DistinctBy(e=>e.Item.Id,StringComparer.OrdinalIgnoreCase).Take(64).ToArray();var ids=(discoveries??[]).Select(ItemKey).ToArray();
            await saveGate.WaitAsync(token);try{await HomeStartupDeck.Save(cache,session,entries,ids,token,day);}finally{saveGate.Release();}
        }
        async Task LoadFresh(EmbySession session,CancellationToken token){
            var generation=Access.Get<CancellationTokenSource?>(page,"_posterLoadCts");var client=Access.Get<object?>(page,"_client");
            using var cancel=CancellationTokenSource.CreateLinkedTokenSource(token,generation?.Token??CancellationToken.None);
            bool Needed()=>visible&&!cancel.IsCancellationRequested&&ReferenceEquals(session,Access.Get<object?>(page,"_session"))&&ReferenceEquals(client,Access.Get<object?>(page,"_client"))&&ReferenceEquals(generation,Access.Get<CancellationTokenSource?>(page,"_posterLoadCts"));
            var targets=fresh.ToArray();var results=freshCards;int index=-1;
            // Start the first visible carousel image first, then the left hero.
            // Hidden slides remain eager queued work on the same two workers.
            var order=Enumerable.Range(0,targets.Length).OrderBy(i=>i==1?-1:i).ToArray();
            async Task Worker(){while(true){int next=Interlocked.Increment(ref index);if(next>=order.Length)return;int at=order[next];if(results[at] is {} loaded&&Ready(loaded))continue;
                try{
                    var item=targets[at];if(!Needed())return;var image=await AndroidCacheCards.CachedHomeLandscape(page,item,cancel.Token);
                    if(image==null)foreach(var candidate in MediaArtworkPolicy.GetLandscapeCandidates(item).Where(c=>c.ImageType is "Thumb" or "Backdrop")){
                        if(!Needed())return;
                        image=await AndroidCacheCards.Bitmap(page,item,candidate.ImageType,1280,cancel.Token,candidate.ItemId,candidate.ImageTag,PosterFetchPriority.Interactive,PosterCacheRetention.Detail,Needed,null);
                        if(image is {PixelWidth:>0,PixelHeight:>0}&&ResumeArtwork.IsLandscape(image.PixelWidth,image.PixelHeight))break;image=null;
                    }
                    if(image==null||!Needed()||!Current(session,token))continue;
                    // Keep the same model, title, button and hit target; fill only its bitmap.
                    if(results[at] is {} card&&(discoveries??[]).Contains(card))card.GetType().GetProperty("Poster")!.SetValue(card,image);

                }catch(OperationCanceledException){}catch(Exception e){Warn(e);}
            }}
            try{await Task.WhenAll(Worker(),Worker());}finally{if(Current(session,token)){freshRunning=false;if(ReferenceEquals(generation,Access.Get<CancellationTokenSource?>(page,"_posterLoadCts")))heroReady.TrySetResult(true);Queue();}}
        }
        async Task Open(object card,Button button)
        {
            if(!ReferenceEquals(owner,Access.Get<object?>(page,"_session"))||Access.Get<bool>(page,"_detailOpenInProgress"))return;
            var client=Access.Get<object?>(page,"_client");var session=owner;
            Access.Set(page,"_detailOpenInProgress",true);
            try
            {
                if(card.GetType().GetProperty("Item")?.GetValue(card) is not EmbyItem source)return;
                var target=await (Task<(EmbyItem Detail,string? FocusEpisodeId,string? FocusSeasonId)>)Access.Call(page,"ResolveDetailTargetAsync",source)!;
                if(!button.IsLoaded||!ReferenceEquals(session,Access.Get<object?>(page,"_session"))||!ReferenceEquals(client,Access.Get<object?>(page,"_client"))||Find<Grid>("LibraryView")?.Visibility!=Visibility.Visible||Find<Grid>("SettingsView")?.Visibility==Visibility.Visible)return;
                await (Task)Access.Call(page,"ShowDetailAsync",target.Detail,null,null,target.FocusEpisodeId,target.FocusSeasonId)!;
            }
            catch(Exception e){try{PlaybackTransport.Write("Warning","Home.Presentation","首页详情未打开；"+e.GetType().Name);Access.Call(page,"ShowLibraryStatus","详情暂时无法打开，请稍后重试。");}catch(Exception){}}
            finally{Access.Set(page,"_detailOpenInProgress",false);}
        }
        Button Tile(object card,DesktopThemePalette p,bool lead)
        {
            var item=(EmbyItem)card.GetType().GetProperty("Item")!.GetValue(card)!;
            var button=new Button{Name=lead?"HomeCinemaLead":"HomeCinemaTile",Padding=new(0),BorderThickness=new(0),CornerRadius=new(Math.Min(DesktopTheme.Options.Radius,14)),HorizontalAlignment=HorizontalAlignment.Stretch,VerticalAlignment=VerticalAlignment.Stretch,HorizontalContentAlignment=HorizontalAlignment.Stretch,VerticalContentAlignment=VerticalAlignment.Stretch,DataContext=card};
            var surface=new Grid{Background=DesktopVisuals.Brush(p.Surface)};
            var image=new Image{Stretch=Stretch.UniformToFill};image.SetBinding(Image.SourceProperty,new Binding{Source=card,Path=new("Poster"),Mode=BindingMode.OneWay});surface.Children.Add(image);
            var shade=new LinearGradientBrush{StartPoint=new(0,0),EndPoint=new(1,0)};
            shade.GradientStops.Add(new(){Offset=0,Color=DesktopMaterial.Color(0x880B1724)});shade.GradientStops.Add(new(){Offset=.45,Color=DesktopMaterial.Color(0x380B1724)});shade.GradientStops.Add(new(){Offset=1,Color=DesktopMaterial.Color(0x080B1724)});
            surface.Children.Add(new Border{Background=shade,IsHitTestVisible=false});
            var words=new Grid{Margin=new(Math.Clamp(page.ActualWidth*.022,18,32))};words.RowDefinitions.Add(new(){Height=new(1,GridUnitType.Star)});words.RowDefinitions.Add(new(){Height=GridLength.Auto});
            var title=new TextBlock{FontSize=Math.Clamp(page.ActualWidth/48,22,38),FontWeight=Microsoft.UI.Text.FontWeights.SemiBold,Foreground=DesktopVisuals.Brush(0xFFFFFFFF),TextWrapping=TextWrapping.Wrap,MaxLines=3,VerticalAlignment=VerticalAlignment.Top,MaxWidth=Math.Clamp(page.ActualWidth*.18,160,350),HorizontalAlignment=HorizontalAlignment.Left};title.SetBinding(TextBlock.TextProperty,new Binding{Source=card,Path=new(item.Type.Equals("Episode",StringComparison.OrdinalIgnoreCase)&&!string.IsNullOrWhiteSpace(item.SeriesName)?"Item.SeriesName":"Item.Name"),Mode=BindingMode.OneWay});words.Children.Add(title);
            surface.Children.Add(words);var frame=new Border{CornerRadius=new(Math.Min(DesktopTheme.Options.Radius,14)),Child=surface};button.Content=frame;
            if(lead)PosterMotion.Attach(button,surface); // Carousel owns one shared hover transform.
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button,"查看详情："+item.Name);
            // These two slots own their loading; ordinary viewport loaders must not race them.
            object? displayed=null;
            void Reveal(){
                if(image.Source is not Microsoft.UI.Xaml.Media.Imaging.BitmapSource{PixelWidth:>0,PixelHeight:>0} source||ReferenceEquals(displayed,source))return;
                displayed=source;
                if(DesktopTheme.Options.ReducedMotion){image.Opacity=1;return;}
                var fade=new Microsoft.UI.Xaml.Media.Animation.DoubleAnimation{From=0,To=1,Duration=new Duration(TimeSpan.FromMilliseconds(160))};
                Microsoft.UI.Xaml.Media.Animation.Storyboard.SetTarget(fade,image);Microsoft.UI.Xaml.Media.Animation.Storyboard.SetTargetProperty(fade,"Opacity");
                var transition=new Microsoft.UI.Xaml.Media.Animation.Storyboard();transition.Children.Add(fade);transition.Begin();
            }
            image.Opacity=0;image.ImageOpened+=(_,_)=>Reveal();image.Loaded+=(_,_)=>Reveal();
            image.RegisterPropertyChangedCallback(Image.SourceProperty,(_,_)=>Reveal());
            button.Click+=(_,_)=>PosterTap.Queue(page,button,card,()=>{_=Open(card,button);},HeroCarousel.TapAnchor(button));
            return button;
        }
    }
}
