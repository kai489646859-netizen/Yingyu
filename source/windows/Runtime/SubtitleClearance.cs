using Richasy.MpvKernel.Core.Models;
namespace Yingyu.Update;
// Compatibility entries: subtitles keep their native baseline and user position.
// Overlay visibility and resizing never write subtitle positioning properties.
public static class SubtitleClearance
{
 public static double Position(double requested,double controlsTop,double height)=>requested;
 public static void Bind(object session) { }
 public static void Notify(object session,MpvClientNotifyEventArgs e) { }
 public static void Changed(object overlay) { }
}
