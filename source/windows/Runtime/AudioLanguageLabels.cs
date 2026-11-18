using System.Text.RegularExpressions;
using EmbyDesktop.Core.Models;
using Richasy.MpvKernel.Core.Enums;
using Richasy.MpvKernel.Core.Models;

namespace Yingyu.Update;

// Metadata for display only. The MPV selection and saved track preference are unchanged.
internal static class AudioLanguageLabels
{
    internal const string Unknown="未知语言";
    static readonly (string Label,string Tags,string Names)[] Languages=
    [
        ("普通话","cmn|zh-cmn|zho-cmn","普通话|普通話|国语|國語|国配|國配|Mandarin|Putonghua"),
        ("粤语","yue|zh-yue","粤语|粵語|粤配|粵配|广东话|廣東話|Cantonese"),
        ("闽南语","nan|zh-nan","闽南语|閩南語|台语|台語|Hokkien"),
        ("中文","zh|zho|chi|chs|cht","中文|汉语|漢語|Chinese"),
        ("英文","en|eng","英语|英語|英文|English"),
        ("日语","ja|jpn","日语|日語|日文|日本語|日配|Japanese"),
        ("韩语","ko|kor","韩语|韓語|韩文|韓文|韩国语|韓國語|한국어|Korean"),
        ("法语","fr|fra|fre","法语|法語|法文|French|Français"),
        ("德语","de|deu|ger","德语|德語|德文|German|Deutsch"),
        ("西班牙语","es|spa","西班牙语|西班牙語|西语|西語|Spanish|Español|Castellano"),
        ("意大利语","it|ita","意大利语|意大利語|義大利語|Italian|Italiano"),
        ("葡萄牙语","pt|por","葡萄牙语|葡萄牙語|葡语|葡語|Portuguese|Português"),
        ("俄语","ru|rus","俄语|俄語|俄文|Russian|Русский"),
        ("乌克兰语","uk|ukr","乌克兰语|烏克蘭語|Ukrainian|Українська"),
        ("泰语","th|tha","泰语|泰語|泰文|Thai|ไทย"),
        ("越南语","vi|vie","越南语|越南語|Vietnamese|Tiếng Việt"),
        ("印尼语","id|ind","印尼语|印尼語|印度尼西亚语|Indonesian|Bahasa Indonesia"),
        ("马来语","ms|msa|may","马来语|馬來語|Malay|Bahasa Melayu"),
        ("阿拉伯语","ar|ara","阿拉伯语|阿拉伯語|Arabic|العربية"),
        ("印地语","hi|hin","印地语|印地語|Hindi|हिन्दी"),
        ("泰米尔语","ta|tam","泰米尔语|泰米爾語|Tamil"),
        ("泰卢固语","te|tel","泰卢固语|泰盧固語|Telugu"),
        ("孟加拉语","bn|ben","孟加拉语|孟加拉語|Bengali"),
        ("乌尔都语","ur|urd","乌尔都语|烏爾都語|Urdu"),
        ("土耳其语","tr|tur","土耳其语|土耳其語|Turkish|Türkçe"),
        ("波斯语","fa|fas|per","波斯语|波斯語|Persian|Farsi"),
        ("波兰语","pl|pol","波兰语|波蘭語|Polish|Polski"),
        ("荷兰语","nl|nld|dut","荷兰语|荷蘭語|Dutch|Nederlands"),
        ("瑞典语","sv|swe","瑞典语|瑞典語|Swedish|Svenska"),
        ("丹麦语","da|dan","丹麦语|丹麥語|Danish|Dansk"),
        ("挪威语","no|nor|nb|nob|nn|nno","挪威语|挪威語|Norwegian|Norsk"),
        ("芬兰语","fi|fin","芬兰语|芬蘭語|Finnish|Suomi"),
        ("希腊语","el|ell|gre","希腊语|希臘語|Greek"),
        ("捷克语","cs|ces|cze","捷克语|捷克語|Czech"),
        ("匈牙利语","hu|hun","匈牙利语|匈牙利語|Hungarian"),
        ("罗马尼亚语","ro|ron|rum","罗马尼亚语|羅馬尼亞語|Romanian"),
        ("希伯来语","he|heb|iw","希伯来语|希伯來語|Hebrew"),
        ("菲律宾语","tl|tgl|fil","菲律宾语|菲律賓語|Filipino|Tagalog")
    ];

