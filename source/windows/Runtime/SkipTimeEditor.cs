using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Yingyu.Update;

internal static class SkipTimeEditor
{
    internal static StackPanel Build(NumberBox original, bool credits,
        Func<(double Position,double Duration)> current, Action<string> status)
    {
        var pane=new StackPanel{Spacing=8};
        pane.Children.Add(new TextBlock{Text=credits?"片尾时长":"片头时长",TextWrapping=TextWrapping.Wrap});
        var row=new Grid{ColumnSpacing=8};row.ColumnDefinitions.Add(new(){Width=new(1,GridUnitType.Star)});row.ColumnDefinitions.Add(new(){Width=new(1,GridUnitType.Star)});
        var minutes=new NumberBox{Name=credits?"CreditsMinutes":"IntroMinutes",Header="分",Minimum=0,Maximum=Math.Floor(original.Maximum/60),SmallChange=1,SpinButtonPlacementMode=NumberBoxSpinButtonPlacementMode.Compact};
        var seconds=new NumberBox{Name=credits?"CreditsSeconds":"IntroSeconds",Header="秒",Minimum=0,Maximum=59,SmallChange=1,SpinButtonPlacementMode=NumberBoxSpinButtonPlacementMode.Compact};
        row.Children.Add(minutes);Grid.SetColumn(seconds,1);row.Children.Add(seconds);pane.Children.Add(row);
        bool painting=false;
        void Paint(){painting=true;try{double value=double.IsFinite(original.Value)?Math.Floor(original.Value):0;minutes.Value=Math.Floor(value/60);seconds.Value=value%60;}finally{painting=false;}}
        void Edit(){if(painting||!double.IsFinite(minutes.Value)||!double.IsFinite(seconds.Value))return;original.Value=Math.Clamp(Math.Floor(minutes.Value)*60+Math.Floor(seconds.Value),original.Minimum,original.Maximum);Paint();}
        minutes.ValueChanged+=(_,_)=>Edit();seconds.ValueChanged+=(_,_)=>Edit();Paint();
        var use=new Button{Name=credits?"UseCurrentCredits":"UseCurrentIntro",Content=credits?"当前位置设为片尾开始":"当前位置设为片头结束",HorizontalAlignment=HorizontalAlignment.Stretch};
        use.Click+=(_,_)=>
        {
            try
            {
                var snapshot=current();
                if(!double.IsFinite(snapshot.Position)||!double.IsFinite(snapshot.Duration)||snapshot.Duration<=0||snapshot.Position<0||snapshot.Position>snapshot.Duration)
                    throw new InvalidOperationException("等待播放位置和时长就绪后再设置。");
                double value=Math.Floor(credits?snapshot.Duration-snapshot.Position:snapshot.Position);
                if(value<original.Minimum||value>original.Maximum)throw new InvalidOperationException($"时长须在 {original.Minimum/60:0}—{original.Maximum/60:0} 分钟内，可手动调整。");
                original.Value=value;Paint();status("已填入当前时间，点击“记住本剧跳过时间”保存。");
            }
            catch(InvalidOperationException e){status(e.Message);}
        };
        pane.Children.Add(use);
        pane.Children.Add(new TextBlock{Text="0 分 0 秒表示不手动设置",FontSize=12,TextWrapping=TextWrapping.Wrap});
        return pane;
    }
}
