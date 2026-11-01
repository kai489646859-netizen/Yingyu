using Mono.Cecil;
using Mono.Cecil.Cil;

static class ResponseSafetyPatch
{
    static IEnumerable<TypeDefinition> Types(IEnumerable<TypeDefinition> types)
    { foreach (var type in types) { yield return type; foreach (var child in Types(type.NestedTypes)) yield return child; } }
    internal static void Apply(AssemblyDefinition core, AssemblyDefinition native, AssemblyDefinition helper, Action<MethodDefinition> mark)
    {
        MethodReference Import(ModuleDefinition module, string type, string name) => module.ImportReference(helper.MainModule.GetType("Yingyu.Update." + type).Methods.Single(m => m.Name == name));
        var redactor = core.MainModule.GetType("EmbyDesktop.Core.Services.DiagnosticRedactor").Methods.Single(m => m.Name == "Redact");
        mark(redactor);
        var redactIl = redactor.Body.GetILProcessor(); var first = redactor.Body.Instructions[0];
        redactIl.InsertBefore(first, Instruction.Create(OpCodes.Ldarg_0));
        redactIl.InsertBefore(first, Instruction.Create(OpCodes.Call, Import(core.MainModule, "StructuredLogRedactor", "Redact")));
        redactIl.InsertBefore(first, Instruction.Create(OpCodes.Starg, redactor.Parameters[0]));
        var api = core.MainModule.GetType("EmbyDesktop.Core.Services.EmbyApiClient");
        var discovery = Types(core.MainModule.Types).Single(t => t.Name.StartsWith("<ProbePublicSystemInfoAsync>")).Methods.Single(m => m.Name == "MoveNext");
        var publicSend = discovery.Body.Instructions.Single(i => i.Operand is MethodReference m && m.DeclaringType.FullName == "System.Net.Http.HttpClient" && m.Name == "SendAsync" && m.Parameters.Count == 3);
        mark(discovery); publicSend.OpCode = OpCodes.Call; publicSend.Operand = Import(core.MainModule, "ApiResponseGuard", "SendPublicInfoAsync");
        var send = api.Methods.Single(m => m.Name == "SendApiRequestAsync");
        mark(send);
        send.Body.Instructions.Clear(); send.Body.Variables.Clear(); send.Body.ExceptionHandlers.Clear();
        var sendIl = send.Body.GetILProcessor();
        sendIl.Emit(OpCodes.Ldarg_0); sendIl.Emit(OpCodes.Ldfld, api.Fields.Single(f => f.Name == "_httpClient"));
        sendIl.Emit(OpCodes.Ldarg_1); sendIl.Emit(OpCodes.Ldarg_2); sendIl.Emit(OpCodes.Ldarg_3);
        sendIl.Emit(OpCodes.Call, Import(core.MainModule, "ApiResponseGuard", "SendAsync")); sendIl.Emit(OpCodes.Ret);
        var error = Types(core.MainModule.Types).Single(t => t.Name.StartsWith("<CreateApiExceptionAsync>")).Methods.Single(m => m.Name == "MoveNext");
        var read = error.Body.Instructions.Single(i => i.Operand is MethodReference m && m.DeclaringType.FullName == "System.Net.Http.HttpContent" && m.Name == "ReadAsStringAsync" && m.Parameters.Count == 1);
        mark(error); read.OpCode = OpCodes.Call; read.Operand = Import(core.MainModule, "ApiResponseGuard", "ReadErrorAsync");

        var type = native.MainModule.GetType("Richasy.MpvKernel.MpvNative");
        var command = type.Methods.Single(m => m.Name == "SetCommand" && m.Parameters[1].ParameterType.FullName == "System.String[]");
        var invoke = type.Methods.Single(m => m.Name == "SetCommand" && m.Parameters[1].ParameterType.FullName == "System.IntPtr");
        var target = Import(native.MainModule, "NativeCommands", "Send");
        var ctor = new MethodReference(".ctor", native.MainModule.TypeSystem.Void, target.Parameters[2].ParameterType) { HasThis = true };
        ctor.Parameters.Add(new(native.MainModule.TypeSystem.Object)); ctor.Parameters.Add(new(native.MainModule.TypeSystem.IntPtr));
        mark(command); command.Body.Instructions.Clear(); command.Body.Variables.Clear(); command.Body.ExceptionHandlers.Clear();
        var il = command.Body.GetILProcessor();
        il.Emit(OpCodes.Ldarg_0); il.Emit(OpCodes.Ldarg_1); il.Emit(OpCodes.Ldnull); il.Emit(OpCodes.Ldftn, invoke);
        il.Emit(OpCodes.Newobj, ctor); il.Emit(OpCodes.Call, target); il.Emit(OpCodes.Ret);
    }
}
