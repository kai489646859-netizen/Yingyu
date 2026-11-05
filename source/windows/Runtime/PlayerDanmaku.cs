using System.Diagnostics;
using System.Runtime.CompilerServices;
using EmbyDesktop.Core.Models;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Composition;
using System.Runtime.InteropServices;
using Richasy.MpvKernel.Core.Enums;
using Richasy.MpvKernel.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;
using Windows.Foundation;

namespace Yingyu.Update;

// A hit-test transparent presentation layer. Never seeks, pauses, sends a
// playback report, changes a track, calls mpv or makes requests on the UI thread.
internal static class PlayerDanmaku
{
    static readonly ConditionalWeakTable<object,State> States=new();
    static readonly ConditionalWeakTable<object,State> Overlays=new();
    internal static void Bind(object session)
    {
        try{
            if(Access.Get<object?>(session,"_overlay") is not FrameworkElement overlay)return;
            if(States.TryGetValue(session,out var previous)&&!ReferenceEquals(previous.Element,overlay))
            {previous.BeginStop();Overlays.Remove(previous.Element);States.Remove(session);}
            var state=States.GetValue(session,s=>new State(s,overlay));Overlays.Remove(overlay);Overlays.Add(overlay,state);state.Bind();
        }catch(Exception e){Log(e);}
    }
    internal static void Observe(object session, MpvClientNotifyEventArgs args)
    {
        if (args.Id is not (MpvClientEventId.PositionChanged or MpvClientEventId.SpeedChanged or MpvClientEventId.StateChanged)) return;
        if (States.TryGetValue(session, out var state)) state.MediaClock.Observe(args);
    }
    internal static void Stop(object session){try{if(States.TryGetValue(session,out var state))state.BeginStop();}catch(Exception e){Log(e);}}
    internal static void Ready(object session)=>Dispatch(session,playlistChanged:false);
    internal static void PlaylistReady(object session)=>Dispatch(session,playlistChanged:true);
    static void Dispatch(object session,bool playlistChanged)
    {
        try
        {
            if(Access.Get<object?>(session,"_overlay") is not FrameworkElement overlay)return;
            void Apply()
            {
                try
                {
                    if(!overlay.IsLoaded||NativeDolby.IsClosing(session)
                        ||!ReferenceEquals(overlay,Access.Get<object?>(session,"_overlay"))
                        ||!Access.Get<bool>(session,"_hasStartedPlayback"))return;
                    if(!States.TryGetValue(session,out var state)||!ReferenceEquals(state.Element,overlay)||!state.Current)
                    {
                        Bind(session);
                        States.TryGetValue(session,out state);
                    }
                    if(playlistChanged)state?.PlaylistReady();
                    else state?.Ready();
                }
                catch(Exception e){Log(e);}
            }
            if(overlay.DispatcherQueue.HasThreadAccess)Apply();
            else overlay.DispatcherQueue.TryEnqueue(Apply);
        }
        catch(Exception e){Log(e);}
    }
    internal static UIElement Menu(object session)=>BuildMenu(States.TryGetValue(session,out var state)?state:null);
    internal static UIElement OverlayMenu(object overlay)=>BuildMenu(Overlays.TryGetValue(overlay,out var state)?state:null);
    static readonly ConditionalWeakTable<object,ToggleButton> FeaturedButtons=new();
    internal static void AttachFeatured(object overlay,ToggleButton button)
    {
        FeaturedButtons.Add(overlay,button);button.IsEnabled=false;
        button.Click+=(_,_)=>{
            if(Overlays.TryGetValue(overlay,out var state))state.SetFeatured(button.IsChecked==true);
        };
        if(Overlays.TryGetValue(overlay,out var state))state.PaintFeatured();
    }
    internal static void Sought(object session)
    {
        if(!States.TryGetValue(session,out var state))return;
        void Apply()=>state.GuardSeek();
        if(state.Element.DispatcherQueue.HasThreadAccess)Apply();else state.Element.DispatcherQueue.TryEnqueue(Apply);
    }
    static UIElement BuildMenu(State? state){try{if(state is not null)return state.Menu();}catch(Exception e){Log(e);}return new TextBlock{Text="开始播放后可设置弹幕",TextWrapping=TextWrapping.Wrap};}
    static void Log(Exception e){try{PlaybackTransport.Write("Warning","Playback.Danmaku","弹幕辅助层暂不可用，保留原播放；"+e.GetType().Name);}catch(Exception){}}
    sealed class Moving
    {
        internal required Border View;
        internal CompositionPropertySet? Position;
        internal ExpressionAnimation? Translation;
        internal ScalarKeyFrameAnimation? Travel;
        internal bool Fallback;
        internal bool Exiting;
        internal double ExitX;
        internal AnimationController? Motion;
        internal DanmakuComment Comment=null!;internal double End,Width,Velocity,X;internal int Row;internal bool Fits=true;internal TextBlock[] Glyphs=[];
    }
    // Aggregate on the dispatcher and enqueue one local log entry per window.
    // Timings describe callbacks and CPU work, not frames presented by DWM.
    struct FrameProbe
    {
        long first, lastFrame;
        int timerUpdates, gaps, stale, held, epochs, maxRows;
        double maxGap, maxWork, maxSampleAge, maxDrift;

        internal void Record(object session,long now,bool moving,bool playing,
            bool epochChanged,double age,double drift,double speed,int rows,bool featured)
        {
            if(first==0)first=now;
            if(moving)
            {
                if(lastFrame!=0)
                {
                    double gap=Stopwatch.GetElapsedTime(lastFrame,now).TotalMilliseconds;
                    maxGap=Math.Max(maxGap,gap);
                    if(gap>=50)gaps++;
                }
                lastFrame=now;
                timerUpdates++;
            }
            else if(!moving)lastFrame=0;
            if(!moving)
            {
                if(playing)stale++;
                else held++;
            }
            if(epochChanged)epochs++;
            maxRows=Math.Max(maxRows,rows);
            maxWork=Math.Max(maxWork,Stopwatch.GetElapsedTime(now).TotalMilliseconds);
            if(playing&&double.IsFinite(age))maxSampleAge=Math.Max(maxSampleAge,age*1000);
            if(moving&&double.IsFinite(drift))maxDrift=Math.Max(maxDrift,Math.Abs(drift)*1000);
            double seconds=Stopwatch.GetElapsedTime(first,now).TotalSeconds;
            if(seconds<8)return;
            PlaybackTelemetry.DanmakuTiming(session,FormattableString.Invariant(
                $"windowSeconds={seconds:0.0}; speedLast={speed:0.##}; featured={featured}; motion=compositor-or-fallback; timerUpdates={timerUpdates}; timerGaps50ms={gaps}; maxTimerGapMs={maxGap:0.0}; maxWorkMs={maxWork:0.0}; staleUpdates={stale}; heldUpdates={held}; epochChanges={epochs}; maxSampleAgeMs={maxSampleAge:0.0}; maxClockDriftMs={maxDrift:0.0}; peakRows={maxRows}"));
            this=default;
        }
    }

