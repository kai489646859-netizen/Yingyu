using Mono.Cecil;
using Mono.Cecil.Cil;

// Integration: call MpvHttpHeadersPatch.Apply(kernelCore, helper, Mark) once
// after the existing PlayAsync/BlurayMpvOptions patch and before writing files.
// Only the two async MoveNext bodies are edited; their await states stay intact.
internal static class MpvHttpHeadersPatch
{
    internal static void Apply(AssemblyDefinition kernelCore, AssemblyDefinition helper, Action<MethodDefinition> mark)
    {
        var client = AllTypes(kernelCore.MainModule.Types).Single(t => t.FullName == "Richasy.MpvKernel.Core.MpvClient");
        var runtime = AllTypes(helper.MainModule.Types).Single(t => t.FullName == "Yingyu.Update.MpvHttpHeaders");
        var setAsync = kernelCore.MainModule.ImportReference(runtime.Methods.Single(m => m.Name == "SetAsync"));
        var handle = client.Fields.Single(f => f.Name == "_handle" && f.FieldType.FullName == "Richasy.MpvKernel.MpvInteropHandle");
        var throwFailed = client.Methods.Single(m => m.Name == "ThrowIfFailed" && m.Parameters.Count == 2);
        var setState = client.NestedTypes.Single(t => t.Name.StartsWith("<SetHttpHeadersAsync>d__", StringComparison.Ordinal));
        var playState = client.NestedTypes.Single(t => t.Name.StartsWith("<PlayAsync>d__", StringComparison.Ordinal));

        var setMethod = setState.Methods.Single(m => m.Name == "MoveNext");
        mark(setMethod);
        var setStore = setMethod.Body.Instructions.Single(i => IsField(i, OpCodes.Stfld, "headerStr"));
        var setStart = setMethod.Body.Instructions.Single(i => IsField(i, OpCodes.Stfld, "errorCode")).Next;
        var setAwait = After(setStore).First(i => IsMethod(i, "GetAwaiter"));
        ReplaceHeaderSpan(setMethod, setStart, setAwait, [
            Instruction.Create(OpCodes.Ldarg_0),
            Instruction.Create(OpCodes.Ldfld, setState.Fields.Single(f => f.Name == "<>4__this")),
            Instruction.Create(OpCodes.Ldfld, handle),
            Instruction.Create(OpCodes.Ldarg_0),
            Instruction.Create(OpCodes.Ldfld, setState.Fields.Single(f => f.Name == "headers")),
            Instruction.Create(OpCodes.Call, setAsync)
        ]);
        // Consume the Task result with the existing ThrowIfFailed call. The old
        // closure errorCode is no longer written by the removed delegate.
        var setResult = After(setAwait).First(i => IsMethod(i, "GetResult"));
        var oldSetResultTail = new[] { setResult.Next, setResult.Next.Next, setResult.Next.Next.Next, setResult.Next.Next.Next.Next };
        if (oldSetResultTail[0].OpCode != OpCodes.Pop || !IsLoadThis(oldSetResultTail[1]) ||
            !IsField(oldSetResultTail[2], OpCodes.Ldfld, "<>8__1") || !IsField(oldSetResultTail[3], OpCodes.Ldfld, "errorCode") ||
            oldSetResultTail[3].Next.OpCode != OpCodes.Ldstr || (string)oldSetResultTail[3].Next.Operand != "Mpv | set http-header-fields failed" ||
            !IsMethod(oldSetResultTail[3].Next.Next, "ThrowIfFailed")) throw new InvalidOperationException("Unexpected SetHttpHeadersAsync error tail");
        foreach (var instruction in oldSetResultTail) Nop(instruction);

        var playMethod = playState.Methods.Single(m => m.Name == "MoveNext");
        mark(playMethod);
        var playStore = playMethod.Body.Instructions.Single(i => IsField(i, OpCodes.Stfld, "headerStr"));
        var headerClosure = ((FieldReference)playStore.Operand).DeclaringType;
        var playStart = playMethod.Body.Instructions.Single(i => i.OpCode == OpCodes.Newobj && i.Operand is MethodReference m && m.DeclaringType.FullName == headerClosure.FullName);
        var playAwait = After(playStore).First(i => IsMethod(i, "GetAwaiter"));
        var headersGetter = playMethod.Body.Instructions.Select(i => i.Operand).OfType<MethodReference>().First(m => m.Name == "get_HttpHeaders");
        ReplaceHeaderSpan(playMethod, playStart, playAwait, [
            Instruction.Create(OpCodes.Ldarg_0),
            Instruction.Create(OpCodes.Ldfld, playState.Fields.Single(f => f.Name == "<>4__this")),
            Instruction.Create(OpCodes.Ldfld, handle),
            Instruction.Create(OpCodes.Ldarg_0),
            Instruction.Create(OpCodes.Ldfld, playState.Fields.Single(f => f.Name == "options")),
            Instruction.Create(OpCodes.Callvirt, headersGetter),
            Instruction.Create(OpCodes.Call, setAsync)
        ]);
        var playResult = After(playAwait).First(i => IsMethod(i, "GetResult"));
        var resultPop = playResult.Next;
        if (resultPop.OpCode != OpCodes.Pop) throw new InvalidOperationException("Unexpected PlayAsync header result");
        // Leave the original no-headers branch target at the following instruction;
        // it must skip both this message and the newly inserted failure check.
        resultPop.OpCode = OpCodes.Ldstr;
        resultPop.Operand = "Mpv | set http-header-fields failed";
        playMethod.Body.GetILProcessor().InsertAfter(resultPop, Instruction.Create(OpCodes.Call, throwFailed));
    }

