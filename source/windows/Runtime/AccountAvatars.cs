using System.Runtime.CompilerServices;
using EmbyDesktop.Core.Models;
using EmbyDesktop.Core.Services;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.UI.Xaml.Shapes;

namespace Yingyu.Update;

public static class AccountAvatars
{
    static readonly ConditionalWeakTable<object,State> States=new();
    sealed class State
    {
        internal EmbySession? Session;
        internal EmbyApiClient? Client;
        internal CancellationTokenSource? Pending;
        internal Task Work=Task.CompletedTask;
        internal DateTimeOffset RetryAt;
        internal readonly Dictionary<string,ImageSource> Images=new(StringComparer.Ordinal);
        internal bool Hooked;
        internal readonly ImageBrush ToolbarImage=new(){Stretch=Stretch.UniformToFill};
    }
    static string Key(EmbySession s)=>s.ServerUrl+"|"+s.ServerId+"|"+s.UserId;
    public static Task Load(object page,EmbyApiClient? client,EmbySession session)
    {
        if(client==null)return Task.CompletedTask;
        var state=States.GetOrCreateValue(page);
        if(!state.Hooked)
        {
            state.Hooked=true;
            ((FrameworkElement)page).Unloaded+=(_,_)=>{state.Pending?.Cancel();state.Pending=null;state.Session=null;state.Client=null;state.Images.Clear();};
        }
        bool same=ReferenceEquals(state.Session,session)&&ReferenceEquals(state.Client,client);
        if(same&&(!state.Work.IsCompleted||DateTimeOffset.UtcNow<state.RetryAt))return state.Work;
        state.Pending?.Cancel();state.Pending=new();state.Pending.CancelAfter(TimeSpan.FromSeconds(15));
        state.Session=session;state.Client=client;state.RetryAt=DateTimeOffset.UtcNow.AddMinutes(5);
        Paint(page,state);
        state.Work=Fetch(page,state,client,session,state.Pending);
        return state.Work;
    }
    static async Task Fetch(object page,State state,EmbyApiClient client,EmbySession session,CancellationTokenSource cancellation)
    {
        bool Current()=>!cancellation.IsCancellationRequested&&ReferenceEquals(state.Pending,cancellation)
            &&ReferenceEquals(client,Access.Get<EmbyApiClient?>(page,"_client"))&&ReferenceEquals(session,Access.Get<EmbySession?>(page,"_session"));
        try
        {
            var user=await client.GetCurrentUserAsync(cancellation.Token);
            if(!Current()||user.Id!=session.UserId)return;
            var request=new PosterCacheRequest(session.ServerId,session.UserId,session.UserId,"UserPrimary",user.PrimaryImageTag,128,90);
            // Some compatible servers return the avatar without a revision tag.
            // Try the actual image endpoint instead of treating a missing tag as proof of no image.
            var cache=Access.Get<PosterCacheService>(page,"_posterCache");
            var file=await cache.GetOrDownloadAsync(request,client.BuildUserImageUri(session.UserId),cancellation.Token,PosterFetchPriority.Interactive,false,Current);
            if(file==null||!Current())return;
            var bitmap=await (Task<BitmapImage?>)Access.Call(page,"LoadBitmapFromFileAsync",file.FilePath,cancellation.Token)!;
            if(bitmap==null||!Current())return;
            state.Images[Key(session)]=bitmap;
            Access.Get<Image>(page,"UserAvatarImage").Source=bitmap;
            Paint(page,state);
        }
        catch(OperationCanceledException)when(cancellation.IsCancellationRequested){}
        catch(Exception){PlaybackTransport.Write("Warning","Account.Avatar","账户头像暂不可用，保留姓名占位。 ");}
        finally{if(ReferenceEquals(state.Pending,cancellation))state.Pending=null;cancellation.Dispose();}
    }
    public static void Refresh(object page)
    {
        var state=States.GetOrCreateValue(page);
        Paint(page,state);
        if(Access.Get<EmbySession?>(page,"_session") is {} session)_=Load(page,Access.Get<EmbyApiClient?>(page,"_client"),session);
    }
    static void Paint(object page,State state)
    {
        var current=Access.Get<EmbySession?>(page,"_session");
        if(current!=null)
        {
            state.Images.TryGetValue(Key(current),out var image);
            var original=Access.Get<Image>(page,"UserAvatarImage");original.Source=image;
            original.Stretch=Stretch.UniformToFill;
        }
        var profiles=(IEnumerable<ServerProfile>)Access.Call(page,"get_ServerProfiles")!;
        var panel=Access.Get<StackPanel>(page,"ProfileQuickSwitchPanel");
        foreach(var button in UiElements.Descendants(panel).OfType<Button>().ToArray())
        {
            if(button.Tag is not string id||profiles.FirstOrDefault(p=>p.Id==id)?.Session is not {} account)continue;
            UIElement? label=button.Content as UIElement;
            if(label is StackPanel existing&&existing.Name=="AccountAvatarRow")label=existing.Children.LastOrDefault() as UIElement;
            if(label==null)continue;
            if(button.Content is StackPanel previous&&previous.Name=="AccountAvatarRow")previous.Children.Remove(label);
            button.Content=null;
            var row=new StackPanel{Name="AccountAvatarRow",Orientation=Orientation.Horizontal,Spacing=10};
            state.Images.TryGetValue(Key(account),out var image);
            row.Children.Add(new PersonPicture{Width=30,Height=30,DisplayName=account.UserName,ProfilePicture=image});
            row.Children.Add(label);button.Content=row;
            if(label is FrameworkElement text)text.VerticalAlignment=VerticalAlignment.Center;
        }
        Style(page);
    }
    public static void Style(object page)
    {
        if(!States.TryGetValue(page,out var state))return;
        var account=Access.Get<EmbySession?>(page,"_session");if(account==null)return;
        var button=Access.Get<Button>(page,"ProfileSwitchButton");
        if(button.Content is not Grid {Name:"FullAccountAvatar"} face)
        {
            face=new Grid{Name="FullAccountAvatar",Width=40,Height=40};
            face.Children.Add(new Ellipse{Width=40,Height=40,StrokeThickness=0});
            face.Children.Add(new TextBlock{Name="FullAccountAvatarInitial",HorizontalAlignment=HorizontalAlignment.Center,VerticalAlignment=VerticalAlignment.Center,FontSize=16});
            button.Content=face;
        }
        state.Images.TryGetValue(Key(account),out var image);state.ToolbarImage.ImageSource=image;
        ((Ellipse)face.Children[0]).Fill=image!=null?state.ToolbarImage:DesktopVisuals.Brush(0xFF626B7D);
        var initial=(TextBlock)face.Children[1];initial.Visibility=image==null?Visibility.Visible:Visibility.Collapsed;
        initial.Text=string.IsNullOrWhiteSpace(account.UserName)?"?":System.Globalization.StringInfo.GetNextTextElement(account.UserName.Trim());
        initial.Foreground=DesktopVisuals.Brush(0xFFFFFFFF);
        // Fill the original 40-DIP button, using the ellipse itself as the crop.
        // A rounded Border alone would not clip its square image child.
        button.Width=button.Height=button.MinWidth=button.MinHeight=40;button.Padding=new(0);button.BorderThickness=new(0);button.CornerRadius=new(20);
        button.HorizontalContentAlignment=HorizontalAlignment.Center;button.VerticalContentAlignment=VerticalAlignment.Center;
    }
}
