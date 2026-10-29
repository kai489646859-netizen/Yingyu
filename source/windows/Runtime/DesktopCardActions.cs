using System.Reflection;
using EmbyDesktop.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
namespace Yingyu.Update;
internal static class DesktopCardActions
{
    const BindingFlags Flags=BindingFlags.Instance|BindingFlags.Public|BindingFlags.NonPublic;
    static object? Call(object page,string name,params object?[] args)=>page.GetType().GetMethod(name,Flags)!.Invoke(page,args);
    static EmbyItem Item(object card)=>(EmbyItem)card.GetType().GetProperty("Item")!.GetValue(card)!;
    internal static async Task Play(object page,object card)
    {
        PosterTap.Cancel(page);
        try{var item=Item(card);if(item.Type is "Series" or "Season"){await Detail(page,card);return;}await (Task)Call(page,"StartPlaybackSafelyAsync",item,false,CancellationToken.None)!;}
        catch(Exception error){Report(page,error);}
    }
    internal static async Task Watched(object page,object card)
    {PosterTap.Cancel(page);try{var current=Item(card);await (Task)Call(page,"ChangeUserStateAsync",current,null,current.UserData?.Played!=true)!;}catch(Exception error){Report(page,error);}}
    static async Task Detail(object page,object card)
    {
        var item=Item(card);var task=(Task)Call(page,"ResolveDetailTargetAsync",item)!;await task;
        var result=task.GetType().GetProperty("Result")!.GetValue(task)!;var resolved=(EmbyItem)result.GetType().GetField("Item1")!.GetValue(result)!;
        object? bitmap=resolved.Id==item.Id?card.GetType().GetProperty("Poster")!.GetValue(card):null;
        await (Task)Call(page,"ShowDetailAsync",resolved,bitmap,null,result.GetType().GetField("Item2")!.GetValue(result),result.GetType().GetField("Item3")!.GetValue(result))!;
    }
    internal static MenuFlyout Menu(object page,FrameworkElement root,object card)
    {
        var menu=new MenuFlyout();var item=Item(card);
        void Action(string text,Func<Task> action){var button=new MenuFlyoutItem{Text=text};button.Click+=async (_,_)=>{try{await action();}catch(Exception error){Report(page,error);}};menu.Items.Add(button);}
        Action(item.Type is "Series" or "Season"?"选择集数":"播放／继续观看",()=>Play(page,card));
        Action("查看详情",()=>Detail(page,card));
        Action(item.UserData?.IsFavorite==true?"取消收藏":"收藏到 Emby",async()=>{var current=Item(card);await (Task)Call(page,"ChangeUserStateAsync",current,current.UserData?.IsFavorite!=true,null)!;});
        Action(item.UserData?.Played==true?"标为未看":"标为已看",async()=>{var current=Item(card);await (Task)Call(page,"ChangeUserStateAsync",current,null,current.UserData?.Played!=true)!;});
        ReferenceSurfaces.Flyout(menu);return menu;
    }
    static void Report(object page,Exception error){try{PlaybackTransport.Write("Warning","Desktop.Card","海报操作未完成；"+error.GetType().Name);}catch(Exception){}try{Call(page,"ShowLibraryStatus","操作未完成，请重试。","操作提示",InfoBarSeverity.Error,false);}catch(Exception){} }
}