    sealed class State
    {
        internal FrameworkElement Element=>overlay;
        readonly object session;readonly FrameworkElement overlay;readonly Canvas canvas=new(){IsHitTestVisible=false};
        readonly DispatcherQueueTimer timer;readonly List<Moving> active=new();
        readonly Stack<Moving> availableRows=new();
        readonly TextBlock measurer=new()
        {
            FontWeight=Microsoft.UI.Text.FontWeights.SemiBold,TextWrapping=TextWrapping.NoWrap
        };
        readonly SolidColorBrush brightOutline=DesktopVisuals.Brush(0xFFF4F4F4);
        readonly SolidColorBrush darkOutline=DesktopVisuals.Brush(0xFF101010);
        readonly SolidColorBrush textBackground=DesktopVisuals.Brush(0x80000000);
        CancellationTokenSource? lifetime;
        readonly Dictionary<string,CancellationTokenSource> feeds=new(StringComparer.Ordinal);
        readonly Dictionary<string,DanmakuTrack> sourceTracks=new(StringComparer.Ordinal);
        bool combining;
        int trackRevision;DanmakuOptions options=new();DanmakuIdentity? identity,lastSearchIdentity;DanmakuTrack? track;
        readonly DispatcherQueueTimer saveTimer;readonly DispatcherQueueTimer retryTimer;double feedPosition;int attempts;string? lastQuery;bool searching;
        DanmakuCandidate[] candidates=[];ComboBox? candidateBox;
        int generation=int.MinValue,request,index,appliedSearch=-1;bool stopped=true,attached,optionsReady,waiting;
        internal readonly DanmakuClock MediaClock = new();
        double clock,last=double.NaN,measuredFont=double.NaN;
        long renderedAt, admittedAt;
        bool fallbackRendering;
        FrameProbe frameProbe;
        int mediaEpoch=-1;
        double motionRate,lastSpeed;
        long rateAt;
        double subtitleAnchor=100;
        readonly Dictionary<(string Text,int Mode),(double Time,bool DropNext)> featuredRepeats=new();
        TextBlock? status;string description="正在准备自动匹配…";
        internal State(object session,FrameworkElement overlay)
        {
            this.session=session;this.overlay=overlay;
            timer=overlay.DispatcherQueue.CreateTimer();timer.Interval=TimeSpan.FromMilliseconds(33);timer.Tick+=Tick;
            saveTimer=overlay.DispatcherQueue.CreateTimer();saveTimer.IsRepeating=false;saveTimer.Interval=TimeSpan.FromMilliseconds(350);saveTimer.Tick+=(_,_)=>{saveTimer.Stop();_=Save();};
            retryTimer=overlay.DispatcherQueue.CreateTimer();retryTimer.IsRepeating=false;retryTimer.Tick+=(_,_)=>Guard(()=>{if(Current&&options.Enabled&&options.Automatic&&attempts<3){attempts++;Search(false,lastQuery);}});
            overlay.Loaded+=(_,_)=>Guard(()=>{Bind();Ready();});
            overlay.Unloaded+=(_,_)=>Guard(()=>{Stop();attached=false;});
            overlay.SizeChanged+=(_,_)=>Guard(()=>{if(Current){Clip();Reflow();}});
        }
        internal bool Current=>!stopped&&overlay.IsLoaded&&!NativeDolby.IsClosing(session)
            &&generation==Access.Get<int>(session,"_mediaGeneration")&&ReferenceEquals(overlay,Access.Get<object?>(session,"_overlay"));
        internal void Bind()
        {
            // Repeated layout/bind notifications for the same live media are
            // not a new playback session or a reason to restart its comments.
            if(Current){if(!attached)Attach();return;}
            Stop();
            MediaClock.Reset(Access.Get<double>(session,"_position"),Access.Get<double>(session,"_currentSpeed"));
            stopped=false;generation=Access.Get<int>(session,"_mediaGeneration");request++;
            identity=null;lastSearchIdentity=null;optionsReady=false;
            if(overlay.IsLoaded)Attach();
            var cts=lifetime=new CancellationTokenSource();int version=request;
            _=Initialize(version,cts.Token);
        }
        async Task Initialize(int version,CancellationToken token)
        {
            try{
                var loaded=await Task.Run(()=>DanmakuStorage.ReadOptions(token),token).ConfigureAwait(false);
                overlay.DispatcherQueue.TryEnqueue(()=>Guard(()=>{
                    if(version!=request||token.IsCancellationRequested||stopped)return;
                    options=loaded;optionsReady=true;PaintFeatured();canvas.Visibility=options.Enabled?Visibility.Visible:Visibility.Collapsed;
                    if(options.Enabled&&options.Automatic){waiting=true;Ready();}
                    else
                    {
                        Describe(options.Enabled?"自动匹配已关闭":"弹幕已关闭");
                        DanmakuSources.Trace("player","start",options.Enabled?"automatic-disabled":"disabled");
                    }
                }));
            }catch(OperationCanceledException){}catch(Exception e){Log(e);}
        }
        void Attach()
        {
            var root=Access.Get<Grid>(overlay,"RootGrid");
            Grid.SetRowSpan(canvas,Math.Max(1,root.RowDefinitions.Count));Grid.SetColumnSpan(canvas,Math.Max(1,root.ColumnDefinitions.Count));
            if(!root.Children.Contains(canvas))root.Children.Insert(0,canvas);
            attached=true;Clip();
        }
        void Clip(){canvas.Clip=new RectangleGeometry{Rect=new Rect(0,0,Math.Max(0,overlay.ActualWidth),Math.Max(0,overlay.ActualHeight))};}
        internal void Stop()
        {
            if(saveTimer.IsRunning){saveTimer.Stop();_=Save();}
            stopped=true;waiting=false;request++;Cancel();ResetSources();retryTimer.Stop();attempts=0;candidates=[];candidateBox=null;status=null;timer.Stop();Clear();foreach(var row in availableRows){row.Translation?.Dispose();row.Position?.Dispose();}availableRows.Clear();measurer.Text="";track=null;last=double.NaN;mediaEpoch=-1;motionRate=0;rateAt=0;renderedAt=0;frameProbe=default;
        }
        internal void BeginStop()
        {
            if(overlay.DispatcherQueue.HasThreadAccess)Guard(Stop);
            else overlay.DispatcherQueue.TryEnqueue(()=>Guard(Stop));
        }
        void Cancel(){searching=false;var previous=lifetime;lifetime=null;previous?.Cancel();previous?.Dispose();}
        void StopFeed()
        {
            foreach(var owner in feeds.Values){owner.Cancel();owner.Dispose();}
            feeds.Clear();
        }
        void ResetSources()
        {
            StopFeed();sourceTracks.Clear();track=null;trackRevision++;
        }
        internal void Ready()
        {
            // Playback-start callbacks may originate on the native event thread.
            // Only the dispatcher may touch the XAML tree or presentation timer.
            void Apply()=>Guard(()=>{if(waiting&&optionsReady&&options.Enabled&&options.Automatic&&Current&&Access.Get<bool>(session,"_hasStartedPlayback")){waiting=false;Search();}});
            if(overlay.DispatcherQueue.HasThreadAccess)Apply();else overlay.DispatcherQueue.TryEnqueue(Apply);
        }
        DanmakuIdentity? CurrentIdentity()
        {
            var item=Access.Get<EmbyItem>(session,"_item");
            var playlist=Access.Get<IReadOnlyList<EmbyItem>?>(session,"_playlist")??[];
            double duration=Access.Get<double>(session,"_duration");
            if(!double.IsFinite(duration)||duration<=0)duration=item.RunTimeTicks.GetValueOrDefault()/10000000d;
            var match=DanmakuIdentity.From(item,duration);
            if(match is null&&item.Type=="Episode"&&!string.IsNullOrWhiteSpace(item.Id))
            {
                // Only the queue row for the same item can fill missing episode metadata.
                var row=playlist.FirstOrDefault(ep=>string.Equals(ep.Id,item.Id,StringComparison.OrdinalIgnoreCase)
                    &&(string.IsNullOrWhiteSpace(item.SeriesId)||string.Equals(item.SeriesId,ep.SeriesId,StringComparison.OrdinalIgnoreCase)));
                if(row is not null)match=DanmakuIdentity.From(row,duration);
            }
            if(match is not {Movie:false}||playlist.Count<DanmakuProtocol.ContinuousEpisodeFloor)return match;
            if(!playlist.Any(ep=>string.Equals(ep.Id,item.Id,StringComparison.OrdinalIgnoreCase)))return match;
            bool continuous=playlist.Any(ep=>ep.IndexNumber>=DanmakuProtocol.ContinuousEpisodeFloor
                &&(!string.IsNullOrWhiteSpace(item.SeasonId)
                    ?string.Equals(ep.SeasonId,item.SeasonId,StringComparison.OrdinalIgnoreCase)
                    :!string.IsNullOrWhiteSpace(item.SeriesId)&&string.Equals(ep.SeriesId,item.SeriesId,StringComparison.OrdinalIgnoreCase)
                        &&ep.ParentIndexNumber==match.Season));
            return continuous?match with{ContinuousNumbering=true}:match;
        }

