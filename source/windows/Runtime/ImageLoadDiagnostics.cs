using System.Collections.Concurrent;
using System.Diagnostics;

namespace Yingyu.Update;

// Fixed stage names and numbers only: no file paths, URLs or media identities.
// Coalesce normal traffic; retain a few immediate failures to distinguish an
// absent source from server refusal, timeout, disk/decode and queue delays.
internal static class ImageLoadDiagnostics
{
    sealed class Sample { internal long Count,Total,Maximum; }
    static readonly ConcurrentDictionary<string,Sample> Samples=new();
    static long nextReport;static int failures;
    internal static long Start()=>Stopwatch.GetTimestamp();
    internal static void Record(string stage,long start,int status=0)
    {
        long elapsed=(long)Stopwatch.GetElapsedTime(start).TotalMilliseconds;
        var sample=Samples.GetOrAdd(stage,_=>new());Interlocked.Increment(ref sample.Count);Interlocked.Add(ref sample.Total,elapsed);
        long old;do{old=Volatile.Read(ref sample.Maximum);if(old>=elapsed)break;}while(Interlocked.CompareExchange(ref sample.Maximum,elapsed,old)!=old);
        bool failed=stage is "http-failed" or "timeout" or "io-failed" or "decode-failed";
        if(failed&&Interlocked.Increment(ref failures)<=8)
            PlaybackTransport.Write("Warning","Poster.Pipeline",$"stage={stage}; status={status}; elapsedMs={elapsed}; identities=omitted");
        long now=Environment.TickCount64,previous=Volatile.Read(ref nextReport);
        if(now<previous||Interlocked.CompareExchange(ref nextReport,now+5000,previous)!=previous)return;
        var fields=Samples.OrderBy(p=>p.Key).Select(p=>$"{p.Key}[count={Volatile.Read(ref p.Value.Count)},meanMs={Volatile.Read(ref p.Value.Total)/Math.Max(1,Volatile.Read(ref p.Value.Count))},maxMs={Volatile.Read(ref p.Value.Maximum)}]");
        PlaybackTransport.Write("Info","Poster.Pipeline",string.Join("; ",fields)+"; identities=omitted");
    }
}
