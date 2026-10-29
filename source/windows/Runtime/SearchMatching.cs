using System.Text;
using EmbyDesktop.Core.Models;
using EmbyDesktop.Core.Services;

namespace Yingyu.Update;

// Every query component must match. Chinese fragments may skip intervening letters;
// punctuation, whitespace, casing and width never create a separate spelling.
public static class SearchMatching
{
    public static string Normalize(string? value)=>string.Concat((value??"").Normalize(NormalizationForm.FormKC).EnumerateRunes().Where(Rune.IsLetterOrDigit).Select(r=>r.ToString())).ToUpperInvariant();
    static bool Han(Rune r)=>r.Value is >=0x3400 and <=0x9fff or >=0x20000 and <=0x323af;
    public static string[] Queries(string text)
    {
        var values=new List<string>();string whole=Normalize(text);if(whole.Length==0)return [];
        values.Add(whole);var word=new StringBuilder();
        void Flush(){if(word.Length>0){values.Add(word.ToString());word.Clear();}}
        foreach(var rune in text.Normalize(NormalizationForm.FormKC).EnumerateRunes())
        {if(Han(rune)){Flush();values.Add(rune.ToString());}else if(Rune.IsLetterOrDigit(rune))word.Append(rune.ToString().ToUpperInvariant());else Flush();}
        Flush();return values.Distinct(StringComparer.Ordinal).ToArray();
    }
    public static int Score(string? name,string query)
    {
        string value=Normalize(name),whole=Normalize(query);if(value.Length==0||whole.Length==0)return 0;
        if(value==whole)return 10000;
        if(value.Contains(whole,StringComparison.Ordinal))return 9000;
        var terms=Queries(query).Skip(1).ToArray();int hits=terms.Count(t=>value.Contains(t,StringComparison.Ordinal));
        if(terms.Length==0||hits!=terms.Length)return 0;
        if(whole.EnumerateRunes().Any(Han)){
            var required=whole.EnumerateRunes().ToArray();int at=0;
            foreach(var rune in value.EnumerateRunes())if(at<required.Length&&rune==required[at])at++;
            if(at!=required.Length)return 0;
        }
        return 1000+hits*100;
    }
    public static IReadOnlyList<EmbyItem> Search(IEnumerable<LocalSearchIndexEntry> entries,string searchTerm,string? libraryId,int limit,bool favoritesOnly,int offset,CancellationToken token)
    {
        ArgumentNullException.ThrowIfNull(entries);
        if(Normalize(searchTerm).Length==0)return Array.Empty<EmbyItem>();
        return entries.Where(e=>string.IsNullOrWhiteSpace(libraryId)||string.Equals(e.LibraryId,libraryId,StringComparison.OrdinalIgnoreCase))
            .Select(e=>e.Item).Where(i=>!favoritesOnly||i.UserData?.IsFavorite==true)
            .Select(i=>{token.ThrowIfCancellationRequested();return (Item:i,Score:new[]{i.Name,i.OriginalTitle}.Max(n=>Score(n,searchTerm)));})
            .Where(x=>x.Score>0).GroupBy(x=>x.Item.Id,StringComparer.OrdinalIgnoreCase).Select(g=>g.OrderByDescending(x=>x.Score).First())
            .OrderByDescending(x=>x.Score).ThenBy(x=>x.Item.Name,StringComparer.CurrentCultureIgnoreCase)
            .Skip(Math.Max(0,offset)).Take(Math.Max(1,limit)).Select(x=>x.Item).ToArray();
    }
}
