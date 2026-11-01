using System.Collections.ObjectModel;
using System.Text.Json;
using EmbyDesktop.Core.Models;
using EmbyDesktop.Core.Services;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Yingyu.Update;
public static class ProfileOrder
{
    static string FilePath=>Path.Combine(CachePaths.UserDataRoot,"profile-order.json");
    public static async Task<IReadOnlyList<ServerProfile>> Load(ServerProfileStore store,CancellationToken token)
        =>Sort(await store.LoadAsync(token));
    public static IReadOnlyList<ServerProfile> Sort(IReadOnlyList<ServerProfile> profiles)
    {
        try{
            if(new FileInfo(FilePath) is not{Exists:true,Length:<=262144})return profiles;
            var ids=JsonSerializer.Deserialize<string[]>(File.ReadAllText(FilePath))??[];
            var rank=ids.Where(x=>!string.IsNullOrEmpty(x)).Distinct().Take(2000).Select((id,index)=>(id,index)).ToDictionary(x=>x.id,x=>x.index);
            return profiles.OrderBy(p=>rank.GetValueOrDefault(p.Id,int.MaxValue)).ToArray();
        }catch(Exception error) when(error is IOException or UnauthorizedAccessException or JsonException){return profiles;}
    }
    public static void Decorate(object page)
    {
        var profiles=(ObservableCollection<ServerProfile>)Access.Call(page,"get_ServerProfiles")!;
        var panel=Access.Get<StackPanel>(page,"ProfileQuickSwitchPanel");
        foreach(var button in panel.Children.OfType<Button>().ToArray()){
            if(button.Tag is not string id)continue;
            int index=profiles.ToList().FindIndex(p=>p.Id==id);if(index<0)continue;
            int rowIndex=panel.Children.IndexOf(button);panel.Children.RemoveAt(rowIndex);
            var row=new Grid{ColumnSpacing=4};row.ColumnDefinitions.Add(new(){Width=new(1,GridUnitType.Star)});row.ColumnDefinitions.Add(new(){Width=GridLength.Auto});row.ColumnDefinitions.Add(new(){Width=GridLength.Auto});
            button.HorizontalAlignment=HorizontalAlignment.Stretch;button.MinWidth=0;row.Children.Add(button);
            for(int direction=-1;direction<=1;direction+=2){
                int move=direction;var action=new Button{Content=move<0?"↑":"↓",Width=32,Height=32,Padding=new(0),MinWidth=0,VerticalAlignment=VerticalAlignment.Center,IsEnabled= index+move>=0&&index+move<profiles.Count,Name=move<0?"AccountMoveUp":"AccountMoveDown"};
                Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(action,(move<0?"上移 ":"下移 ")+profiles[index].DisplayName);
                Grid.SetColumn(action,move<0?1:2);row.Children.Add(action);
                action.Click+=(_,_)=>Move(page,id,move);action.Tapped+=(_,e)=>e.Handled=true;
            }
            panel.Children.Insert(rowIndex,row);
        }
    }
    public static bool Move(object page,string id,int direction)
    {
        var profiles=(ObservableCollection<ServerProfile>)Access.Call(page,"get_ServerProfiles")!;
        int index=profiles.ToList().FindIndex(p=>p.Id==id),target=index+direction;
        if(Math.Abs(direction)!=1||index<0||target<0||target>=profiles.Count)return false;
        var ids=profiles.Select(p=>p.Id).ToList();(ids[index],ids[target])=(ids[target],ids[index]);
        string temp=FilePath+"."+Guid.NewGuid().ToString("N")+".tmp";
        try{
            Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
            File.WriteAllText(temp,JsonSerializer.Serialize(ids));File.Move(temp,FilePath,true);
            profiles.Move(index,target);Access.Call(page,"RefreshAccountPanel");return true;
        }catch(Exception error) when(error is IOException or UnauthorizedAccessException){
            Access.Call(page,"ShowOperationFeedback","顺序保存失败，原顺序保持，请重试。",InfoBarSeverity.Error);return false;
        }finally{try{if(File.Exists(temp))File.Delete(temp);}catch(IOException){}}
    }
}
