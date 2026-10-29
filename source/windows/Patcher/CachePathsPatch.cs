using Mono.Cecil;
using Mono.Cecil.Cil;

internal static class CachePathsPatch
{
    // The caller includes every returned method in the existing scope audit.
    internal static IReadOnlyList<string> Apply(AssemblyDefinition app, AssemblyDefinition core, AssemblyDefinition helper)
    {
        var changed = new List<string>();
        var paths = helper.MainModule.Types.Single(t => t.FullName == "Yingyu.Update.CachePaths");
        MethodReference Import(ModuleDefinition module, string name) => module.ImportReference(paths.Methods.Single(m => m.Name == name));
        void RedirectArgument(string typeName, string methodName, int parameter, string redirect)
        {
            var method = core.MainModule.Types.Single(t => t.FullName == typeName).Methods
                .Single(m => m.Name == methodName && m.Parameters.Count > parameter);
            if (method.Parameters[parameter].ParameterType.FullName != "System.String") throw new InvalidOperationException("Cache path argument changed: " + method.FullName);
            var il = method.Body.GetILProcessor(); var first = method.Body.Instructions[0];
            il.InsertBefore(first, Instruction.Create(OpCodes.Ldarg, method.Parameters[parameter]));
            il.InsertBefore(first, Instruction.Create(OpCodes.Call, Import(core.MainModule, redirect)));
            il.InsertBefore(first, Instruction.Create(OpCodes.Starg, method.Parameters[parameter]));
            changed.Add(method.FullName);
        }
        RedirectArgument("EmbyDesktop.Core.Services.LocalSearchIndexStore", ".ctor", 0, "RedirectSearch");
        RedirectArgument("EmbyDesktop.Core.Services.ArtworkInitializationStore", ".ctor", 0, "RedirectInitialization");
        RedirectArgument("EmbyDesktop.Core.Services.OverviewTranslationService", ".ctor", 0, "RedirectTranslations");
        RedirectArgument("EmbyDesktop.Core.Services.OfflineOverviewTranslator", ".ctor", 0, "RedirectModels");
        RedirectArgument("EmbyDesktop.Core.Services.NetworkIsoMount", "StartAsync", 3, "RedirectNetworkIso");
        var session = app.MainModule.Types.Single(t => t.FullName == "EmbyDesktop.Services.MpvPlaybackSession");
        var constructor = session.Methods.Single(m => m.Name == ".ctor");
        var subtitle = constructor.Body.Instructions.Single(i => i.OpCode == OpCodes.Stfld
            && i.Operand is FieldReference field && field.Name == "_externalSubtitleDirectory");
        constructor.Body.GetILProcessor().InsertBefore(subtitle,
            Instruction.Create(OpCodes.Call, Import(app.MainModule, "RedirectSubtitles")));
        changed.Add(constructor.FullName);
        return changed;
    }
}
