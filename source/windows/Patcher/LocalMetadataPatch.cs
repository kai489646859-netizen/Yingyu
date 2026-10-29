using Mono.Cecil;
using Mono.Cecil.Cil;

static class LocalMetadataPatch
{
    static IEnumerable<TypeDefinition> Types(IEnumerable<TypeDefinition> types)
    {foreach(var t in types){yield return t;foreach(var n in Types(t.NestedTypes))yield return n;}}
    public static void Apply(AssemblyDefinition app,AssemblyDefinition core,AssemblyDefinition helper,Action<MethodDefinition> mark)
    {
        var local=Types(helper.MainModule.Types).Single(t=>t.FullName=="Yingyu.Update.LocalMetadata");
        MethodReference Import(ModuleDefinition module,string name)=>module.ImportReference(local.Methods.Single(m=>m.Name==name&&m.IsPublic));
        var client=Types(core.MainModule.Types).Single(t=>t.FullName=="EmbyDesktop.Core.Services.EmbyApiClient");
        var items=client.Methods.Single(m=>m.Name=="GetItemsAsync");
        var fields=items.Body.Instructions.Single(i=>i.OpCode==OpCodes.Ldstr&&((string)i.Operand).StartsWith("Fields=ProviderIds,Overview,PrimaryImageAspectRatio,DateCreated,",StringComparison.Ordinal));
        var il=items.Body.GetILProcessor();var at=fields;
        foreach(var instruction in new[]{Instruction.Create(OpCodes.Ldarg_1),Instruction.Create(OpCodes.Ldarg_2),Instruction.Create(OpCodes.Ldarg,items.Parameters[3]),Instruction.Create(OpCodes.Ldarg,items.Parameters[6]),Instruction.Create(OpCodes.Call,Import(core.MainModule,"CatalogueFields"))}){il.InsertAfter(at,instruction);at=instruction;}mark(items);
        var send=client.NestedTypes.Single(t=>t.Name.StartsWith("<SendAsync>",StringComparison.Ordinal));
        var move=send.Methods.Single(m=>m.Name=="MoveNext");
        var read=move.Body.Instructions.Single(i=>i.Operand is GenericInstanceMethod method&&method.Name=="ReadFromJsonAsync");
        var old=(GenericInstanceMethod)read.Operand;var replacement=new GenericInstanceMethod(Import(core.MainModule,"ReadJsonAsync"));
        foreach(var argument in old.GenericArguments)replacement.GenericArguments.Add(argument);
        il=move.Body.GetILProcessor();
        FieldReference Bound(string name)=>(FieldReference)move.Body.Instructions.First(i=>i.Operand is FieldReference f&&f.Name==name).Operand;
        foreach(var instruction in new[]{Instruction.Create(OpCodes.Ldarg_0),Instruction.Create(OpCodes.Ldfld,Bound("<>4__this")),Instruction.Create(OpCodes.Ldarg_0),Instruction.Create(OpCodes.Ldfld,Bound("request"))})il.InsertBefore(read,instruction);
        read.OpCode=OpCodes.Call;read.Operand=replacement;mark(move);
        foreach(var pair in new[]{("<LoadSeriesAsync>","GetSeasonsAsync","Seasons"),("<LoadSeasonEpisodesAsync>","GetEpisodesAsync","Episodes"),("<ResolveDetailTargetAsync>","GetItemAsync","DisplayItem")}){
            var type=Types(app.MainModule.Types).Single(t=>t.Name.StartsWith(pair.Item1,StringComparison.Ordinal));
            var method=type.Methods.Single(m=>m.Name=="MoveNext");
            var call=method.Body.Instructions.Single(i=>i.Operand is MethodReference reference&&reference.DeclaringType.FullName==client.FullName&&reference.Name==pair.Item2);
            call.OpCode=OpCodes.Call;call.Operand=Import(app.MainModule,pair.Item3);mark(method);
        }
        var page=Types(app.MainModule.Types).Single(t=>t.FullName=="EmbyDesktop.MainPage");
        foreach(string name in new[]{"GlobalRefreshButton_Click","RefreshLibraryButton_Click","RefreshCacheButton_Click"}){
            var method=page.Methods.Single(m=>m.Name==name);il=method.Body.GetILProcessor();var first=method.Body.Instructions[0];
            il.InsertBefore(first,Instruction.Create(OpCodes.Ldarg_0));il.InsertBefore(first,Instruction.Create(OpCodes.Call,Import(app.MainModule,"Refresh")));mark(method);
        }
    }
}
