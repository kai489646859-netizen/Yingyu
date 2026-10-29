using System.Runtime.CompilerServices;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;
namespace Yingyu.Update;
public static class PosterTap
{
    sealed class State{public CancellationTokenSource? Pending;public bool Dispatching;}
    static readonly ConditionalWeakTable<object,State> States=new();
    public static void Cancel(object page){if(States.TryGetValue(page,out var state))state.Pending?.Cancel();}
    public static bool Defer(object page,object sender,ItemClickEventArgs args)
    {
        if(States.TryGetValue(page,out var state)&&state.Dispatching)return false;
        for(DependencyObject? node=args.OriginalSource as DependencyObject;node!=null;node=VisualTreeHelper.GetParent(node)){if(node is ButtonBase)return false;if(ReferenceEquals(node,sender))break;}
        if(args.ClickedItem is not {} card||card.GetType().GetProperty("Item")==null||sender is not ItemsControl items||items.ContainerFromItem(card) is not FrameworkElement container)return false;
        return Queue(page,container,card,()=>Access.Call(page,"MediaGrid_ItemClick",sender,args));
    }
    internal static bool Queue(object page,FrameworkElement container,object card,Action navigate)
    {
        var state=States.GetOrCreateValue(page);state.Pending?.Cancel();var pending=state.Pending=new CancellationTokenSource();
        string? scope=Access.Get<string?>(page,"_activeSnapshotKey"),profile=Access.Get<string?>(page,"_activeProfileId");
        bool library=Access.Get<Grid>(page,"LibraryView").Visibility==Visibility.Visible,detail=Access.Get<Grid>(page,"DetailView").Visibility==Visibility.Visible,settings=Access.Get<Grid>(page,"SettingsView").Visibility==Visibility.Visible;
        var existingPopups=page is FrameworkElement source&&source.XamlRoot!=null?VisualTreeHelper.GetOpenPopupsForXamlRoot(source.XamlRoot).Where(p=>p.IsOpen).ToHashSet():new HashSet<Popup>();
        _=Run();return true;
        async Task Run()
        {
            try{
                await Task.Delay(PosterMotion.FeedbackMilliseconds+20,pending.Token);
                if(pending.IsCancellationRequested||!ReferenceEquals(state.Pending,pending)||page is not FrameworkElement element||!element.IsLoaded||!container.IsLoaded
                    ||!ReferenceEquals(container.DataContext,card)&&!(container is ContentControl content&&ReferenceEquals(content.Content,card))
                    ||scope!=Access.Get<string?>(page,"_activeSnapshotKey")||profile!=Access.Get<string?>(page,"_activeProfileId")||DesktopScroll.IsAnimating(page)
                    ||(Access.Get<Grid>(page,"LibraryView").Visibility==Visibility.Visible)!=library||(Access.Get<Grid>(page,"SettingsView").Visibility==Visibility.Visible)!=settings
                    ||(Access.Get<Grid>(page,"DetailView").Visibility==Visibility.Visible)!=detail||VisualTreeHelper.GetOpenPopupsForXamlRoot(element.XamlRoot).Any(p=>p.IsOpen&&!existingPopups.Contains(p)))return;
                state.Dispatching=true;try{navigate();}finally{state.Dispatching=false;}
            }catch(OperationCanceledException){}
            catch(Exception error){try{PlaybackTransport.Write("Warning","Poster.Tap","海报详情未打开；"+error.GetType().Name);}catch(Exception){}}
            finally{if(ReferenceEquals(state.Pending,pending))state.Pending=null;pending.Dispose();}
        }
    }
}
