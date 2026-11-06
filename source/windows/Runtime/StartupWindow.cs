using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;

namespace Yingyu.Update;
public static class StartupWindow
{
    public static void Apply(object owner)
    {
        if(owner is not Window window||window.Content is not FrameworkElement root)return;
        bool closed=false;
        window.Closed+=(_,_)=>closed=true;
        void Attach()
        {
            window.DispatcherQueue.TryEnqueue(DispatcherQueuePriority.Low,()=>
            {
                if(!closed&&root.IsLoaded)DesktopPlacement.Attach(window);
            });
        }
        void Loaded(object sender,RoutedEventArgs args)
        {
            root.Loaded-=Loaded;
            Attach();
        }
        if(root.IsLoaded)Attach();else root.Loaded+=Loaded;
    }
}
