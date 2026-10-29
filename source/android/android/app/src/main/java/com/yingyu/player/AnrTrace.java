package com.yingyu.player;

import android.app.ActivityManager;
import android.app.ApplicationExitInfo;
import android.content.Context;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.util.*;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.regex.*;
import io.flutter.plugin.common.MethodChannel;

/** Own-process ANR only. Raw trace text, paths and thread names never leave Java. */
final class AnrTrace {
    static final int MAX_BYTES = 8 * 1024 * 1024;
    static final int MAX_THREADS = 64;
    static final int MAX_FRAMES = 256;
    private static final AtomicBoolean started = new AtomicBoolean();
    private static volatile Map<String,Object> cached;
    private static final Pattern HEADER = Pattern.compile("^\"([^\"]{1,128})\".*?\\b(?:tid|sysTid)=(\\d{1,9})(?:\\s|$).*$");
    private static final Pattern JAVA = Pattern.compile("^\\s*at ((?:android\\.|java\\.|javax\\.|dalvik\\.|io\\.flutter\\.|com\\.yingyu\\.|com\\.alexmercerind\\.)[A-Za-z0-9_.$]{1,220})\\([^\\r\\n]*\\).*$");
    private static final Pattern NATIVE = Pattern.compile("^\\s*native:\\s*#\\d+\\s+pc\\s+([0-9a-fA-F]{1,16})\\s+(\\S{1,4096})(?:\\s.*)?$");
    private static final Pattern OWNER = Pattern.compile("^\\s*-.*held by thread (\\d{1,9}).*$");
    private static final Pattern BUILD = Pattern.compile("\\(BuildId: ([0-9a-fA-F]{16,128})\\)");

