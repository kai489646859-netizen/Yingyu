using System.Globalization;
using FluentResults;
using Richasy.MpvKernel.Core;
using Richasy.MpvKernel.Core.Enums;
using Richasy.MpvKernel.Core.Models;

namespace Yingyu.Update;

public static class BlurayTracks
{
    // The title byte-stream cannot carry MPLS language tags. Match the MPV
    // transport-stream source PID, never a menu ordinal or MPV user track ID.
    public static async Task<Result<List<MpvTrackInfo>>> GetTracks(MpvClient client, object session)
    {
        var uri = Access.Get<Uri>(session, "_playbackUri");
        int generation = Access.Get<int>(session, "_mediaGeneration");
        var result = await client.GetTracksAsync().ConfigureAwait(false);
        if (result.IsFailed || uri.Scheme != "yingyu-bd"
            || generation != Access.Get<int>(session, "_mediaGeneration")) return result;
        try
        {
            if (PlaybackTransport.Get(client, "stream-open-filename") != uri.ToString()) return result;
            foreach (var audio in result.Value.Where(t => t.Type == MpvTrackType.Audio))
                DiscAudioLabels.Remember(audio, audio.Language, null, null, audio.Title);
            int restored = 0;
            if (!int.TryParse(PlaybackTransport.Get(client, "track-list/count"), out int count) || count > 1024) return result;
            for (int i = 0; i < count; i++)
            {
                string path = "track-list/" + i + "/";
                string type = PlaybackTransport.Get(client, path + "type");
                if (type is not ("sub" or "audio")
                    || PlaybackTransport.Get(client, path + "external") == "yes"
                    || !int.TryParse(PlaybackTransport.Get(client, path + "id"), out int id)) continue;
                if (type == "audio")
                {
                    var audio = result.Value.SingleOrDefault(t => t.Type == MpvTrackType.Audio && t.Id == id);
                    if (audio == null) continue;
                    string? audioLanguage = audio.Language;
                    if ((string.IsNullOrWhiteSpace(audioLanguage) || audioLanguage == "und")
                        && ushort.TryParse(PlaybackTransport.Get(client, path + "src-id"), out ushort audioPid))
                        audioLanguage = DiscAudioLabels.AudioLanguage(uri, audioPid);
                    DiscAudioLabels.Remember(audio, audioLanguage, PlaybackTransport.Get(client, path + "codec"),
                        PlaybackTransport.Get(client, path + "demux-channel-count"), PlaybackTransport.Get(client, path + "title"));
                    continue;
                }
                var track = result.Value.SingleOrDefault(t => t.Type == MpvTrackType.Subtitle && t.Id == id);
                if (track == null) continue;
                string codec = PlaybackTransport.Get(client, path + "codec");
                if (!string.IsNullOrEmpty(codec)) track.Codec = codec;
                if (!string.IsNullOrWhiteSpace(track.Language) && track.Language != "und") continue;
                if (ushort.TryParse(PlaybackTransport.Get(client, path + "src-id"), out ushort pid)
                    && NetworkBluray.SubtitleLanguage(uri, pid) is { Length: > 0 } language)
                {
                    track.Language = language;
                    restored++;
                }
            }
            PlaybackTransport.Write("Info", "Playback.Tracks", $"网络蓝光字幕语言按 mpv 来源 PID 补齐={restored}；沿用原轨道 ID、选择偏好及 mpv 字幕解码。 ");
        }
        catch (Exception error)
        {
            PlaybackTransport.Write("Warning", "Playback.Tracks", "蓝光字幕语言补充暂不可用：" + error.GetType().Name + "；保留 mpv 已读取的轨道。 ");
        }
        return result;
    }

    // Retained binary hook name. It now selects a disc-specific display label
    // for tagged audio as well as PGS; no new hook in the original assembly.
    public static bool IsPgs(MpvTrackInfo track) => DiscAudioLabels.Contains(track) || track.Type == MpvTrackType.Subtitle
        && (track.Codec?.Contains("pgs", StringComparison.OrdinalIgnoreCase) == true
            || track.Title?.Contains("HDMV Presentation Graph", StringComparison.OrdinalIgnoreCase) == true);

    public static string Label(MpvTrackInfo track)
    {
        if (DiscAudioLabels.Get(track) is { } audio) return audio;
        string tag = track.Language?.Trim().ToLowerInvariant() ?? "";
        string language = tag switch
        {
            "chi" or "zho" or "zh" or "zh-cn" or "zh-tw" or "zh-hans" or "zh-hant" => "中文",
            "eng" or "en" => "英语", "jpn" or "ja" => "日语", "kor" or "ko" => "韩语",
            "fra" or "fre" or "fr" => "法语", "deu" or "ger" or "de" => "德语",
            "spa" or "es" => "西班牙语", "ita" or "it" => "意大利语",
            "rus" or "ru" => "俄语", "por" or "pt" => "葡萄牙语",
            "tha" or "th" => "泰语", "vie" or "vi" => "越南语",
            "" or "und" or "unknown" => "语言未知", _ => tag
        };
        string label = $"{language} · PGS · 轨道 {track.Id.ToString(CultureInfo.InvariantCulture)}";
        // Keep authored track names; suppress only the repeated codec description.
        string title = track.Title?.Trim() ?? "";
        int description = title.IndexOf("HDMV Presentation Graph", StringComparison.OrdinalIgnoreCase);
        if (description >= 0) title = title[..description].Trim();
        if (title.Length > 0 && !title.Contains("hdmv_pgs", StringComparison.OrdinalIgnoreCase)
            && !title.Equals("PGS", StringComparison.OrdinalIgnoreCase)
            && !title.Equals(tag, StringComparison.OrdinalIgnoreCase)) label += " · " + title;
        return label;
    }
}
