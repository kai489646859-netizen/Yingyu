using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;

namespace Yingyu.Update;

internal static class UiElements
{
    internal static IEnumerable<DependencyObject> Descendants(DependencyObject root)
    {
        for (int i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++)
        {
            var child = VisualTreeHelper.GetChild(root, i); yield return child;
            foreach (var nested in Descendants(child)) yield return nested;
        }
    }
}
