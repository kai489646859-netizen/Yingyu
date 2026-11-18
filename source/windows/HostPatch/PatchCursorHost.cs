using Mono.Cecil;
using Mono.Cecil.Cil;

internal static class PatchCursorHost
{
    internal static void Run(string root)
    {
        var staged = Path.Combine(root, "stamped");
        using var resolver = new DefaultAssemblyResolver();
        resolver.AddSearchDirectory(Path.Combine(root, "payload"));
        resolver.AddSearchDirectory(Path.GetDirectoryName(typeof(object).Assembly.Location)!);
        using var helper = AssemblyDefinition.ReadAssembly(Path.Combine(root, "helper-build", "Yingyu.Update.dll"));
        using var app = AssemblyDefinition.ReadAssembly(Path.Combine(staged, "Yingyu.dll"),
            new ReaderParameters { ReadSymbols = true, InMemory = true, AssemblyResolver = resolver });
        var module = app.MainModule;
        var cursor = helper.MainModule.GetType("Yingyu.Update.WindowedCursor");
        var session = module.GetType("EmbyDesktop.Services.MpvPlaybackSession");
        var handler = session.Methods.Single(m => m.Name == "OnControlsVisibilityChanged");
        if (handler.Parameters.Count != 2 || handler.Body.HasExceptionHandlers) throw new InvalidOperationException("Unexpected cursor handler");
        var first = handler.Body.Instructions[0];
        var il = handler.Body.GetILProcessor();
        il.InsertBefore(first, Instruction.Create(OpCodes.Ldarg_0));
        il.InsertBefore(first, Instruction.Create(OpCodes.Ldarg_2));
        il.InsertBefore(first, Instruction.Create(OpCodes.Call, module.ImportReference(cursor.Methods.Single(m => m.Name == "HandleVisibility"))));
        il.InsertBefore(first, Instruction.Create(OpCodes.Brfalse, first));
        il.InsertBefore(first, Instruction.Create(OpCodes.Ret));

        var shield = module.GetType("EmbyDesktop.Services.FullscreenCursorIdleShield");
        var dispose = shield.Methods.Single(m => m.Name == "Dispose");
        first = dispose.Body.Instructions[0];
        il = dispose.Body.GetILProcessor();
        il.InsertBefore(first, Instruction.Create(OpCodes.Ldarg_0));
        il.InsertBefore(first, Instruction.Create(OpCodes.Ldfld, shield.Fields.Single(f => f.Name == "_ownerWindowHandle")));
        il.InsertBefore(first, Instruction.Create(OpCodes.Call, module.ImportReference(cursor.Methods.Single(m => m.Name == "Unwatch"))));
        var show = shield.Methods.Single(m => m.Name == "Show");
        var getRect = show.Body.Instructions.Single(i => i.Operand is MethodReference m && m.Name == "GetClientRect");
        var old = (MethodReference)getRect.Operand;
        var rect = ((ByReferenceType)old.Parameters[1].ParameterType).ElementType.Resolve();
        var bounds = new MethodDefinition("GetPlaybackClientRect", MethodAttributes.Private | MethodAttributes.Static, module.TypeSystem.Boolean);
        bounds.Parameters.Add(new ParameterDefinition(old.Parameters[0].ParameterType));
        bounds.Parameters.Add(new ParameterDefinition(old.Parameters[1].ParameterType));
        shield.Methods.Add(bounds);
        il = bounds.Body.GetILProcessor();
        il.Emit(OpCodes.Ldarg_0);
        foreach (string field in new[] { "Left", "Top", "Right", "Bottom" })
        {
            il.Emit(OpCodes.Ldarg_1);
            il.Emit(OpCodes.Ldflda, rect.Fields.Single(f => f.Name == field));
        }
        il.Emit(OpCodes.Call, module.ImportReference(cursor.Methods.Single(m => m.Name == "TryGetBounds")));
        il.Emit(OpCodes.Ret);
        getRect.Operand = bounds;

        var output = Path.Combine(root, "host-final");
        Directory.CreateDirectory(output);
        app.Write(Path.Combine(output, "Yingyu.dll"), new WriterParameters { WriteSymbols = true });
    }
}
