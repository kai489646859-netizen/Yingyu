using Mono.Cecil;
using Mono.Cecil.Cil;
using Mono.Cecil.Rocks;

// Reapply these helper-side transforms after rebuilding the runtime.
if (args.Length > 1 && args[1] == "cursor") { PatchCursorHost.Run(args[0]); return; }
if (args.Length > 1) { PatchPlayerHost.Run(args[0]); return; }
var root = args[0];
using var resolver = new DefaultAssemblyResolver();
resolver.AddSearchDirectory(Path.Combine(root, "payload"));
resolver.AddSearchDirectory(Path.GetDirectoryName(typeof(object).Assembly.Location)!);
using var assembly = AssemblyDefinition.ReadAssembly(Path.Combine(root, "helper-build", "Yingyu.Update.dll"),
    new ReaderParameters { ReadSymbols = true, AssemblyResolver = resolver });
var module = assembly.MainModule;

// Carry forward the two helper-side transformations from the 1.3.4 Patcher.
var runtime = module.GetType("Yingyu.Update.AndroidCacheRuntime");
var pause = runtime.Methods.Single(m => m.Name == "Pause");
var isPaused = runtime.Methods.Single(m => m.Name == "get_IsPaused");
var setMigrationPaused = module.GetType("Yingyu.Update.CachePaths").Methods.Single(m => m.Name == "SetMigrationPaused");
pause.Body.SimplifyMacros();
var il = pause.Body.GetILProcessor();
foreach (var ret in pause.Body.Instructions.Where(i => i.OpCode == OpCodes.Ret).ToArray())
{
    il.InsertBefore(ret, Instruction.Create(OpCodes.Call, isPaused));
    il.InsertBefore(ret, Instruction.Create(OpCodes.Call, setMigrationPaused));
}
pause.Body.OptimizeMacros();

var input = module.GetType("Yingyu.Update.DesktopInputBehavior");
var setToolTip = input.Methods.Single(m => m.Name == "SetToolTip");
foreach (var type in module.GetTypes().Where(t => t != input))
foreach (var method in type.Methods.Where(m => m.HasBody))
foreach (var ins in method.Body.Instructions)
{
    if (ins.Operand is MethodReference target
        && target.DeclaringType.FullName == "Microsoft.UI.Xaml.Controls.ToolTipService"
        && target.Name == "SetToolTip")
    {
        ins.OpCode = OpCodes.Call;
        ins.Operand = setToolTip;
    }
}

string output = Path.Combine(root, "helper-final");
Directory.CreateDirectory(output);
assembly.Write(Path.Combine(output, "Yingyu.Update.dll"), new WriterParameters { WriteSymbols = true });
