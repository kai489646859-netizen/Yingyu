using Mono.Cecil;
using Mono.Cecil.Cil;

internal static class PatchPlayerHost
{
    internal static void Run(string root)
    {
        var payload = Path.Combine(root, "payload");
        var output = Path.Combine(root, "stamped");
        using var resolver = new DefaultAssemblyResolver();
        resolver.AddSearchDirectory(payload);
        resolver.AddSearchDirectory(Path.GetDirectoryName(typeof(object).Assembly.Location)!);
        using var helper = AssemblyDefinition.ReadAssembly(Path.Combine(root, "helper-final", "Yingyu.Update.dll"));
        using var app = AssemblyDefinition.ReadAssembly(Path.Combine(output, "Yingyu.dll"),
            new ReaderParameters { ReadSymbols = true, AssemblyResolver = resolver });
        var feedback = helper.MainModule.GetType("Yingyu.Update.PlayerFeedback");
        var overlay = app.MainModule.GetType("EmbyDesktop.Controls.PlayerOverlay");
        Guard("UpdatePosition", "CanUpdatePosition", true);
        Guard("UpdatePlayerState", "CanUpdatePlayerState", false);
        var patched = Path.Combine(root, "host-final");
        Directory.CreateDirectory(patched);
        app.Write(Path.Combine(patched, "Yingyu.dll"), new WriterParameters { WriteSymbols = true });

        void Guard(string name, string helperName, bool values)
        {
            var method = overlay.Methods.Single(item => item.Name == name && item.Parameters.Count == 2);
            if (method.ReturnType.MetadataType != MetadataType.Void || method.Body.HasExceptionHandlers)
                throw new InvalidOperationException("Unexpected player overlay method " + name);
            var validate = feedback.Methods.Single(item => item.Name == helperName);
            var il = method.Body.GetILProcessor();
            var first = method.Body.Instructions[0];
            il.InsertBefore(first, Instruction.Create(OpCodes.Ldarg_0));
            if (values)
            {
                il.InsertBefore(first, Instruction.Create(OpCodes.Ldarg_1));
                il.InsertBefore(first, Instruction.Create(OpCodes.Ldarg_2));
            }
            il.InsertBefore(first, Instruction.Create(OpCodes.Call, app.MainModule.ImportReference(validate)));
            il.InsertBefore(first, Instruction.Create(OpCodes.Brtrue, first));
            il.InsertBefore(first, Instruction.Create(OpCodes.Ret));
        }
    }
}
