using System.Text.RegularExpressions;
using Richasy.MpvKernel.Core.Models;
using Richasy.MpvKernel.Core.Enums;

namespace Yingyu.Update;

// Display only: never rewrites MPV track IDs, language, selection or preferences.
public static class TrackLabels
{
    static string Clean(string? text)=>string.IsNullOrWhiteSpace(text)||text=="未提供"?"":text.Trim()[..Math.Min(text.Trim().Length,512)];
    static bool Has(string text,string pattern)=>Regex.IsMatch(text,pattern,RegexOptions.IgnoreCase|RegexOptions.CultureInvariant);
    public static string Language(string? language,string? title=null){
        string tag=Clean(language).Replace('_','-').ToLowerInvariant(),name=Clean(title);
        bool simplified=tag is "zh-cn" or "zh-sg" or "chs"||tag.Contains("hans")||Has(name,@"简[体中]|簡[體中]|simplified|\bchs\b|\bzh[-_]hans\b");
        bool traditional=tag is "zh-tw" or "zh-hk" or "zh-mo" or "cht"||tag.Contains("hant")||Has(name,@"繁[体體中]|traditional|\bcht\b|\bzh[-_]hant\b");
        bool chinese=tag is "zh" or "zho" or "chi" or "chs" or "cht"||tag.StartsWith("zh-")||((tag is "" or "und" or "unknown")&&(simplified||traditional||Has(name,"中文|Chinese")));
        if(chinese)return simplified&&!traditional?"简中":traditional&&!simplified?"繁中":"中文";
        var baseTag=tag.Split('-')[0];
        return baseTag switch{
            "en" or "eng"=>"英文","ja" or "jpn"=>"日语","ko" or "kor"=>"韩语","fr" or "fra" or "fre"=>"法语","de" or "deu" or "ger"=>"德语",
            "es" or "spa"=>"西班牙语","it" or "ita"=>"意大利语","ru" or "rus"=>"俄语","pt" or "por"=>"葡萄牙语","th" or "tha"=>"泰语","vi" or "vie"=>"越南语",
            "yue"=>"粤语","cmn"=>"普通话","ar" or "ara"=>"阿拉伯语","hi" or "hin"=>"印地语","id" or "ind"=>"印尼语","ms" or "msa" or "may"=>"马来语",
            "nl" or "nld" or "dut"=>"荷兰语","sv" or "swe"=>"瑞典语","pl" or "pol"=>"波兰语","tr" or "tur"=>"土耳其语","uk" or "ukr"=>"乌克兰语",
            _=>Has(name,@"\bEnglish\b|英文|英语")?"英文":Has(name,@"\bJapanese\b|日语|日文")?"日语":"未知语言"
        };
    }
    public static string Channels(string? channels,string? title=null){
        string raw=Clean(channels),name=Clean(title);
        foreach(var value in new[]{raw,name}){
            var layout=Regex.Match(value,@"(?<!\d)([1-9])\.([0-2])(?:\.([0-9]))?(?!\d)");
            if(layout.Success)return layout.Value+" 声道";
        }
        if(raw.Equals("mono",StringComparison.OrdinalIgnoreCase))return "单声道";
        if(raw.Equals("stereo",StringComparison.OrdinalIgnoreCase))return "双声道";
        if(!int.TryParse(raw,out int count)){
            var match=Regex.Match(name,@"(?i)(?:\(|\b)(\d{1,2})\s*(?:ch(?:annels?)?\b|声道)");
            if(match.Success)int.TryParse(match.Groups[1].Value,out count);
        }
        return count is >0 and <=64?count+" 声道":"";
    }
    public static string Format(string? language,string? title,string? codec,string? channels,bool audio){
        string name=Clean(title),kind=Clean(codec);var parts=new List<string>{Language(language,name)};
        var candidates=new[]{("DTS-HD MA",@"DTS[- _]?HD.*(?:MA|Master)"),("DTS-HD",@"DTS[- _]?HD"),("TrueHD",@"truehd"),("E-AC-3",@"e[-_]?ac[-_]?3|Dolby Digital Plus"),("AC-3",@"(?<![A-Za-z])ac[-_]?3|Dolby Digital(?! Plus)"),("DTS",@"\bdts\b"),("AAC",@"\baac\b"),("FLAC",@"\bflac\b"),("Opus",@"\bopus\b"),("MP3",@"\bmp3\b"),("PCM",@"\bpcm\b"),("PGS",@"pgs|HDMV Presentation Graph"),("ASS",@"\bass\b|\bssa\b"),("SRT",@"subrip|\bsrt\b"),("VobSub",@"dvd_subtitle|vobsub"),("WebVTT",@"webvtt")};
        string haystack=kind+" "+name;var known=candidates.FirstOrDefault(c=>Has(haystack,c.Item2)).Item1;
        if(!string.IsNullOrEmpty(known))parts.Add(known);
        if(audio&&Channels(channels,name) is {Length:>0} channel)parts.Add(channel);
        if(Has(name,@"\bcommentary\b|评论|講評|讲评"))parts.Add("评论音轨");
        if(!audio&&Has(name,@"\bforced\b|强制|強制"))parts.Add("强制");
        if(!audio&&Has(name,@"\bsdh\b|听障|聽障"))parts.Add("听障");
        if(Has(name,@"\bAtmos\b"))parts.Add("Atmos");
        if(!audio&&parts[0] is "简中" or "繁中" or "中文"&&Has(name,@"双语|雙語|中英|简英|繁英"))parts[0]+=" / 英文";
        return string.Join(" · ",parts);
    }
    public static string Display(MpvTrackInfo track)=>DiscAudioLabels.Get(track)??Format(track.Language,track.Title,track.Codec,track.AdditionalText,track.Type==MpvTrackType.Audio);
}
