using Richasy.MpvKernel.Core;

namespace Yingyu.Update;

internal static class HomeCinemaAudio
{
    internal static readonly string[] Labels=["兼容 PCM（默认）","WASAPI 独占 PCM","HDMI 压缩音频直通"];
    const string Codecs="ac3,eac3,dts-hd,truehd";

    internal static void Append(List<string> options,int mode)
    {
        if(mode is not (1 or 2))return;
        options.Add("ao=wasapi");
        options.Add("audio-exclusive=yes");
        options.Add("audio-fallback-to-null=yes");
        if(mode==2)options.Add($"audio-spdif=%{Codecs.Length}%{Codecs}");
    }

    internal static bool ShouldFallback(string selected,string output,string driver)
        => int.TryParse(selected,out int id) && id>0
            && (driver=="null" || string.IsNullOrWhiteSpace(output));

    internal static bool TryShared(MpvClient client)
    {
        if(PlaybackTransport.Set(client,"file-local-options/audio-spdif","")<0
            || PlaybackTransport.Set(client,"file-local-options/audio-exclusive","no")<0
            || PlaybackTransport.Set(client,"file-local-options/audio-fallback-to-null","no")<0
            || PlaybackTransport.Get(client,"options/audio-exclusive")!="no"
            || PlaybackTransport.Get(client,"options/audio-spdif")!="")return false;
        string device=PlaybackTransport.Get(client,"audio-device");
        return PlaybackTransport.Set(client,"audio-device",device.Length>0?device:"auto")>=0;
    }
}
