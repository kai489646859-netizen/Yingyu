using System.Runtime.CompilerServices;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
namespace Yingyu.Update;
public static class ModalProtection
{
    sealed class State { public bool Busy; }
    static readonly ConditionalWeakTable<XamlRoot,State> States=new();
    public static async Task<ContentDialogResult> Show(ContentDialog dialog)
    {
        // A duplicate must not inherit the first dialog's destructive confirmation.
        if(dialog.XamlRoot is not {} root)return await dialog.ShowAsync();
        var state=States.GetOrCreateValue(root);
        if(state.Busy)return ContentDialogResult.None;
        state.Busy=true;
        try{return await dialog.ShowAsync();}
        finally{
            state.Busy=false;
            // XamlRoot is a WinRT wrapper. Keep the weak-table key alive while
            // its dialog is active so GC cannot split duplicate-request state.
            GC.KeepAlive(root);
        }
    }
}
