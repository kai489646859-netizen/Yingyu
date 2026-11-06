using System.Text.RegularExpressions;
using EmbyDesktop.Core.Models;
using Microsoft.UI.Xaml.Controls;

namespace Yingyu.Update;

public static class EpisodeLabels
{
    static readonly Regex NumberedTitle=new(
        @"^(?<series>.+?)[\s._·-]*(?:第\s*(?<season>\d{1,3})\s*季\s*(?<annual>年番)?\s*第\s*(?<episode>\d{1,5})\s*[集话話]|S(?<season>\d{1,3})[\s._-]*E(?<episode>\d{1,5})(?!\d))",
        RegexOptions.IgnoreCase,TimeSpan.FromMilliseconds(50));

    internal static (int Season,int Episode,bool Annual)? ExplicitNumber(EmbyItem item)
    {
        if(!string.Equals(item.Type,"Episode",StringComparison.OrdinalIgnoreCase)
            ||item.Name is not {Length:>0 and <=240} name||string.IsNullOrWhiteSpace(item.SeriesName))return null;
        var match=NumberedTitle.Match(name.Trim());
        if(!match.Success||!int.TryParse(match.Groups["season"].Value,out int season)
            ||!int.TryParse(match.Groups["episode"].Value,out int episode)||episode<=0
            ||item.ParentIndexNumber is {} indexedSeason&&indexedSeason!=season)return null;
        string TitleKey(string value)=>Regex.Replace(value,@"[\s\p{P}\p{S}]","",RegexOptions.None,TimeSpan.FromMilliseconds(50));
        if(!string.Equals(TitleKey(match.Groups["series"].Value),TitleKey(item.SeriesName),StringComparison.OrdinalIgnoreCase))return null;
        return (season,episode,match.Groups["annual"].Success);
    }

    internal static int? Index(EmbyItem item)=>ExplicitNumber(item)?.Episode??item.IndexNumber;

    public static string Number(EmbyItem item, int ordinal)
        => (Index(item) is >=0 and int number?number:ordinal).ToString();

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
        if(ExplicitNumber(item) is {} numbered)return $"第 {numbered.Episode} 集 · {item.SeriesName!.Trim()}";
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
