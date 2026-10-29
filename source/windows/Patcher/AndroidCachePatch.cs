using Mono.Cecil;
using Mono.Cecil.Cil;

static class AndroidCachePatch
{
    static IEnumerable<TypeDefinition> Types(IEnumerable<TypeDefinition> types)
    { foreach (var type in types) { yield return type; foreach (var nested in Types(type.NestedTypes)) yield return nested; } }
    public static void Apply(AssemblyDefinition app, AssemblyDefinition core, AssemblyDefinition helper, Action<MethodDefinition> mark)
    {
        TypeDefinition Type(AssemblyDefinition assembly, string name) => Types(assembly.MainModule.Types).Single(t => t.FullName == name);
        MethodDefinition Method(AssemblyDefinition assembly, string type, string name) => Type(assembly, type).Methods.Single(m => m.Name == name);
        MethodReference Hook(MethodDefinition target, string type, string name) => target.Module.ImportReference(
            Type(helper, "Yingyu.Update." + type).Methods.Single(m => m.Name == name && m.IsPublic && m.IsStatic));
        void Replace(MethodDefinition target, string type, string name, bool includeThis = true)
        {
            var hook = Hook(target, type, name);
            int argumentCount = target.Parameters.Count + (includeThis && !target.IsStatic ? 1 : 0);
            if (hook.Parameters.Count != argumentCount || target.ReturnType.FullName != hook.ReturnType.FullName)
                throw new InvalidOperationException("Cache hook signature mismatch: " + target.FullName + " -> " + hook.FullName);
            mark(target); target.Body.Instructions.Clear(); target.Body.ExceptionHandlers.Clear(); target.Body.Variables.Clear();
            if (includeThis && !target.IsStatic) target.Body.Instructions.Add(Instruction.Create(OpCodes.Ldarg_0));
            foreach (var argument in target.Parameters) target.Body.Instructions.Add(Instruction.Create(OpCodes.Ldarg, argument));
            target.Body.Instructions.Add(Instruction.Create(OpCodes.Call, hook)); target.Body.Instructions.Add(Instruction.Create(OpCodes.Ret));
        }
        const string cache = "EmbyDesktop.Core.Services.PosterCacheService", page = "EmbyDesktop.MainPage";
        Replace(Method(core, "EmbyDesktop.Core.Services.PosterRequestScheduler", "ExecuteAsync"), "AndroidCacheImages", "Execute");
        Replace(Method(core, "EmbyDesktop.Core.Services.PosterRequestScheduler", "GetRetryDelay"), "AndroidCacheImages", "Retry");
        Replace(Method(core, "EmbyDesktop.Core.Services.PosterCacheInventory", "TrimAsync"), "AndroidCacheImages", "Trim");
        Replace(Method(core, cache, "BuildCacheDirectory"), "AndroidCacheImages", "DirectoryFor");
        Replace(Method(core, cache, "TryResolveSharedPath"), "AndroidCacheImages", "ResolveShared");
        Replace(Method(core, cache, "TryResolveWorkPath"), "AndroidCacheImages", "ResolveWork");
        Replace(Method(core, cache, "TrimAsync"), "AndroidCacheImages", "TrimCache");
        Replace(Method(core, cache, "EnforceMaximumSizeAsync"), "AndroidCacheImages", "Enforce");
        Replace(Method(core, cache, "SetMaximumCacheBytesAsync"), "AndroidCacheImages", "SetLimit");
        Replace(Method(core, cache, "GetStatisticsAsync"), "AndroidCacheImages", "Statistics");
        Replace(Method(core, cache, "HasAnyUsableFile"), "AndroidCacheImages", "HasAny");
        Replace(Method(core, cache, "ValidateLocalCache"), "AndroidCacheImages", "Validate");
        Replace(Method(core, cache, "ValidateLocalCacheAsync"), "AndroidCacheImages", "ValidateAsync");
        Replace(Method(core, cache, "RemoveItemsAsync"), "AndroidCacheImages", "Remove");
        Replace(Method(core, cache, "ClearAsync"), "AndroidCacheImages", "ClearPosters");
        Replace(Method(core, cache, "DownloadAtomicallyAsync"), "AndroidCacheImages", "Download");
        Replace(Method(core, cache, "Touch"), "AndroidCacheImages", "Touch", false);
        Replace(Method(core, "EmbyDesktop.Core.Services.ArtworkRequestSizePolicy", "Resolve"), "AndroidCacheImages", "Sizes", false);
        // Remove the inherited extra one-second gate for large downloads. All
        // image categories now share the same Android pacing and two body slots.
        var download = Method(core, cache, "DownloadAtomicallyAsync");
        foreach (var method in Types(core.MainModule.Types).SelectMany(t => t.Methods).Where(m => m.HasBody))
            foreach (var instruction in method.Body.Instructions.Where(i => i.Operand is MethodReference call
                && call.DeclaringType.FullName == "Yingyu.Update.ArtworkFeedback" && call.Name == "Download").ToArray())
            { mark(method); instruction.OpCode = OpCodes.Callvirt; instruction.Operand = download; }
        Replace(Method(app, page, "LoadPosterBitmapAsync"), "AndroidCacheCards", "Bitmap");
        Replace(Method(app, page, "UpdateMediaCards"), "HomeCards", "Update");
        Replace(Method(app, page, "LoadCardPosterAsync"), "AndroidCacheCards", "Load");
        Replace(Method(app, page, "SetMediaCardViewport"), "AndroidCacheCards", "Viewport");
        Replace(Method(app, page, "MediaCard_EffectiveViewportChanged"), "AndroidCacheCards", "EffectiveViewport");
        var updateCard = Method(app, "EmbyDesktop.ViewModels.MediaCardViewModel", "UpdateItem");
        mark(updateCard);
        foreach (var ret in updateCard.Body.Instructions.Where(i => i.OpCode == OpCodes.Ret).ToArray())
        {
            var il = updateCard.Body.GetILProcessor();
            il.InsertBefore(ret, Instruction.Create(OpCodes.Ldarg_0));
            il.InsertBefore(ret, Instruction.Create(OpCodes.Call, Hook(updateCard, "AndroidCacheCards", "ArtworkChanged")));
        }
        foreach (string name in new[] { "InitializeArtworkCacheAsync", "RefreshArtworkInitializationStatusAsync", "LoadArtworkBrowsingStateAsync" })
        {
            var target = Method(app, page, name); mark(target);
            target.Body.Instructions.Clear(); target.Body.ExceptionHandlers.Clear(); target.Body.Variables.Clear();
            target.Body.Instructions.Add(Instruction.Create(OpCodes.Call, Hook(target, "AndroidCacheRuntime", "DisabledInitialization")));
            target.Body.Instructions.Add(Instruction.Create(OpCodes.Ret));
        }
        // The original service constructor has a readonly root; write it in
        // its constructor after the base call, before any consumer can observe it.
        var constructor = Type(core, cache).Methods.Single(m => m.IsConstructor && !m.IsStatic);
        mark(constructor);
        foreach (var ret in constructor.Body.Instructions.Where(i => i.OpCode == OpCodes.Ret).ToArray())
        {
            var il = constructor.Body.GetILProcessor();
            il.InsertBefore(ret, Instruction.Create(OpCodes.Ldarg_0));
            il.InsertBefore(ret, Instruction.Create(OpCodes.Call, Hook(constructor, "AndroidCacheImages", "Prepare")));
        }
        var imageUri = Method(core, "EmbyDesktop.Core.Services.EmbyApiClient", "BuildImageUri");
        var quality = imageUri.Body.Instructions.Single(i => i.OpCode == OpCodes.Ldstr && Equals(i.Operand, "&quality=90"));
        mark(imageUri); quality.Operand = "&quality=85";
        var decoded = Type(app, "EmbyDesktop.Services.DecodedPosterCache");
        var decode = decoded.NestedTypes.Single(t => t.Name.StartsWith("<DecodeAsync>d__")).Methods.Single(m => m.Name == "MoveNext");
        var limits = decode.Body.Instructions.Where(i => i.OpCode == OpCodes.Ldc_I4 && Equals(i.Operand, 128 * 1024 * 1024)).ToArray();
        if (limits.Length != 2) throw new InvalidOperationException("Unexpected inherited decoded image budget");
        mark(decode); foreach (var limit in limits) limit.Operand = 96 * 1024 * 1024;
        decoded.Fields.Single(f => f.Name == "MaximumBytes" && f.HasConstant).Constant = 96L * 1024 * 1024;
    }
}
