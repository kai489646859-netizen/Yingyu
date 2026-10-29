using System.Globalization;
using System.Runtime.CompilerServices;
using EmbyDesktop.Core.Models;
using EmbyDesktop.Core.Services;
using Richasy.MpvKernel.Core;

namespace Yingyu.Update;

// Android info.dart section order. Local session/decoder observations only;
// server annotations never masquerade as decoded facts or display capability.
internal static class PlayerInfoData
{
    internal sealed record Row(string Label,string Value);
    internal sealed record Section(string Title,IReadOnlyList<Row> Rows);
    static readonly ConditionalWeakTable<EmbyApiClient,EmbySession> Accounts=new();
    internal static void Remember(object page)
    {
        if(Access.Get<EmbyApiClient?>(page,"_client") is {} client&&Access.Get<EmbySession?>(page,"_session") is {} account)
        {Accounts.Remove(client);Accounts.Add(client,account);}
    }
    internal static string Clock(double seconds)
    {if(!double.IsFinite(seconds)||seconds<0)return "未提供";var t=TimeSpan.FromSeconds(seconds);return t.TotalHours>=1?$"{(int)t.TotalHours}:{t.Minutes:00}:{t.Seconds:00}":$"{(int)t.TotalMinutes}:{t.Seconds:00}";}
    internal static IReadOnlyList<Section> Read(object session)
    {
        var client=Access.Get<MpvClient?>(session,"_mpvClient");if(client==null||client.IsDisposed)return [new("播放状态",[new("状态","当前播放会话已结束")])];
        bool seeking=PlaybackTransport.Get(client,"seeking")=="yes";
        string Get(string key){var v=seeking?"":PlaybackTransport.Get(client,key);return string.IsNullOrWhiteSpace(v)?"未提供":v;}
        double? Number(string key)=>double.TryParse(Get(key),NumberStyles.Float,CultureInfo.InvariantCulture,out var n)&&double.IsFinite(n)?n:null;
        string Units(string key,string unit)=>Number(key) is {} n?n.ToString("0.##",CultureInfo.InvariantCulture)+unit:"未提供";
        string Rate(double? n)=>n is >0?(n.Value/1000000).ToString("0.##",CultureInfo.InvariantCulture)+" Mbps":"未提供";
        string Joined(params string[] keys)=>string.Join(" · ",keys.Select(Get).Where(v=>v!="未提供")) is {Length:>0} value?value:"未提供";
        string Track(string type)
        {
            string id=Get(type=="sub"?"sid":"aid");if(id=="no")return "关闭";
            string title=Get($"current-tracks/{type}/title"),language=Get($"current-tracks/{type}/lang"),codec=Get($"current-tracks/{type}/codec");
            return string.Join(" · ",new[]{title,language,codec}.Where(v=>v!="未提供")) is {Length:>0} text?text:"未提供";
        }
        var item=Access.Get<EmbyItem>(session,"_item");var source=Access.Get<MediaSourceInfo>(session,"_source");
        var api=Access.Get<EmbyApiClient>(session,"_embyClient");var result=new List<Section>();
        if(Accounts.TryGetValue(api,out var account))result.Add(new("当前账号",[new(account.UserName,account.ServerName)]));
        string format=Get("file-format");string container=format switch{"matroska,webm" or "matroska"=>"Matroska / WebM","mov,mp4,m4a,3gp,3g2,mj2"=>"MP4 / MOV","mpegts"=>"MPEG-TS",_=>format};
        var uri=Access.Get<Uri>(session,"_playbackUri");if(uri.Scheme is "yingyu-bd" or "bd"||!string.IsNullOrWhiteSpace(Access.Get<string?>(session,"_nativeDiscPath")))container="蓝光原盘";
        string color=Get("video-params/gamma");string primaries=Get("video-params/primaries");string profile=Get("current-tracks/video/dolby-vision-profile");
        string dynamic=MediaNotice.SourceFormat(session);
        var movie=new List<Row>{new(item.Name,item.Type=="Episode"?string.Join(" · ",new[]{item.SeriesName,item.ParentIndexNumber is {} season?$"第 {season} 季":"",item.IndexNumber is {} episode?$"第 {episode} 集":""}.Where(v=>!string.IsNullOrWhiteSpace(v))):item.ProductionYear?.ToString()??""),new("资源类型",container+(dynamic.Length>0?" · "+dynamic:""))};
        if(!string.IsNullOrWhiteSpace(item.Overview))movie.Add(new("剧情简介",item.Overview));
        movie.Add(new("播放进度",Clock(Access.Get<double>(session,"_position"))+" / "+Clock(Access.Get<double>(session,"_duration"))));movie.Add(new("显示输出",MediaNotice.OutputFormat(session)));if(dynamic.StartsWith("杜比视界",StringComparison.Ordinal)){movie.Add(new("杜比播放方式",MediaNotice.PlaybackMessage(session,false)));}result.Add(new("影片",movie));
        result.Add(new("视频",[
            new("当前视频编码",Get("video-format")),new("视频码率（当前估算）",Rate(Number("video-bitrate"))),new("当前视频尺寸",Number("video-params/w") is >0&&Number("video-params/h") is >0?$"{Get("video-params/w")} × {Get("video-params/h")}":"未提供"),
            new("像素格式",Get("video-params/pixelformat")),new("色彩信息",Joined("video-params/primaries","video-params/gamma","video-params/colorlevels")),new("片源帧率",Units("container-fps"," fps")),
            new("当前显示输出",Joined("current-vo","video-target-params/primaries","video-target-params/gamma")),new("当前屏幕能力","未提供独立屏幕能力数据"),new("当前硬件解码",Get("hwdec-current"))]));
        string passthrough=Get("audio-out-params/format");string output=passthrough.StartsWith("spdif",StringComparison.OrdinalIgnoreCase)?"压缩音频直通":passthrough=="未提供"?"未提供":"PCM 解码输出";
        result.Add(new("音频与字幕",[new("音频输出方式",output),new("系统媒体路由",Get("current-ao")),new("当前音轨",Track("audio")),new("当前音频编码",Get("audio-codec-name")),new("音频码率（当前估算）",Rate(Number("audio-bitrate"))),new("当前字幕",Track("sub")),new("音频采样率",Units("audio-params/samplerate"," Hz")),new("解码音频声道",Get("audio-params/channels")),new("设备输出声道",Get("audio-out-params/channels")),new("字幕位置",Units("sub-pos","%")),new("字幕延迟",Units("sub-delay"," s")),new("码率说明","当前码率由实际播放数据估算；服务器标注单独显示，未能读取的信息不作猜测。") ]));
        var server=new List<Row>();var video=source.MediaStreams.Where(s=>s.Type=="Video").ToArray();var audio=source.MediaStreams.Where(s=>s.Type=="Audio").ToArray();
        if(video.Length==1){var v=video[0];server.Add(new("视频编码（服务器标注）",v.Codec??"未提供"));if(v.BitRate is >0)server.Add(new("视频码率（服务器标注）",Rate(v.BitRate)));if(v.Width is >0&&v.Height is >0)server.Add(new("分辨率（服务器标注）",$"{v.Width} × {v.Height}"));}
        // A multi-track source is not evidence of which stream is selected.
        if(audio.Length==1&&audio[0].BitRate is >0)server.Add(new("音频码率（服务器标注）",Rate(audio[0].BitRate)));
        if(server.Count>0)result.Add(new("服务器补充资料",server));
        result.Add(new("播放状态",[new("状态",seeking?"正在定位":Get("paused-for-cache")=="yes"?"正在缓冲":Get("pause")=="yes"?"已暂停":"播放中"),new("速度",Units("speed","×"))]));
        return result;
    }
}
