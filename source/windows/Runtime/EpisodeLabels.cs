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

    static readonly Regex DisplayOrdinal = new(
        @"(?:^|[^a-z0-9])S(?<season>[0-9]{1,3})[\s._-]*E(?<episode>[0-9]{1,5})(?![0-9])|第\s*(?<season>[0-9]{1,3})\s*季|第\s*(?<episode>[0-9]{1,5})\s*[集话話]|(?:^|[\s._-])(?:Episode|Ep\.?)[\s._-]*(?<episode>[0-9]{1,5})(?![0-9])",
        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant, TimeSpan.FromMilliseconds(50));
    static readonly Regex FileExtension = new(
        @"\.(?:strm|mkv|mp4|m2ts|avi|mov|ts|webm)$", RegexOptions.IgnoreCase,
        TimeSpan.FromMilliseconds(50));

    internal static (int? Season, int? Episode) DisplayNumbers(EmbyItem item)
    {
        if (!string.Equals(item.Type,"Episode",StringComparison.OrdinalIgnoreCase)) return (null,null);
        var matches = new[]{item.Name,item.OriginalTitle,ResourceSourceInfo.Basename(item.Path)}
            .Where(name=>name is {Length:>0 and <=4096})
            .Select(name=>DisplayOrdinal.Matches(name!).Cast<Match>()).ToArray();
        int? Read(string group,int minimum)
        {
            foreach (var label in matches)
            {
                var numbers = label.Select(match=>int.TryParse(match.Groups[group].Value,out int value) ? value : -1)
                    .Where(number=>number>=minimum).Distinct().Take(2).ToArray();
                if (numbers.Length>0) return numbers.Length==1?numbers[0]:null;
            }
            return null;
        }
        return (item.ParentIndexNumber is >=0 ? item.ParentIndexNumber : Read("season",0),
            item.IndexNumber is >0 ? item.IndexNumber : Read("episode",1));
    }

    internal static int? DisplayIndex(EmbyItem item) => DisplayNumbers(item).Episode;

    public static string Number(EmbyItem item, int ordinal)
        => DisplayIndex(item)?.ToString() ?? "—";

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
        int? episode = DisplayIndex(item);
        if (episode is >0)
            name = Regex.Replace(name, $@"^(?:第\s*0*{episode}\s*[集话話]|(?:Episode|Ep\.?|E)\s*0*{episode}(?!\d))\s*[·:：\-—]*\s*", "", RegexOptions.IgnoreCase);
        if (Generic(name) || FileStyle(name,item.SeriesName))
            name = !Generic(item.OriginalTitle) && !FileStyle(item.OriginalTitle!,item.SeriesName) ? item.OriginalTitle!.Trim() : "";
        if (episode is not >0) return name.Length>0?name:"分集";
        string prefix = $"第 {episode} 集";
        return name.Length==0 ? prefix : $"{prefix} · {name}";
    }
    static bool FileStyle(string name,string? series)
        => name.Length<=4096 && (DisplayOrdinal.IsMatch(name) || FileExtension.IsMatch(name)
            || (!string.IsNullOrWhiteSpace(series) && name.StartsWith(series.Trim(),StringComparison.OrdinalIgnoreCase)));
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
