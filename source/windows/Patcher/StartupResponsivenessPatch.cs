using Mono.Cecil;
using Mono.Cecil.Cil;

static class StartupResponsivenessPatch
{
    static IEnumerable<TypeDefinition> Types(IEnumerable<TypeDefinition> roots)
    { foreach (var type in roots) { yield return type; foreach (var child in Types(type.NestedTypes)) yield return child; } }
    public static IReadOnlyList<string> Apply(AssemblyDefinition app, AssemblyDefinition core, AssemblyDefinition helper,
        Action<MethodDefinition> mark)
    {
        var changed = new List<string>();
        var page = app.MainModule.Types.Single(t => t.FullName == "EmbyDesktop.MainPage");
        var startup = helper.MainModule.Types.Single(t => t.FullName == "Yingyu.Update.StartupResponsiveness");
        MethodReference Hook(MethodDefinition method, string name) => method.Module.ImportReference(startup.Methods.Single(m => m.Name == name));
        void Changed(MethodDefinition method) { mark(method); if (!changed.Contains(method.FullName)) changed.Add(method.FullName); }
        void Stage(MethodDefinition method, Instruction before, string phase, FieldReference? owner = null)
        {
            var il = method.Body.GetILProcessor();
            il.InsertBefore(before, Instruction.Create(OpCodes.Ldarg_0));
            if (owner != null) il.InsertBefore(before, Instruction.Create(OpCodes.Ldfld, owner));
            il.InsertBefore(before, Instruction.Create(OpCodes.Ldstr, phase));
            il.InsertBefore(before, Instruction.Create(OpCodes.Call, Hook(method, "Mark")));
        }
        var loaded = page.Methods.Single(m => m.Name == "Page_Loaded"); Changed(loaded);
        var head = loaded.Body.Instructions[0]; var loadedIl = loaded.Body.GetILProcessor();
        loadedIl.InsertBefore(head, Instruction.Create(OpCodes.Ldarg_0));
        loadedIl.InsertBefore(head, Instruction.Create(OpCodes.Call, Hook(loaded, "Begin")));
        var state = page.NestedTypes.Single(t => t.Name.StartsWith("<Page_Loaded>d__"));
        var move = state.Methods.Single(m => m.Name == "MoveNext");
        var owner = state.Fields.Single(f => f.Name == "<>4__this");
        var limit = move.Body.Instructions.Single(i => i.Operand is MethodReference call
            && call.DeclaringType.FullName == "EmbyDesktop.Core.Services.PosterCacheService" && call.Name == "SetMaximumCacheBytesAsync");
        Changed(move); limit.OpCode = OpCodes.Call; limit.Operand = Hook(move, "SetStartupImageLimit");
        foreach (var call in move.Body.Instructions.Where(i => i.Operand is MethodReference).ToArray())
        {
            var target = (MethodReference)call.Operand;
            string? phase = target.Name switch
            {
                "RestoreAsync" when target.DeclaringType.Name == "AccountSessionStore" => "account-restore-start",
                "LoadLocalSearchIndexAsync" => "local-home-read-start",
                "GetPublicSystemInfoAsync" => "server-check-start",
                "SyncLibraryNavigationAsync" => "library-navigation-start",
                "LoadHomeAsync" => "home-request-start",
                _ => null
            };
            if (phase != null) Stage(move, call, phase, owner);
        }
        foreach (var name in new[] { "ShowShell", "ShowHomeSnapshot" })
        {
            var method = page.Methods.Single(m => m.Name == name); Changed(method);
            Stage(method, method.Body.Instructions[0], name == "ShowShell" ? "shell-visible" : "home-content");
        }
        // Use the existing combined playback/background ownership decision.
        var pause = helper.MainModule.Types.Single(t => t.FullName == "Yingyu.Update.AndroidCacheRuntime").Methods.Single(m => m.Name == "Pause");
        var isPaused = pause.DeclaringType.Methods.Single(m => m.Name == "get_IsPaused");
        var pauseMigration = helper.MainModule.Types.Single(t => t.FullName == "Yingyu.Update.CachePaths").Methods.Single(m => m.Name == "SetMigrationPaused");
        foreach (var ret in pause.Body.Instructions.Where(i => i.OpCode == OpCodes.Ret).ToArray())
        {
            var il = pause.Body.GetILProcessor();
            il.InsertBefore(ret, Instruction.Create(OpCodes.Call, isPaused));
            il.InsertBefore(ret, Instruction.Create(OpCodes.Call, pauseMigration));
        }
        Changed(pause);
        return changed;
    }
}
