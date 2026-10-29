using Mono.Cecil;
using Mono.Cecil.Cil;

internal static class SubtitleSelectionPatch
{
    internal static void Apply(AssemblyDefinition app, AssemblyDefinition helper)
    {
        var target = helper.MainModule.Types.Single(t => t.FullName == "Yingyu.Update.SubtitleSelection").Methods.Single(m => m.Name == "Select");
        var changed = new List<string>();
        foreach (var type in Types(app.MainModule.Types))
        foreach (var method in type.Methods.Where(m => m.HasBody))
        foreach (var instruction in method.Body.Instructions)
        {
            if (instruction.Operand is not MethodReference call || call.DeclaringType.FullName != "EmbyDesktop.Core.Services.SubtitlePreferencePolicy" || call.Name != "Select") continue;
            if (instruction.OpCode != OpCodes.Call || target.ReturnType.FullName != call.ReturnType.FullName
                || !target.Parameters.Select(p => p.ParameterType.FullName).SequenceEqual(call.Parameters.Select(p => p.ParameterType.FullName)))
                throw new InvalidOperationException("Subtitle selection signature mismatch");
            instruction.Operand = app.MainModule.ImportReference(target);
            changed.Add(type.Name);
        }
        string[] expected = ["<ApplyTrackPreferencesAsync>d__132", "<LoadExternalSubtitlesAsync>d__216"];
        if (!changed.Order().SequenceEqual(expected.Order())) throw new InvalidOperationException("Unexpected subtitle selection scope: " + string.Join(",", changed));
    }
    static IEnumerable<TypeDefinition> Types(IEnumerable<TypeDefinition> types)
    {
        foreach (var type in types) { yield return type; foreach (var nested in Types(type.NestedTypes)) yield return nested; }
    }
}
