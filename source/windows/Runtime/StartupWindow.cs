using System.Runtime.InteropServices;
using EmbyDesktop.Core.Services;
using Microsoft.UI.Xaml;
using Microsoft.UI.Windowing;
using Windows.Graphics;

namespace Yingyu.Update;
public static class StartupWindow
{
    [DllImport("user32.dll")] static extern uint GetDpiForWindow(IntPtr window);
    public static void Apply(object owner)
    {
        var window=(Window)owner;var app=window.AppWindow;
        var area=DisplayArea.GetFromWindowId(app.Id,DisplayAreaFallback.Primary).WorkArea;
        double scale=Math.Max(1,GetDpiForWindow(WinRT.Interop.WindowNative.GetWindowHandle(window))/96.0);
        int width=Math.Min((int)(area.Width*.9),Math.Max((int)(960*scale),Math.Min(app.Size.Width,(int)(1440*scale))));
        int height=Math.Min((int)(area.Height*.9),Math.Max((int)(640*scale),Math.Min(app.Size.Height,(int)(900*scale))));
        int x=Math.Clamp(app.Position.X,area.X,area.X+area.Width-width),y=Math.Clamp(app.Position.Y,area.Y,area.Y+area.Height-height);
        if(app.Presenter is OverlappedPresenter presenter){
            if(presenter.State==OverlappedPresenterState.Maximized)presenter.Restore();
            app.MoveAndResize(new RectInt32(x,y,width,height));
            Access.Set(owner,"_lastPlacement",new WindowPlacement(x,y,width,height,true));
            presenter.Maximize();
        }
    }
}
