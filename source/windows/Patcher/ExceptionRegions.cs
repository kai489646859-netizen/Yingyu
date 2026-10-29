#nullable enable
using Mono.Cecil;
using Mono.Cecil.Cil;

// Metadata-only control-flow checks. Assemblies are never loaded or executed.
internal static class ExceptionRegions
{
    sealed record Region(string Kind, int Start, int End, ExceptionHandler Handler);

    internal static List<string> Check(MethodDefinition method)
    {
        var errors = new List<string>();
        if (!method.HasBody) return errors;
        var body = method.Body;
        var code = body.Instructions;
        int Index(Instruction? instruction) => instruction == null ? code.Count : code.IndexOf(instruction);
        var regions = new List<Region>();
        foreach (var handler in body.ExceptionHandlers)
        {
            regions.Add(new("try", Index(handler.TryStart), Index(handler.TryEnd), handler));
            regions.Add(new("handler", Index(handler.HandlerStart), Index(handler.HandlerEnd), handler));
            if (handler.FilterStart != null)
                regions.Add(new("filter", Index(handler.FilterStart), Index(handler.HandlerStart), handler));
        }
        foreach (var region in regions)
            if (region.Start < 0 || region.End <= region.Start)
                errors.Add($"{method.FullName}: invalid {region.Kind} extent");
        Region[] At(int index) => regions.Where(r => r.Start <= index && index < r.End).ToArray();
        void Error(Instruction instruction, string message) => errors.Add($"{method.FullName} IL_{instruction.Offset:x4}: {message}");
        foreach (var instruction in code)
        {
            var source = At(Index(instruction));
            if (instruction.OpCode == OpCodes.Ret && source.Length != 0)
                Error(instruction, "ret inside exception region");
            if (instruction.OpCode == OpCodes.Endfinally && !source.Any(r => r.Kind == "handler" &&
                (r.Handler.HandlerType == ExceptionHandlerType.Finally || r.Handler.HandlerType == ExceptionHandlerType.Fault)))
                Error(instruction, "endfinally outside finally/fault handler");
            if (instruction.OpCode.FlowControl != FlowControl.Branch && instruction.OpCode.FlowControl != FlowControl.Cond_Branch)
                continue;
            var targets = instruction.Operand is Instruction single ? new[] { single } : instruction.Operand as Instruction[] ?? [];
            bool leave = instruction.OpCode == OpCodes.Leave || instruction.OpCode == OpCodes.Leave_S;
            foreach (var target in targets)
            {
                var destination = At(Index(target));
                foreach (var entered in destination.Where(r => !source.Contains(r)))
                {
                    if (entered.Kind != "try") Error(instruction, $"branch enters {entered.Handler.HandlerType} {entered.Kind} at IL_{target.Offset:x4}");
                    else if (leave || Index(target) != entered.Start) Error(instruction, "branch enters protected block away from entry");
                }
                if (!leave && source.Any(r => !destination.Contains(r))) Error(instruction, "branch exits exception region without leave");
                // A nested try/catch inside a finally may leave back into the
                // same finally. It must not leave the enclosing handler itself.
                if (leave && source.Any(r => r.Kind == "filter" || (r.Kind == "handler" && !destination.Contains(r) &&
                    (r.Handler.HandlerType == ExceptionHandlerType.Finally || r.Handler.HandlerType == ExceptionHandlerType.Fault))))
                    Error(instruction, "leave exits finally/fault/filter");
            }
        }
        foreach (var region in regions.Where(r => r.Kind == "handler" || r.Kind == "filter"))
        {
            if (region.End <= region.Start) continue;
            var last = code[region.End - 1];
            if (last.OpCode.FlowControl is not (FlowControl.Return or FlowControl.Throw or FlowControl.Branch))
                Error(last, "exception handler falls through its exclusive end");
        }
        return errors.Distinct().ToList();
    }
}
