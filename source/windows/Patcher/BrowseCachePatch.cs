using Mono.Cecil;
using Mono.Cecil.Cil;

static class BrowseCachePatch
{
    static IEnumerable<TypeDefinition> Types(IEnumerable<TypeDefinition> types)
    { foreach (var type in types) { yield return type; foreach (var child in Types(type.NestedTypes)) yield return child; } }
    public static void Apply(AssemblyDefinition app, AssemblyDefinition core, AssemblyDefinition helper, Action<MethodDefinition> mark)
    {
        var policy = Types(helper.MainModule.Types).Single(t => t.FullName == "Yingyu.Update.BrowseCachePolicy");
        MethodReference Helper(ModuleDefinition module, string name) => module.ImportReference(policy.Methods.Single(m => m.IsPublic && m.Name == name));
        var store = Types(core.MainModule.Types).Single(t => t.Name == "LocalSearchIndexStore");
        foreach (var name in new[] { "LoadAsync", "SaveAsync" })
        {
            var method = store.Methods.Single(m => m.Name == name);
            method.Body = new Mono.Cecil.Cil.MethodBody(method);
            var il = method.Body.GetILProcessor(); il.Emit(OpCodes.Ldarg_0);
            foreach (var parameter in method.Parameters) il.Emit(OpCodes.Ldarg, parameter);
            il.Emit(OpCodes.Call, Helper(core.MainModule, name)); il.Emit(OpCodes.Ret); mark(method);
        }
        var interval = Types(core.MainModule.Types).Single(t => t.Name == "ExperiencePreferences")
            .Methods.Single(m => m.Name == "get_CacheSyncMinutes");
        interval.Body = new Mono.Cecil.Cil.MethodBody(interval);
        interval.Body.Instructions.Add(Instruction.Create(OpCodes.Call, Helper(core.MainModule, "get_RefreshMinutes")));
        interval.Body.Instructions.Add(Instruction.Create(OpCodes.Ret)); mark(interval);
        var page = Types(app.MainModule.Types).Single(t => t.FullName == "EmbyDesktop.MainPage");
        var refresh = page.Methods.Single(m => m.Name == "SynchronizeCacheInBackgroundAsync");
        refresh.Body = new Mono.Cecil.Cil.MethodBody(refresh);
        var processor = refresh.Body.GetILProcessor(); processor.Emit(OpCodes.Ldarg_0);
        processor.Emit(OpCodes.Call, Helper(app.MainModule, "RefreshAsync")); processor.Emit(OpCodes.Ret); mark(refresh);
        var start = page.Methods.Single(m => m.Name == "StartCacheSynchronization");
        var original = start.Body.Instructions[0];
        processor = start.Body.GetILProcessor();
        processor.InsertBefore(original, Instruction.Create(OpCodes.Ldarg_0));
        processor.InsertBefore(original, Instruction.Create(OpCodes.Call, Helper(app.MainModule, "Configure")));
        var fromMinutes = start.Body.Instructions.Single(i => i.Operand is MethodReference m && m.Name == "FromMinutes");
        var duration = (MethodReference)fromMinutes.Operand;
        if (duration.Parameters.Single().ParameterType.MetadataType != MetadataType.Int64 || fromMinutes.Previous.Previous.OpCode != OpCodes.Ldc_I4_1)
            throw new InvalidOperationException("Unexpected original cache timer interval");
        fromMinutes.Previous.Previous.OpCode = OpCodes.Ldc_I4;
        fromMinutes.Previous.Previous.Operand = 30;
        fromMinutes.Operand = new MethodReference("FromSeconds", duration.ReturnType, duration.DeclaringType) { HasThis = false };
        ((MethodReference)fromMinutes.Operand).Parameters.Add(new ParameterDefinition(duration.Parameters[0].ParameterType));
        mark(start);
        // The old 1/5/15 selector is replaced by the unified Android cache UI.
        var changed = page.Methods.Single(m => m.Name == "CacheSyncIntervalCombo_SelectionChanged");
        changed.Body = new Mono.Cecil.Cil.MethodBody(changed); changed.Body.Instructions.Add(Instruction.Create(OpCodes.Ret)); mark(changed);
    }
}