    static readonly Dictionary<string,string> Tags=Languages.SelectMany(language=>language.Tags.Split('|')
        .Select(tag=>(tag,language.Label))).ToDictionary(pair=>pair.tag,pair=>pair.Label,StringComparer.OrdinalIgnoreCase);
    static readonly (string Label,Regex Pattern)[] Titles=Languages.Select(language=>
        (language.Label,new Regex(string.Join("|",language.Names.Split('|')
            .Concat(language.Tags.Split('|').Where(tag=>tag.Length==3))
            .Select(name=>name is "国语" or "國語" ? $"(?<![韩韓]){name}" : name.Any(ch=>ch is >= '㐀' and <= '鿿')?Regex.Escape(name)
                :$"(?<![\\p{{L}}\\p{{N}}]){Regex.Escape(name)}(?![\\p{{L}}\\p{{N}}])")),
            RegexOptions.IgnoreCase|RegexOptions.CultureInvariant))).ToArray();

    internal static string Resolve(string? language,string? title)
    {
        string tag=(language??"").Trim().Replace('_','-');
        if(tag.Equals("mul",StringComparison.OrdinalIgnoreCase))return "多语言";
        if(tag.Equals("zxx",StringComparison.OrdinalIgnoreCase))return "无语言内容";
        string primary=tag.Split('-')[0];
        if(Tags.TryGetValue(tag,out var tagged)||Tags.TryGetValue(primary,out tagged))
        {
            if(tagged!="中文")return tagged;
            var named=FromTitle(title);
            return named is "普通话" or "粤语" or "闽南语"?named:tagged;
        }
        string fromTag=FromTitle(language);
        return fromTag!=Unknown?fromTag:FromTitle(title);
    }

    static string FromTitle(string? title)
    {
        if(string.IsNullOrWhiteSpace(title))return Unknown;
        var hits=Titles.Where(language=>language.Pattern.IsMatch(title[..Math.Min(title.Length,512)]))
            .Select(language=>language.Label).ToArray();
        if(hits.Any(label=>label is "普通话" or "粤语" or "闽南语"))
            hits=hits.Where(label=>label!="中文").ToArray();
        return hits.Length==1?hits[0]:Unknown;
    }

    internal static void Supplement(IReadOnlyList<MpvTrackInfo> tracks,MediaSourceInfo source)
    {
        var native=tracks.Where(track=>track.Type==MpvTrackType.Audio).ToArray();
        var server=(source.MediaStreams??[]).Where(stream=>stream is {Type:"Audio",IsExternal:false}).ToArray();
        if(native.Length==0||native.Length!=server.Length)return;

        foreach(var track in native)
        {
            if(Resolve(track.Language,track.Title)!=Unknown)continue;
            string codec=CodecKey(track.Codec);
            MediaStreamInfo? same=null;
            if(native.Length==1)
            {
                if(codec.Length==0||CodecKey(server[0].Codec).Length==0||codec==CodecKey(server[0].Codec))
                    same=server[0];
            }
            else if(codec.Length>0&&native.Count(other=>CodecKey(other.Codec)==codec)==1)
            {
                var matches=server.Where(stream=>CodecKey(stream.Codec)==codec).Take(2).ToArray();
                if(matches.Length==1)same=matches[0];
            }
            if(same!=null&&Resolve(same.Language,same.DisplayTitle)!=Unknown)
                DiscAudioLabels.Remember(track,same.Language,track.Codec??same.Codec,track.AdditionalText,
                    same.DisplayTitle);
        }
    }

    static string CodecKey(string? codec)=>new string((codec??"").Where(char.IsAsciiLetterOrDigit).ToArray()).ToLowerInvariant() switch
    {
        "dtshd" or "dtshdma" or "dcadec"=>"dts",
        "mp4a"=>"aac",
        "ac3fixed"=>"ac3",
        var name=>name
    };
}
