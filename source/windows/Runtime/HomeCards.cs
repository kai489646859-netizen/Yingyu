using System.Collections;
using EmbyDesktop.Core.Models;
using EmbyDesktop.Core.Services;
using Microsoft.UI.Xaml;

namespace Yingyu.Update;
public static class HomeCards
{
    public static void Update(object page, object collection, IReadOnlyList<EmbyItem> items, bool landscape)
    {
        var cards=(IList)collection;
        items=ResumeSync.DisplayItems(items,landscape);
        var excluded=Access.Get<HashSet<string>>(page,"_unavailableMediaKeys");
        var wanted=items.Where(i=>!UnavailableMediaItemPolicy.IsExcluded(i,excluded)).ToArray();
        var ids=wanted.Select(i=>i.Id).ToHashSet(StringComparer.OrdinalIgnoreCase);
        EmbyItem Item(object card)=>(EmbyItem)card.GetType().GetProperty("Item")!.GetValue(card)!;
        for(int n=cards.Count-1;n>=0;n--)if(!ids.Contains(Item(cards[n]!).Id)){
            AndroidCacheCards.Viewport(cards[n]!,false,false);
            cards.RemoveAt(n);
        }
        var existing=cards.Cast<object>().ToDictionary(c=>Item(c).Id,StringComparer.OrdinalIgnoreCase);
        var cardType=page.GetType().Assembly.GetType("EmbyDesktop.ViewModels.MediaCardViewModel",true)!;
        int index=0;
        foreach(var item in wanted)
        {
            if(existing.TryGetValue(item.Id,out var card)&&(bool)card.GetType().GetProperty("PreferLandscapeArtwork")!.GetValue(card)! == landscape)
            {
                // Retain the model, its realized template and the decoded bitmap.
                // ArtworkChanged alone decides whether actual image demand changed.
                Access.Call(card,"UpdateItem",item);
                int oldIndex=cards.IndexOf(card);
                if(oldIndex!=index)Access.Call(collection,"Move",oldIndex,index);
            }
            else
            {
                if(card!=null){AndroidCacheCards.Viewport(card,false,false);cards.Remove(card);}
                card=Activator.CreateInstance(cardType)!;
                cardType.GetProperty("Item")!.SetValue(card,item);
                cardType.GetProperty("PreferLandscapeArtwork")!.SetValue(card,landscape);
                cards.Insert(index,card);
            }
            index++;
        }
        CachedArtwork.Enqueue(page,cards);
        if(page is FrameworkElement element)
            element.DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low,()=>AndroidCacheCards.Reconcile(page));
    }
}


