using System.Runtime.CompilerServices;
using System.Text.RegularExpressions;
using EmbyDesktop.Core.Models;

namespace Yingyu.Update;

public static class ResourceSourceInfo
{
    internal sealed record Labels(string Resolution, string Range, string Codec, bool Named)
    {
        internal string Title(string fallback) {
            var label = string.Join(" · ", new[]{Resolution,Range,Codec}.Where(value => value.Length > 0));
            return label.Length == 0 ? fallback : label;
        }
    }

    static readonly ConditionalWeakTable<MediaSourceInfo,string> DialogLabels = new();
    static readonly Regex NamedPixels = new(@"(?<![0-9])(\d{3,5})\s*[x×]\s*(\d{3,5})(?![0-9])",
        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant, TimeSpan.FromMilliseconds(50));

    static string First(string first, string second) => first.Length == 0 ? second : first;
    static bool VisibleTier(string label) => label is "720P" or "1080P" or "4K";

    static string Tier(int width, int height)
    {
        var (longSide, shortSide) = (Math.Max(width,height), Math.Min(width,height));
        if ((longSide >= 7600 && longSide <= 8192) || shortSide == 4320) return "8K";
        if (longSide >= 3800 && longSide <= 4096) return "4K";
        if (longSide is 2048 or 2560 || (longSide <= 2560 && shortSide == 1440)) return "2K";
        if (longSide == 1920 || (longSide < 2048 && shortSide == 1080)) return "1080P";
        if (longSide == 1280 || (longSide < 1920 && shortSide == 720)) return "720P";
        return shortSide is 576 or 540 or 480 or 360 ? shortSide + "P" : "";
    }

    static string ResolutionWord(string word) => word switch
    {
        "8k" or "4320p" => "8K",
        "4k" or "2160p" or "uhd" => "4K",
        "2k" or "1440p" => "2K",
        "1k" or "1080p" or "1080i" => "1080P",
        "720p" => "720P",
        "576p" or "540p" or "480p" or "360p" => word.ToUpperInvariant(),
        _ => ""
    };

    static string RangeWord(string word) => word switch
    {
        "dv" or "dovi" or "dvhe" or "dvh1" or "dolbyvision" => "杜比视界",
        "hdr10plus" => "HDR10+",
        "hdr10" => "HDR10",
        "hlg" => "HLG",
        "hdr" => "HDR",
        "sdr" => "SDR",
        _ => ""
    };

    static string CodecWord(string word) => word switch
    {
        "hevc" or "h265" or "x265" or "hev1" or "hvc1" => "HEVC",
        "h264" or "x264" or "avc" or "avc1" => "H264",
        "av1" or "av01" => "AV1",
        "vp9" or "vp09" => "VP9",
        "vp8" => "VP8",
        "vvc" or "h266" or "vvc1" => "VVC",
        _ => ""
    };

    static (string Resolution,string Range,string Codec) Hints(string? label)
    {
        if (string.IsNullOrWhiteSpace(label) || label.Length > 4096) return ("","","");
        string normalized = Regex.Replace(label.ToLowerInvariant(),@"dolby[ ._-]+vision","dolbyvision");
        normalized = Regex.Replace(normalized,@"hdr10\s*\+","hdr10plus");
        var tokens = Regex.Split(normalized,@"[^a-z0-9]+");
        var resolutions = tokens.Select(ResolutionWord).Where(value => value.Length > 0).ToHashSet();
        if (resolutions.Count == 0)
            foreach (Match match in NamedPixels.Matches(label))
            {
                var tier = Tier(int.Parse(match.Groups[1].Value),int.Parse(match.Groups[2].Value));
                if (tier.Length > 0) resolutions.Add(tier);
            }
        var ranges = tokens.Select(RangeWord).ToHashSet();
        var range = new[]{"杜比视界","HDR10+","HDR10","HLG","HDR","SDR"}.FirstOrDefault(ranges.Contains) ?? "";
        var codecs = tokens.Select(CodecWord).Where(value => value.Length > 0).ToHashSet();
        for (int index = 1; index < tokens.Length; index++)
        {
            string previous = tokens[index - 1];
            if (ResolutionWord(previous).Length == 0 && RangeWord(previous).Length == 0) continue;
            if (tokens[index] is "264" or "265") codecs.Add(tokens[index] == "265" ? "HEVC" : "H264");
        }
        return (resolutions.Count == 1 ? resolutions.Single() : "",range,codecs.Count == 1 ? codecs.Single() : "");
    }

