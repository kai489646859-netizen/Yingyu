using System.Runtime.InteropServices;
using System.Runtime.CompilerServices;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Windows.System;

namespace Yingyu.Update;

// A chord has one virtual key and explicit modifiers. All editing and dispatch
// share this policy; old fixed commands cannot silently steal a custom binding.
public static class ShortcutBinding
{
    static readonly ConditionalWeakTable<Button,Func<bool>> Recorders=new();
    internal static bool IsRecording(XamlRoot? root)
    {
        if(root==null)return false;
        for(var node=FocusManager.GetFocusedElement(root) as DependencyObject;node!=null;node=Microsoft.UI.Xaml.Media.VisualTreeHelper.GetParent(node))
            if(node is Button button&&Recorders.TryGetValue(button,out var active)&&active())return true;
        return false;
    }
    public const int Ctrl=0x10000,Shift=0x20000,Alt=0x40000;
    [DllImport("user32.dll")] static extern short GetKeyState(int key);
    public static int Modifiers() => ((GetKeyState(17)&0x8000)!=0?Ctrl:0)|((GetKeyState(16)&0x8000)!=0?Shift:0)|((GetKeyState(18)&0x8000)!=0?Alt:0);
    public static bool Valid(int chord)
    {
        int key=chord&0xFFFF,mods=chord&~0xFFFF;
        if((mods&~(Ctrl|Shift|Alt))!=0)return false;
        if(!(key is 32 or 38 or 40 || key is >=48 and <=90 || key is >=96 and <=123 || key is >=186 and <=192 || key is >=219 and <=222))return false;
        // Windows-owned and existing transport commands retain their meaning.
        if(mods==0&&key is 74 or 76 or 219 or 221)return false;
        if((mods&Alt)!=0&&key==115)return false; // Alt+F4
        return true;
    }
    public static int[] Values(DesktopThemeOptions o)=>[o.PauseKey,o.MuteKey,o.FullScreenKey,o.VolumeUpKey,o.VolumeDownKey];
    public static readonly string[] Labels=["播放／暂停","静音","全屏","音量加","音量减"];
    static readonly int[] Defaults=[32,77,70,38,40];
    public static DesktopThemeOptions Normalize(DesktopThemeOptions o)
    {
        var values=Values(o);
        // Earlier files do not distinguish an explicitly selected B from the
        // old default. Migrate only the complete old default set; customized
        // layouts keep their bindings. New edits carry explicit provenance.
        if(o.ShortcutVersion<2 && o.CustomShortcutMask==0
            && values.SequenceEqual(new[]{32,66,70,38,40}))values[1]=77;
        var used=new HashSet<int>();
        for(int i=0;i<values.Length;i++){
            if(!Valid(values[i])||!used.Add(values[i])){
                int key=Defaults[i];if(used.Contains(key))key=Enumerable.Range(112,12).First(k=>!used.Contains(k));
                values[i]=key;used.Add(key);
            }
        }
        return o with{PauseKey=values[0],MuteKey=values[1],FullScreenKey=values[2],VolumeUpKey=values[3],VolumeDownKey=values[4],ShortcutVersion=2,RightHoldBoost=true,KeyboardVolumeKeys=true};
    }
    public static string Format(int chord)
    {
        int key=chord&0xFFFF;
        string label=key switch{32=>"空格",38=>"↑",40=>"↓",>=112 and <=123=>"F"+(key-111),>=96 and <=105=>"小键盘 "+(key-96),_=>((VirtualKey)key).ToString()};
        return ((chord&Ctrl)!=0?"Ctrl + ":"")+((chord&Shift)!=0?"Shift + ":"")+((chord&Alt)!=0?"Alt + ":"")+label;
    }
    public static int Command(DesktopThemeOptions o,int key,int modifiers)
    {
        int at=Array.IndexOf(Values(o),key|modifiers);
        return at<0?0:new[]{32,77,70,38,40}[at];
    }
    internal static void AddEditors(Panel panel,Func<DesktopThemeOptions,bool> save)
    {
        var message=new TextBlock{Text="点击右侧按键后，按下新快捷键。支持 Ctrl、Shift、Alt 组合；Esc 取消。",TextWrapping=TextWrapping.Wrap,FontSize=13};
        for(int i=0;i<Labels.Length;i++){
            int index=i;var row=new Grid{ColumnSpacing=16};row.ColumnDefinitions.Add(new(){Width=new(1,GridUnitType.Star)});row.ColumnDefinitions.Add(new(){Width=GridLength.Auto});
            row.Children.Add(new TextBlock{Text=Labels[i]+"快捷键",VerticalAlignment=VerticalAlignment.Center,TextWrapping=TextWrapping.Wrap});
            var button=new Button{Name="ShortcutCapture"+i,Content=Format(Values(DesktopTheme.Options)[i]),MinWidth=100,MinHeight=36};Grid.SetColumn(button,1);row.Children.Add(button);
            bool capturing=false;VirtualKey blocked=VirtualKey.None;
            Recorders.Add(button,()=>capturing);
            void Reset(){capturing=false;button.Content=Format(Values(DesktopTheme.Options)[index]);}
            button.Click+=(_,_)=>{capturing=true;button.Content="请按快捷键…";message.Text="正在设置“"+Labels[index]+"”：按 Esc 取消。";button.Focus(FocusState.Programmatic);};
            button.PreviewKeyDown+=(_,e)=>{
                if(e.Key==blocked&&e.KeyStatus.WasKeyDown){e.Handled=true;return;}
                if(!capturing)return;
                e.Handled=true;if(e.KeyStatus.WasKeyDown)return;
                if(e.Key==VirtualKey.Escape){blocked=e.Key;Reset();message.Text="已取消，原快捷键保持。";return;}
                if(e.Key is VirtualKey.Control or VirtualKey.Shift or VirtualKey.Menu or VirtualKey.LeftControl or VirtualKey.RightControl or VirtualKey.LeftShift or VirtualKey.RightShift or VirtualKey.LeftMenu or VirtualKey.RightMenu)return;
                int chord=(int)e.Key|Modifiers();
                if(!Valid(chord)){message.Text="该按键保留给系统或播放定位，请换一个按键。";return;}
                var values=Values(DesktopTheme.Options);int conflict=Array.IndexOf(values,chord);
                if(conflict>=0&&conflict!=index){message.Text="已用于“"+Labels[conflict]+"”，请换一个快捷键。";return;}
                values[index]=chord;var next=DesktopTheme.Options with{PauseKey=values[0],MuteKey=values[1],FullScreenKey=values[2],VolumeUpKey=values[3],VolumeDownKey=values[4],ShortcutVersion=2,CustomShortcutMask=DesktopTheme.Options.CustomShortcutMask|(1<<index)};
                if(save(next)){blocked=e.Key;Reset();message.Text="已保存：“"+Labels[index]+"”使用 "+Format(chord)+"。";}else message.Text="保存失败，原快捷键保持，请重试。";
            };
            button.PreviewKeyUp+=(_,e)=>{if(capturing||e.Key==blocked){e.Handled=true;blocked=VirtualKey.None;}};
            button.LostFocus+=(_,_)=>{if(capturing){Reset();message.Text="已取消录入，原快捷键保持。";}};
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button,Labels[i]+"快捷键，点击修改");panel.Children.Add(row);
        }
        panel.Children.Add(message);
    }
}