        internal void PlaylistReady()=>Guard(()=>
        {
            if(!Current||!optionsReady||!options.Enabled||!options.Automatic
                ||!string.IsNullOrWhiteSpace(lastQuery)||sourceTracks.Count>0)return;
            if(waiting){Ready();return;}
            var updated=CurrentIdentity();
            if(updated is null||lastSearchIdentity is {} old&&old.Key==updated.Key
                &&old.ContinuousNumbering==updated.ContinuousNumbering)return;
            DanmakuSources.Trace("player","lookup","playlist-recheck");
            Search();
        });

        void Search(bool refresh=false,string? query=null)
        {
            if(!Current)return;
            waiting=false;retryTimer.Stop();lastQuery=query;if(refresh)attempts=0;
            Cancel();var cts=lifetime=new CancellationTokenSource();var token=cts.Token;int version=++request;
            var id=identity=CurrentIdentity();
            lastSearchIdentity=id;
            var prefs=new DanmakuOptions{CompatibleApi=options.CompatibleApi};
            if(id is null)
            {
                Describe("缺少准确片名或集数，未自动加载");
                DanmakuSources.Trace("player","lookup","missing-identity");return;
            }
            if(DanmakuSources.IsPlatformLink(query)&&!PublicDanmaku.IsDirectLink(query)&&string.IsNullOrEmpty(prefs.CompatibleApi))
            {Describe("请粘贴腾讯视频或爱奇艺的单集链接，其他链接可通过兼容服务读取");return;}
            searching=true;
            Describe("正在后台查找公开弹幕…");
            _=Task.Run(async()=>{
                int found=0;bool offered=false;
                try{
                    DanmakuSources.Trace("player","lookup",id.ContinuousNumbering?"start-continuous":"start");
                    await DanmakuSources.Find(id,prefs,candidate=>{
                        if(token.IsCancellationRequested)return;Interlocked.Increment(ref found);
                        overlay.DispatcherQueue.TryEnqueue(()=>Guard(()=>{
                            if(version!=request||!Current||token.IsCancellationRequested)return;
                            if(appliedSearch!=version&&!string.IsNullOrWhiteSpace(query))ResetSources();
                            appliedSearch=version;
                            ApplyTrack(candidate);
                        }));
                    },token,refresh,rows=>{
                        offered=true;var copy=rows.ToArray();overlay.DispatcherQueue.TryEnqueue(()=>Guard(()=>{if(version!=request||!Current||token.IsCancellationRequested)return;candidates=copy;FillCandidates();if(sourceTracks.Count==0)Describe("找到多个哔哩哔哩候选，可在弹幕面板选择版本");}));
                    },query).ConfigureAwait(false);
                    if(found==0&&!offered)overlay.DispatcherQueue.TryEnqueue(()=>Guard(()=>{
                        if(version!=request||!Current||token.IsCancellationRequested)return;
                        if(sourceTracks.Count>0){Describe("新查询暂未匹配，保留已有弹幕来源");return;}
                        if(options.Automatic&&attempts<3){retryTimer.Interval=TimeSpan.FromSeconds(30*(attempts+1));retryTimer.Start();Describe("暂未匹配，稍后自动重试；也可搜索或粘贴单集播放链接");}
                        else Describe("暂无可用匹配，请搜索或粘贴单集播放链接选择来源");
                    }));
                }catch(OperationCanceledException){}catch(Exception e){Log(e);}
                finally{overlay.DispatcherQueue.TryEnqueue(()=>{if(version==request)searching=false;});}
            },token);
        }
        void ApplyTrack(DanmakuTrack candidate)
        {
            string source=candidate.Source;
            if(sourceTracks.TryGetValue(source,out var existing)&&
                candidate.StreamCid is not null&&existing.StreamCid==candidate.StreamCid&&feeds.ContainsKey(source))return;
            if(feeds.Remove(source,out var previous)){previous.Cancel();previous.Dispose();}
            sourceTracks[source]=candidate;
            RefreshCombined();
            if(DanmakuSources.ValidCid(candidate.StreamCid)||candidate.PublicFeed is not null)
                StartFeed(candidate);
        }

        void StartFeed(DanmakuTrack candidate)
        {
            string source=candidate.Source;
            if(feeds.ContainsKey(source))return;
            var owner=new CancellationTokenSource();feeds.Add(source,owner);
            var token=owner.Token;
            Volatile.Write(ref feedPosition,Math.Max(0,Access.Get<double>(session,"_position")-options.Delay));
            _=Task.Run(async()=>
            {
                try
                {
                    await DanmakuSources.Watch(candidate,()=>Volatile.Read(ref feedPosition),snapshot=>
                    {
                        if(token.IsCancellationRequested)return;
                        overlay.DispatcherQueue.TryEnqueue(()=>Guard(()=>
                        {
                            if(token.IsCancellationRequested||!Current)return;
                            sourceTracks[source]=snapshot;RefreshCombined();
                        }));
                    },message=>overlay.DispatcherQueue.TryEnqueue(()=>Guard(()=>
                    {
                        if(!token.IsCancellationRequested&&Current&&sourceTracks.Values.All(t=>t.Comments.Length==0))
                            Describe(message);
                    })),token).ConfigureAwait(false);
                }
                catch(OperationCanceledException){}
                catch(Exception e){Log(e);}
            },token);
        }

