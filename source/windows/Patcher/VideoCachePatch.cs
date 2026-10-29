using Mono.Cecil;
using Mono.Cecil.Cil;

internal static class VideoCachePatch
{
    internal static void Apply(AssemblyDefinition app, AssemblyDefinition core, AssemblyDefinition helper, Action<MethodDefinition> mark)
    {
        var runtime = All(helper.MainModule.Types).ToDictionary(t => t.FullName);
        MethodReference Hook(ModuleDefinition module, string type, string name) => module.ImportReference(runtime["Yingyu.Update." + type].Methods.Single(m => m.Name == name));
        var play = All(app.MainModule.Types).Single(t => t.FullName.StartsWith("EmbyDesktop.Services.MpvPlaybackSession/<PlayCurrentItemAsync>", StringComparison.Ordinal))
            .Methods.Single(m => m.Name == "MoveNext");
        var load = play.Body.Instructions.Single(i => i.Operand is MethodReference m && m.DeclaringType.FullName == "Richasy.MpvKernel.Core.MpvClient" && m.Name == "PlayAsync");
        var session = play.Body.Variables.Single(v => v.VariableType.FullName == "EmbyDesktop.Services.MpvPlaybackSession");
        mark(play);
        var argument = Instruction.Create(OpCodes.Ldloc, session);
        Prefix(play, load, argument);
        load.OpCode = OpCodes.Call; load.Operand = Hook(app.MainModule, "VideoCache", "PlayAsync");

        var dispose = All(app.MainModule.Types).Single(t => t.FullName == "EmbyDesktop.Services.MpvPlaybackSession").Methods.Single(m => m.Name == "DisposeCoreAsync");
        mark(dispose);
        Prefix(dispose, dispose.Body.Instructions[0], Instruction.Create(OpCodes.Ldarg_0), Instruction.Create(OpCodes.Call, Hook(app.MainModule, "VideoCache", "Stop")));

        // Existing account-aware ISO preparation already receives the client.
        // Only wrap that call to carry an AsyncLocal account identity into its
        // existing source constructor; every old open/probe operation remains.
        var isoCalls = All(app.MainModule.Types).SelectMany(t => t.Methods).Where(m => m.HasBody)
            .SelectMany(m => m.Body.Instructions.Where(i => i.Operand is MethodReference target && target.DeclaringType.FullName == "Yingyu.Update.MediaRequestIdentity" && target.Name == "PrepareIso").Select(i => (Method: m, Instruction: i))).ToArray();
        if (isoCalls.Length != 1) throw new InvalidOperationException("Expected one authenticated ISO preparation call");
        foreach (var call in isoCalls) { mark(call.Method); call.Instruction.OpCode = OpCodes.Call; call.Instruction.Operand = Hook(app.MainModule, "VideoCache", "PrepareIso"); }

        var source = All(core.MainModule.Types).Single(t => t.FullName == "EmbyDesktop.Core.Services.NetworkIsoSource");
        var constructor = source.Methods.Single(m => m.Name == ".ctor");
        mark(constructor);
        foreach (var ret in constructor.Body.Instructions.Where(i => i.OpCode == OpCodes.Ret).ToArray())
            Prefix(constructor, ret, Instruction.Create(OpCodes.Ldarg_0), Instruction.Create(OpCodes.Call, Hook(core.MainModule, "VideoCacheIso", "BindSource")));
        var original = source.Methods.Single(m => m.Name == "OpenRangeAsync");
        string oldName = original.FullName;
        var callers = All(core.MainModule.Types).SelectMany(t => t.Methods).Where(m => m.HasBody)
            .SelectMany(m => m.Body.Instructions.Where(i => i.Operand is MethodReference target && target.FullName == oldName).Select(i => (Method: m, Instruction: i))).ToArray();
        if (callers.Length == 0) throw new InvalidOperationException("Missing original ISO range callers");
        original.Name = "OpenRangeWithoutVideoCacheAsync";
        var wrapper = new MethodDefinition("OpenRangeAsync", original.Attributes, original.ReturnType);
        foreach (var parameter in original.Parameters) wrapper.Parameters.Add(new ParameterDefinition(parameter.Name, parameter.Attributes, parameter.ParameterType));
        source.Methods.Add(wrapper); mark(wrapper);
        var body = wrapper.Body.GetILProcessor();
        body.Append(Instruction.Create(OpCodes.Ldarg_0));
        foreach (var parameter in wrapper.Parameters) body.Append(Instruction.Create(OpCodes.Ldarg, parameter));
        body.Append(Instruction.Create(OpCodes.Call, Hook(core.MainModule, "VideoCacheIso", "OpenRange"))); body.Append(Instruction.Create(OpCodes.Ret));
        foreach (var call in callers) { mark(call.Method); call.Instruction.Operand = wrapper; }
    }
    static void Prefix(MethodDefinition method, Instruction target, params Instruction[] added)
    {
        var prior = method.Body.Instructions.ToArray(); var il = method.Body.GetILProcessor();
        foreach (var instruction in added) il.InsertBefore(target, instruction);
        foreach (var instruction in prior)
        {
            if (instruction.Operand == target) instruction.Operand = added[0];
            else if (instruction.Operand is Instruction[] targets)
                for (int i = 0; i < targets.Length; i++) if (targets[i] == target) targets[i] = added[0];
        }
        foreach (var handler in method.Body.ExceptionHandlers)
        {
            if (handler.TryStart == target) handler.TryStart = added[0];
            if (handler.HandlerStart == target) handler.HandlerStart = added[0];
            if (handler.FilterStart == target) handler.FilterStart = added[0];
            if (handler.TryEnd == target) handler.TryEnd = added[0];
            if (handler.HandlerEnd == target) handler.HandlerEnd = added[0];
        }
    }
    static IEnumerable<TypeDefinition> All(IEnumerable<TypeDefinition> types) { foreach (var type in types) { yield return type; foreach (var nested in All(type.NestedTypes)) yield return nested; } }
}
