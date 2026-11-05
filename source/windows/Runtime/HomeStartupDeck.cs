using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using EmbyDesktop.Core.Models;
using EmbyDesktop.Core.Services;

namespace Yingyu.Update;

// A bounded metadata reservoir for the next launch, independent of cache hits.
// Selection never requests metadata, scans image directories or decodes images.
internal static class HomeStartupDeck
{
    internal sealed record Entry(EmbyItem Item,string ImageOwner,string ImageType,string Tag,int Width,int Quality,PosterCacheRetention Retention);
    sealed record Document(int Version,string Scope,Entry[] Entries,string[] Last,string? Day=null);
    internal sealed record Ready(Entry[] Pool,Entry[] Picks,bool SameDay=false);
    internal sealed record Plan(Entry[] Pool,EmbyItem[] Fresh,Dictionary<string,EmbyItem> Current);
    const int MaximumEntries=64,MaximumBytes=256*1024;
    internal static string Scope(EmbySession session)=>Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(session.ServerUrl+"\n"+session.ServerId+"\n"+session.UserId)));
    internal static string PathFor(EmbySession session)=>Path.Combine(CachePaths.UserDataRoot,"home-discovery",Scope(session)+".ready.json");
    static bool Text(string? s,int limit)=>s!=null&&s.Length<=limit;
    static bool Allowed(EmbyItem? item)=>item!=null&&Text(item.Id,512)&&!string.IsNullOrWhiteSpace(item.Id)&&Text(item.Name,512)&&item.Type is "Movie" or "Series";
    static bool StableProvider(KeyValuePair<string,string> pair){
        if(string.IsNullOrWhiteSpace(pair.Value)||pair.Value.Length>64)return false;
        if(pair.Key.Equals("Tmdb",StringComparison.OrdinalIgnoreCase)||pair.Key.Equals("Tvdb",StringComparison.OrdinalIgnoreCase))return pair.Value.All(char.IsAsciiDigit);
        return pair.Key.Equals("Imdb",StringComparison.OrdinalIgnoreCase)&&pair.Value.StartsWith("tt",StringComparison.OrdinalIgnoreCase)&&pair.Value.Length>2&&pair.Value.Skip(2).All(char.IsAsciiDigit);
    }
    static EmbyItem Clean(EmbyItem item)=>new(){Id=item.Id,Name=item.Name,Type=item.Type,
        ProductionYear=item.ProductionYear,ProviderIds=item.ProviderIds.Where(StableProvider).ToDictionary(p=>p.Key,p=>p.Value),
        ImageTags=item.ImageTags.Where(p=>p.Key is "Primary" or "Thumb"&&Text(p.Value,1024)).ToDictionary(p=>p.Key,p=>p.Value),
        BackdropImageTags=item.BackdropImageTags.Where(v=>Text(v,1024)).Take(4).ToList(),
        ParentThumbItemId=Text(item.ParentThumbItemId,512)?item.ParentThumbItemId:null,ParentThumbImageTag=Text(item.ParentThumbImageTag,1024)?item.ParentThumbImageTag:null,
        ParentBackdropItemId=Text(item.ParentBackdropItemId,512)?item.ParentBackdropItemId:null,ParentBackdropImageTags=item.ParentBackdropImageTags.Where(v=>Text(v,1024)).Take(4).ToList()};
    internal static string? Resolve(PosterCacheService cache,EmbySession session,Entry entry)
    {
        if(!Allowed(entry.Item)||!Text(entry.ImageOwner,512)||!Text(entry.Tag,1024)||string.IsNullOrWhiteSpace(entry.Tag)
            ||entry.ImageType is not ("Thumb" or "Backdrop")||entry.Width is not (360 or 480 or 700 or 720 or 960 or 1280 or 1920 or 2560)
            ||entry.Quality is not (85 or 90)||entry.Retention is not (PosterCacheRetention.Detail or PosterCacheRetention.Browse))return null;
        if(!MediaArtworkPolicy.GetLandscapeCandidates(entry.Item).Any(c=>c.ItemId==entry.ImageOwner&&c.ImageType==entry.ImageType&&c.ImageTag==entry.Tag))return null;
        var request=new PosterCacheRequest(session.ServerId,session.UserId,entry.ImageOwner,entry.ImageType,entry.Tag,entry.Width,entry.Quality,entry.Retention);
        string file=Path.GetFullPath((string)Access.Call(cache,"BuildExactPath",request)!);
        string root=Path.GetFullPath(entry.Retention==PosterCacheRetention.Detail?CachePaths.Artwork:CachePaths.Posters).TrimEnd(Path.DirectorySeparatorChar);
        if(!file.StartsWith(root+Path.DirectorySeparatorChar,StringComparison.OrdinalIgnoreCase))return null;
        try{
            var info=new FileInfo(file);if(!info.Exists||info.Length is <=0 or >4*1024*1024||(info.Attributes&FileAttributes.ReparsePoint)!=0)return null;
            for(string? at=info.DirectoryName;at!=null&&at.StartsWith(root,StringComparison.OrdinalIgnoreCase);at=Path.GetDirectoryName(at)){
                if((File.GetAttributes(at)&FileAttributes.ReparsePoint)!=0)return null;if(at.Equals(root,StringComparison.OrdinalIgnoreCase))break;
            }
            return file;
        }catch(Exception e)when(e is IOException or UnauthorizedAccessException){return null;}
    }
    internal static Entry? Capture(PosterCacheService cache,EmbySession session,EmbyItem item)
    {
        if(!Allowed(item))return null;var clean=Clean(item);
        foreach(var c in MediaArtworkPolicy.GetLandscapeCandidates(clean).Where(c=>c.ImageType is "Thumb" or "Backdrop"))
        foreach(int width in new[]{1280,360,480,700,720,960,1920,2560})
        foreach(int quality in new[]{85,90})
        foreach(var retention in new[]{PosterCacheRetention.Detail,PosterCacheRetention.Browse}){
            var entry=new Entry(clean,c.ItemId,c.ImageType,c.ImageTag,width,quality,retention);if(Resolve(cache,session,entry)!=null)return entry;
        }
        return null;
    }
    static bool Valid(Entry? entry)=>entry!=null&&Allowed(entry.Item)&&Text(entry.ImageOwner,512)&&Text(entry.Tag,1024)&&!string.IsNullOrWhiteSpace(entry.Tag)
        &&entry.ImageType is "Thumb" or "Backdrop"&&entry.Width==1280&&entry.Quality==85&&entry.Retention==PosterCacheRetention.Detail
        &&MediaArtworkPolicy.GetLandscapeCandidates(entry.Item).Any(c=>c.ItemId==entry.ImageOwner&&c.ImageType==entry.ImageType&&c.ImageTag==entry.Tag);
    internal static Entry? Candidate(EmbyItem item){
        if(!Allowed(item))return null;var clean=Clean(item);
        var c=MediaArtworkPolicy.GetLandscapeCandidates(clean).FirstOrDefault(c=>c.ImageType is "Thumb" or "Backdrop"&&!string.IsNullOrWhiteSpace(c.ImageTag));
        return c==null?null:new Entry(clean,c.ItemId,c.ImageType,c.ImageTag,1280,85,PosterCacheRetention.Detail);
    }
    internal static Task<Ready> Read(PosterCacheService cache,EmbySession session,CancellationToken token)=>Task.Run(()=>{
        token.ThrowIfCancellationRequested();try{
            var file=new FileInfo(PathFor(session));if(!file.Exists||file.Length is <=0 or >MaximumBytes)return new Ready([],[]);
            var doc=JsonSerializer.Deserialize<Document>(File.ReadAllBytes(file.FullName));
            if(doc==null||doc.Version is not (1 or 2 or 3)||doc.Scope!=Scope(session)||doc.Entries==null||doc.Entries.Length>MaximumEntries||doc.Last==null||doc.Last.Length>6)return new Ready([],[]);
            var pool=doc.Entries.Where(e=>e!=null&&(doc.Version==1?Resolve(cache,session,e)!=null:Valid(e)))
                .Select(e=>Candidate(e.Item)).OfType<Entry>().DistinctBy(e=>e.Item.Id,StringComparer.OrdinalIgnoreCase).ToArray();
            bool sameDay=doc.Version==3&&doc.Day==DateTime.Today.ToString("yyyy-MM-dd",System.Globalization.CultureInfo.InvariantCulture);
            var picks=sameDay?doc.Last.Select(id=>pool.FirstOrDefault(e=>e.Item.Id.Equals(id,StringComparison.OrdinalIgnoreCase))).OfType<Entry>().DistinctBy(e=>e.Item.Id).ToArray():pool.OrderBy(_=>Random.Shared.Next()).Take(6).ToArray();
            token.ThrowIfCancellationRequested();return new Ready(pool,picks,sameDay&&picks.Length>0);
        }catch(Exception e)when(e is IOException or UnauthorizedAccessException or JsonException or ArgumentException or NullReferenceException){return new Ready([],[]);}
    },token);
    internal static Task Save(PosterCacheService cache,EmbySession session,IEnumerable<Entry> entries,IEnumerable<string> last,CancellationToken token,DateTime? day=null)=>Task.Run(()=>{
        token.ThrowIfCancellationRequested();string path=PathFor(session),temp=path+"."+Guid.NewGuid().ToString("N")+".tmp";
        try{
            var pool=entries.Where(Valid).DistinctBy(e=>e.Item.Id,StringComparer.OrdinalIgnoreCase).Take(MaximumEntries).Select(e=>e with{Item=Clean(e.Item)}).ToArray();
            var bytes=JsonSerializer.SerializeToUtf8Bytes(new Document(3,Scope(session),pool,last.Take(6).ToArray(),(day??DateTime.Today).ToString("yyyy-MM-dd",System.Globalization.CultureInfo.InvariantCulture)));if(bytes.Length>MaximumBytes)return;
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);File.WriteAllBytes(temp,bytes);token.ThrowIfCancellationRequested();File.Move(temp,path,true);
        }catch(Exception e)when(e is IOException or UnauthorizedAccessException){}
        finally{if(File.Exists(temp))File.Delete(temp);}
    },token);
    internal static Task<Plan> Build(PosterCacheService cache,EmbySession session,LocalSearchIndexSnapshot snapshot,HashSet<string> shown,CancellationToken token)=>Task.Run(()=>{
        var pool=new List<Entry>(MaximumEntries);var picks=new List<EmbyItem>(6);var current=new Dictionary<string,EmbyItem>(StringComparer.OrdinalIgnoreCase);
        var seen=new HashSet<string>(StringComparer.OrdinalIgnoreCase);int count=0;
        foreach(var row in snapshot.Entries){
            token.ThrowIfCancellationRequested();var item=row.Item;if(!Allowed(item)||!seen.Add(item.Id))continue;
            if(shown.Contains(item.Id))current.TryAdd(item.Id,item);var entry=Candidate(item);if(entry==null)continue;
            count++;if(pool.Count<MaximumEntries)pool.Add(entry);else{int at=Random.Shared.Next(count);if(at<MaximumEntries)pool[at]=entry;}
            if(picks.Count<6)picks.Add(entry.Item);else{int at=Random.Shared.Next(count);if(at<6)picks[at]=entry.Item;}
        }
        for(int i=picks.Count-1;i>0;i--){int at=Random.Shared.Next(i+1);(picks[i],picks[at])=(picks[at],picks[i]);}
        pool=picks.Select(Candidate).OfType<Entry>().Concat(pool).DistinctBy(e=>e.Item.Id,StringComparer.OrdinalIgnoreCase).Take(MaximumEntries).ToList();
        return new Plan(pool.ToArray(),picks.ToArray(),current);
    },token);
}
