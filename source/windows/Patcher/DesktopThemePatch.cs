using Mono.Cecil;
using Mono.Cecil.Cil;

static class DesktopThemePatch
{
    static IEnumerable<TypeDefinition> Types(IEnumerable<TypeDefinition> types)
    { foreach (var type in types) { yield return type; foreach (var nested in Types(type.NestedTypes)) yield return nested; } }
    public static void Apply(AssemblyDefinition app, AssemblyDefinition core, AssemblyDefinition helper, Action<MethodDefinition> mark)
    {
        TypeDefinition Type(AssemblyDefinition assembly, string name) => Types(assembly.MainModule.Types).Single(t => t.FullName == name);
        var page = Type(app, "EmbyDesktop.MainPage");
        var hooks = Type(helper, "Yingyu.Update.DesktopTheme");
        MethodReference Hook(MethodDefinition target, string name) => target.Module.ImportReference(hooks.Methods.Single(m => m.Name == name && m.IsPublic && m.IsStatic));
        void After(MethodDefinition target, string name, bool argument = false)
        {
            mark(target); var hook = Hook(target, name); var il = target.Body.GetILProcessor();
            foreach (var ret in target.Body.Instructions.Where(i => i.OpCode == OpCodes.Ret).ToArray())
            {
                // Convert the original ret to the first injected instruction so
                // branches to it also execute the hook exactly once.
                ret.OpCode = OpCodes.Ldarg_0; ret.Operand = null;
                var cursor = ret;
                if (argument) { var load = Instruction.Create(OpCodes.Ldarg_1); il.InsertAfter(cursor, load); cursor = load; }
                var call = Instruction.Create(OpCodes.Call, hook); il.InsertAfter(cursor, call); il.InsertAfter(call, Instruction.Create(OpCodes.Ret));
            }
        }
        After(page.Methods.Single(m => m.IsConstructor && !m.IsStatic && m.Parameters.Count == 2), "Configure");
        foreach (string name in new[] { "MediaCard_Loaded", "MediaCard_DataContextChanged", "PosterCardRoot_Loaded" })
            After(page.Methods.Single(m => m.Name == name), "Card", true);
        After(page.Methods.Single(m => m.Name == "UpdateDetailExperienceLayout"), "Detail");
        After(page.Methods.Single(m => m.Name == "SetActiveNavigation"), "Navigation");
        var theme = Type(app, "EmbyDesktop.MainWindow").Methods.Single(m => m.Name == "ApplyTheme");
        mark(theme);
        var processor = theme.Body.GetILProcessor(); var start = theme.Body.Instructions[0];
        processor.InsertBefore(start, Instruction.Create(OpCodes.Ldarg_1));
        processor.InsertBefore(start, Instruction.Create(OpCodes.Call, Hook(theme, "WindowTheme")));
        processor.InsertBefore(start, Instruction.Create(OpCodes.Starg, theme.Parameters[0]));
        var metrics = Type(core, "EmbyDesktop.Core.Services.LibraryBrowseLayoutPolicy").Methods.Single(m => m.Name == "ResolvePosterGridMetrics");
        mark(metrics); metrics.Body.Instructions.Clear(); metrics.Body.ExceptionHandlers.Clear(); metrics.Body.Variables.Clear();
        metrics.Body.Instructions.Add(Instruction.Create(OpCodes.Ldarg_0)); metrics.Body.Instructions.Add(Instruction.Create(OpCodes.Ldarg_1));
        metrics.Body.Instructions.Add(Instruction.Create(OpCodes.Call, Hook(metrics, "Metrics"))); metrics.Body.Instructions.Add(Instruction.Create(OpCodes.Ret));
        // Combine preferences at the desktop animation consumers. Do not alter
        // the persisted ExperiencePreferences getter or any player/color logic.
        foreach (var consumer in Types(new[] { page }).SelectMany(t => t.Methods).Where(m => m.HasBody && m.Name != "InitializeExperienceControls"))
        {
            foreach (var call in consumer.Body.Instructions.Where(i => i.Operand is MethodReference method
                && method.DeclaringType.FullName == "EmbyDesktop.Core.Services.ExperiencePreferences" && method.Name == "get_ReducedMotion").ToArray())
            {
                mark(consumer); consumer.Body.GetILProcessor().InsertAfter(call, Instruction.Create(OpCodes.Call, Hook(consumer, "ReduceMotion")));
            }
        }
    }
}