        void RefreshCombined()
        {
            trackRevision++;
            if(sourceTracks.Count==0)return;
            if(sourceTracks.Count==1){SetCombined(sourceTracks.Values.First());return;}
            if(combining)return;
            var snapshot=sourceTracks.Values.OrderBy(t=>t.Source,StringComparer.Ordinal).ToArray();
            combining=true;
            int revision=trackRevision;
            _=Task.Run(()=>
            {
                // Keep a bounded, evenly sampled share per source. Dense
                // providers must not crowd out the later part of another track.
                int limit=120000/snapshot.Length;
                var comments=DanmakuProtocol.Normalize(snapshot.SelectMany(t=>SampleRows(t.Comments,limit)));
                var labels=snapshot.Where(t=>t.Comments.Length>0).Select(t=>t.Source).ToArray();
                var combined=new DanmakuTrack(labels.Length>0?string.Join(" + ",labels):"公开弹幕",
                    snapshot[0].Identity,0,comments,0);
                overlay.DispatcherQueue.TryEnqueue(()=>Guard(()=>
                {
                    combining=false;
                    if(!Current||!options.Enabled)return;
                    if(revision!=trackRevision){RefreshCombined();return;}
                    SetCombined(combined);
                }));
            });
        }

        static IEnumerable<DanmakuComment> SampleRows(DanmakuComment[] rows,int limit)
        {
            if(rows.Length<=limit)return rows;
            return Enumerable.Range(0,limit).Select(i=>rows[(int)((long)i*(rows.Length-1)/(limit-1))]);
        }

        void SetCombined(DanmakuTrack combined)
        {
            track=combined;Reindex(false);
            if(options.Enabled)timer.Start();
            Describe(combined.Comments.Length>0?combined.Source+" · "+combined.Comments.Length+" 条":
                "已匹配来源，有可用弹幕时会自动显示");
        }
        void FillCandidates()
        {
            if(candidateBox is null)return;candidateBox.Items.Clear();foreach(var candidate in candidates)candidateBox.Items.Add(new ComboBoxItem{Content=candidate.Label,Tag=candidate});if(candidates.Length>0)candidateBox.SelectedIndex=0;
        }
        void Describe(string text){description=text;if(status is not null)status.Text=text;}
        void Guard(Action action){try{action();}catch(Exception e){try{Stop();}catch(Exception cleanup){Log(cleanup);}Log(e);}}
        void Clear()
        {
            featuredRepeats.Clear();
            foreach(var row in active){StopMotion(row);availableRows.Push(row);}
            admittedAt=0;
            active.Clear();canvas.Children.Clear();UpdateFallbackRendering();
        }
        void Reindex(bool resetClock=true, double? timelinePosition=null)
        {
            index=0;if(track is null)return;
            double now=timelinePosition??(Access.Get<double>(session,"_position")-options.Delay);
            if(!resetClock&&!double.IsNaN(last))now=Math.Max(now,last);
            int lo=0,hi=track.Comments.Length;
            while(lo<hi){int mid=lo+(hi-lo)/2;if(track.Comments[mid].Time<now||!resetClock&&track.Comments[mid].Time==now)lo=mid+1;else hi=mid;}index=lo;
            if(resetClock){last=double.NaN;renderedAt=0;motionRate=0;rateAt=0;}
        }
        void Tick(DispatcherQueueTimer sender,object args)=>Guard(Render);
        void Render()
        {
            if(!Current||!options.Enabled||track is null){timer.Stop();Clear();return;}
            double width=overlay.ActualWidth,height=overlay.ActualHeight;
            if(width<100||height<80){SetMotionRate(0);UpdateFallbackRendering();SetTickInterval(66);return;}
            var sample=MediaClock.Read();
            if(!double.IsFinite(sample.Position)||sample.Position<0)return;
            Volatile.Write(ref feedPosition,Math.Max(0,sample.Position-options.Delay));
            long wall=Stopwatch.GetTimestamp();
            double age=Stopwatch.GetElapsedTime(sample.PositionAt,wall).TotalSeconds;
            double horizon=DanmakuClock.Horizon(sample);
            bool moving=sample.Playing&&age<horizon;
            double target=sample.Position+(sample.Playing?Math.Min(horizon,age)*sample.Speed:0)-options.Delay;
            bool epochChanged=mediaEpoch!=-1&&mediaEpoch!=sample.Epoch;
            int measuredRows=active.Count;
            try
            {
                if(mediaEpoch!=sample.Epoch)
                {
                    if(epochChanged){Clear();Reindex(timelinePosition:sample.Position-options.Delay);}
                    mediaEpoch=sample.Epoch;
                }
                double elapsed=renderedAt==0?0:Stopwatch.GetElapsedTime(renderedAt,wall).TotalSeconds;
                renderedAt=wall;
                double progress=elapsed*motionRate;
                clock=double.IsNaN(last)?target:last+progress;
                last=clock;
                for(int i=active.Count-1;i>=0;i--)
                {
                    var row=active[i];
                    if(row.Comment.Mode==1)
                    {
                        row.X=Math.Max(row.ExitX,row.X-progress*row.Velocity);
                        if(clock>=row.End&&!row.Exiting)
                        {
                            // Allow the last compositor update to reach the left edge
                            // before the dispatcher removes the visual.
                            row.Exiting=true;
                            if(row.Fallback)SetPosition(row,row.ExitX);
                            continue;
                        }
                    }
                    if(clock>=row.End)
                    {
                        StopMotion(row);canvas.Children.Remove(row.View);active.RemoveAt(i);availableRows.Push(row);
                    }
                }
                bool speedChanged=sample.Speed!=lastSpeed;
                if(!moving)SetMotionRate(0);
                else if(motionRate==0||speedChanged||Stopwatch.GetElapsedTime(rateAt,wall).TotalMilliseconds>=150)
                {
                    lastSpeed=sample.Speed;rateAt=wall;
                    SetMotionRate(DanmakuClock.Rate(clock,target,sample.Speed));
                }
                UpdateSubtitleBand();
                if(moving&&(admittedAt==0||Stopwatch.GetElapsedTime(admittedAt,wall)>=TimeSpan.FromMilliseconds(30)))
                {
                    admittedAt=wall;
                    AdmitComments(track.Comments,sample.Speed,width,height);
                }
                UpdateFallbackRendering();
                SetTickInterval(moving?33:66);
            }
            finally
            {
                if(measuredRows>0||active.Count>0)
                    frameProbe.Record(session,wall,moving,sample.Playing,epochChanged,age,
                        target-clock,sample.Speed,Math.Max(measuredRows,active.Count),options.Featured);
                else frameProbe=default;
            }
        }