    static void ReplaceHeaderSpan(MethodDefinition method, Instruction start, Instruction end, Instruction[] replacement)
    {
        var span = AfterInclusive(start).TakeWhile(i => i != end).ToArray();
        if (span.Length < replacement.Length || span.Count(i => IsMethod(i, "Join")) != 1 ||
            span.Count(i => IsMethod(i, "Run")) != 1 || span.Count(i => IsField(i, OpCodes.Stfld, "headerStr")) != 1)
            throw new InvalidOperationException("Unexpected HTTP header string/delegate region");
        var members = span.ToHashSet();
        foreach (var instruction in method.Body.Instructions.Where(i => !members.Contains(i)))
        {
            if (instruction.Operand is Instruction target && members.Contains(target) && target != start ||
                instruction.Operand is Instruction[] targets && targets.Any(t => members.Contains(t) && t != start))
                throw new InvalidOperationException("External entry into HTTP header region");
        }
        foreach (var handler in method.Body.ExceptionHandlers)
            foreach (var boundary in new[] { handler.TryStart, handler.TryEnd, handler.HandlerStart, handler.HandlerEnd, handler.FilterStart })
                if (boundary != null && members.Contains(boundary) && boundary != start)
                    throw new InvalidOperationException("Exception boundary inside HTTP header region");
        // Preserve every original branch and exception-boundary instruction identity.
        // Internal delegate-cache branches become harmless NOPs with the old region.
        foreach (var instruction in span) Nop(instruction);
        for (int index = 0; index < replacement.Length; index++)
        {
            span[index].OpCode = replacement[index].OpCode;
            span[index].Operand = replacement[index].Operand;
        }
    }

    static void Nop(Instruction instruction) { instruction.OpCode = OpCodes.Nop; instruction.Operand = null; }
    static bool IsLoadThis(Instruction instruction) => instruction.OpCode == OpCodes.Ldarg_0 || instruction.OpCode == OpCodes.Ldarg && instruction.Operand is ParameterDefinition parameter && parameter.Index == -1;
    static bool IsField(Instruction instruction, OpCode opcode, string name) => instruction.OpCode == opcode && instruction.Operand is FieldReference field && field.Name == name;
    static bool IsMethod(Instruction instruction, string name) => instruction.Operand is MethodReference method && method.Name == name;
    static IEnumerable<Instruction> After(Instruction instruction) => AfterInclusive(instruction.Next);
    static IEnumerable<Instruction> AfterInclusive(Instruction? instruction) { for (; instruction != null; instruction = instruction.Next) yield return instruction; }
    static IEnumerable<TypeDefinition> AllTypes(IEnumerable<TypeDefinition> types) { foreach (var type in types) { yield return type; foreach (var nested in AllTypes(type.NestedTypes)) yield return nested; } }
}
