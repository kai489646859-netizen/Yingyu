using System.Collections;
using EmbyDesktop.Core.Models;

namespace Yingyu.Update;
public static class UserStatePresentation
{
    // Called only after the host's account-guarded server commit, or when its
    // detail controls refresh. Keep its write/readback and duplicate gate intact.
    public static void Refresh(object page)
    {
        if(Access.Get<object?>(page,"_client")==null)return;
        var cards=(IEnumerable)Access.Call(page,"get_FavoriteCards")!;
        foreach(var card in cards){Access.Call(card,"NotifyPlaybackStateChanged");}
        DesktopCardSurface.RefreshUserState(page);
    }
}