        void AdmitComments(DanmakuComment[] comments,double speed,double width,double height)
        {
            int inspected=0,attempted=0;
            double freshness=Math.Max(.6,speed*.35);
            while(index<comments.Length&&comments[index].Time<clock-freshness&&inspected++<300)index++;
            // Keep the previous admission budget even when the display refreshes faster.
            // Late batches cannot monopolize the UI during dense sequences.
            while(index<comments.Length&&comments[index].Time<=clock&&inspected++<300&&attempted<3)
            {
                var comment=comments[index++];
                if(clock-comment.Time>freshness||active.Count>=48||!ModeEnabled(comment.Mode))continue;
                if(options.Featured&&SkipFeaturedRepeat(comment,width))continue;
                attempted++;
                Show(comment,width,height);
            }
        }

        void SetTickInterval(int milliseconds)
        {
            var interval=TimeSpan.FromMilliseconds(milliseconds);
            if(timer.Interval!=interval)timer.Interval=interval;
        }

        bool SkipFeaturedRepeat(DanmakuComment comment,double width)
        {
            // Keep every distinct line. For a repeated burst, retain the first
            // and then every second occurrence within the same media window.
            var key=(comment.Text.Trim(),comment.Mode);
            bool drop=featuredRepeats.TryGetValue(key,out var previous)
                &&comment.Time>=previous.Time&&comment.Time-previous.Time<=12&&previous.DropNext;
            if(featuredRepeats.Count>=256&&!featuredRepeats.ContainsKey(key))featuredRepeats.Clear();
            featuredRepeats[key]=(comment.Time,!drop);
            if(!drop||comment.Mode!=1)return drop;

            // Repeat reduction must not empty a quiet rolling overlay.
            int lanes=0;
            foreach(var row in active)
            {
                if(row.Comment.Mode!=1||row.View.Visibility!=Visibility.Visible||row.X>=width||row.X+row.Width<=0)continue;
                lanes|=1<<row.Row;
                if((lanes&(lanes-1))!=0)return true;
            }
            return false;
        }
        internal void PaintFeatured()
        {
            if(!FeaturedButtons.TryGetValue(overlay,out var button))return;
            button.IsChecked=options.Featured;button.IsEnabled=optionsReady&&options.Enabled;
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button,options.Featured?"精品弹幕：开":"精品弹幕：关");
        }
        internal void SetFeatured(bool enabled)=>Guard(()=>{
            if(!Current||!optionsReady||!options.Enabled){PaintFeatured();return;}
            options.Featured=enabled;featuredRepeats.Clear();PaintFeatured();
            saveTimer.Stop();saveTimer.Start();
        });
        bool Show(DanmakuComment comment,double width,double height)
        {
            double rowHeight=RowHeight;
            int rows=LaneCount(height);
            if(rows==0)return false;
            double size=EffectiveFont;
            measurer.FontSize=size;measurer.Text=comment.Text;
            measurer.Measure(new Size(double.PositiveInfinity,rowHeight));
            double measured=measurer.DesiredSize.Width+8;
            if(!double.IsFinite(measured)||measured>width*1.5)return false;
            double exit=-measured-8;
            double velocity=(width-exit)/options.TravelSeconds;
            double x=width-(clock-comment.Time)*velocity;
            int lane=-1,safeSlots=0;
            bool spread=options.Featured&&comment.Mode==1;
            for(int slot=0;slot<rows;slot++)
            {
                double y=LaneY(comment.Mode,slot,height);
                if(!SubtitleClear(y,height))continue;
                safeSlots++;
                bool free=true,occupied=false;
                foreach(var old in active)
                {
                    if(old.View.Visibility!=Visibility.Visible||Math.Abs(Canvas.GetTop(old.View)-y)>=rowHeight-.01)continue;
                    occupied=true;
                    if(comment.Mode!=1||old.Comment.Mode!=1||!CanFollow(old,x,velocity)){free=false;break;}
                }
                if(free)
                {
                    if(!spread||!occupied){lane=slot;break;}
                    if(lane<0)lane=slot;
                }
                if(lane>=0&&safeSlots>=3)break;
            }
            if(lane<0)return false;
            var item=availableRows.TryPop(out var reuse)?reuse:CreateRow();
            double luminance=((comment.Color>>16)&255)*.2126+((comment.Color>>8)&255)*.7152+(comment.Color&255)*.0722;
            var outline=luminance<75?brightOutline:darkOutline;
            for(int i=0;i<item.Glyphs.Length;i++)
            {
                var glyph=item.Glyphs[i];
                glyph.Text=comment.Text;glyph.FontSize=size;
                glyph.Foreground=i==item.Glyphs.Length-1?DesktopVisuals.Brush(0xFF000000|comment.Color):outline;
            }
            item.View.Background=options.Background?textBackground:null;
            item.View.Opacity=options.Opacity;item.View.Visibility=Visibility.Visible;
            item.Comment=comment;item.End=comment.Time+(comment.Mode==1?options.TravelSeconds:4);
            item.Width=measured;item.Row=lane;item.Fits=true;
            item.X=comment.Mode==1?x:(width-measured)/2;
            item.Velocity=velocity;item.ExitX=exit;item.Exiting=false;
            Canvas.SetTop(item.View,LaneY(comment.Mode,lane,height));
            canvas.Children.Add(item.View);
            StartMotion(item);active.Add(item);return true;
        }
        static Moving CreateRow()
        {
            var letters=new Grid();
            var offsets=new[]{(-.8,0d),(.8,0d),(0d,-.8),(0d,.8),(0d,0d)};
            var glyphs=new TextBlock[offsets.Length];
            for(int i=0;i<offsets.Length;i++)
            {
                var offset=offsets[i];
                var glyph=new TextBlock
                {
                    FontWeight=Microsoft.UI.Text.FontWeights.SemiBold,TextWrapping=TextWrapping.NoWrap,
                    RenderTransform=new TranslateTransform{X=offset.Item1,Y=offset.Item2}
                };
                glyphs[i]=glyph;letters.Children.Add(glyph);
            }
            var view=new Border{Child=letters,Padding=new(4,0,4,0),CornerRadius=new(3)};
            return new Moving{View=view,Glyphs=glyphs};
        }
        double EffectiveFont=>Math.Round(options.FontSize*(options.AdaptiveSize?Math.Clamp(Math.Min(overlay.ActualWidth/1280,overlay.ActualHeight/800),1,1.5):1)*2)/2;
        double RowHeight=>Math.Ceiling(EffectiveFont*1.4)+2;
        void RefreshGlyphMetrics()
        {
            double size=EffectiveFont;if(Math.Abs(size-measuredFont)<.01)return;measuredFont=size;
            foreach(var row in active){foreach(var glyph in row.Glyphs)glyph.FontSize=size;row.View.Measure(new Size(double.PositiveInfinity,RowHeight));row.Width=row.View.DesiredSize.Width;}
        }
        double RegionEdge(double height)=>Math.Min(height*options.Area,height*.72);
        void UpdateSubtitleBand()
        {
            double live=Access.Get<double>(session,"_liveSubtitlePosition");
            double next=double.IsFinite(live)?Math.Clamp(live,0,100):100;
            if(Math.Abs(next-subtitleAnchor)<.01)return;
            subtitleAnchor=next;Reflow();
        }
        bool SubtitleClear(double y,double height)
        {
            // Reserve the ordinary dialogue area, and allow extra clearance
            // around the user's subtitle position when it has been raised.
            double band=height*subtitleAnchor/100;
            return y+RowHeight<=band-height*.28||y>=band+height*.12;
        }