    internal static string? Basename(string? path)
        => path?.Split('?', '#')[0].Split('/','\\').LastOrDefault();

    internal static MediaStreamInfo? Video(MediaSourceInfo source)
    {
        var videos=(source.MediaStreams??[]).Where(s=>s!=null&&string.Equals(s.Type,"Video",StringComparison.OrdinalIgnoreCase)&&!s.IsExternal).ToArray();
        if(videos.Length==1)return videos[0];
        var defaults=videos.Where(s=>s.IsDefault).ToArray();
        if(defaults.Length==1)return defaults[0];
        // Identical layered/duplicate video records still establish these same facts.
        return videos.Length>0&&videos.All(s=>(s.Width,s.Height,s.Codec,s.VideoRange,s.VideoRangeType)==(videos[0].Width,videos[0].Height,videos[0].Codec,videos[0].VideoRange,videos[0].VideoRangeType))?videos[0]:null;
    }

    static string ServerRange(MediaStreamInfo? video)
    {
        if (video == null) return "";
        string mark = ((video.VideoRangeType ?? "") + " " + (video.VideoRange ?? "")).ToLowerInvariant()
            .Replace(" ","").Replace("_","").Replace("-","");
        if (mark.Contains("dolbyvision") || mark.Contains("dovi") || mark.Contains("dvwith") || mark is "dv" or "dvhe" or "dvh1") return "杜比视界";
        if (mark.Contains("hdr10+") || mark.Contains("hdr10plus")) return "HDR10+";
        if (mark.Contains("hdr10")) return "HDR10";
        if (mark.Contains("hlg")) return "HLG";
        return mark.Contains("hdr") ? "HDR" : "";
    }

    static string ServerCodec(MediaStreamInfo? video)
    {
        var codec = video?.Codec?.Trim().ToLowerInvariant() ?? "";
        return First(CodecWord(codec), codec != "unknown" && Regex.IsMatch(codec,@"^[a-z0-9][a-z0-9_-]{0,19}$")
            ? codec.ToUpperInvariant() : "");
    }

    internal static Labels Describe(MediaSourceInfo? source, MediaSourceInfo? supplement = null, EmbyItem? soleItem = null)
    {
        if (source != null && supplement != null && source.Id != supplement.Id) supplement = null;
        string namedResolution = "", namedRange = "", namedCodec = "";
        foreach (var name in new[]{source?.Name,supplement?.Name,Basename(source?.Path),
            Basename(supplement?.Path),soleItem?.Name,Basename(soleItem?.Path)})
        {
            var hint = Hints(name);
            namedResolution = First(namedResolution,hint.Resolution);
            namedRange = First(namedRange,hint.Range);
            namedCodec = First(namedCodec,hint.Codec);
        }
        var video = source == null ? null : Video(source);
        var extra = supplement == null ? null : Video(supplement);
        var resolution = First(namedResolution, First(Tier(video?.Width ?? 0, video?.Height ?? 0),
            Tier(extra?.Width ?? 0, extra?.Height ?? 0)));
        return new(VisibleTier(resolution) ? resolution : "",
            First(namedRange,First(ServerRange(video),ServerRange(extra))),
            First(namedCodec,First(ServerCodec(video),ServerCodec(extra))),
            VisibleTier(namedResolution) || namedRange.Length > 0 || namedCodec.Length > 0);
    }

    internal static MediaSourceInfo DialogSource(MediaSourceInfo source, MediaSourceInfo? supplement, int index)
    {
        // The selector saves only the original ID. Give each row its own label.
        var choice = new MediaSourceInfo { Id = source.Id };
        var label = Describe(source,supplement).Title("");
        DialogLabels.Add(choice,label.Length == 0 ? $"版本 {index}" : $"{index}. {label}");
        return choice;
    }

    public static string VersionLabel(MediaSourceInfo source)
        => DialogLabels.TryGetValue(source,out var label) ? label : Describe(source).Title("原始资源");
}
