using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Richasy.MpvKernel.Core;
namespace Yingyu.Update;

// Native mpv stats owns rendering, refresh, page keys and Escape handling.
public static class PlayerMediaInfo
{
 // Retain the existing binding ABI, with no extra upper-left control.
 public static void Configure(object overlay) { }
 public static void Bind(object session)
 {
  SubtitlePlacement.Bind(session);
 }
 public static string Snapshot(object session)=>string.Join("\n\n",PlayerInfoData.Read(session).Select(s=>s.Title+"\n"+string.Join("\n",s.Rows.Select(r=>r.Label+"："+r.Value))));
 public static void Toggle(object session)
 {
    if(NativeDolby.IsClosing(session))return;
    if(Access.Get<MpvClient?>(session,"_mpvClient") is not {} client||client.IsDisposed)return;
    if(Access.Get<object?>(session,"_overlay") is {} owner)PlayerDesktopStyle.CancelClick(owner);
    int result=DolbyVision.CommandAsync(client,"script-binding","stats/display-page-1-toggle");
    PlaybackFeatureLog.Write(session,"native-stats",result<0?"request-failed":"requested",result);
 }
}
