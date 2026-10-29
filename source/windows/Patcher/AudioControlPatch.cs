using Mono.Cecil;
using Mono.Cecil.Cil;

internal static class AudioControlPatch
{
    internal static void Apply(AssemblyDefinition app, AssemblyDefinition helper)
    {
        var targets = new Dictionary<string, string> {
            ["SetVolumeAsync"] = "Volume", ["SetSpeedAsync"] = "Speed", ["SetAudioTrackAsync"] = "Track"
        };
        var changed = new List<string>();
        foreach (var type in Types(app.MainModule.Types))
        foreach (var method in type.Methods.Where(m => m.HasBody))
        foreach (var instruction in method.Body.Instructions)
        {
            if (instruction.Operand is not MethodReference call || call.DeclaringType.FullName != "Richasy.MpvKernel.Core.MpvClient"
                || !targets.TryGetValue(call.Name, out string? name)) continue;
            if (instruction.OpCode != OpCodes.Callvirt || !type.FullName.StartsWith("EmbyDesktop.Services.MpvPlaybackSession/<", StringComparison.Ordinal))
                throw new InvalidOperationException("Unexpected audio control call site: " + method.FullName);
            var replacement = helper.MainModule.Types.Single(t => t.FullName == "Yingyu.Update.AudioControl").Methods.Single(m => m.Name == name);
            if (replacement.ReturnType.FullName != call.ReturnType.FullName || replacement.Parameters.Count != call.Parameters.Count + 1
                || replacement.Parameters[0].ParameterType.FullName != call.DeclaringType.FullName
                || !replacement.Parameters.Skip(1).Select(p => p.ParameterType.FullName).SequenceEqual(call.Parameters.Select(p => p.ParameterType.FullName)))
                throw new InvalidOperationException("Audio control signature mismatch");
            instruction.OpCode = OpCodes.Call;
            instruction.Operand = app.MainModule.ImportReference(replacement);
            changed.Add(type.Name + ":" + name);
        }
        string[] expected = ["<SetVolumeAsync>d__99:Volume", "<SetSpeedAsync>d__101:Speed", "<SetAudioTrackAsync>d__104:Track",
            "<ApplyTrackPreferencesAsync>d__132:Track", "<ApplyTrackPreferencesAsync>d__132:Track"];
        if (!changed.Order().SequenceEqual(expected.Order())) throw new InvalidOperationException("Unexpected audio control patch scope");
    }
    static IEnumerable<TypeDefinition> Types(IEnumerable<TypeDefinition> types)
    {
        foreach (var type in types) { yield return type; foreach (var child in Types(type.NestedTypes)) yield return child; }
    }
}
