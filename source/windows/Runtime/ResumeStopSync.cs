using EmbyDesktop.Core.Models;
using EmbyDesktop.Core.Services;

namespace Yingyu.Update;

// Only the actual player's existing stop report calls this seam. No periodic
// reads, homepage uploads, guessed max-progress, or parallel report requests.
public static class ResumeStopSync
{
    internal static bool Confirmed(EmbyItem remote,long position,bool completed)
    {
        if(remote.UserData is not {} data||!data.LastPlayedDate.HasValue)return false;
        if(completed)return data.Played&&data.PlaybackPositionTicks==0;
        if(position==0)return !data.Played&&data.PlaybackPositionTicks==0;
        return data.PlaybackPositionTicks>0&&Math.Abs((decimal)data.PlaybackPositionTicks-position)<=TimeSpan.TicksPerSecond*2;
    }
    public static async Task Stop(EmbyApiClient client,PlaybackRequest request,CancellationToken token,PlaybackStopReason reason)
    {
        EmbyItem? before=null;
        try{using var read=CancellationTokenSource.CreateLinkedTokenSource(token);read.CancelAfter(TimeSpan.FromSeconds(3));before=await client.GetItemAsync(request.ItemId,read.Token);}
        catch(Exception e)when(e is not OutOfMemoryException){PlaybackTransport.Write("Warning","Playback.Sync","停止前核对未完成，仍执行原停止上报；"+e.GetType().Name);}
        if(before!=null)ResumeDeviceSync.CaptureStop(client,before,request.PlaySessionId);
        try{await client.ReportPlaybackStoppedInBackgroundAsync(request,token);}
        catch(EmbyApiException){throw;}
        catch(Exception error){throw new EmbyApiException("停止上报未获确认；进度保留待同步。",innerException:error);}
        // HTTP success only acknowledges the request. The caller's original
        // EmbyApiException path persists the report if read-back is unconfirmed.
        try
        {
            using var read=CancellationTokenSource.CreateLinkedTokenSource(token);read.CancelAfter(TimeSpan.FromSeconds(4));
            for(int attempt=0;attempt<2;attempt++)
            {
                if(attempt>0)await Task.Delay(350,read.Token);
                var remote=await client.GetItemAsync(request.ItemId,read.Token);
                bool complete=reason==PlaybackStopReason.NaturalEnd;
                if(Confirmed(remote,request.PositionTicks,complete))
                {PlaybackTransport.Write("Info","Playback.Sync","停止上报已由当前服务器账号回读确认；位置秒="+(request.PositionTicks/TimeSpan.TicksPerSecond));return;}
            }
            throw new EmbyApiException("停止请求已返回，但服务器尚未确认对应位置；进度保留待同步。");
        }
        catch(EmbyApiException){throw;}
        catch(Exception e){throw new EmbyApiException("停止上报回读未完成；进度保留待同步。",innerException:e);}
    }
}
