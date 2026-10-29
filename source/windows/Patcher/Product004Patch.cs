using Mono.Cecil;
using Mono.Cecil.Cil;

static class Product004Patch
{
    static IEnumerable<TypeDefinition> All(IEnumerable<TypeDefinition> types){foreach(var t in types){yield return t;foreach(var n in All(t.NestedTypes))yield return n;}}
    public static void Apply(AssemblyDefinition app,AssemblyDefinition core,AssemblyDefinition helper,Action<MethodDefinition> mark)
    {
        var page=app.MainModule.GetType("EmbyDesktop.MainPage");
        MethodDefinition Method(string name)=>page.Methods.Single(m=>m.Name==name);
        MethodReference Hook(ModuleDefinition module,string type,string name)=>module.ImportReference(helper.MainModule.GetType("Yingyu.Update."+type).Methods.Single(m=>m.Name==name&&m.IsPublic&&m.IsStatic));
        void After(string name,string type,string hook)
        {
            var method=Method(name);mark(method);var il=method.Body.GetILProcessor();
            foreach(var ret in method.Body.Instructions.Where(i=>i.OpCode==OpCodes.Ret).ToArray())
            {
                // Prefix at the original return, preserving branch destinations
                // and exclusive exception ends just as the existing UI hooks do.
                ret.OpCode=OpCodes.Ldarg_0;ret.Operand=null;var call=Instruction.Create(OpCodes.Call,Hook(app.MainModule,type,hook));il.InsertAfter(ret,call);il.InsertAfter(call,Instruction.Create(OpCodes.Ret));
            }
        }
        var search=core.MainModule.GetType("EmbyDesktop.Core.Services.LocalSearchIndexStore").Methods.Single(m=>m.Name=="Search");mark(search);search.Body=new Mono.Cecil.Cil.MethodBody(search);
        foreach(var parameter in search.Parameters)search.Body.Instructions.Add(Instruction.Create(OpCodes.Ldarg,parameter));
        search.Body.Instructions.Add(Instruction.Create(OpCodes.Call,Hook(core.MainModule,"SearchMatching","Search")));search.Body.Instructions.Add(Instruction.Create(OpCodes.Ret));
        var history=Method("MergeLocalPlaybackHistoryAsync");mark(history);history.Body.Instructions.Clear();history.Body.ExceptionHandlers.Clear();history.Body.Variables.Clear();
        foreach(var i in new[]{Instruction.Create(OpCodes.Ldarg_0),Instruction.Create(OpCodes.Ldarg_1),Instruction.Create(OpCodes.Call,Hook(app.MainModule,"ResumeSync","History")),Instruction.Create(OpCodes.Ret)})history.Body.Instructions.Add(i);
        After("ShowHomeSnapshot","ResumeSync","Home");
        After("UpdateDesktopDetailButtons","DesktopPeople","Detail");
        After("AppendSearchPage","DesktopPeople","Search");
        var startSearch=Method("LoadSearchAsync");mark(startSearch);var sip=startSearch.Body.GetILProcessor();var firstSearch=startSearch.Body.Instructions[0];
        sip.InsertBefore(firstSearch,Instruction.Create(OpCodes.Ldarg_0));sip.InsertBefore(firstSearch,Instruction.Create(OpCodes.Call,Hook(app.MainModule,"DesktopSearch","Begin")));
        var input=Method("SearchBox_TextChanged");mark(input);input.Body.Instructions.Clear();input.Body.ExceptionHandlers.Clear();input.Body.Variables.Clear();
        foreach(var i in new[]{Instruction.Create(OpCodes.Ldarg_0),Instruction.Create(OpCodes.Ldarg_1),Instruction.Create(OpCodes.Ldarg_2),Instruction.Create(OpCodes.Call,Hook(app.MainModule,"DesktopSearch","TextChanged")),Instruction.Create(OpCodes.Ret)})input.Body.Instructions.Add(i);

        After("ReloadMissingPosters","DesktopPeople","Resume");
        After("SettingsButton_Click","DesktopSettings","Open");
        After("SettingsCategoryButton_Click","DesktopSettings","Category");
        After("ExperienceSettingsSearch_TextChanged","DesktopSettings","Filter");
        var resumeReaders=All(app.MainModule.Types).Where(t=>t.Name.StartsWith("<FetchHomeSnapshotAsync>")||t.Name.StartsWith("<RefreshResumeItemsAsync>"));
        int replacements=0;
        foreach(var reader in resumeReaders.SelectMany(t=>t.Methods).Where(m=>m.HasBody))
        foreach(var call in reader.Body.Instructions.Where(i=>i.Operand is MethodReference m&&m.DeclaringType.FullName=="EmbyDesktop.Core.Services.PendingResumePreservationPolicy"&&m.Name=="MergePendingItems"))
        {mark(reader);call.Operand=Hook(app.MainModule,"ResumeSync","ServerItems");replacements++;}
        if(replacements!=2)throw new InvalidOperationException("Expected exactly two home/server reconciliation consumers");

        var translation=core.MainModule.GetType("EmbyDesktop.Core.Services.OverviewTranslationService");
        var ctor=translation.Methods.Single(m=>m.IsConstructor&&!m.IsStatic);mark(ctor);var cip=ctor.Body.GetILProcessor();
        cip.InsertBefore(ctor.Body.Instructions[0],Instruction.Create(OpCodes.Starg,ctor.Parameters[2]));cip.InsertBefore(ctor.Body.Instructions[0],Instruction.Create(OpCodes.Ldnull));
        var translate=translation.Methods.Single(m=>m.Name=="TranslateAsync");mark(translate);var tip=translate.Body.GetILProcessor();var first=translate.Body.Instructions[0];
        tip.InsertBefore(first,Instruction.Create(OpCodes.Ldarg,translate.Parameters[3]));tip.InsertBefore(first,Instruction.Create(OpCodes.Call,Hook(core.MainModule,"OnlineTranslations","Mode")));tip.InsertBefore(first,Instruction.Create(OpCodes.Starg,translate.Parameters[3]));
        var cached=translation.Methods.Single(m=>m.Name=="ReadCachedAsync");mark(cached);cached.Body.Instructions.Clear();cached.Body.ExceptionHandlers.Clear();cached.Body.Variables.Clear();
        foreach(var i in new[]{Instruction.Create(OpCodes.Ldarg_0),Instruction.Create(OpCodes.Ldarg_1),Instruction.Create(OpCodes.Ldarg_2),Instruction.Create(OpCodes.Ldarg_3),Instruction.Create(OpCodes.Call,Hook(core.MainModule,"OnlineTranslations","ReadCached")),Instruction.Create(OpCodes.Ret)})cached.Body.Instructions.Add(i);
        foreach(var assembly in new[]{app,core})foreach(var method in All(assembly.MainModule.Types).SelectMany(t=>t.Methods).Where(m=>m.HasBody))
        foreach(var instruction in method.Body.Instructions.Where(i=>i.OpCode==OpCodes.Ldstr))
        {
            string value=(string)instruction.Operand;
            if(value=="换一个关键词或首字母试试"){mark(method);instruction.Operand="尝试片名、演员名或其中任意汉字";}
            if(value=="在线翻译暂不可用，且尚未安装离线包。请稍后重试或导入离线包。"||value=="翻译暂不可用，已保留原文。可稍后重试，或在设置中检查辅助代理、导入离线包。")
            {mark(method);instruction.Operand="在线翻译暂不可用，已保留原文。请稍后重试或检查辅助服务代理。";}
        }
    }
}
