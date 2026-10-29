using System.Reflection;
using System.Runtime.CompilerServices;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.System;

namespace Yingyu.Update;

internal static class DesktopLogin
{
    static readonly ConditionalWeakTable<FrameworkElement,State> Pages=new();
    const BindingFlags Flags=BindingFlags.Public|BindingFlags.NonPublic|BindingFlags.Instance;
    static T? Find<T>(FrameworkElement page,string name) where T:class
        =>page.GetType().GetField(name,Flags)?.GetValue(page) as T??page.FindName(name) as T;
    internal static void Apply(FrameworkElement page,DesktopThemePalette palette)
        =>Pages.GetValue(page,p=>new State(p)).Update(palette);
    sealed class State
    {
        readonly FrameworkElement page;
        readonly Grid? login;
        readonly Grid board=new(){ColumnSpacing=48,RowSpacing=24};
        readonly Grid canvas=new();
        readonly ScrollViewer scroll=new(){VerticalScrollBarVisibility=ScrollBarVisibility.Auto,HorizontalScrollBarVisibility=ScrollBarVisibility.Disabled,HorizontalScrollMode=ScrollMode.Disabled,Padding=new Thickness(32)};
        readonly StackPanel brand=new(){Spacing=18,VerticalAlignment=VerticalAlignment.Center};
        readonly Border form=new(){Padding=new Thickness(28),CornerRadius=new(24),BorderThickness=new(1)};
        readonly Border mark=new(){Width=64,Height=64,CornerRadius=new(20),HorizontalAlignment=HorizontalAlignment.Left};
        readonly TextBlock name=new(){Text="映屿",FontSize=42,FontWeight=Microsoft.UI.Text.FontWeights.SemiBold};
        readonly TextBlock intro=new(){Text="连接你的媒体库",FontSize=26,FontWeight=Microsoft.UI.Text.FontWeights.SemiBold};
        readonly TextBlock description=new(){Text="选择已保存的账号，或添加服务器。\n从这里，继续你的观影时光。",FontSize=15,LineHeight=25,TextWrapping=TextWrapping.Wrap};
        readonly TextBlock heading=new(){Text="欢迎回来",FontSize=26,FontWeight=Microsoft.UI.Text.FontWeights.SemiBold};
        readonly TextBlock hint=new(){Text="登录 Emby，开始浏览与观看",FontSize=14,TextWrapping=TextWrapping.Wrap};
        readonly TextBlock footer=new(){Text="选择服务器，继续你的观影时光。",FontSize=12,TextWrapping=TextWrapping.Wrap};
        readonly StackPanel serverStep=new(){Spacing=16},accountStep=new(){Spacing=16,Visibility=Visibility.Collapsed};
        readonly TextBlock serverSummary=new(){TextWrapping=TextWrapping.Wrap,FontSize=13};
        readonly TextBlock serverError=new(){TextWrapping=TextWrapping.Wrap,Visibility=Visibility.Collapsed};
        readonly Button next=new(){Content="继续登录",HorizontalAlignment=HorizontalAlignment.Stretch},back=new(){Content="更换服务器",HorizontalAlignment=HorizontalAlignment.Left};
        readonly Image icon=new(){Width=64,Height=64,Stretch=Stretch.Uniform,Source=new BitmapImage(new Uri(Path.Combine(AppContext.BaseDirectory,"Assets","AppIconSource.png")))};
        readonly bool ready;
        public State(FrameworkElement page)
        {
            this.page=page;login=Find<Grid>(page,"LoginGrid");
            var saved=Find<StackPanel>(page,"SavedLoginAccountsPanel");
            var add=Find<Expander>(page,"NewAccountExpander");var status=Find<TextBlock>(page,"LoginStatusText");
            if(login==null||saved==null||add==null||status==null)return;
            // Move the original bound controls, retaining native event handlers,
            // current busy/error state and the saved-account collection.
            var detachSaved=Removal(login,saved);var detachAdd=Removal(login,add);var detachStatus=Removal(login,status);
            if(detachSaved==null||detachAdd==null||detachStatus==null)return;
            detachStatus();detachAdd();detachSaved();
            mark.Child=icon;brand.Children.Add(mark);brand.Children.Add(name);brand.Children.Add(intro);brand.Children.Add(description);
            var fields=new StackPanel{Spacing=18};fields.Children.Add(heading);fields.Children.Add(hint);
            fields.Children.Add(status);fields.Children.Add(saved);fields.Children.Add(add);fields.Children.Add(footer);form.Child=fields;
            add.Header="添加其他账号";add.HorizontalAlignment=HorizontalAlignment.Stretch;
            if(Find<TextBox>(page,"ServerUrlBox") is {} address&&Find<TextBox>(page,"UsernameBox") is {} username&&Find<PasswordBox>(page,"PasswordBox") is {} password&&Find<Button>(page,"LoginButton") is {} loginButton
                &&Removal(add,address) is {} removeAddress&&Removal(add,username) is {} removeUsername&&Removal(add,password) is {} removePassword&&Removal(add,loginButton) is {} removeLogin)
            {
                removeAddress();removeUsername();removePassword();removeLogin();
                address.Header="服务器地址";username.Header="用户名";password.Header="密码";password.PasswordRevealMode=PasswordRevealMode.Peek;
                serverStep.Children.Add(address);serverStep.Children.Add(serverError);serverStep.Children.Add(next);
                accountStep.Children.Add(serverSummary);accountStep.Children.Add(back);accountStep.Children.Add(username);accountStep.Children.Add(password);accountStep.Children.Add(loginButton);
                var steps=new StackPanel{Spacing=16};steps.Children.Add(serverStep);steps.Children.Add(accountStep);
                if(Find<Button>(page,"CancelAddServerButton") is {} cancel&&Removal(add,cancel) is {} removeCancel){removeCancel();steps.Children.Add(cancel);}
                if(Find<ProgressRing>(page,"LoginProgress") is {} progress&&Removal(add,progress) is {} removeProgress){removeProgress();steps.Children.Add(progress);}
                add.Content=steps;add.Header="添加服务器";
                void Advance(){if(!Uri.TryCreate(address.Text,UriKind.Absolute,out var uri)||uri.Scheme is not ("http" or "https")||string.IsNullOrWhiteSpace(uri.Host)){serverError.Text="请输入完整的 HTTP 或 HTTPS 服务器地址。";serverError.Visibility=Visibility.Visible;address.Focus(FocusState.Keyboard);return;}serverError.Visibility=Visibility.Collapsed;serverSummary.Text="登录到 "+uri.Host+(uri.IsDefaultPort?"":":"+uri.Port)+uri.AbsolutePath;serverStep.Visibility=Visibility.Collapsed;accountStep.Visibility=Visibility.Visible;username.Focus(FocusState.Keyboard);}
                next.Click+=(_,_)=>Advance();back.Click+=(_,_)=>{accountStep.Visibility=Visibility.Collapsed;serverStep.Visibility=Visibility.Visible;address.Focus(FocusState.Keyboard);};
                address.PreviewKeyDown+=(_,e)=>{if(e.Key==VirtualKey.Enter){e.Handled=true;Advance();}};
            }
            board.Children.Add(brand);board.Children.Add(form);
            board.VerticalAlignment=VerticalAlignment.Center;canvas.Children.Add(board);scroll.Content=canvas;
            void Center(){canvas.MinHeight=Math.Max(0,scroll.ViewportHeight);}
            scroll.Loaded+=(_,_)=>Center();scroll.SizeChanged+=(_,_)=>Center();
            login.Children.Clear();login.RowDefinitions.Clear();login.ColumnDefinitions.Clear();login.Children.Add(scroll);
            ready=true;
        }
        static Action? Removal(DependencyObject root,FrameworkElement element)
        {
            // Before first layout WinUI can leave Parent unset even while a
            // control belongs to a logical collection. Find the actual owner.
            if(root is Panel panel)
            {
                if(panel.Children.Contains(element))return ()=>panel.Children.Remove(element);
                foreach(var child in panel.Children){var found=Removal(child,element);if(found!=null)return found;}
            }
            DependencyObject? content=root switch {Border border=>border.Child,ContentControl control=>control.Content as DependencyObject,ContentPresenter presenter=>presenter.Content as DependencyObject,_=>null};
            if(ReferenceEquals(content,element))return root switch {Border b=>()=>b.Child=null,ContentControl c=>()=>c.Content=null,ContentPresenter cp=>()=>cp.Content=null,_=>null};
            return content==null?null:Removal(content,element);
        }
        public void Update(DesktopThemePalette p)
        {
            if(!ready)return;
            double width=Math.Max(320,page.ActualWidth-80);bool wide=width>=980;
            board.Width=Math.Min(wide?978:560,width);board.HorizontalAlignment=HorizontalAlignment.Center;
            board.ColumnDefinitions.Clear();board.RowDefinitions.Clear();
            board.ColumnDefinitions.Add(new(){Width=wide?new GridLength(420):new GridLength(1,GridUnitType.Star)});
            if(wide)board.ColumnDefinitions.Add(new(){Width=new GridLength(510)});
            board.RowDefinitions.Add(new(){Height=GridLength.Auto});if(!wide)board.RowDefinitions.Add(new(){Height=GridLength.Auto});
            Grid.SetColumn(form,wide?1:0);Grid.SetRow(form,wide?0:1);
            form.MaxWidth=560;form.HorizontalAlignment=HorizontalAlignment.Stretch;
            brand.MaxWidth=wide?440:560;brand.HorizontalAlignment=wide?HorizontalAlignment.Stretch:HorizontalAlignment.Center;
            name.FontSize=wide?42:30;intro.Visibility=wide?Visibility.Visible:Visibility.Collapsed;
            description.Visibility=wide?Visibility.Visible:Visibility.Collapsed;
            mark.Visibility=wide?Visibility.Visible:Visibility.Collapsed;
            login!.Background=DesktopMaterial.Atmosphere(DesktopTheme.Options,p);form.Background=DesktopVisuals.Brush(p.Surface);form.BorderBrush=DesktopVisuals.Brush(p.Outline);
            next.Background=DesktopVisuals.Brush(p.Accent);next.Foreground=DesktopVisuals.Brush(Brightness(p.Accent)>160?0xFF202127:0xFFFFFFFF);next.MinHeight=44;next.CornerRadius=new(10);back.Foreground=DesktopVisuals.Brush(p.Text);serverSummary.Foreground=DesktopVisuals.Brush(p.Secondary);serverError.Foreground=DesktopVisuals.Brush(0xFFB93E3E);
            mark.Background=DesktopVisuals.Brush(0);
            foreach(var text in new[]{name,intro,heading})text.Foreground=DesktopVisuals.Brush(p.Text);
            foreach(var text in new[]{description,hint,footer})text.Foreground=DesktopVisuals.Brush(p.Secondary);
            foreach(var child in UiElements.Descendants(form))
            {
                if(child is TextBlock text&&text.Name is not ("LoginStatusText" or "LoginButtonText"))text.Foreground=DesktopVisuals.Brush(p.Text);
            }
            // The expander may never have been opened. Style its original
            // fields directly instead of depending on realized visual children.
            foreach(var key in new[]{"ServerUrlBox","UsernameBox"})
                if(Find<TextBox>(page,key) is {} input){input.MinHeight=44;input.MinWidth=0;input.Width=double.NaN;input.CornerRadius=new(10);input.Background=DesktopVisuals.Brush(p.Hover);input.Foreground=DesktopVisuals.Brush(p.Text);input.BorderBrush=DesktopVisuals.Brush(p.Outline);}
            if(Find<PasswordBox>(page,"PasswordBox") is {} password){password.MinHeight=44;password.MinWidth=0;password.Width=double.NaN;password.CornerRadius=new(10);password.Background=DesktopVisuals.Brush(p.Hover);password.Foreground=DesktopVisuals.Brush(p.Text);password.BorderBrush=DesktopVisuals.Brush(p.Outline);}
            if(Find<Expander>(page,"NewAccountExpander") is {} expander)expander.Foreground=DesktopVisuals.Brush(p.Text);
            if(Find<ComboBox>(page,"SavedLoginAccountCombo") is {} combo){combo.MinHeight=44;combo.Width=double.NaN;combo.HorizontalAlignment=HorizontalAlignment.Stretch;combo.CornerRadius=new(10);combo.Foreground=DesktopVisuals.Brush(p.Text);combo.Background=DesktopVisuals.Brush(p.Hover);}
            foreach(var key in new[]{"SavedAccountLoginButton","SavedAccountDeleteButton","LoginButton","CancelAddServerButton"})
            {
                if(Find<Button>(page,key) is not {} button)continue;
                bool primary=key is "SavedAccountLoginButton" or "LoginButton";
                uint foreground=primary?(Brightness(p.Accent)>160?0xFF202127:0xFFFFFFFF):p.Text;
                button.MinHeight=44;button.CornerRadius=new(12);button.Padding=new Thickness(18,10,18,10);
                button.Background=DesktopVisuals.Brush(primary?p.Accent:p.Hover);button.Foreground=DesktopVisuals.Brush(foreground);
                foreach(var suffix in new[]{"","PointerOver","Pressed","Disabled"})button.Resources["ButtonForeground"+suffix]=DesktopVisuals.Brush(foreground);
                button.Resources["ButtonBackgroundPointerOver"]=DesktopVisuals.Brush(primary?p.Accent:p.Selection);
                button.Resources["ButtonBackgroundPressed"]=DesktopVisuals.Brush(primary?p.Accent:p.Selection);
            }
        }
        static double Brightness(uint c)=>((c>>16)&255)*.2126+((c>>8)&255)*.7152+(c&255)*.0722;
    }
}
