using EmbyDesktop.Core.Services;

namespace Yingyu.Update;

public static class SeriesTrackMemory
{
    static string Key(string? language)
    {
        string code=(language??"").Trim().ToLowerInvariant().Replace('_','-');
        return code switch
        {
            "chi" or "zho" or "cmn"=>"zh",
            "zh-cn" or "zh-sg" or "zh-hans"=>"zh-hans",
            "zh-tw" or "zh-hk" or "zh-hant"=>"zh-hant",
            "jpn"=>"ja","eng"=>"en","kor"=>"ko","fre" or "fra"=>"fr","deu" or "ger"=>"de",
            "und" or "unknown"=>"",_=>code
        };
    }

    public static PlaybackTrackMatch Resolve(PlaybackTrackPreference preference,IEnumerable<PlaybackTrackDescriptor> candidates)
    {
        if(preference.Disabled)return new(true,null);
        string wanted=Key(preference.Language);
        int Score(PlaybackTrackDescriptor track)
        {
            string language=Key(track.Language);
            bool title=Same(preference.Title,track.Title);
            if(wanted.Length>0 && language!=wanted && !(title&&(language.Length==0
                || wanted=="zh"&&language.StartsWith("zh-",StringComparison.Ordinal)
                || language=="zh"&&wanted.StartsWith("zh-",StringComparison.Ordinal))))return 0;
            if(wanted.Length==0&&!title)return 0;
            return 8+(title?8:0)+(Same(preference.AdditionalText,track.AdditionalText)?4:0)
                +(Same(preference.Codec,track.Codec)?2:0)+(wanted.Length>0&&language==wanted?4:0);
        }
        var ranked=candidates.Select(track=>(Track:track,Score:Score(track))).Where(row=>row.Score>0)
            .OrderByDescending(row=>row.Score).Take(2).ToArray();
        return ranked.Length>0&&(ranked.Length==1||ranked[0].Score>ranked[1].Score)
            ? new(true,ranked[0].Track.Id):new(false,null);
    }
    static bool Same(string? left,string? right)=>!string.IsNullOrWhiteSpace(left)
        && string.Equals(left.Trim(),right?.Trim(),StringComparison.OrdinalIgnoreCase);
}