        int LaneCount(double height)
            => Math.Clamp((int)((RegionEdge(height)-20)/RowHeight),0,24);

        double LaneY(int mode,int row,double height)
            => mode==4?RegionEdge(height)-(row+1)*RowHeight:20+row*RowHeight;

        bool CanFollow(Moving earlier,double laterX,double laterSpeed)
        {
            double gap=laterX-(earlier.X+earlier.Width);
            return gap>=20+Math.Max(laterSpeed,earlier.Velocity)*Math.Max(1,lastSpeed)*.075+Math.Max(0,laterSpeed-earlier.Velocity)*Math.Max(0,earlier.End-clock);
        }

        void SetMotionRate(double rate)
        {
            if(Math.Abs(rate-motionRate)<.0001)return;
            bool paused=motionRate==0;
            motionRate=rate;
            foreach(var row in active)
            {
                ApplyMotionRate(row,paused);
                if(rate==0&&row.Fallback&&row.Comment.Mode==1)SetPosition(row,row.X);
            }
        }

        void ApplyMotionRate(Moving row,bool resume)
        {
            if(row.Motion is not {} motion)return;
            try
            {
                if(motionRate==0)motion.Pause();
                else
                {
                    motion.PlaybackRate=(float)motionRate;
                    if(resume)motion.Resume();
                }
            }
            catch(Exception e)when(IsMotionFailure(e)){UseFallback(row);}
        }

        static bool IsMotionFailure(Exception error)=>error is COMException or InvalidOperationException or ArgumentException or NotSupportedException;

        static void StopMotion(Moving row)
        {
            if(row.Travel is null)return;
            row.Position!.StopAnimation("X");
            row.Motion?.Dispose();row.Motion=null;
            row.Travel.Dispose();row.Travel=null;
        }

        static void SetPosition(Moving row,double x)
        {
            if(row.Position is {} position)position.InsertScalar("X",(float)x);
            else row.View.Translation=new((float)x,0,0);
        }

        static void UseFallback(Moving row)
        {
            StopMotion(row);
            row.Fallback=true;
            SetPosition(row,row.X);
            DanmakuSources.Trace("presentation","motion","fallback");
        }

        void StartMotion(Moving row)
        {
            try
            {
                if(row.Position is null&&!row.Fallback)
                {
                    // The XAML facade has one writer: an expression backed by
                    // a property set we own, outside the XAML backing visual.
                    var compositor=CompositionTarget.GetCompositorForCurrentThread();
                    var position=compositor.CreatePropertySet();
                    var translation=compositor.CreateExpressionAnimation("Vector3(position.X, 0, 0)");
                    try
                    {
                        position.InsertScalar("X",(float)row.X);
                        translation.SetReferenceParameter("position",position);
                        translation.Target="Translation";
                        row.View.StartAnimation(translation);
                    }
                    catch
                    {
                        translation.Dispose();position.Dispose();throw;
                    }
                    row.Position=position;row.Translation=translation;
                }
                SetPosition(row,row.X);
                if(row.Comment.Mode!=1||row.Fallback)return;

                var properties=row.Position!;
                var animation=properties.Compositor.CreateScalarKeyFrameAnimation();
                row.Travel=animation;
                using var linear=properties.Compositor.CreateLinearEasingFunction();
                animation.Duration=TimeSpan.FromSeconds(Math.Max(.001,row.End-clock));
                animation.StopBehavior=AnimationStopBehavior.SetToFinalValue;
                animation.InsertKeyFrame(0,(float)row.X,linear);
                animation.InsertKeyFrame(1,(float)row.ExitX,linear);
                properties.StartAnimation("X",animation);
                row.Motion=properties.TryGetAnimationController("X")
                    ??throw new InvalidOperationException("Missing danmaku motion controller");
                ApplyMotionRate(row,resume:false);
            }
            catch(Exception e)when(IsMotionFailure(e)){UseFallback(row);}
        }

        void UpdateFallbackRendering()
        {
            bool needed=motionRate>0&&active.Any(row=>row.Fallback&&row.Comment.Mode==1);
            if(needed==fallbackRendering)return;
            fallbackRendering=needed;
            if(needed)CompositionTarget.Rendering+=PaintFallbackFrame;
            else CompositionTarget.Rendering-=PaintFallbackFrame;
        }

        void PaintFallbackFrame(object? sender,object args)
        {
            if(!Current||renderedAt==0||motionRate==0)return;
            double progress=Stopwatch.GetElapsedTime(renderedAt).TotalSeconds*motionRate;
            foreach(var row in active)
                if(row.Fallback&&row.Comment.Mode==1&&row.Fits)
                    SetPosition(row,Math.Max(row.ExitX,row.X-progress*row.Velocity));
        }

