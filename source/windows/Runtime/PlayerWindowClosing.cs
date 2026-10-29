using System.Reflection;
using Microsoft.UI.Windowing;

namespace Yingyu.Update;

public static class PlayerWindowClosing
{
    // Route the title-bar X / Alt+F4 through the same existing, guarded close
    // command as the overlay button. This lets the session save progress and
    // detach controls while the XAML island still exists. AppWindow.Destroy()
    // at the end of disposal does not raise this cancellable Closing event.
    public static void Attach(object session, AppWindow window)
    {
        var method = session.GetType().GetMethod("OnClosePlaybackRequested", BindingFlags.Instance | BindingFlags.NonPublic)
            ?? throw new MissingMethodException(session.GetType().FullName, "OnClosePlaybackRequested");
        var close = (EventHandler)method.CreateDelegate(typeof(EventHandler), session);
        window.Closing += (_, args) =>
        {
            args.Cancel = true;
            close(null, EventArgs.Empty);
        };
    }
}
