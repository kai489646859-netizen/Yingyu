using System.Text;
using System.Text.RegularExpressions;
using EmbyDesktop.Core.Services;

namespace Yingyu.Update;

public static class SubtitleSelection
{
    public static int? Select(SubtitlePreferenceMode preference, IEnumerable<PlaybackTrackDescriptor> tracks)
    {
        ArgumentNullException.ThrowIfNull(tracks);
        // Explicit traditional/bilingual/disabled user settings keep their
        // existing policy. Only the requested simplified-first modes change.
        if (preference is not (SubtitlePreferenceMode.SimplifiedChineseThenBilingualThenTraditional
            or SubtitlePreferenceMode.SimplifiedChinese)) return SubtitlePreferencePolicy.Select(preference, tracks);
        return tracks.Select((track, index) => (track.Id, index, Rank: Rank(track)))
            .Where(x => x.Rank < int.MaxValue).OrderBy(x => x.Rank).ThenBy(x => x.index)
            .Select(x => (int?)x.Id).FirstOrDefault();
    }

    internal static int Rank(PlaybackTrackDescriptor track)
    {
        string language = Normalize(track.Language).Replace('_', '-');
        string title = Normalize(string.Join(' ', track.Title, track.AdditionalText));
        var tags = language.Split('-', StringSplitOptions.RemoveEmptyEntries);
        string primary = tags.FirstOrDefault() ?? "";
        bool chinese = primary is "ZH" or "ZHO" or "CHI" or "CMN" or "YUE" or "CHS" or "CHT" or "ZHS" or "ZHT";
        bool languageSimplified = primary is "CHS" or "ZHS" || chinese && (tags.Contains("HANS") || !tags.Contains("HANT") && (tags.Contains("CN") || tags.Contains("SG")));
        bool languageTraditional = primary is "CHT" or "ZHT" || chinese && (tags.Contains("HANT") || !tags.Contains("HANS") && (tags.Contains("TW") || tags.Contains("HK") || tags.Contains("MO")));
        bool titleSimplified = Contains(title, "简体", "簡體", "简中", "簡中", "简英", "簡英", "简日", "簡日", "简繁", "簡繁", "繁简", "繁簡")
            || Token(title, "CHS|ZHS|SC|ZH[-_ ](?:HANS|CN|SG)(?:[-_ ]CN)?|SIMPLIFIED(?:[ -]?CHINESE)?");
        bool titleTraditional = Contains(title, "繁体", "繁體", "繁中", "繁英", "繁日", "繁简", "繁簡", "简繁", "簡繁")
            || Token(title, "CHT|ZHT|TC|ZH[-_ ](?:HANT|TW|HK|MO)|TRADITIONAL(?:[ -]?CHINESE)?");
        // Contradictory labels do not count as a proven simplified track.
        bool simplified = (languageSimplified || titleSimplified) && !(languageTraditional || titleTraditional);
        bool traditional = (languageTraditional || titleTraditional) && !(languageSimplified || titleSimplified);
        chinese |= languageSimplified || languageTraditional || titleSimplified || titleTraditional
            || Contains(title, "中文", "中字", "中英", "中日", "汉语", "漢語", "国语", "國語")
            || Token(title, "CHINESE|MANDARIN|CHI|ZHO|CMN");
        bool bilingual = Contains(title, "双语", "雙語", "中英", "中日", "简英", "簡英", "简日", "簡日", "繁英", "繁日")
            || Token(title, "BILINGUAL|DUAL[ -]SUB(?:TITLE)?S?|ENG|ENGLISH|JPN|JAPANESE");
        bool forced = Token(title, "FORCED|SIGNS(?:[ &+]SONGS)?|SONGS") || Contains(title, "强制", "強制", "仅标牌", "僅標牌", "标牌字幕", "標牌字幕");
        int group;
        if (simplified) group = bilingual ? 1 : 0;
        else if (chinese && !traditional) group = bilingual ? 3 : 2;
        else if (traditional) group = bilingual ? 5 : 4;
        else if (primary is "ENG" or "EN" || Contains(title, "英文") || Token(title, "ENGLISH")) group = 6;
        else return int.MaxValue;
        return group * 10 + (forced ? 1 : 0);
    }
    static bool Token(string value, string expression) => Regex.IsMatch(value, "(?<![A-Z0-9])(?:" + expression + ")(?![A-Z0-9])", RegexOptions.CultureInvariant);
    static bool Contains(string value, params string[] parts) => parts.Any(part => value.Contains(part, StringComparison.Ordinal));
    static string Normalize(string? value) => (value ?? "").Normalize(NormalizationForm.FormKC).Trim().ToUpperInvariant();
}