        void Reflow()
        {
            double width=overlay.ActualWidth,height=overlay.ActualHeight;
            if(width<100||height<80)return;
            RefreshGlyphMetrics();
            int lanes=LaneCount(height);
            for(int i=0;i<active.Count;i++)
            {
                var row=active[i];
                Canvas.SetTop(row.View,LaneY(row.Comment.Mode,row.Row,height));
                // Resize and appearance changes do not restart rolling rows.
                // Keep their trajectories and only recheck the available lanes.
                if(row.Comment.Mode!=1)SetPosition(row,(width-row.Width)/2);
                row.Fits=row.Row<lanes&&SubtitleClear(Canvas.GetTop(row.View),height);
                for(int j=0;row.Fits&&j<i;j++)
                {
                    var old=active[j];
                    if(old.View.Visibility!=Visibility.Visible||Math.Abs(Canvas.GetTop(old.View)-Canvas.GetTop(row.View))>=RowHeight-.01)continue;
                    row.Fits=row.Comment.Mode==1&&old.Comment.Mode==1&&CanFollow(old,row.X,row.Velocity);
                }
                row.View.Visibility=row.Fits&&ModeEnabled(row.Comment.Mode)?Visibility.Visible:Visibility.Collapsed;
            }
        }
        void AppearanceChanged()
        {
            options.Normalize();
            foreach(var row in active)
            {
                row.View.Background=options.Background?textBackground:null;row.View.Opacity=options.Opacity;
            }
            Reflow();saveTimer.Stop();saveTimer.Start();
        }
        internal void GuardSeek()=>Guard(()=>{if(!Current||track is null)return;Clear();MediaClock.Seek(Access.Get<double>(session,"_position"));mediaEpoch=-1;Reindex();if(options.Enabled)timer.Start();});
        bool ModeEnabled(int mode)=>mode==1?options.Scroll:mode==4?options.Bottom:options.Top;
        void ModesChanged()
        {
            options.Normalize();Reflow();
            saveTimer.Stop();saveTimer.Start();
        }
        void Changed(bool retry=false)
        {
            options.Normalize();PaintFeatured();_=Save();
            if(!options.Enabled){frameProbe=default;Clear();motionRate=0;renderedAt=0;last=double.NaN;canvas.Visibility=Visibility.Collapsed;waiting=false;timer.Stop();retryTimer.Stop();Cancel();StopFeed();request++;Describe("弹幕已关闭");}
            else{
                if(retry)Search(true);
                else if(sourceTracks.Count==0&&options.Automatic&&!searching){waiting=true;Ready();}
                foreach(var source in sourceTracks.Values)
                    if(DanmakuSources.ValidCid(source.StreamCid)||source.PublicFeed is not null)StartFeed(source);
                if(sourceTracks.Count>0)RefreshCombined();
                if(track is not null){Reindex(false);Render();timer.Start();}
                canvas.Visibility=Visibility.Visible;
            }
        }
        async Task Save(){try{await DanmakuStorage.Save(options).ConfigureAwait(false);}catch(Exception e){Log(e);}}
        async Task Import()
        {
            int media=generation;
            try{
                if(!Current)return;
                var picker=new Windows.Storage.Pickers.FileOpenPicker();picker.FileTypeFilter.Add(".xml");
                var owner=Access.Get<object>(session,"_window");var hwnd=(IntPtr)owner.GetType().GetProperty("Handle")!.GetValue(owner)!;
                WinRT.Interop.InitializeWithWindow.Initialize(picker,hwnd);
                var file=await picker.PickSingleFileAsync();if(file is null||!Current||generation!=media)return;
                Cancel();retryTimer.Stop();int version=++request;var cts=lifetime=new CancellationTokenSource();var token=cts.Token;
                var rows=await Task.Run(async()=>{
                    using var input=File.OpenRead(file.Path);using var buffer=new MemoryStream();var block=new byte[16384];int n;
                    while((n=await input.ReadAsync(block,token).ConfigureAwait(false))>0){if(buffer.Length+n>8*1024*1024)throw new InvalidDataException("XML too large");buffer.Write(block,0,n);}
                    return DanmakuProtocol.Xml(buffer.ToArray());
                },token);
                if(!Current||version!=request)return;
                ResetSources();ApplyTrack(new("本地 XML",identity?.Key??"manual",0,rows,100));
            }catch(OperationCanceledException){}catch(Exception e){if(Current&&generation==media)Describe("本地弹幕未加载，请检查 XML 格式或文件大小");Log(e);}
        }
        internal UIElement Menu()
        {
            if(!optionsReady)return new TextBlock{Text="弹幕偏好正在读取，请稍后重新打开",TextWrapping=TextWrapping.Wrap};
            var body=new StackPanel{Spacing=12};bool syncing=false;
            var tabs=new Grid{ColumnSpacing=8};tabs.ColumnDefinitions.Add(new(){Width=new(1,GridUnitType.Star)});tabs.ColumnDefinitions.Add(new(){Width=new(1,GridUnitType.Star)});
            var settingsTab=new ToggleButton{Content="弹幕设置",IsChecked=true,HorizontalAlignment=HorizontalAlignment.Stretch};
            var sourceTab=new ToggleButton{Content="弹幕来源",HorizontalAlignment=HorizontalAlignment.Stretch};Grid.SetColumn(sourceTab,1);tabs.Children.Add(settingsTab);tabs.Children.Add(sourceTab);body.Children.Add(tabs);
            var settings=new StackPanel{Spacing=8};var sources=new StackPanel{Spacing=10,Visibility=Visibility.Collapsed};body.Children.Add(settings);body.Children.Add(sources);
            void Page(bool source){settingsTab.IsChecked=!source;sourceTab.IsChecked=source;settings.Visibility=source?Visibility.Collapsed:Visibility.Visible;sources.Visibility=source?Visibility.Visible:Visibility.Collapsed;}
            settingsTab.Click+=(_,_)=>Page(false);sourceTab.Click+=(_,_)=>Page(true);
            var enabledRow=new Grid();enabledRow.ColumnDefinitions.Add(new(){Width=new(1,GridUnitType.Star)});enabledRow.ColumnDefinitions.Add(new(){Width=GridLength.Auto});
            enabledRow.Children.Add(new TextBlock{Text="显示弹幕",FontSize=12,VerticalAlignment=VerticalAlignment.Center});
            var enabled=new ToggleSwitch{IsOn=options.Enabled,OnContent="开启",OffContent="关闭",MinWidth=0};Grid.SetColumn(enabled,1);enabledRow.Children.Add(enabled);
            enabled.Toggled+=(_,_)=>Guard(()=>{options.Enabled=enabled.IsOn;Changed();});settings.Children.Add(enabledRow);
            var types=new Grid{ColumnSpacing=6};var typeRefresh=new List<Action>();int column=0;
            void Type(string label,Func<bool> read,Action<bool> write)
            {
                types.ColumnDefinitions.Add(new(){Width=new(1,GridUnitType.Star)});
                var button=new ToggleButton{Content=label,IsChecked=read(),HorizontalAlignment=HorizontalAlignment.Stretch,MinWidth=0,Padding=new(6,7,6,7)};Grid.SetColumn(button,column++);types.Children.Add(button);
                button.Click+=(_,_)=>Guard(()=>{write(button.IsChecked==true);ModesChanged();});typeRefresh.Add(()=>button.IsChecked=read());
            }
            Type("滚动",()=>options.Scroll,v=>options.Scroll=v);Type("顶部",()=>options.Top,v=>options.Top=v);Type("底部",()=>options.Bottom,v=>options.Bottom=v);settings.Children.Add(types);
            var refresh=new List<Action>();
            void Range(string label,double min,double max,double step,Func<double> read,Action<double> write,Func<double,string> format)
            {
                var row=new Grid{ColumnSpacing=10};row.ColumnDefinitions.Add(new(){Width=new(72)});row.ColumnDefinitions.Add(new(){Width=new(1,GridUnitType.Star)});row.ColumnDefinitions.Add(new(){Width=new(46)});
                var caption=new TextBlock{Text=label,FontSize=12,VerticalAlignment=VerticalAlignment.Center};row.Children.Add(caption);
                var slider=new Slider{Minimum=min,Maximum=max,StepFrequency=step,Value=read(),MinWidth=0,MinHeight=0,Height=28,IsThumbToolTipEnabled=false,VerticalAlignment=VerticalAlignment.Center};Grid.SetColumn(slider,1);row.Children.Add(slider);
                var value=new TextBlock{Text=format(read()),FontSize=12,HorizontalAlignment=HorizontalAlignment.Right,VerticalAlignment=VerticalAlignment.Center};Grid.SetColumn(value,2);row.Children.Add(value);
                PlayerSliderInput.ConfigureDanmaku(slider);
                slider.ValueChanged+=(_,_)=>Guard(()=>{if(syncing)return;write(slider.Value);value.Text=format(read());AppearanceChanged();});
                refresh.Add(()=>{slider.Value=read();value.Text=format(read());});settings.Children.Add(row);
            }
            Range("不透明度",15,100,5,()=>options.Opacity*100,v=>options.Opacity=v/100,v=>v.ToString("0")+"%");
            Range("基础字号",14,40,1,()=>options.FontSize,v=>options.FontSize=v,v=>v.ToString("0"));
            var adaptive=new CheckBox{Content="随播放窗口自动适配字号",IsChecked=options.AdaptiveSize,FontSize=12,MinHeight=28};
            adaptive.Checked+=(_,_)=>Guard(()=>{if(!syncing){options.AdaptiveSize=true;AppearanceChanged();}});adaptive.Unchecked+=(_,_)=>Guard(()=>{if(!syncing){options.AdaptiveSize=false;AppearanceChanged();}});settings.Children.Add(adaptive);refresh.Add(()=>adaptive.IsChecked=options.AdaptiveSize);
            var background=new CheckBox{Content="显示文字背景框",IsChecked=options.Background,FontSize=12,MinHeight=28};
            background.Checked+=(_,_)=>Guard(()=>{if(!syncing){options.Background=true;AppearanceChanged();}});background.Unchecked+=(_,_)=>Guard(()=>{if(!syncing){options.Background=false;AppearanceChanged();}});settings.Children.Add(background);refresh.Add(()=>background.IsChecked=options.Background);
            Range("显示区域",20,100,5,()=>options.Area*100,v=>options.Area=v/100,v=>v.ToString("0")+"%");
            Range("弹幕速度",45,225,5,()=>900/options.TravelSeconds,v=>options.TravelSeconds=900/v,v=>(v/100).ToString("0.##")+"倍");
            var hint=new TextBlock{Text="弹幕会避开常规字幕区。底部弹幕显示在预留字幕区的上方。",FontSize=11,Opacity=.65,TextWrapping=TextWrapping.Wrap};settings.Children.Add(hint);
            var reset=new Button{Content="恢复默认设置",HorizontalAlignment=HorizontalAlignment.Right};reset.Click+=(_,_)=>Guard(()=>{
                options.Opacity=.8;options.FontSize=24;options.AdaptiveSize=true;options.Background=false;options.Area=.5;options.TravelSeconds=9;options.Scroll=options.Top=options.Bottom=true;
                syncing=true;try{foreach(var update in refresh)update();foreach(var update in typeRefresh)update();}finally{syncing=false;}AppearanceChanged();
            });settings.Children.Add(reset);
            status=new TextBlock{Text=description,TextWrapping=TextWrapping.Wrap,FontSize=12};sources.Children.Add(status);
            void Toggle(string label,bool value,Action<bool> change){var box=new CheckBox{Content=label,IsChecked=value};box.Checked+=(_,_)=>Guard(()=>change(true));box.Unchecked+=(_,_)=>Guard(()=>change(false));sources.Children.Add(box);}
            Toggle("自动在线匹配",options.Automatic,v=>{options.Automatic=v;Changed(v);if(!v){waiting=false;Cancel();retryTimer.Stop();request++;}});
            var retry=new Button{Content="重新匹配公开弹幕",HorizontalAlignment=HorizontalAlignment.Stretch};retry.Click+=(_,_)=>Guard(()=>{if(options.Enabled)Search(true);});sources.Children.Add(retry);
            var query=new TextBox{Header="搜索片名或粘贴单集链接",PlaceholderText="片名，或哔哩哔哩／腾讯视频／爱奇艺的单集链接",MaxLength=320};sources.Children.Add(query);
            var search=new Button{Content="查找在线弹幕",HorizontalAlignment=HorizontalAlignment.Stretch};search.Click+=(_,_)=>Guard(()=>{
                if(!options.Enabled||string.IsNullOrWhiteSpace(query.Text))return;
                if(query.Text.Contains("://",StringComparison.Ordinal)&&!DanmakuSources.IsPlatformLink(query.Text)&&!(Uri.TryCreate(query.Text.Trim(),UriKind.Absolute,out var uri)&&uri.Scheme=="https"&&uri.Host is "www.bilibili.com" or "bilibili.com")){Describe("请使用片名或支持的平台公开播放链接");return;}
                Search(true,query.Text.Trim());
            });sources.Children.Add(search);
            candidateBox=new ComboBox{Header="匹配候选",HorizontalAlignment=HorizontalAlignment.Stretch};FillCandidates();sources.Children.Add(candidateBox);
            var select=new Button{Content="使用所选弹幕",HorizontalAlignment=HorizontalAlignment.Stretch};select.Click+=(_,_)=>Guard(()=>{
                if(!Current||!options.Enabled||identity is null||candidateBox.SelectedItem is not ComboBoxItem{Tag:DanmakuCandidate choice})return;
                retryTimer.Stop();var selected=DanmakuSources.Select(choice,identity);ApplyTrack(selected);_=SaveSelection(selected);
            });sources.Children.Add(select);
            var import=new Button{Content="加载本地 XML 弹幕…",HorizontalAlignment=HorizontalAlignment.Stretch};import.Click+=async(_,_)=>await Import();sources.Children.Add(import);
            var delay=new NumberBox{Header="时间偏移（秒，正数晚出现）",Value=options.Delay,Minimum=-3600,Maximum=3600,SmallChange=.5};
            delay.ValueChanged+=(_,_)=>Guard(()=>{if(double.IsFinite(delay.Value)){options.Delay=delay.Value;Clear();Reindex();Changed();}});sources.Children.Add(delay);
            var api=new TextBox{Header="兼容弹幕服务（HTTPS，可选，添加额外来源）",Text=options.CompatibleApi,MaxLength=512};sources.Children.Add(api);
            var apply=new Button{Content="保存服务地址",HorizontalAlignment=HorizontalAlignment.Stretch};apply.Click+=(_,_)=>Guard(()=>{options.CompatibleApi=api.Text;options.Normalize();api.Text=options.CompatibleApi;Changed(true);});sources.Children.Add(apply);
            var clear=new Button{Content="清空弹幕缓存",HorizontalAlignment=HorizontalAlignment.Stretch};clear.Click+=async(_,_)=>{
                clear.IsEnabled=false;
                try{Cancel();ResetSources();retryTimer.Stop();timer.Stop();Clear();request++;await DanmakuStorage.Clear();if(Current)Describe("弹幕缓存已清空，可重新匹配");}
                catch(Exception e){Log(e);}finally{if(overlay.IsLoaded)clear.IsEnabled=true;}
            };sources.Children.Add(clear);
            sources.Children.Add(new TextBlock{Text="自动查找哔哩哔哩、腾讯视频和爱奇艺，匹配同一集后合并去重。腾讯和爱奇艺的分集链接通过 360 影视目录查找。",TextWrapping=TextWrapping.Wrap,FontSize=12});
            return body;
        }
        async Task SaveSelection(DanmakuTrack selection){try{await DanmakuStorage.Write(selection,CancellationToken.None).ConfigureAwait(false);}catch(Exception e){Log(e);}}
    }
}
