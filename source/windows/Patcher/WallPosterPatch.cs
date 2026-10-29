using Mono.Cecil;
using Mono.Cecil.Cil;

// Program calls WallPosterPatch.Apply(app, helper, Mark). Kept independent so
// the release owner controls all patch ordering and restoration checks.
static class WallPosterPatch
{
    static IEnumerable<TypeDefinition> Types(IEnumerable<TypeDefinition> list)
    {
        foreach (var type in list)
        {
            yield return type;
            foreach (var nested in Types(type.NestedTypes)) yield return nested;
        }
    }

    public static void Apply(AssemblyDefinition app, AssemblyDefinition helper, Action<MethodDefinition> mark)
    {
        var load = Types(app.MainModule.Types).Single(t => t.FullName == "EmbyDesktop.MainPage")
            .Methods.Single(m => m.Name == "LoadCardPosterAsync" && m.Parameters.Count == 2);
        if (load.Body.ExceptionHandlers.Count != 0 || load.ReturnType.FullName != "System.Threading.Tasks.Task")
            throw new InvalidOperationException("Unexpected wall poster async wrapper");
        var reuse = Types(helper.MainModule.Types).Single(t => t.FullName == "Yingyu.Update.WallPosterReuse")
            .Methods.Single(m => m.Name == "TryReuse" && m.Parameters.Count == 3 && m.IsPublic && m.IsStatic);
        mark(load);
        var original = load.Body.Instructions[0];
        var il = load.Body.GetILProcessor();
        var task = new TypeReference("System.Threading.Tasks", "Task", app.MainModule, load.ReturnType.Scope);
        var completedTask = new MethodReference("get_CompletedTask", app.MainModule.ImportReference(load.ReturnType), task) { HasThis = false };
        foreach (var instruction in new[] {
            Instruction.Create(OpCodes.Ldarg_0), Instruction.Create(OpCodes.Ldarg_1), Instruction.Create(OpCodes.Ldarg_2),
            Instruction.Create(OpCodes.Call, app.MainModule.ImportReference(reuse)), Instruction.Create(OpCodes.Brfalse, original),
            Instruction.Create(OpCodes.Call, completedTask), Instruction.Create(OpCodes.Ret) })
            il.InsertBefore(original, instruction);

        var cache = Types(app.MainModule.Types).Single(t => t.FullName == "EmbyDesktop.Services.DecodedPosterCache");
        var decode = cache.NestedTypes.Single(t => t.Name.StartsWith("<DecodeAsync>d__", StringComparison.Ordinal))
            .Methods.Single(m => m.Name == "MoveNext");
        var limits = decode.Body.Instructions.Where(i => i.OpCode == OpCodes.Ldc_I4 && i.Operand is int value && value == 64 * 1024 * 1024).ToArray();
        if (limits.Length != 2 || decode.Body.Instructions.Count(i => i.OpCode == OpCodes.Ldc_I4 && i.Operand is int value && value == 128) != 1)
            throw new InvalidOperationException("Unexpected decoded poster LRU limits");
        var policy = Types(helper.MainModule.Types).Single(t => t.FullName == "Yingyu.Update.WallPosterReusePolicy");
        var maximum = (long)policy.Fields.Single(f => f.Name == "MaximumDecodedBytes" && f.HasConstant).Constant;
        if (maximum != 128L * 1024 * 1024) throw new InvalidOperationException("Unexpected decoded poster budget");
        mark(decode);
        foreach (var instruction in limits) instruction.Operand = checked((int)maximum);
        var maximumField = cache.Fields.Single(f => f.Name == "MaximumBytes" && f.HasConstant);
        if (Convert.ToInt64(maximumField.Constant) != 64L * 1024 * 1024) throw new InvalidOperationException("Unexpected decoded poster constant");
        maximumField.Constant = maximum;
    }
}
