using System.Runtime.CompilerServices;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.Foundation;
namespace Yingyu.Update;
internal static class DesktopDetailLayout
{
    static readonly ConditionalWeakTable<FrameworkElement,State> States=new();
    internal static void Apply(FrameworkElement page)=>States.GetValue(page,p=>new(p)).Queue();
    sealed class State
    {
        readonly FrameworkElement page;readonly TextBlock? synopsis;readonly Button? toggle;
        readonly TextBlock full=new(),limited=new();bool queued;
        public State(FrameworkElement page)
        {
            this.page=page;synopsis=Access.Get<TextBlock?>(page,"DetailOverviewText");toggle=Access.Get<Button?>(page,"DetailOverviewToggle");
            if(synopsis==null||toggle==null)return;
            synopsis.SizeChanged+=(_,e)=>{if(Math.Abs(e.NewSize.Width-e.PreviousSize.Width)>.5)Queue();};
            foreach(var property in new[]{TextBlock.TextProperty,TextBlock.FontSizeProperty,TextBlock.MaxLinesProperty})synopsis.RegisterPropertyChangedCallback(property,(_,_)=>Queue());
            toggle.Click+=(_,_)=>Queue();
        }
        internal void Queue()
        {
            if(queued)return;queued=true;
            if(!page.DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low,()=>{queued=false;try{Update();}catch(Exception e){try{PlaybackTransport.Write("Warning","Desktop.Detail","简介布局未完成；"+e.GetType().Name);}catch(Exception){}}}))queued=false;
        }
        void Update()
        {
            if(synopsis==null||toggle==null||!page.IsLoaded||Access.Get<Grid>(page,"DetailView").Visibility!=Visibility.Visible)return;
            double width=synopsis.ActualWidth;if(width<=0)return;
            void Prepare(TextBlock probe,int lines)
            {
                probe.Text=synopsis.Text;probe.FontFamily=synopsis.FontFamily;probe.FontSize=synopsis.FontSize;probe.FontWeight=synopsis.FontWeight;probe.FontStyle=synopsis.FontStyle;
                probe.CharacterSpacing=synopsis.CharacterSpacing;probe.FlowDirection=synopsis.FlowDirection;probe.IsTextScaleFactorEnabled=synopsis.IsTextScaleFactorEnabled;
                probe.TextWrapping=synopsis.TextWrapping;probe.LineHeight=synopsis.LineHeight;probe.LineStackingStrategy=synopsis.LineStackingStrategy;probe.TextLineBounds=synopsis.TextLineBounds;probe.Padding=synopsis.Padding;
                probe.MaxLines=lines;probe.TextTrimming=TextTrimming.None;probe.Measure(new Size(width,double.PositiveInfinity));
            }
            Prepare(full,0);Prepare(limited,3);
            bool overflow=!string.IsNullOrWhiteSpace(synopsis.Text)&&full.DesiredSize.Height>limited.DesiredSize.Height+.5;
            toggle.Visibility=overflow?Visibility.Visible:Visibility.Collapsed;
            toggle.Content=synopsis.MaxLines==0?"收起简介":"展开简介";
        }
    }
}
