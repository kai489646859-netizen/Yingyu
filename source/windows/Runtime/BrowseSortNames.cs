using EmbyDesktop.Core.Services;
using Microsoft.UI.Xaml.Controls;
namespace Yingyu.Update;
public static class BrowseSortNames
{
    public static LibraryBrowsePreference Normalize(LibraryBrowsePreference preference)
        => string.IsNullOrWhiteSpace(preference.Sort)||preference.Sort=="默认" ? preference with {Sort="名称"} : preference;
    public static void Configure(object page)
    {
        if(Access.Get<ComboBox?>(page,"_browseSort") is not {} combo)return;
        bool prior=Access.Get<bool>(page,"_settingBrowseOptions");
        try
        {
            Access.Set(page,"_settingBrowseOptions",true);
            string selected=combo.SelectedItem as string??"名称";
            combo.ItemsSource=(combo.ItemsSource as IEnumerable<string>??combo.Items.Cast<string>()).Where(x=>x!="默认").Distinct().ToList();
            combo.SelectedItem=selected=="默认"?"名称":selected;
        }
        finally{Access.Set(page,"_settingBrowseOptions",prior);}
    }
}
