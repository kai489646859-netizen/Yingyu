using EmbyDesktop.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Richasy.MpvKernel.Core;

namespace Yingyu.Update;

public static class ResourceSourceInfo
{
    internal static MediaStreamInfo? Video(MediaSourceInfo source)
    {
        var videos=(source.MediaStreams??[]).Where(s=>s!=null&&string.Equals(s.Type,"Video",StringComparison.OrdinalIgnoreCase)&&!s.IsExternal).ToArray();
        if(videos.Length==1)return videos[0];
        var defaults=videos.Where(s=>s.IsDefault).ToArray();
        if(defaults.Length==1)return defaults[0];
        // Identical layered/duplicate video records still establish these same facts.
        return videos.Length>0&&videos.All(s=>(s.Width,s.Height,s.Codec,s.VideoRange,s.VideoRangeType)==(videos[0].Width,videos[0].Height,videos[0].Codec,videos[0].VideoRange,videos[0].VideoRangeType))?videos[0]:null;
    }
    internal static string Resolution(int? width,int? height)
    {
        if(width is not >0 && height is not >0)return "分辨率未知";
        return width>=7680||height>=4320?"8K":width>=3840||height>=2160?"4K":height>=1440?"1440p":width>=1920||height>=1080?"1080p":width>=1280||height>=720?"720p":width is >0&&height is >0?$"{width}×{height}":height is >0?$"{height}p":"分辨率未知";
    }
    internal static string ServerFormat(MediaSourceInfo source)
    {
        var video=Video(source);if(video==null)return "格式未知";
        string mark=((video.VideoRangeType??"")+" "+(video.VideoRange??"")).ToLowerInvariant().Replace(" ","").Replace("_","").Replace("-","");
        if(mark.Contains("dolbyvision")||mark.Contains("dovi")||mark.Contains("dvwith")||mark is "dv" or "dvhe" or "dvh1")return "杜比视界";
        if(mark.Contains("hdr10+")||mark.Contains("hdr10plus"))return "HDR10+";
        if(mark.Contains("hdr10"))return "HDR10";
        if(mark.Contains("hlg"))return "HLG";
        if(mark.Contains("hdr"))return "HDR";
        return mark.Contains("sdr")?"SDR":"格式未知";
    }
    internal static string Summary(MediaSourceInfo source)
    {
        var video=Video(source);
        return (video!=null?Resolution(video.Width,video.Height):"分辨率未知")+" · "+ServerFormat(source);
    }
    public static string VersionLabel(MediaSourceInfo source)
    {
        string resolution=Summary(source).Split(" · ")[0];
        string format=ServerFormat(source);
        if(resolution=="分辨率未知") resolution="";
        if(format is "格式未知" or "SDR") format="";
        if(format=="杜比视界")format="杜比";
        string label=string.Join(" ",new[]{resolution,format}.Where(x=>x.Length>0));
        return label.Length>0?label:"原始资源";
    }
}
