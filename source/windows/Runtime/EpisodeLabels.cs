using System.Text.RegularExpressions;
using EmbyDesktop.Core.Models;
using Microsoft.UI.Xaml.Controls;

namespace Yingyu.Update;

public static class EpisodeLabels
{
    public static string Number(EmbyItem item, int ordinal)
        => (item.IndexNumber is >= 0 ? item.IndexNumber.Value : ordinal).ToString();

    public static string Range(string first, string last, int start, int count)
    {
        if (int.TryParse(first, out int from) && int.TryParse(last, out int to) && (long)to - from == count - 1)
            return count == 1 ? first : $"{first}–{last}";
        return count == 1 ? (start + 1).ToString() : $"{start + 1}–{start + count}";
    }

    public static string Display(EmbyItem item)
    {
        ArgumentNullException.ThrowIfNull(item);
        if (!string.Equals(item.Type, "Episode", StringComparison.OrdinalIgnoreCase)) return item.Name;
        string name = item.Name?.Trim() ?? "";
        if (item.IndexNumber is > 0)
            name = Regex.Replace(name, $@"^(?:第\s*{item.IndexNumber}\s*[集话話]|(?:Episode|Ep\.?|E)\s*{item.IndexNumber}(?!\d))\s*[·:：\-—]*\s*", "", RegexOptions.IgnoreCase);
        if (Generic(name)) name = !Generic(item.OriginalTitle) ? item.OriginalTitle!.Trim() : item.SeriesName?.Trim() ?? "";
        if (item.IndexNumber is not > 0) return name;
        string prefix = $"第 {item.IndexNumber} 集";
        return string.IsNullOrWhiteSpace(name) ? prefix : $"{prefix} · {name}";
    }
    static bool Generic(string? text) => string.IsNullOrWhiteSpace(text) || Regex.IsMatch(text.Trim(),
        @"^(?:第\s*[\d零一二三四五六七八九十百]+\s*[集话話]|(?:Episode|Ep\.?|E)\s*\d+|S\d+\s*E\d+|\d+)$", RegexOptions.IgnoreCase);
    public static void ConfigureVolume(object overlay)
    {
        var slider = Access.Get<Slider>(overlay, "VolumeSlider");
        slider.Minimum = 0;
        slider.Maximum = 300;
        slider.Value = 100;
    }
}
