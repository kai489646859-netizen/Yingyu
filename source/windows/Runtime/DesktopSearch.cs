using System.Collections;
using System.Runtime.CompilerServices;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace Yingyu.Update;

// Editing owns only the pending search. Returning to a library is an explicit
// navigation action, never a side effect of deleting the last input character.
public static class DesktopSearch
{
    static readonly ConditionalWeakTable<object,Origin> Origins=new();
    static readonly ConditionalWeakTable<object,Pending> PendingQueries=new();
    sealed class Pending
    {
        public CancellationTokenSource? Source;
        public Pending(object page){if(page is FrameworkElement root)root.Unloaded+=(_,_)=>Cancel(page);}
    }
    internal static void Cancel(object page)
    {
        if(!PendingQueries.TryGetValue(page,out var pending))return;
        pending.Source?.Cancel();pending.Source?.Dispose();pending.Source=null;
    }
    internal static void Focus(AutoSuggestBox input)
    {
        input.ApplyTemplate();
        // AutoSuggestBox itself is not the editable focus target in this template.
        var editor=UiElements.Descendants(input).OfType<TextBox>().FirstOrDefault();
        if(editor!=null)editor.Focus(FocusState.Keyboard);else input.Focus(FocusState.Keyboard);
    }
    public static void Begin(object page)
    {
        Cancel(page);
        if(string.IsNullOrWhiteSpace(Access.Get<string?>(page,"_lastSearchTerm"))){Origins.Remove(page);Origins.Add(page,new Origin(page));}
    }
    public static void TextChanged(object page,AutoSuggestBox input,AutoSuggestBoxTextChangedEventArgs args)
    {
        if(Access.Get<bool>(page,"_suppressSearchTextChanged")||args.Reason!=AutoSuggestionBoxTextChangeReason.UserInput)return;
        Cancel(page);
        string? previous=Access.Get<string?>(page,"_lastSearchTerm");
        if(input.Text.Trim()==previous&&Access.Get<CancellationTokenSource?>(page,"_searchCancellation") is {IsCancellationRequested:false})return;
        Access.Get<CancellationTokenSource?>(page,"_searchCancellation")?.Cancel();
        DesktopPeople.Edit(page,string.IsNullOrWhiteSpace(input.Text));
        if(!string.IsNullOrWhiteSpace(input.Text)){Schedule(page,input);return;}
        if(string.IsNullOrWhiteSpace(previous))return;
        Access.Set(page,"_lastSearchTerm",null);
        Access.Set(page,"_searchResults",Array.Empty<EmbyDesktop.Core.Models.EmbyItem>());
        ((IList)Access.Call(page,"get_LatestItems")!).Clear();
        Access.Get<StackPanel>(page,"SearchResultsPanel").Visibility=Visibility.Collapsed;
        Access.Get<Grid>(page,"BrowseResultsSection").Visibility=Visibility.Collapsed;
        Access.Get<FrameworkElement>(page,"EmptyState").Visibility=Visibility.Collapsed;
        Access.Get<TextBlock>(page,"SearchResultsCount").Text="";
        Access.Get<Button>(page,"SearchMoreButton").Visibility=Visibility.Collapsed;
        if(Origins.TryGetValue(page,out var origin))origin.Restore(page);
    }
    static async void Schedule(object page,AutoSuggestBox input)
    {
        var pending=PendingQueries.GetValue(page,p=>new Pending(p));
        var source=pending.Source=new CancellationTokenSource();var token=source.Token;
        string query=input.Text.Trim();var owner=Access.Get<object?>(page,"_session");var client=Access.Get<object?>(page,"_client");
        var navigation=Access.Get<object?>(page,"_activeNavigation");string? library=Access.Get<string?>(page,"_activeLibraryId");
        try
        {
            await Task.Delay(280,token);
            if(token.IsCancellationRequested||page is not FrameworkElement {IsLoaded:true}||!input.IsLoaded||!Visible(input)||client==null||!ReferenceEquals(client,Access.Get<object?>(page,"_client"))||!ReferenceEquals(owner,Access.Get<object?>(page,"_session"))||!Equals(navigation,Access.Get<object?>(page,"_activeNavigation"))||library!=Access.Get<string?>(page,"_activeLibraryId")||query!=input.Text.Trim())return;
            if(string.IsNullOrWhiteSpace(Access.Get<string?>(page,"_lastSearchTerm")))
            {
                Access.Set(page,"_searchOriginNavigation",navigation);Access.Set(page,"_searchOriginLibraryId",library);
                Access.Set(page,"_searchOriginVerticalOffset",Access.Get<ScrollViewer>(page,"MainContentScrollViewer").VerticalOffset);
            }
            string? scope=navigation?.ToString()=="Library"?library:navigation==null?Access.Get<string?>(page,"_lastSearchLibraryId"):null;
            bool favorites=navigation?.ToString()=="Favorites"||(navigation==null&&Access.Get<bool>(page,"_lastSearchFavoritesOnly"));
            await (Task)Access.Call(page,"LoadSearchAsync",query,scope,favorites)!;
        }
        catch(OperationCanceledException){}
        catch(Exception error){try{PlaybackTransport.Write("Warning","Search.Input","输入搜索未完成；"+error.GetType().Name);}catch(Exception){}}
        finally{if(ReferenceEquals(pending.Source,source)){pending.Source=null;source.Dispose();}}
    }
    static bool Visible(DependencyObject input)
    {
        for(DependencyObject? node=input;node!=null;node=VisualTreeHelper.GetParent(node))if(node is UIElement {Visibility:Visibility.Collapsed})return false;
        return true;
    }
    sealed class Origin
    {
        readonly object? session,client,navigation;readonly string? library,key,libraryName;
        readonly object[] cards;readonly string title,section;readonly double offset;
        readonly Dictionary<string,Visibility> views=new();
        public Origin(object page)
        {
            session=Access.Get<object?>(page,"_session");client=Access.Get<object?>(page,"_client");navigation=Access.Get<object?>(page,"_activeNavigation");
            library=Access.Get<string?>(page,"_activeLibraryId");key=Access.Get<string?>(page,"_activeSnapshotKey");libraryName=Access.Get<string?>(page,"_activeLibraryName");
            cards=((IList)Access.Call(page,"get_LatestItems")!).Cast<object>().ToArray();
            title=Access.Get<TextBlock>(page,"PageTitleText").Text;section=Access.Get<TextBlock>(page,"ContentSectionTitle").Text;
            offset=(Access.Call(page,"GetActiveVerticalScrollViewer") as ScrollViewer)?.VerticalOffset??0;
            foreach(string name in new[]{"ResumeSection","HomeLibrarySectionsControl","HomeEmptyState","BrowseResultsSection","EmptyState"})views[name]=Access.Get<FrameworkElement>(page,name).Visibility;
        }
        public void Restore(object page)
        {
            if(!ReferenceEquals(session,Access.Get<object?>(page,"_session"))||!ReferenceEquals(client,Access.Get<object?>(page,"_client")))return;
            Access.Set(page,"_activeSnapshotKey",key);Access.Set(page,"_activeLibraryName",libraryName);Access.Set(page,"_renderedBrowseScope",null);
            Access.Call(page,"SetActiveNavigation",navigation,library);Access.Call(page,"ResetPosterLoads");
            var target=(IList)Access.Call(page,"get_LatestItems")!;target.Clear();foreach(var card in cards)target.Add(card);
            Access.Get<TextBlock>(page,"PageTitleText").Text=title;Access.Get<TextBlock>(page,"ContentSectionTitle").Text=section;
            foreach(var view in views)Access.Get<FrameworkElement>(page,view.Key).Visibility=view.Value;
            var element=(FrameworkElement)page;var source=Access.Get<CancellationTokenSource?>(page,"_searchCancellation");
            element.DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low,()=>{
                if(!ReferenceEquals(session,Access.Get<object?>(page,"_session"))||!ReferenceEquals(source,Access.Get<CancellationTokenSource?>(page,"_searchCancellation"))||!string.IsNullOrWhiteSpace(Access.Get<string?>(page,"_lastSearchTerm")))return;
                if(Access.Call(page,"GetActiveVerticalScrollViewer") is ScrollViewer scroll)scroll.ChangeView(null,Math.Clamp(offset,0,scroll.ScrollableHeight),null,true);
            });
        }
    }
}