    static Map<String,Object> status(String value) {
        Map<String,Object> r = new HashMap<>(); r.put("status",value); return r;
    }
    static void readAsync(Context context, MethodChannel.Result reply) {
        Map<String,Object> ready=cached;
        if(ready!=null){reply.success(ready);return;}
        if(!started.compareAndSet(false,true)){reply.success(status("reading"));return;}
        Context app=context.getApplicationContext();
        Thread worker=new Thread(()->{
            Map<String,Object> value;
            try {value=read(app);} catch(RuntimeException|LinkageError e){value=status("unavailable");}
            try { String[] fds=new File("/proc/self/fd").list(); if(fds!=null)value.put("currentOpenFds",fds.length); } catch(RuntimeException ignored) { }
            cached=value; final Map<String,Object> result=value;
            new Handler(Looper.getMainLooper()).post(()->{
                try {reply.success(result);}catch(RuntimeException ignored){ }
            });
        },"yingyu-anr-read");
        worker.setDaemon(true);
        try {worker.start();}catch(RuntimeException e){cached=status("unavailable");reply.success(cached);}
    }
    static Map<String,Object> read(Context app) {
        if(Build.VERSION.SDK_INT<30)return status("unsupported");
        ActivityManager manager=(ActivityManager)app.getSystemService(Context.ACTIVITY_SERVICE);
        if(manager==null)return status("unavailable");
        String name=app.getPackageName();
        Map<String,Object> unavailable=null;
        final long deadline=System.nanoTime()+2_000_000_000L;
        for(ApplicationExitInfo info:manager.getHistoricalProcessExitReasons(name,0,8)){
            // A recovered ANR may be attached to a later user-stop or other
            // exit reason. Native-crash streams are protobuf, handled elsewhere.
            if(!name.equals(info.getProcessName())||info.getReason()==ApplicationExitInfo.REASON_CRASH_NATIVE)continue;
            if(System.nanoTime()>deadline)break;
            Map<String,Object> value;
            try(InputStream stream=info.getTraceInputStream()){
                value=stream==null?status("unavailable"):parse(stream,name,deadline);
            }catch(Limit e){value=status(e.kind);}
            catch(IOException|RuntimeException e){value=status("invalid");}
            value.put("timestamp",info.getTimestamp());
            value.put("exitReason",info.getReason());
            if("available".equals(value.get("status"))){
                Object pid=value.get("tracePid"), time=value.get("traceTimestamp");
                String association=pid instanceof Integer&&info.getPid()>0
                    ? (((Integer)pid).intValue()==info.getPid()?"pid-match":"pid-mismatch")
                    : "unverified";
                if("pid-match".equals(association)&&time instanceof Long
                        &&((Long)time)>info.getTimestamp()+60000L)association="time-mismatch";
                value.put("association",association);return value;
            }
            if(unavailable==null&&info.getReason()==ApplicationExitInfo.REASON_ANR)unavailable=value;
        }
        return unavailable==null?status("none"):unavailable;
    }
    static final class Limit extends IOException {
        final String kind; Limit(String value){kind=value;}
    }
    // Bounded line reader: avoids allocating arbitrarily long arbitrary trace lines.
    private static final class Lines {
        final InputStream input; final long deadline; int bytes;
        Lines(InputStream input,long deadline){this.input=new BufferedInputStream(input,8192);this.deadline=deadline;}
        String next()throws IOException{
            ByteArrayOutputStream line=new ByteArrayOutputStream(); boolean any=false,overflow=false;
            while(true){
                if(System.nanoTime()>deadline)throw new Limit("expired");
                int b=input.read();if(b<0)return any?(overflow?"":line.toString(StandardCharsets.UTF_8.name())):null;
                if(++bytes>MAX_BYTES)throw new Limit("too_large");
                any=true;if(b==10)return overflow?"":line.toString(StandardCharsets.UTF_8.name());
                if(line.size()<4096)line.write(b);else overflow=true;
            }
        }
    }
    @SuppressWarnings("unchecked")
    static Map<String,Object> parse(InputStream input,String name,long deadline)throws IOException{
        Lines lines=new Lines(input,deadline);boolean own=false,seen=false,truncated=false;
        List<Map<String,Object>> threads=new ArrayList<>();Map<String,Object> thread=null;
        int total=0, importantFrames=0, otherFrames=0, tracePid=0;Long traceTime=null;String line;
        while((line=lines.next())!=null){
            if(!own&&line.startsWith("----- pid ")){
                Matcher start=Pattern.compile("^----- pid ([0-9]{1,9}) at (.{1,100}) -----$").matcher(line);
                if(start.matches()){
                    tracePid=Integer.parseInt(start.group(1));
                    try{
                        String date=start.group(2).replace(' ','T')
                            .replaceFirst("([+-][0-9]{2})([0-9]{2})$","$1:$2");
                        traceTime=java.time.OffsetDateTime.parse(date).toInstant().toEpochMilli();
                    }catch(java.time.DateTimeException ignored){traceTime=null;}
                }
            }
            if(line.startsWith("Cmd line: ")){
                if(seen)break;seen=true;
                if(!line.substring(10).trim().equals(name))return status("wrong_process");
                own=true;continue;
            }
            if(!own)continue;
            if(line.startsWith("----- end "))break;
            Matcher header=HEADER.matcher(line);
            if(header.matches()){
                thread=null;
                if(threads.size()>=MAX_THREADS){truncated=true;continue;}
                thread=new HashMap<>();thread.put("id",Integer.parseInt(header.group(2)));
                String role=header.group(1);
                role=role.equals("main")?"main":role.matches("(?:[0-9]+\\.)?raster")?"raster":role.matches("(?:[0-9]+\\.)?io")?"io":"other";
                thread.put("role",role);String state="unknown";
                for(String s:new String[]{"Native","Runnable","Blocked","Waiting","TimedWaiting","Suspended"})if(line.endsWith(" "+s))state=s;
                thread.put("state",state);thread.put("frames",new ArrayList<Map<String,Object>>());threads.add(thread);continue;
            }
            if(thread==null)continue;
            Matcher owner=OWNER.matcher(line);
            if(owner.matches()){thread.put("owner",Integer.parseInt(owner.group(1)));continue;}
            Map<String,Object> frame=null;Matcher java=JAVA.matcher(line),nativeFrame=NATIVE.matcher(line);
            if(java.matches()){frame=new HashMap<>();frame.put("kind","java");frame.put("method",java.group(1));}
            else if(nativeFrame.matches()){
                frame=new HashMap<>();frame.put("kind","native");frame.put("pc",nativeFrame.group(1).toLowerCase(Locale.ROOT));
                String path=nativeFrame.group(2),library=path.substring(path.lastIndexOf('/')+1);
                if(!library.matches("lib[A-Za-z0-9_.+-]{1,90}\\.so(?:\\.[0-9]+)*"))library="unknown";
                frame.put("library",library);
                Matcher build=BUILD.matcher(line);
                if(build.find())frame.put("buildId",build.group(1).toLowerCase(Locale.ROOT));
            }
            if(frame!=null){
                List<Map<String,Object>> frames=(List<Map<String,Object>>)thread.get("frames");
                boolean important=!"other".equals(thread.get("role"));
                // Reserve a separate half-budget for main/raster/io, even when
                // many binder/worker threads precede the raster thread.
                if(frames.size()<(important?32:8)&&(important?importantFrames:otherFrames)<MAX_FRAMES/2){
                    frames.add(frame);total++;if(important)importantFrames++;else otherFrames++;
                }else truncated=true;
            }
        }
        if(!own||total==0)return status("invalid");
        Map<String,Object> result=status("available");result.put("threads",threads);result.put("truncated",truncated);
        if(tracePid>0)result.put("tracePid",tracePid);
        if(traceTime!=null)result.put("traceTimestamp",traceTime);
        return result;
    }
}
