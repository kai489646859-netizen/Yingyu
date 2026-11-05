using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Mono.Cecil;
using Mono.Cecil.Cil;
using Mono.Cecil.Rocks;

Console.OutputEncoding = Encoding.UTF8;
string root = Path.GetFullPath(args[0]);
string baseline = Path.Combine(root, "baseline", "0.2.5-redline", "installed");
string stage = Path.Combine(root, "updates", "1.2.2-desktop", "payload");
string runtime = Path.Combine(root, "updates", "1.2.2-desktop", "runtime-build", "Yingyu.Update.dll");
var expected = new Dictionary<string, string>
{
    ["Yingyu.dll"] = "e5b9984ac2f0d3f832b9498db1f091f2d434316a4be1985ffe76a0ddf155e313",
    ["Yingyu.Core.dll"] = "b280b3d7833bab52b1c20554f29a986b8cca3804dc1a144d446a0fc5f43b6dc2",
    ["Yingyu.exe"] = "b2bf342f16d14738ed93acd69e99d0ad19d21b539382531c40105cb1fda740ed"
};
foreach (var pair in expected)
    if (Convert.ToHexStringLower(SHA256.HashData(File.ReadAllBytes(Path.Combine(baseline, pair.Key)))) != pair.Value)
        throw new InvalidOperationException("Redline baseline fingerprint mismatch: " + pair.Key);
Directory.CreateDirectory(stage);
foreach (var file in Directory.EnumerateFiles(baseline, "*", SearchOption.AllDirectories))
{
    var relative = Path.GetRelativePath(baseline, file);
    if (Path.GetFileName(relative).StartsWith("unins", StringComparison.OrdinalIgnoreCase) || relative.EndsWith(".pdb", StringComparison.OrdinalIgnoreCase)) continue;
    var destination = Path.Combine(stage, relative);
    Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
    File.Copy(file, destination, true);
}
File.Copy(runtime, Path.Combine(stage, "Yingyu.Update.dll"), true);
// .NET 10.0.11 duplicates cached COM wrappers in its debugger-only registry.
// Keep normal diagnostics/log export and native playback; skip that optional registry.
// See dotnet/runtime#129191 and the shipped-CoreLib reproduction in release evidence.
string runtimeConfigPath = Path.Combine(stage, "Yingyu.runtimeconfig.json");
var runtimeConfig = System.Text.Json.Nodes.JsonNode.Parse(File.ReadAllText(runtimeConfigPath))!;
var runtimeOptions = runtimeConfig["runtimeOptions"]!.AsObject();
var runtimeProperties = runtimeOptions["configProperties"] as System.Text.Json.Nodes.JsonObject;
if (runtimeProperties == null) runtimeOptions["configProperties"] = runtimeProperties = new();
runtimeProperties["System.Diagnostics.Debugger.IsSupported"] = false;
File.WriteAllText(runtimeConfigPath, runtimeConfig.ToJsonString(new JsonSerializerOptions { WriteIndented = true }), new UTF8Encoding(false));
var resolver = new DefaultAssemblyResolver();
resolver.AddSearchDirectory(baseline);
resolver.AddSearchDirectory(Path.GetDirectoryName(runtime)!);
resolver.AddSearchDirectory(Path.GetDirectoryName(typeof(object).Assembly.Location)!);
var parameters = new ReaderParameters { AssemblyResolver = resolver, InMemory = true, ReadSymbols = true };
using var helper = AssemblyDefinition.ReadAssembly(runtime, parameters);
using var app = AssemblyDefinition.ReadAssembly(Path.Combine(baseline, "Yingyu.dll"), parameters);
using var core = AssemblyDefinition.ReadAssembly(Path.Combine(baseline, "Yingyu.Core.dll"), parameters);
using var windowUi = AssemblyDefinition.ReadAssembly(Path.Combine(baseline, "Richasy.MpvKernel.WinUI.dll"),
    new ReaderParameters { AssemblyResolver = resolver, InMemory = true, ReadSymbols = false });
using var kernelCore = AssemblyDefinition.ReadAssembly(Path.Combine(baseline, "Richasy.MpvKernel.Core.dll"),
    new ReaderParameters { AssemblyResolver = resolver, InMemory = true, ReadSymbols = false });
using var kernelNative = AssemblyDefinition.ReadAssembly(Path.Combine(baseline, "Richasy.MpvKernel.dll"),
    new ReaderParameters { AssemblyResolver = resolver, InMemory = true, ReadSymbols = false });
var touched = new HashSet<string>();
IEnumerable<TypeDefinition> Types(IEnumerable<TypeDefinition> list) { foreach (var t in list) { yield return t; foreach (var n in Types(t.NestedTypes)) yield return n; } }
MethodDefinition Method(AssemblyDefinition assembly, string type, string name) => Types(assembly.MainModule.Types).Single(t => t.FullName == type).Methods.Single(m => m.Name == name && (type != "EmbyDesktop.MainPage" || name != ".ctor" || m.Parameters.Count == 2));
MethodReference Helper(ModuleDefinition module, string type, string name) => module.ImportReference(Method(helper, "Yingyu.Update." + type, name));
void Mark(MethodDefinition method) { touched.Add(method.FullName); method.Body.SimplifyMacros(); }
// Alphabetical browsing is now an always-on product behavior. The original
// setter/storage shape remains compatible with existing preference files.
var alphabetDefault=Method(core,"EmbyDesktop.Core.Services.UserPreferences","get_AlphabeticalLibraryNavigation");
Mark(alphabetDefault);alphabetDefault.Body.Instructions.Clear();alphabetDefault.Body.ExceptionHandlers.Clear();alphabetDefault.Body.Variables.Clear();
alphabetDefault.Body.Instructions.Add(Instruction.Create(OpCodes.Ldc_I4_1));alphabetDefault.Body.Instructions.Add(Instruction.Create(OpCodes.Ret));
void Prefix(MethodDefinition method, Instruction at, params Instruction[] inserted)
{
    var original = method.Body.Instructions.ToArray();
    var il = method.Body.GetILProcessor();
    foreach (var ins in inserted) il.InsertBefore(at, ins);
    foreach (var ins in original)
    {
        if (ReferenceEquals(ins.Operand, at)) ins.Operand = inserted[0];
        else if (ins.Operand is Instruction[] targets)
            for (int i = 0; i < targets.Length; i++) if (ReferenceEquals(targets[i], at)) targets[i] = inserted[0];
    }
    foreach (var h in method.Body.ExceptionHandlers)
    {
        if (h.TryStart == at) h.TryStart = inserted[0];
        if (h.HandlerStart == at) h.HandlerStart = inserted[0];
        if (h.FilterStart == at) h.FilterStart = inserted[0];
    }
}
void BeforeReturns(MethodDefinition method, string type, string function, bool preserveExclusiveEnds = false)
{
    Mark(method);
    foreach (var ret in method.Body.Instructions.Where(i => i.OpCode == OpCodes.Ret).ToArray())
    {
        var first = Instruction.Create(OpCodes.Ldarg_0);
        Prefix(method, ret, first, Instruction.Create(OpCodes.Call, Helper(method.Module, type, function)));
        if (!preserveExclusiveEnds) continue;
        // End markers are exclusive. A return hook belongs to the same outer
        // region as the original ret, after the enumerator's finally handler.
        // Keeping HandlerEnd at ret would put the hook inside that handler and
        // redirect its original leave/branch targets into a finally block.
        foreach (var handler in method.Body.ExceptionHandlers)
        {
            if (handler.TryEnd == ret) handler.TryEnd = first;
            if (handler.HandlerEnd == ret) handler.HandlerEnd = first;
        }
    }
}
void GuardVoid(string name)
{
    var method = Method(app, "EmbyDesktop.MainPage", name);
    Mark(method);
    Prefix(method, method.Body.Instructions[0], Instruction.Create(OpCodes.Ldarg_0),
        Instruction.Create(OpCodes.Call, Helper(app.MainModule, "BackgroundArtwork", "IsRunning")),
        Instruction.Create(OpCodes.Brfalse, method.Body.Instructions[0]), Instruction.Create(OpCodes.Ret));
}
// The carousel owns RenderTransform. Preserve the host's opacity feedback but
// bypass its Scale/Translation reset, which WinUI rejects even after a slide
// animation clears RenderTransform. Ordinary buttons retain their original path.
var interactiveState=Method(app,"EmbyDesktop.MainPage","ApplyInteractiveButtonState");
Mark(interactiveState);
var interactiveStart=interactiveState.Body.Instructions[0];
Prefix(interactiveState,interactiveStart,
    Instruction.Create(OpCodes.Ldarg_1),
    Instruction.Create(OpCodes.Call,Helper(app.MainModule,"PosterMotion","OwnsButton")),
    Instruction.Create(OpCodes.Brfalse,interactiveStart),
    Instruction.Create(OpCodes.Ldarg_0),Instruction.Create(OpCodes.Ldarg_1),Instruction.Create(OpCodes.Ldarg_2),
    Instruction.Create(OpCodes.Call,Method(app,"EmbyDesktop.MainPage","UpdateButtonPressFeedback")),Instruction.Create(OpCodes.Ret));
// Retain the server's watch counter in user-data observations. Older caches omit
// it; nullable + write-null omission preserves their existing update payloads.
var userData=Types(core.MainModule.Types).Single(t=>t.FullName=="EmbyDesktop.Core.Models.EmbyUserData");
var optionalCount=new GenericInstanceType(((GenericInstanceType)userData.Fields.First(f=>f.FieldType is GenericInstanceType g&&g.ElementType.FullName=="System.Nullable`1").FieldType).ElementType);optionalCount.GenericArguments.Add(core.MainModule.TypeSystem.Int32);
var countField=new FieldDefinition("_yingyuPlayCount",Mono.Cecil.FieldAttributes.Private,optionalCount);userData.Fields.Add(countField);
var countGet=new MethodDefinition("get_PlayCount",Mono.Cecil.MethodAttributes.Public|Mono.Cecil.MethodAttributes.HideBySig|Mono.Cecil.MethodAttributes.SpecialName,optionalCount);
countGet.Body.Instructions.Add(Instruction.Create(OpCodes.Ldarg_0));countGet.Body.Instructions.Add(Instruction.Create(OpCodes.Ldfld,countField));countGet.Body.Instructions.Add(Instruction.Create(OpCodes.Ret));userData.Methods.Add(countGet);
var countSet=new MethodDefinition("set_PlayCount",Mono.Cecil.MethodAttributes.Public|Mono.Cecil.MethodAttributes.HideBySig|Mono.Cecil.MethodAttributes.SpecialName,core.MainModule.TypeSystem.Void);countSet.Parameters.Add(new("value",Mono.Cecil.ParameterAttributes.None,optionalCount));
countSet.Body.Instructions.Add(Instruction.Create(OpCodes.Ldarg_0));countSet.Body.Instructions.Add(Instruction.Create(OpCodes.Ldarg_1));countSet.Body.Instructions.Add(Instruction.Create(OpCodes.Stfld,countField));countSet.Body.Instructions.Add(Instruction.Create(OpCodes.Ret));userData.Methods.Add(countSet);
Mark(countGet);Mark(countSet);
var countProperty=new PropertyDefinition("PlayCount",Mono.Cecil.PropertyAttributes.None,optionalCount){GetMethod=countGet,SetMethod=countSet};userData.Properties.Add(countProperty);
var jsonScope=core.MainModule.AssemblyReferences.Single(r=>r.Name=="System.Text.Json");
var ignoreType=new TypeReference("System.Text.Json.Serialization","JsonIgnoreAttribute",core.MainModule,jsonScope);
var ignoreCtor=new MethodReference(".ctor",core.MainModule.TypeSystem.Void,ignoreType){HasThis=true};var ignore=new CustomAttribute(ignoreCtor);
ignore.Properties.Add(new("Condition",new CustomAttributeArgument(new TypeReference("System.Text.Json.Serialization","JsonIgnoreCondition",core.MainModule,jsonScope,true),(int)System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull)));countProperty.CustomAttributes.Add(ignore);
BeforeReturns(Method(app,"EmbyDesktop.MainPage","ConfigureBrowseOptions"),"BrowseSortNames","Configure",preserveExclusiveEnds:true);
var sortPreference=Method(app,"EmbyDesktop.MainPage","get_BrowsePreference");Mark(sortPreference);
foreach(var ret in sortPreference.Body.Instructions.Where(i=>i.OpCode==OpCodes.Ret).ToArray())Prefix(sortPreference,ret,Instruction.Create(OpCodes.Call,Helper(app.MainModule,"BrowseSortNames","Normalize")));
foreach(var name in new[]{"SavePendingPlaybackSyncAsync","DrainPendingPlaybackSyncAsync"}){
    var method=Method(app,"EmbyDesktop.MainPage",name);Mark(method);method.Body.Instructions.Clear();method.Body.Variables.Clear();method.Body.ExceptionHandlers.Clear();
    method.Body.Instructions.Add(Instruction.Create(OpCodes.Ldarg_0));if(name=="SavePendingPlaybackSyncAsync"){method.Body.Instructions.Add(Instruction.Create(OpCodes.Ldarg_1));method.Body.Instructions.Add(Instruction.Create(OpCodes.Ldarg_2));}
    method.Body.Instructions.Add(Instruction.Create(OpCodes.Call,Helper(app.MainModule,"ResumeDeviceSync",name=="SavePendingPlaybackSyncAsync"?"Save":"Drain")));method.Body.Instructions.Add(Instruction.Create(OpCodes.Ret));
}
// Verify the one real stop-report call; all original stop/gate/queue handlers stay.
var stopState=Types(app.MainModule.Types).Single(t=>t.Name.StartsWith("<ReportStoppedOnceAsync>",StringComparison.Ordinal)).Methods.Single(m=>m.Name=="MoveNext");
var stopCall=stopState.Body.Instructions.Single(i=>i.Operand is MethodReference m&&m.DeclaringType.FullName=="EmbyDesktop.Core.Services.EmbyApiClient"&&m.Name=="ReportPlaybackStoppedInBackgroundAsync");
Mark(stopState);Prefix(stopState,stopCall,Instruction.Create(OpCodes.Ldarg_0),Instruction.Create(OpCodes.Ldfld,stopState.DeclaringType.Fields.Single(f=>f.Name=="reason")));stopCall.OpCode=OpCodes.Call;stopCall.Operand=Helper(app.MainModule,"ResumeStopSync","Stop");
var activity=Method(app,"EmbyDesktop.MainPage","PlaybackSession_PlaybackActivityChanged");Mark(activity);
var activityBody=((MethodReference)activity.Body.Instructions.Single(i=>i.OpCode==OpCodes.Ldftn).Operand).Resolve();
Prefix(activity,activity.Body.Instructions[0],Instruction.Create(OpCodes.Ldarg_0),Instruction.Create(OpCodes.Ldarg_1),Instruction.Create(OpCodes.Ldarg_2),Instruction.Create(OpCodes.Call,Helper(app.MainModule,"ResumeDeviceSync","CaptureActivity")));
var activityOwner=activityBody.DeclaringType.Fields.Single(f=>f.FieldType.FullName=="EmbyDesktop.MainPage");var activityArgs=activityBody.DeclaringType.Fields.Single(f=>f.FieldType.FullName=="EmbyDesktop.Services.PlaybackActivityEventArgs");
Mark(activityBody);var activityStart=activityBody.Body.Instructions[0];
Prefix(activityBody,activityStart,Instruction.Create(OpCodes.Ldarg_0),Instruction.Create(OpCodes.Ldfld,activityOwner),Instruction.Create(OpCodes.Ldarg_0),Instruction.Create(OpCodes.Ldfld,activityArgs),Instruction.Create(OpCodes.Call,Helper(app.MainModule,"ResumeDeviceSync","CanApplyActivity")),Instruction.Create(OpCodes.Brtrue,activityStart),Instruction.Create(OpCodes.Ret));
// Persist alongside the original local save, before the original report gate
// and recovery-backoff return. Keep its existing awaiter and item snapshot.
var stopLocal=stopState.Body.Instructions.Single(i=>i.Operand is MethodReference m&&m.DeclaringType.FullName=="EmbyDesktop.Services.MpvPlaybackSession"&&m.Name=="SaveLocalPlaybackAsync");
var stopRequest=stopState.DeclaringType.Fields.Single(f=>f.Name.StartsWith("<request>",StringComparison.Ordinal));
Prefix(stopState,stopLocal,Instruction.Create(OpCodes.Ldarg_0),Instruction.Create(OpCodes.Ldfld,stopRequest));
stopLocal.OpCode=OpCodes.Call;stopLocal.Operand=Helper(app.MainModule,"DurablePlaybackSync","SaveLocalAndPending");
// Bind account ownership before any playback stop. Verified stops remove only
// their own durable record; delayed item-only cleanup cannot erase newer sessions.
BeforeReturns(Method(app,"EmbyDesktop.MainPage","ShowShell"),"DurablePlaybackSync","Bind",preserveExclusiveEnds:true);
var stopEntry=Method(app,"EmbyDesktop.Services.MpvPlaybackSession","ReportStoppedOnceAsync");Mark(stopEntry);
var startedStop=Instruction.Create(OpCodes.Pop);
Prefix(stopEntry,stopEntry.Body.Instructions[0],Instruction.Create(OpCodes.Ldarg_0),Instruction.Create(OpCodes.Call,Helper(app.MainModule,"DurablePlaybackSync","UnstartedStop")),Instruction.Create(OpCodes.Dup),Instruction.Create(OpCodes.Brfalse,startedStop),Instruction.Create(OpCodes.Ret),startedStop);
var removeOldStop=Method(app,"EmbyDesktop.MainPage","RemoveSupersededPendingPlaybackSyncAsync");Mark(removeOldStop);
removeOldStop.Body.Instructions.Clear();removeOldStop.Body.Variables.Clear();removeOldStop.Body.ExceptionHandlers.Clear();
removeOldStop.Body.Instructions.Add(Instruction.Create(OpCodes.Ldarg_0));removeOldStop.Body.Instructions.Add(Instruction.Create(OpCodes.Ldarg_1));
removeOldStop.Body.Instructions.Add(Instruction.Create(OpCodes.Call,Helper(app.MainModule,"DurablePlaybackSync","Refresh")));removeOldStop.Body.Instructions.Add(Instruction.Create(OpCodes.Ret));
// Feed detail badges from the existing source selection, without new requests.
var detailSource=Method(app,"EmbyDesktop.MainPage","SelectDesktopSource");Mark(detailSource);
foreach(var ret in detailSource.Body.Instructions.Where(i=>i.OpCode==OpCodes.Ret).ToArray())
    Prefix(detailSource,ret,Instruction.Create(OpCodes.Ldarg_0),Instruction.Create(OpCodes.Ldarg_2),Instruction.Create(OpCodes.Ldarg_1),Instruction.Create(OpCodes.Ldarg_3),Instruction.Create(OpCodes.Call,Helper(app.MainModule,"DetailResourceBadges","Capture")));
BeforeReturns(Method(app,"EmbyDesktop.MainPage","UpdateDesktopDetailButtons"),"DetailResourceBadges","Refresh",preserveExclusiveEnds:true);
BeforeReturns(Method(app,"EmbyDesktop.MainPage","ClearPreparedPlaybackCache"),"DetailResourceBadges","Refresh",preserveExclusiveEnds:true);
var versionsMove=Types(app.MainModule.Types).Single(t=>t.FullName.Contains("MainPage/<ShowVersionsAsync>")).Methods.Single(m=>m.Name=="MoveNext");
Mark(versionsMove);
foreach(var text in versionsMove.Body.Instructions.Where(i=>i.OpCode==OpCodes.Ldstr))
{
    if((string)text.Operand=="自动选择原始片源（不转码）")text.Operand="自动选择";
    if((string)text.Operand=="选择已有片源 · 不转码")text.Operand="选择资源版本";
}

foreach(var call in versionsMove.Body.Instructions.Where(i=>i.Operand is MethodReference m&&m.DeclaringType.Name=="ModalProtection"&&m.Name=="Show"))call.Operand=Helper(app.MainModule,"DetailResourceBadges","ShowVersions");
// Reuse the existing remembered source selection; enrich only its display label.
var sourceLabel=Types(app.MainModule.Types).SelectMany(t=>t.Methods).Single(m=>m.Name=="<ShowVersionsAsync>b__97_0");
Mark(sourceLabel);sourceLabel.Body.Instructions.Clear();sourceLabel.Body.Variables.Clear();sourceLabel.Body.ExceptionHandlers.Clear();
sourceLabel.Body.Instructions.Add(Instruction.Create(OpCodes.Ldarg_1));
sourceLabel.Body.Instructions.Add(Instruction.Create(OpCodes.Call,Helper(app.MainModule,"ResourceSourceInfo","VersionLabel")));
sourceLabel.Body.Instructions.Add(Instruction.Create(OpCodes.Ret));
// 1.2.2: episode-list items become local resume cards after playback. Request
// the same parent artwork metadata as GetResumeAsync in the existing request.
var episodeArtwork = Types(core.MainModule.Types).Single(t => t.Name.StartsWith("<GetEpisodesAsync>", StringComparison.Ordinal))
    .Methods.Single(m => m.Name == "MoveNext");
Mark(episodeArtwork);
var episodeFields = episodeArtwork.Body.Instructions.Single(i => i.OpCode == OpCodes.Ldstr &&
    (string)i.Operand == "&Fields=ProviderIds,Overview,PrimaryImageAspectRatio,Path,Container&EnableUserData=true&ImageTypeLimit=1");
episodeFields.Operand = "&Fields=ProviderIds,Overview,PrimaryImageAspectRatio,SeriesPrimaryImageTag,ParentThumbItemId,ParentThumbImageTag,ParentBackdropItemId,ParentBackdropImageTags,Path,Container&EnableUserData=true&EnableImageTypes=Primary,Thumb,Backdrop&ImageTypeLimit=1";
BeforeReturns(Method(app, "EmbyDesktop.MainPage", ".ctor"), "BackgroundArtwork", "Configure");
BeforeReturns(Method(app, "EmbyDesktop.MainPage", ".ctor"), "ArtworkStorage", "Configure");
BeforeReturns(Method(app, "EmbyDesktop.MainPage", "ShowLibrarySnapshot"), "BrowseArtwork", "SnapshotReady", preserveExclusiveEnds: true);
var posterClick=Method(app,"EmbyDesktop.MainPage","MediaGrid_ItemClick");Mark(posterClick);
var posterClickStart=posterClick.Body.Instructions[0];Prefix(posterClick,posterClickStart,Instruction.Create(OpCodes.Ldarg_0),Instruction.Create(OpCodes.Ldarg_1),Instruction.Create(OpCodes.Ldarg_2),Instruction.Create(OpCodes.Call,Helper(app.MainModule,"PosterTap","Defer")),Instruction.Create(OpCodes.Brfalse,posterClickStart),Instruction.Create(OpCodes.Ret));
// Fresh library entries start at zero. Explicit live layout anchors still
// override this default, preserving responsive layout and detail-return state.
var restorePosition=Method(app,"EmbyDesktop.MainPage","RestoreBrowseOffset");Mark(restorePosition);
var savedOffset=restorePosition.Body.Instructions.Single(i=>i.Operand is MethodReference m&&m.DeclaringType.FullName=="EmbyDesktop.Core.Services.LibraryBrowsePreference"&&m.Name=="get_Offset");
savedOffset.OpCode=OpCodes.Pop;savedOffset.Operand=null;restorePosition.Body.GetILProcessor().InsertAfter(savedOffset,Instruction.Create(OpCodes.Ldc_R8,0d));
var libraryEntry=Types(app.MainModule.Types).Single(t=>t.Name.StartsWith("<LibraryNavButton_Click>",StringComparison.Ordinal)).Methods.Single(m=>m.Name=="MoveNext");Mark(libraryEntry);
var clearEntrySearch=libraryEntry.Body.Instructions.Single(i=>i.Operand is MethodReference m&&m.DeclaringType.FullName=="EmbyDesktop.MainPage"&&m.Name=="ClearSearchContext");
var renderedScope=app.MainModule.GetType("EmbyDesktop.MainPage").Fields.Single(f=>f.Name=="_renderedBrowseScope");
Prefix(libraryEntry,clearEntrySearch,Instruction.Create(OpCodes.Dup),Instruction.Create(OpCodes.Ldc_I4_0),Instruction.Create(OpCodes.Call,Method(app,"EmbyDesktop.MainPage","CancelAlphabetScrollAnimation")),Instruction.Create(OpCodes.Dup),Instruction.Create(OpCodes.Ldnull),Instruction.Create(OpCodes.Stfld,renderedScope));
// Native scroll animation owns the transition; no per-frame UI ChangeView loop.
foreach(var (name,function) in new[]{("StartAlphabetScrollAnimation","Start"),("CancelAlphabetScrollAnimation","Cancel")})
{
    var method=Method(app,"EmbyDesktop.MainPage",name);Mark(method);
    method.Body.Instructions.Clear();method.Body.Variables.Clear();method.Body.ExceptionHandlers.Clear();
    var il=method.Body.GetILProcessor();il.Append(Instruction.Create(OpCodes.Ldarg_0));
    foreach(var parameter in method.Parameters)il.Append(Instruction.Create(OpCodes.Ldarg,parameter));
    il.Append(Instruction.Create(OpCodes.Call,Helper(app.MainModule,"DesktopScroll",function)));il.Append(Instruction.Create(OpCodes.Ret));
}
BeforeReturns(Method(app,"EmbyDesktop.MainPage","UpdateBackToTopButtonVisibility"),"DesktopScroll","StyleTop",preserveExclusiveEnds:true);
var alphabetClick=Method(app,"EmbyDesktop.MainPage","AlphabetNavigationButton_Click");Mark(alphabetClick);
alphabetClick.Body.Instructions.Clear();alphabetClick.Body.Variables.Clear();alphabetClick.Body.ExceptionHandlers.Clear();
alphabetClick.Body.Instructions.Add(Instruction.Create(OpCodes.Ldarg_0));alphabetClick.Body.Instructions.Add(Instruction.Create(OpCodes.Ldarg_1));
alphabetClick.Body.Instructions.Add(Instruction.Create(OpCodes.Call,Helper(app.MainModule,"DesktopNavigation","Jump")));alphabetClick.Body.Instructions.Add(Instruction.Create(OpCodes.Ret));
foreach(var name in new[]{"LatestGrid_LayoutUpdated","RefreshBrowsePosterViewport","<LatestGrid_LayoutUpdated>b__556_0"})
{
    var method=Method(app,"EmbyDesktop.MainPage",name);Mark(method);var first=method.Body.Instructions[0];
    Prefix(method,first,Instruction.Create(OpCodes.Ldarg_0),Instruction.Create(OpCodes.Call,Helper(app.MainModule,"DesktopScroll","IsAnimating")),Instruction.Create(OpCodes.Brfalse,first),Instruction.Create(OpCodes.Ret));
}
var topClick=Method(app,"EmbyDesktop.MainPage","BackToTopButton_Click");Mark(topClick);
topClick.Body.Instructions.Clear();topClick.Body.Variables.Clear();topClick.Body.ExceptionHandlers.Clear();
topClick.Body.Instructions.Add(Instruction.Create(OpCodes.Ldarg_0));topClick.Body.Instructions.Add(Instruction.Create(OpCodes.Call,Helper(app.MainModule,"DesktopScroll","Top")));topClick.Body.Instructions.Add(Instruction.Create(OpCodes.Ret));
foreach(string name in new[]{"MediaCard_Loaded","MediaCard_DataContextChanged"})
{
    var method=Method(app,"EmbyDesktop.MainPage",name);Mark(method);
    foreach(var ret in method.Body.Instructions.Where(i=>i.OpCode==OpCodes.Ret).ToArray())
        Prefix(method,ret,Instruction.Create(OpCodes.Ldarg_0),Instruction.Create(OpCodes.Ldarg_1),Instruction.Create(OpCodes.Call,Helper(app.MainModule,"AndroidCacheCards","Attach")));
}
// 1.2.2 background log lifecycle starts with the main page, before settings open.
BeforeReturns(Method(app, "EmbyDesktop.MainPage", ".ctor"), "LogCenterLauncher", "StartBackground", preserveExclusiveEnds: true);
// Cache recovery receives only containers measured by this viewport pass.
var browseViewport = Method(app, "EmbyDesktop.MainPage", "RefreshBrowsePosterViewport");
Mark(browseViewport);
var realizedCards = browseViewport.Body.Variables.Single(v => v.VariableType.FullName.StartsWith("System.Collections.Generic.HashSet`1<EmbyDesktop.ViewModels.MediaCardViewModel>"));
var viewportReturn = browseViewport.Body.Instructions.Last(i => i.OpCode == OpCodes.Ret);
var viewportHook = Instruction.Create(OpCodes.Ldarg_0);
Prefix(browseViewport, viewportReturn, viewportHook, Instruction.Create(OpCodes.Ldloc, realizedCards),
    Instruction.Create(OpCodes.Call, Helper(app.MainModule, "BrowseArtwork", "LoadVisible")));
foreach (var handler in browseViewport.Body.ExceptionHandlers)
{
    if (handler.TryEnd == viewportReturn) handler.TryEnd = viewportHook;
    if (handler.HandlerEnd == viewportReturn) handler.HandlerEnd = viewportHook;
}
// Ordinary card loaders share these flags and their original cancellation.
var cardViewport = Method(app, "EmbyDesktop.MainPage", "SetMediaCardViewport");
Mark(cardViewport);
Prefix(cardViewport, cardViewport.Body.Instructions[0], Instruction.Create(OpCodes.Ldarg, cardViewport.Parameters[1]),
    Instruction.Create(OpCodes.Starg, cardViewport.Parameters[2]));
foreach (var ret in cardViewport.Body.Instructions.Where(i => i.OpCode == OpCodes.Ret).ToArray())
    Prefix(cardViewport, ret, Instruction.Create(OpCodes.Ldarg, cardViewport.Parameters[0]),
        Instruction.Create(OpCodes.Ldarg, cardViewport.Parameters[1]),
        Instruction.Create(OpCodes.Call, Helper(app.MainModule, "BrowseArtwork", "CancelIfHidden")));
var inViewport = Method(app, "EmbyDesktop.ViewModels.MediaCardViewModel", "get_IsInViewport");
var firstPoster = Method(app, "EmbyDesktop.MainPage", "PrimeFirstLibraryPoster");
Mark(firstPoster);
var forceFirst = firstPoster.Body.Instructions.Single(i => i.Operand is MethodReference m && m.Name == "set_IsNearViewport").Previous;
if (forceFirst.OpCode != OpCodes.Ldc_I4 || (int)forceFirst.Operand != 1) throw new InvalidOperationException("Unexpected first-card bootstrap");
forceFirst.OpCode = OpCodes.Dup; forceFirst.Operand = null;
firstPoster.Body.GetILProcessor().InsertAfter(forceFirst, Instruction.Create(OpCodes.Callvirt, inViewport));
var detailActivity = Method(app, "EmbyDesktop.MainPage", "ApplyPlaybackActivityToDetailEpisodes");
BeforeReturns(Method(app, "EmbyDesktop.MainPage", "SettingsButton_Click"), "LogCenterLauncher", "Configure", preserveExclusiveEnds: true);
// Restore the original right pane before its existing category navigation.
foreach (var (name, function) in new[] { ("SettingsCategoryButton_Click", "Leave"), ("CloseSettingsButton_Click", "Close") })
{
    var entry = Method(app, "EmbyDesktop.MainPage", name);
    Mark(entry);
    Prefix(entry, entry.Body.Instructions[0], Instruction.Create(OpCodes.Ldarg_0),
        Instruction.Create(OpCodes.Call, Helper(app.MainModule, "LogCenterLauncher", function)));
}
// 1.2.2: retain the user-confirmed 1.2.2 original player window initialization.
var detailPlay = Method(app, "EmbyDesktop.MainPage", "DetailPlayButton_Click");
Mark(detailPlay);
Prefix(detailPlay, detailPlay.Body.Instructions[0], Instruction.Create(OpCodes.Ldarg_0),
    Instruction.Create(OpCodes.Call, Helper(app.MainModule, "LogCenterLauncher", "DetailPlay")));
Mark(detailActivity);
Prefix(detailActivity, detailActivity.Body.Instructions[0], Instruction.Create(OpCodes.Ldarg_0),
    Instruction.Create(OpCodes.Ldarg, detailActivity.Parameters[0]),
    Instruction.Create(OpCodes.Call, Helper(app.MainModule, "DetailProgress", "Apply")));
// Reuse loaded landscape artwork within the same series when episodes change,
// while the original card replacement keeps the new episode and its progress.
var resumeActivity = Method(app, "EmbyDesktop.MainPage", "ApplyPlaybackActivityToResumeItems");
Mark(resumeActivity);
var cachedResumeItems = resumeActivity.Body.Instructions.Single(i =>
    i.Operand is MethodReference m && m.DeclaringType.FullName == "EmbyDesktop.MainPage" && m.Name == "FindCachedItems");
Prefix(resumeActivity, cachedResumeItems.Next, Instruction.Create(OpCodes.Ldarg_1),
    Instruction.Create(OpCodes.Call, Helper(app.MainModule, "ResumeDeviceSync", "WithActivityItem")));
var previousResumeCard = resumeActivity.Body.Variables.Single(v => v.VariableType.Name == "MediaCardViewModel");
var reuseResumePoster = resumeActivity.Body.Instructions.Single(i => i.Operand is MethodReference m && m.DeclaringType.Name == "ArtworkReusePolicy" && m.Name == "CanReuse");
var currentResumeItem = (FieldReference)resumeActivity.Body.Instructions.Single(i => i.OpCode == OpCodes.Stfld &&
    i.Operand is FieldReference f && f.FieldType.FullName == "EmbyDesktop.Core.Models.EmbyItem").Operand;
var currentResumeOwner = resumeActivity.Body.Variables.Single(v => v.VariableType.FullName == currentResumeItem.DeclaringType.FullName);
Prefix(resumeActivity, reuseResumePoster, Instruction.Create(OpCodes.Ldloc, previousResumeCard),
    Instruction.Create(OpCodes.Ldloc, currentResumeOwner), Instruction.Create(OpCodes.Ldfld, currentResumeItem));
reuseResumePoster.Operand = Helper(app.MainModule, "ResumeArtwork", "CanReuse");
BeforeReturns(Method(app, "EmbyDesktop.Controls.PlayerOverlay", ".ctor"), "PlayerShortcuts", "Configure");
BeforeReturns(Method(app, "EmbyDesktop.Controls.PlayerOverlay", ".ctor"), "PlayerHover", "Configure");
BeforeReturns(Method(app, "EmbyDesktop.Controls.PlayerOverlay", ".ctor"), "PlayerSliderInput", "Configure");
foreach (var name in new[]{"PositionSlider_PointerPressed", "PositionSlider_PointerReleased"})
{
    var m=Method(app,"EmbyDesktop.Controls.PlayerOverlay",name); Mark(m);
    m.Body.Instructions.Clear(); m.Body.Variables.Clear(); m.Body.ExceptionHandlers.Clear();
    m.Body.Instructions.Add(Instruction.Create(OpCodes.Ret));
}
BeforeReturns(Method(app,"EmbyDesktop.Controls.PlayerOverlay","SetMedia"), "PlayerSliderInput", "Reset");
var positionUi=Method(app,"EmbyDesktop.Controls.PlayerOverlay","UpdatePosition"); Mark(positionUi);
var seekingField=positionUi.Body.Instructions.First(i=>i.Operand is FieldReference f && f.Name=="_isSeeking");
seekingField.OpCode=OpCodes.Ldarg_1; seekingField.Operand=null;
var positionIl=positionUi.Body.GetILProcessor();
var durationArg=Instruction.Create(OpCodes.Ldarg_2);positionIl.InsertAfter(seekingField,durationArg);
positionIl.InsertAfter(durationArg,Instruction.Create(OpCodes.Call,Helper(app.MainModule,"PlayerSliderInput","HoldPosition")));

BeforeReturns(Method(app, "EmbyDesktop.Controls.PlayerOverlay", ".ctor"), "PlayerFeedback", "Configure");
// State changes update button glyphs but preserve already-hidden chrome.
var playingUi=Method(app,"EmbyDesktop.Controls.PlayerOverlay","UpdatePlayingState");
Mark(playingUi);
foreach(var instruction in playingUi.Body.Instructions.Where(i=>i.Operand is MethodReference m && m.DeclaringType.FullName=="EmbyDesktop.Controls.PlayerOverlay" && m.Name is "ShowControlsTemporarily" or "SetControlsVisible"))
{
    var old=(MethodReference)instruction.Operand;
    instruction.OpCode=OpCodes.Call;
    instruction.Operand=Helper(app.MainModule,"PlaybackStateFeedback",old.Name=="SetControlsVisible"?"Paused":"Changed");
}
var pauseAccelerator=Method(app,"EmbyDesktop.Controls.PlayerOverlay","PlayPauseAccelerator_Invoked");
Mark(pauseAccelerator);
var showOnPause=pauseAccelerator.Body.Instructions.Single(i=>i.Operand is MethodReference m && m.Name=="ShowControlsTemporarily");
showOnPause.OpCode=OpCodes.Pop;showOnPause.Operand=null;
// 1.2.2 loading readiness guard; original state handlers remain intact.
var loadingState = Method(app, "EmbyDesktop.Controls.PlayerOverlay", "UpdatePlayerState");
Mark(loadingState);
foreach (var ret in loadingState.Body.Instructions.Where(i => i.OpCode == OpCodes.Ret).ToArray())
    Prefix(loadingState, ret, Instruction.Create(OpCodes.Ldarg_0), Instruction.Create(OpCodes.Ldarg_1),
        Instruction.Create(OpCodes.Call, Helper(app.MainModule, "PlayerFeedback", "KeepStartupVisible")));
foreach(var call in loadingState.Body.Instructions.Where(i=>i.Operand is MethodReference m&&m.DeclaringType.FullName=="EmbyDesktop.Controls.PlayerOverlay"&&m.Name is "SetControlsVisible" or "ShowControlsTemporarily"))
{
    var original=(MethodReference)call.Operand;call.OpCode=OpCodes.Call;
    call.Operand=Helper(app.MainModule,"PlaybackStateFeedback",original.Name=="SetControlsVisible"?"StateControls":"StateTemporarily");
}
// End 1.2.2 loading readiness guard.
// 1.2.2 first-frame confirmation resolves an earlier preliminary Playing event.
BeforeReturns(Method(app, "EmbyDesktop.Services.MpvPlaybackSession", "MarkPlaybackStarted"), "PlayerFeedback", "Ready", preserveExclusiveEnds: true);
var episodeQueue = Types(app.MainModule.Types).Single(t=>t.FullName.StartsWith(
    "EmbyDesktop.Services.MpvPlaybackSession/<LoadEpisodePlaylistAfterStartAsync>d__",StringComparison.Ordinal));
var episodeQueueMove=episodeQueue.Methods.Single(m=>m.Name=="MoveNext");
var playlistWrite=episodeQueueMove.Body.Instructions.Single(i=>i.OpCode==OpCodes.Stfld&&i.Operand is FieldReference field&&field.Name=="_playlist");
Mark(episodeQueueMove);
var episodeQueueIl=episodeQueueMove.Body.GetILProcessor();
var queueOwner=Instruction.Create(OpCodes.Ldarg_0);
episodeQueueIl.InsertAfter(playlistWrite,queueOwner);
var getPlayer=Instruction.Create(OpCodes.Ldfld,episodeQueue.Fields.Single(f=>f.Name=="<>4__this"));
episodeQueueIl.InsertAfter(queueOwner,getPlayer);
episodeQueueIl.InsertAfter(getPlayer,Instruction.Create(OpCodes.Call,Helper(app.MainModule,"PlayerFeedback","EpisodePlaylistReady")));

// End 1.2.2 first-frame confirmation.

BeforeReturns(Method(app, "EmbyDesktop.Controls.PlayerOverlay", ".ctor"), "PlayerMenus", "Configure");
BeforeReturns(Method(app, "EmbyDesktop.Controls.PlayerOverlay", ".ctor"), "EpisodeLabels", "ConfigureVolume");
BeforeReturns(Method(app, "EmbyDesktop.Controls.PlayerOverlay", ".ctor"), "PlaybackUi", "Configure", preserveExclusiveEnds: true);
var episodeDisplay = Method(core, "EmbyDesktop.Core.Services.PlaybackDisplayTitlePolicy", "Create");
Mark(episodeDisplay);
Prefix(episodeDisplay, episodeDisplay.Body.Instructions[0], Instruction.Create(OpCodes.Ldarg_0),
    Instruction.Create(OpCodes.Call, Helper(core.MainModule, "EpisodeLabels", "Display")), Instruction.Create(OpCodes.Ret));
// Playlist refresh and window resize must share the same fixed outer height.
var episodeHeight = Method(app, "EmbyDesktop.Controls.PlayerOverlay", "UpdateEpisodeDrawerHeight");
Mark(episodeHeight);
episodeHeight.Body = new Mono.Cecil.Cil.MethodBody(episodeHeight);
episodeHeight.Body.Instructions.Add(Instruction.Create(OpCodes.Ldarg_0));
episodeHeight.Body.Instructions.Add(Instruction.Create(OpCodes.Call, Helper(app.MainModule, "PlayerSeasonPanel", "SizeDrawer")));
episodeHeight.Body.Instructions.Add(Instruction.Create(OpCodes.Ret));
// The player locator uses 50-item ranges. Detail pages retain their own ranges.
var setEpisodePlaylist = Method(app, "EmbyDesktop.Controls.PlayerOverlay", "SetPlaylist");
Mark(setEpisodePlaylist);
var createEpisodeRanges = setEpisodePlaylist.Body.Instructions.Single(i =>
    i.Operand is MethodReference method && method.DeclaringType.FullName == "EmbyDesktop.Core.Services.EpisodeRangePolicy"
    && method.Name == "Create");
var oldEpisodeRangeSize = createEpisodeRanges.Previous;
if (oldEpisodeRangeSize.OpCode != OpCodes.Ldc_I4 || !Equals(oldEpisodeRangeSize.Operand, 50))
    throw new InvalidOperationException("Unexpected player episode range size");
oldEpisodeRangeSize.OpCode = OpCodes.Nop;
oldEpisodeRangeSize.Operand = null;
createEpisodeRanges.Operand = Helper(app.MainModule, "PlayerSeasonPanel", "CreateRanges");
var episodeOptions = Method(app, "EmbyDesktop.Controls.PlayerOverlay", "PopulateVisibleEpisodes");
Mark(episodeOptions);
var episodeRangeCalls = episodeOptions.Body.Instructions.Where(i =>
    i.Operand is MethodReference method && method.DeclaringType.FullName == "EmbyDesktop.Core.Services.EpisodeRangePolicy"
    && method.Name == "ResolveVisibleRange").ToArray();
if (episodeRangeCalls.Length != 2) throw new InvalidOperationException("Unexpected episode range branches");
foreach (var resolveRange in episodeRangeCalls)
{
    resolveRange.OpCode = OpCodes.Call;
    resolveRange.Operand = Helper(app.MainModule, "PlayerSeasonPanel", "VisibleEpisodes");
}
var episodeRangeChanged = Method(app, "EmbyDesktop.Controls.PlayerOverlay", "EpisodeRangeCombo_SelectionChanged");
Mark(episodeRangeChanged);
var originalRangeChanged = episodeRangeChanged.Body.Instructions[0];
var rangeGuard = episodeRangeChanged.Body.GetILProcessor();
rangeGuard.InsertBefore(originalRangeChanged, Instruction.Create(OpCodes.Ldarg_0));
rangeGuard.InsertBefore(originalRangeChanged,
    Instruction.Create(OpCodes.Call, Helper(app.MainModule, "PlayerSeasonPanel", "NavigateOriginalRange")));
rangeGuard.InsertBefore(originalRangeChanged, Instruction.Create(OpCodes.Brfalse, originalRangeChanged));
rangeGuard.InsertBefore(originalRangeChanged, Instruction.Create(OpCodes.Ret));
var episodeItem = episodeOptions.Body.Variables.Single(v => v.VariableType.FullName == "EmbyDesktop.Core.Models.EmbyItem");
var titleJoin = episodeOptions.Body.Instructions.Single(i => i.OpCode == OpCodes.Br &&
    i.Previous.Operand is MethodReference m && m.Name == "ToStringAndClear").Operand as Instruction
    ?? throw new InvalidOperationException("Missing episode title join");
// Both title branches leave their label on the stack; replace that single
// argument before the original selected-brush and option construction.
Prefix(episodeOptions, titleJoin, Instruction.Create(OpCodes.Pop), Instruction.Create(OpCodes.Ldloc, episodeItem),
    Instruction.Create(OpCodes.Call, Helper(app.MainModule, "EpisodeLabels", "Display")));
// Keep Emby metadata unchanged. Supply a visible label even without IndexNumber.
var episodeDash = episodeOptions.Body.Instructions.Single(ins => ins.OpCode == OpCodes.Ldstr && Equals(ins.Operand, "—"));
var numberJoin = episodeDash.Next;
var episodeOrdinal = episodeOptions.Body.Variables[2];
if (episodeOrdinal.VariableType.FullName != "System.Int32") throw new InvalidOperationException("Unexpected episode index local");
Prefix(episodeOptions, numberJoin, Instruction.Create(OpCodes.Pop), Instruction.Create(OpCodes.Ldloc, episodeItem),
    Instruction.Create(OpCodes.Ldloc, episodeOrdinal), Instruction.Create(OpCodes.Ldc_I4_1), Instruction.Create(OpCodes.Add),
    Instruction.Create(OpCodes.Call, Helper(app.MainModule, "EpisodeLabels", "Number")));
// Assign the season-local ordinal before publishing each row to XAML.
const string detailRowType = "EmbyDesktop.ViewModels.EpisodeRowViewModel";
var detailNumber = Method(app, detailRowType, "get_DisplayNumber");
var detailOrdinal = new FieldDefinition("_displayOrdinal", FieldAttributes.Assembly, app.MainModule.TypeSystem.Int32);
detailNumber.DeclaringType.Fields.Add(detailOrdinal);
Mark(detailNumber);
Prefix(detailNumber, detailNumber.Body.Instructions[0],
    Instruction.Create(OpCodes.Ldarg_0), Instruction.Create(OpCodes.Call, Method(app, detailRowType, "get_Item")),
    Instruction.Create(OpCodes.Ldarg_0), Instruction.Create(OpCodes.Ldfld, detailOrdinal),
    Instruction.Create(OpCodes.Call, Helper(app.MainModule, "EpisodeLabels", "Number")), Instruction.Create(OpCodes.Ret));

var detailLoad = Types(app.MainModule.Types).Single(t => t.FullName.StartsWith("EmbyDesktop.MainPage/<LoadSeasonEpisodesAsync>"))
    .Methods.Single(m => m.Name == "MoveNext");
Mark(detailLoad);
var detailLoadOrdinal = new VariableDefinition(app.MainModule.TypeSystem.Int32);
detailLoad.Body.Variables.Add(detailLoadOrdinal);
var firstDetailClear = detailLoad.Body.Instructions.First(i => i.Operand is MethodReference m && m.Name == "Clear" &&
    m.DeclaringType is GenericInstanceType g && g.GenericArguments.Count == 1 && g.GenericArguments[0].FullName == detailRowType);
Prefix(detailLoad, firstDetailClear.Next, Instruction.Create(OpCodes.Ldc_I4_0), Instruction.Create(OpCodes.Stloc, detailLoadOrdinal));
var publishRow = detailLoad.Body.Instructions.Single(i => i.Operand is MethodReference m && m.Name == "Add" &&
    m.DeclaringType is GenericInstanceType g && g.GenericArguments.Count == 1 && g.GenericArguments[0].FullName == detailRowType);
Prefix(detailLoad, publishRow,
    Instruction.Create(OpCodes.Ldloc, detailLoadOrdinal), Instruction.Create(OpCodes.Ldc_I4_1),
    Instruction.Create(OpCodes.Add), Instruction.Create(OpCodes.Stloc, detailLoadOrdinal),
    Instruction.Create(OpCodes.Dup), Instruction.Create(OpCodes.Ldloc, detailLoadOrdinal), Instruction.Create(OpCodes.Stfld, detailOrdinal));
var detailRanges = Method(app, "EmbyDesktop.MainPage", "BuildEpisodeRanges");
Mark(detailRanges);
var range = detailRanges.Body.Variables.Single(v => v.VariableType.FullName == "EmbyDesktop.Core.Services.EpisodeRange");
var rangeNumbers = detailRanges.Body.Instructions.Where(i => i.Operand is MethodReference m && m.Name == "get_DisplayNumber")
    .Select(i => (VariableDefinition)i.Next.Operand).ToArray();
var rangeLabel = detailRanges.Body.Instructions.Single(i => i.Operand is MethodReference m && m.Name == "set_Label");
MethodReference RangeGetter(string name) => (MethodReference)detailRanges.Body.Instructions.Single(i =>
    i.Operand is MethodReference m && m.DeclaringType.FullName == range.VariableType.FullName && m.Name == name &&
    i.Next.Operand is MethodReference setter && setter.Name.StartsWith("set_")).Operand;
Prefix(detailRanges, rangeLabel, Instruction.Create(OpCodes.Pop),
    Instruction.Create(OpCodes.Ldloc, rangeNumbers[0]), Instruction.Create(OpCodes.Ldloc, rangeNumbers[1]),
    Instruction.Create(OpCodes.Ldloc, range), Instruction.Create(OpCodes.Callvirt, RangeGetter("get_StartIndex")),
    Instruction.Create(OpCodes.Ldloc, range), Instruction.Create(OpCodes.Callvirt, RangeGetter("get_Count")),
    Instruction.Create(OpCodes.Call, Helper(app.MainModule, "EpisodeLabels", "Range")));
var isoStartState = Types(app.MainModule.Types).Single(t => t.FullName.StartsWith("EmbyDesktop.MainPage/<StartNetworkIsoPlaybackAsync>"));
var isoStartMove = isoStartState.Methods.Single(m => m.Name == "MoveNext");
Mark(isoStartMove);
var isoPage = isoStartMove.Body.Variables.Single(v => v.VariableType.FullName == "EmbyDesktop.MainPage");
var newIsoPlayer = isoStartMove.Body.Instructions.Single(i => i.OpCode == OpCodes.Newobj && i.Operand is MethodReference m && m.DeclaringType.Name == "MpvPlaybackSession");
Prefix(isoStartMove, newIsoPlayer.Next, Instruction.Create(OpCodes.Dup), Instruction.Create(OpCodes.Ldloc, isoPage),
    Instruction.Create(OpCodes.Call, Helper(app.MainModule, "NetworkEpisodes", "Configure")));
var preparePlayerState = Types(app.MainModule.Types).Single(t => t.FullName.StartsWith("EmbyDesktop.MainPage/<ShowPlaybackPreparationAsync>"));
var preparePlayerMove = preparePlayerState.Methods.Single(m => m.Name == "MoveNext");
Mark(preparePlayerMove);
// Prepare playback metadata while the download cancellation settles. Both
// operations complete before switching or opening the media stream.
Mark(preparePlayerMove);
var pauseDownloads = preparePlayerMove.Body.Instructions.Single(i => i.Operand is MethodReference m &&
    m.DeclaringType.Name == "OfflineDownloadManager" && m.Name == "PauseAsync");
var downloadsGetter = (MethodReference)pauseDownloads.Previous.Previous.Operand;
var pauseMethod = (MethodReference)pauseDownloads.Operand;
var launchOwner = (VariableDefinition)pauseDownloads.Previous.Previous.Previous.Operand;
Prefix(preparePlayerMove, pauseDownloads, Instruction.Create(OpCodes.Pop), Instruction.Create(OpCodes.Pop));
pauseDownloads.OpCode = OpCodes.Call;
pauseDownloads.Operand = app.MainModule.ImportReference(typeof(Task).GetProperty(nameof(Task.CompletedTask))!.GetMethod!);
var prepareMetadata = preparePlayerMove.Body.Instructions.Single(i => i.Operand is MethodReference m && m.Name == "GetPreparedPlaybackAsync");
var metadataTask = (GenericInstanceType)((MethodReference)prepareMetadata.Operand).ReturnType;
var joinPreparation = new GenericInstanceMethod(Helper(app.MainModule, "PlaybackLaunchGuard", "JoinPreparation"));
joinPreparation.GenericArguments.Add(metadataTask.GenericArguments.Single());
Prefix(preparePlayerMove, prepareMetadata.Next, Instruction.Create(OpCodes.Ldloc, launchOwner),
    Instruction.Create(OpCodes.Call, downloadsGetter), Instruction.Create(OpCodes.Ldnull),
    Instruction.Create(OpCodes.Callvirt, pauseMethod), Instruction.Create(OpCodes.Call, joinPreparation));
var canReusePlayer = preparePlayerMove.Body.Instructions.Single(i => i.Operand is MethodReference m && m.Name == "get_CanSwitch");
canReusePlayer.OpCode = OpCodes.Call; canReusePlayer.Operand = Helper(app.MainModule, "NetworkEpisodes", "CanSwitch");
// A remote ISO may create a new session, so post-switch detail indicators must
// read the active session rather than the now-disposed request sender.
var pumpState = Types(app.MainModule.Types).Single(t => t.FullName.StartsWith("EmbyDesktop.MainPage/<ProcessPendingEpisodeRequestAsync>"));
var pumpMove = pumpState.Methods.Single(m => m.Name == "MoveNext");
Mark(pumpMove);
var pumpPage = pumpMove.Body.Variables.Single(v => v.VariableType.FullName == "EmbyDesktop.MainPage");
var pumpId = pumpMove.Body.Instructions.Where(i => i.Operand is MethodReference m && m.Name == "get_ItemId").Last();
var pumpItem = pumpMove.Body.Instructions.Single(i => i.Operand is MethodReference m && m.DeclaringType.Name == "MpvPlaybackSession" && m.Name == "get_Item");
foreach (var (ins, function) in new[] { (pumpId, "CurrentId"), (pumpItem, "CurrentItem") })
{
    Prefix(pumpMove, ins, Instruction.Create(OpCodes.Ldloc, pumpPage));
    ins.OpCode = OpCodes.Call; ins.Operand = Helper(app.MainModule, "NetworkEpisodes", function);
}
// Reuse the existing tools content and action handlers in a hover flyout. The
// original async finally still restores all dialog/shortcut suppression flags.
var toolsState = Types(app.MainModule.Types).Single(t => t.FullName.StartsWith("EmbyDesktop.Services.MpvPlaybackSession/<ShowDesktopPlayerAsync>"));
var toolsMove = toolsState.Methods.Single(m => m.Name == "MoveNext");
Mark(toolsMove);
var toolsSession = toolsMove.Body.Variables.Single(v => v.VariableType.FullName == "EmbyDesktop.Services.MpvPlaybackSession");
var showTools = toolsMove.Body.Instructions.Single(i => i.Operand is MethodReference m && m.DeclaringType.Name == "ContentDialog" && m.Name == "ShowAsync");
var toolsAwaiter = showTools.Next;
if (toolsAwaiter.Operand is not GenericInstanceMethod oldToolsAwaiter || oldToolsAwaiter.Name != "GetAwaiter") throw new InvalidOperationException("Unexpected tools awaiter");
// Import the compiler-produced generic member signature (return uses !0).
// A hand-built concrete return signature could fail member resolution at runtime.
var helperToolsMove = Types(helper.MainModule.Types).Single(t => t.FullName.StartsWith("Yingyu.Update.PlayerMenus/<ShowTools>"))
    .Methods.Single(m => m.Name == "MoveNext");
var helperToolsAwaiter = helperToolsMove.Body.Instructions.Single(i => i.Operand is MethodReference m && m.Name == "GetAwaiter" && m.DeclaringType.Name == "Task`1");
toolsAwaiter.OpCode = OpCodes.Callvirt;
toolsAwaiter.Operand = app.MainModule.ImportReference((MethodReference)helperToolsAwaiter.Operand);
Prefix(toolsMove, showTools, Instruction.Create(OpCodes.Ldloc, toolsSession));
showTools.OpCode = OpCodes.Call; showTools.Operand = Helper(app.MainModule, "PlayerMenus", "ShowTools");
foreach (var method in Types(app.MainModule.Types).Where(t => t.FullName.StartsWith("EmbyDesktop.Services.MpvPlaybackSession"))
    .SelectMany(t => t.Methods).Where(m => m.HasBody))
    foreach (var ins in method.Body.Instructions.Where(i => i.Operand is MethodReference m && m.DeclaringType.Name == "ContentDialog" && m.Name == "Hide").ToArray())
    {
        // Unknown/non-tools dialogs keep their original Hide operation.
        Mark(method); ins.OpCode = OpCodes.Call; ins.Operand = Helper(app.MainModule, "PlayerMenus", "HideTools");
    }
var disconnectKeys = Method(app, "EmbyDesktop.Controls.PlayerOverlay", "Disconnect");
Mark(disconnectKeys);
Prefix(disconnectKeys, disconnectKeys.Body.Instructions[0], Instruction.Create(OpCodes.Ldarg_0),
    Instruction.Create(OpCodes.Call, Helper(app.MainModule, "PlayerShortcuts", "Disconnect")));
// Do not start speculative playback/302 preparation for adjacent or hovered
// episodes. Actual click, auto-advance, route reuse and refresh are preserved.
var adjacent = Method(app, "EmbyDesktop.MainPage", "PrefetchAdjacentPlaybackAsync");
Mark(adjacent);
var completedTask = app.MainModule.ImportReference(typeof(Task).GetProperty("CompletedTask")!.GetMethod!);
Prefix(adjacent, adjacent.Body.Instructions[0], Instruction.Create(OpCodes.Call, completedTask), Instruction.Create(OpCodes.Ret));
var hovered = Method(app, "EmbyDesktop.MainPage", "PlaybackSession_EpisodePreviewRequested");
Mark(hovered);
Prefix(hovered, hovered.Body.Instructions[0], Instruction.Create(OpCodes.Ret));
var detailPrefetch = Method(app, "EmbyDesktop.MainPage", "QueueDetailPlaybackPrefetch");
Mark(detailPrefetch);
Prefix(detailPrefetch, detailPrefetch.Body.Instructions[0], Instruction.Create(OpCodes.Ldarg, detailPrefetch.Parameters[0]),
    Instruction.Create(OpCodes.Call, Helper(app.MainModule, "EpisodeRequests", "IsEpisode")),
    Instruction.Create(OpCodes.Brfalse, detailPrefetch.Body.Instructions[0]), Instruction.Create(OpCodes.Ret));
BeforeReturns(Method(app, "EmbyDesktop.Controls.PlayerOverlay", "ShowActionFeedback"), "PlayerFeedback", "Sync");
// Complete only the fallback title's metadata before the original preference
// selection; preserve MPV user IDs and the original selection/reporting code.
var trackState = Types(app.MainModule.Types).Single(t => t.FullName.StartsWith("EmbyDesktop.Services.MpvPlaybackSession/<RefreshTracksAsync>"));
var trackMove = trackState.Methods.Single(m => m.Name == "MoveNext");
Mark(trackMove);
var trackSession = trackMove.Body.Variables.Single(v => v.VariableType.FullName == "EmbyDesktop.Services.MpvPlaybackSession");
var getTracks = trackMove.Body.Instructions.Single(i => i.Operand is MethodReference m && m.Name == "GetTracksAsync");
Prefix(trackMove, getTracks, Instruction.Create(OpCodes.Ldloc, trackSession));
getTracks.OpCode = OpCodes.Call; getTracks.Operand = Helper(app.MainModule, "BlurayTracks", "GetTracks");
var trackLabel = Method(app, "EmbyDesktop.Controls.PlayerOverlay", "BuildTrackLabel");
Mark(trackLabel);
Prefix(trackLabel, trackLabel.Body.Instructions[0], Instruction.Create(OpCodes.Ldarg, trackLabel.Parameters[0]),
    Instruction.Create(OpCodes.Call, Helper(app.MainModule, "BlurayTracks", "IsPgs")),
    Instruction.Create(OpCodes.Brfalse, trackLabel.Body.Instructions[0]),
    Instruction.Create(OpCodes.Ldarg, trackLabel.Parameters[0]),
    Instruction.Create(OpCodes.Call, Helper(app.MainModule, "BlurayTracks", "Label")), Instruction.Create(OpCodes.Ret));
// Inject file-local MPV options immediately before the existing loadfile option
// count check, including when the original MpvPlayOptions is null.
var kernelPlayState = Types(kernelCore.MainModule.Types).Single(t => t.Name.StartsWith("<PlayAsync>d__"));
var kernelPlay = kernelPlayState.Methods.Single(m => m.Name == "MoveNext");
Mark(kernelPlay);
var optionField = kernelPlayState.Fields.Single(f => f.Name.Contains("<commandOptions>"));
var optionCount = kernelPlay.Body.Instructions.Single(i => i.Operand is MethodReference m && m.Name == "get_Count"
    && i.Previous.Operand is FieldReference f && f.Name == optionField.Name);
var pathField = kernelPlayState.Fields.Single(f => f.Name == "filePath");
var optionBoundary = optionCount.Previous.Previous;
var optionPrefix = new[] { Instruction.Create(OpCodes.Ldarg_0), Instruction.Create(OpCodes.Ldfld, optionField),
    Instruction.Create(OpCodes.Ldarg_0), Instruction.Create(OpCodes.Ldfld, pathField),
    Instruction.Create(OpCodes.Call, Helper(kernelCore.MainModule, "BlurayMpvOptions", "Append")) };
Prefix(kernelPlay, optionBoundary, optionPrefix);
// The original instruction is also the exclusive end of an enumerator's
// finally handler. Keep the new call outside that handler, preserving legal
// branches from every original options/null-options path.
foreach (var handler in kernelPlay.Body.ExceptionHandlers)
{
    if (handler.TryEnd == optionBoundary) handler.TryEnd = optionPrefix[0];
    if (handler.HandlerEnd == optionBoundary) handler.HandlerEnd = optionPrefix[0];
}
var detailImages = Method(app, "EmbyDesktop.MainPage", "LoadDetailImagesAsync");
Mark(detailImages);
detailImages.Body.Instructions.Clear(); detailImages.Body.Variables.Clear(); detailImages.Body.ExceptionHandlers.Clear();
detailImages.Body.Instructions.Add(Instruction.Create(OpCodes.Ldarg_0));
detailImages.Body.Instructions.Add(Instruction.Create(OpCodes.Ldarg, detailImages.Parameters[0]));
detailImages.Body.Instructions.Add(Instruction.Create(OpCodes.Ldarg, detailImages.Parameters[1]));
detailImages.Body.Instructions.Add(Instruction.Create(OpCodes.Call, Helper(app.MainModule, "DetailArtwork", "Load")));
detailImages.Body.Instructions.Add(Instruction.Create(OpCodes.Ret));
var operationFeedback = Method(app, "EmbyDesktop.MainPage", "ShowOperationFeedback");
Mark(operationFeedback);
Prefix(operationFeedback, operationFeedback.Body.Instructions[0], Instruction.Create(OpCodes.Ldarg_0),
    Instruction.Create(OpCodes.Ldarg, operationFeedback.Parameters[0]),
    Instruction.Create(OpCodes.Call, Helper(app.MainModule, "ArtworkFeedback", "Suppress")),
    Instruction.Create(OpCodes.Brfalse, operationFeedback.Body.Instructions[0]), Instruction.Create(OpCodes.Ret));
var kernelEventType = Types(kernelCore.MainModule.Types).Single(t => t.Name.StartsWith("<HandleEvent>d__"));
var kernelEvent = kernelEventType.Methods.Single(m => m.Name == "MoveNext");
Mark(kernelEvent);
foreach (var (pattern, function) in new[] { ("Seek failed", "SeekIsTls"), ("Failed to seek when reading header element", "HeaderSeekIsTls"), ("tls: IO error", "TlsLogIsTerminal") })
{
    var text = kernelEvent.Body.Instructions.Single(i => i.OpCode == OpCodes.Ldstr && Equals(i.Operand, pattern));
    var contains = text.Next;
    if (contains.Operand is not MethodReference) contains = contains.Next;
    if (contains.Operand is not MethodReference method || method.Name != "Contains") throw new InvalidOperationException("Unexpected diagnostic shape");
    contains.OpCode = OpCodes.Call; contains.Operand = Helper(kernelCore.MainModule, "PlaybackDiagnostics", function);
}
// HTTP source failure is a load error, not a video-output initialization error.
var httpOpenText = kernelEvent.Body.Instructions.Single(i => i.OpCode == OpCodes.Ldstr && Equals(i.Operand, "Failed to open http"));
var httpOpenEnd = kernelEvent.Body.Instructions.Skip(kernelEvent.Body.Instructions.IndexOf(httpOpenText))
    .First(i => i.Operand is MethodReference m && m.Name == "Invoke");
if (httpOpenEnd.Previous.OpCode != OpCodes.Ldc_I4 || !Equals(httpOpenEnd.Previous.Operand, -15)) throw new InvalidOperationException("Unexpected HTTP error shape");
httpOpenEnd.Previous.Operand = -13;
var warningHttpText = kernelEvent.Body.Instructions.Single(i => i.OpCode == OpCodes.Ldstr && Equals(i.Operand, "HTTP error"));
var packetErrorText = kernelEvent.Body.Instructions.Single(i => i.OpCode == OpCodes.Ldstr && Equals(i.Operand, "error reading packet"));
var httpGenericCode = kernelEvent.Body.Instructions.Skip(kernelEvent.Body.Instructions.IndexOf(warningHttpText))
    .Take(kernelEvent.Body.Instructions.IndexOf(packetErrorText) - kernelEvent.Body.Instructions.IndexOf(warningHttpText))
    .Single(i => i.OpCode == OpCodes.Ldc_I4 && Equals(i.Operand, -15));
httpGenericCode.Operand = -13;
// Retain the existing window/presenter and native decoder; synchronize the XAML
// bridge with the same physical client rectangle for windowed and fullscreen use.
var viewport = Method(windowUi, "Richasy.MpvKernel.WinUI.MpvPlayerWindow", "UpdateXamlSourcePosition");
Mark(viewport);
viewport.Body.Instructions.Clear(); viewport.Body.Variables.Clear(); viewport.Body.ExceptionHandlers.Clear();
viewport.Body.Instructions.Add(Instruction.Create(OpCodes.Ldarg_0));
viewport.Body.Instructions.Add(Instruction.Create(OpCodes.Call, Helper(windowUi.MainModule, "PlayerPresentation", "UpdateWindow")));
viewport.Body.Instructions.Add(Instruction.Create(OpCodes.Ret));
BeforeReturns(Method(app, "EmbyDesktop.MainPage", "UpdateDetailPlaybackButtonState"), "BackgroundArtwork", "UpdatePlaybackButton");
var init = Method(app, "EmbyDesktop.MainPage", "InitializeArtworkCacheAsync");
Mark(init);
Prefix(init, init.Body.Instructions[0],
    Instruction.Create(OpCodes.Ldarg_0), Instruction.Create(OpCodes.Call, Helper(app.MainModule, "BackgroundArtwork", "BlockInitialization")),
    Instruction.Create(OpCodes.Brfalse, init.Body.Instructions[0]),
    Instruction.Create(OpCodes.Call, app.MainModule.ImportReference(typeof(Task).GetProperty(nameof(Task.CompletedTask))!.GetMethod!)), Instruction.Create(OpCodes.Ret));
// Force Quick even if an older control selection/caller passes Complete.
var originalInitStart = init.Body.Instructions[5];
Prefix(init, originalInitStart, Instruction.Create(OpCodes.Ldc_I4_0), Instruction.Create(OpCodes.Starg, init.Parameters[0]));
var initState = Types(app.MainModule.Types).Single(t => t.Name.StartsWith("<InitializeArtworkCacheAsync>d__"));
var moveInit = initState.Methods.Single(m => m.Name == "MoveNext");
Mark(moveInit);
var pageLocal = moveInit.Body.Variables.Single(v => v.VariableType.FullName == "EmbyDesktop.MainPage");
var stores = moveInit.Body.Instructions.Where(i => i.OpCode == OpCodes.Stfld && i.Operand is FieldReference f && f.Name == "_artworkInitializationCts").ToArray();
if (stores.Length != 2) throw new InvalidOperationException("Unexpected initialization lifetime shape");
var initIl = moveInit.Body.GetILProcessor();
var overlayLoad = moveInit.Body.Instructions.First(i => i.Operand is FieldReference f && f.Name == "ArtworkInitializationOverlay");
Prefix(moveInit, overlayLoad.Previous, Instruction.Create(OpCodes.Ldloc, pageLocal),
    Instruction.Create(OpCodes.Call, Helper(app.MainModule, "BackgroundArtwork", "Begin")));
var endLoad = Instruction.Create(OpCodes.Ldloc, pageLocal);
initIl.InsertAfter(stores[1], endLoad);
initIl.InsertAfter(endLoad, Instruction.Create(OpCodes.Call, Helper(app.MainModule, "BackgroundArtwork", "End")));
// 1.2.2 incremental initialization: reuse the existing async wait and original
// download loop. Filter only after existing artwork registration completes.
var planField = initState.Fields.Single(f => f.Name.StartsWith("<plan>"));
var totalField = initState.Fields.Single(f => f.Name.StartsWith("<total>"));
var cancelField = initState.Fields.Single(f => f.Name.StartsWith("<cancellationToken>"));
var indexRead = moveInit.Body.Instructions.Single(i => i.Operand is FieldReference f && f.Name == "_existingArtworkIndexTask");
Prefix(moveInit, indexRead.Next,
    Instruction.Create(OpCodes.Ldloc, pageLocal),
    Instruction.Create(OpCodes.Ldarg_0), Instruction.Create(OpCodes.Ldfld, planField),
    Instruction.Create(OpCodes.Ldarg_0), Instruction.Create(OpCodes.Ldfld, cancelField),
    Instruction.Create(OpCodes.Call, Helper(app.MainModule, "ArtworkInitializationReuse", "Prepare")));
var estimateNew = moveInit.Body.Instructions.Single(i => i.OpCode == OpCodes.Newobj && i.Operand is MethodReference m && m.DeclaringType.Name == "ArtworkInitializationEstimateTracker");
var planCount = (MethodReference)moveInit.Body.Instructions.Single(i => i.OpCode == OpCodes.Stfld && i.Operand == totalField && i.Previous.OpCode == OpCodes.Callvirt).Previous.Operand;
Prefix(moveInit, estimateNew.Previous,
    Instruction.Create(OpCodes.Ldarg_0), Instruction.Create(OpCodes.Ldloc, pageLocal),
    Instruction.Create(OpCodes.Ldarg_0), Instruction.Create(OpCodes.Ldfld, planField),
    Instruction.Create(OpCodes.Call, Helper(app.MainModule, "ArtworkInitializationReuse", "TakePlan")), Instruction.Create(OpCodes.Stfld, planField),
    Instruction.Create(OpCodes.Ldarg_0), Instruction.Create(OpCodes.Ldarg_0), Instruction.Create(OpCodes.Ldfld, planField),
    Instruction.Create(OpCodes.Callvirt, planCount), Instruction.Create(OpCodes.Stfld, totalField));
BeforeReturns(Method(app, "EmbyDesktop.MainPage", "UpdateArtworkInitializationUi"), "ArtworkInitializationReuse", "Annotate", preserveExclusiveEnds: true);
foreach (var text in moveInit.Body.Instructions.Where(i => i.OpCode == OpCodes.Ldstr && Equals(i.Operand, "正在优先初始化海报墙图片…")))
    text.Operand = "正在补齐缺失的海报墙图片…";
// End 1.2.2 incremental initialization.
var playback = Method(app, "EmbyDesktop.MainPage", "StartPlaybackSafelyAsync");
Mark(playback);
Prefix(playback, playback.Body.Instructions[0], Instruction.Create(OpCodes.Ldarg_0),
    Instruction.Create(OpCodes.Call, Helper(app.MainModule, "BackgroundArtwork", "BlockPlayback")),
    Instruction.Create(OpCodes.Brfalse, playback.Body.Instructions[0]), Instruction.Create(OpCodes.Ldc_I4_0),
    Instruction.Create(OpCodes.Call, app.MainModule.ImportReference(typeof(Task).GetMethod(nameof(Task.FromResult))!.MakeGenericMethod(typeof(bool)))), Instruction.Create(OpCodes.Ret));
// One bounded entry guard: keep the original async launcher, semaphore,
// cancellation, errors and finally cleanup byte-for-byte after this prefix.
var startPlayback=Method(app,"EmbyDesktop.MainPage","StartPlaybackSafelyAsync");
Mark(startPlayback);
var noRepeatedLaunch=Instruction.Create(OpCodes.Pop);
Prefix(startPlayback,startPlayback.Body.Instructions[0],Instruction.Create(OpCodes.Ldarg_0),
    Instruction.Create(OpCodes.Ldarg,startPlayback.Parameters[1]),
    Instruction.Create(OpCodes.Call,Helper(app.MainModule,"PlaybackLaunchGuard","Repeated")),
    Instruction.Create(OpCodes.Dup),Instruction.Create(OpCodes.Brfalse,noRepeatedLaunch),
    Instruction.Create(OpCodes.Ret),noRepeatedLaunch);
// End common launch guard.
foreach (string name in new[] { "QueueDetailPlaybackPrefetch", "RefreshCacheButton_Click", "ClearCacheButton_Click" }) GuardVoid(name);
var loadPoster = Method(app, "EmbyDesktop.MainPage", "LoadPosterBitmapAsync");
Mark(loadPoster);
var cachedLoader = new List<Instruction>
{
    Instruction.Create(OpCodes.Ldarg_0), Instruction.Create(OpCodes.Call, Helper(app.MainModule, "BackgroundArtwork", "IsRunning")),
    Instruction.Create(OpCodes.Brfalse, loadPoster.Body.Instructions[0]), Instruction.Create(OpCodes.Ldarg_0)
};
foreach (int index in new[] { 0, 1, 2, 3, 4, 5, 7 }) cachedLoader.Add(Instruction.Create(OpCodes.Ldarg, loadPoster.Parameters[index]));
cachedLoader.Add(Instruction.Create(OpCodes.Call, Helper(app.MainModule, "BackgroundArtwork", "CachedPosterAsync")));
cachedLoader.Add(Instruction.Create(OpCodes.Ret));
Prefix(loadPoster, loadPoster.Body.Instructions[0], cachedLoader.ToArray());

foreach (string name in new[] { "RootGrid_KeyDown", "PlayerOverlay_PreviewKeyDown" })
{
    var method = Method(app, "EmbyDesktop.Controls.PlayerOverlay", name);
    Mark(method);
    Prefix(method, method.Body.Instructions[0], Instruction.Create(OpCodes.Ldarg_0), Instruction.Create(OpCodes.Ldarg, method.Parameters[1]),
        Instruction.Create(OpCodes.Call, Helper(app.MainModule, "PlayerShortcuts", "KeyDown")),
        Instruction.Create(OpCodes.Brfalse, method.Body.Instructions[0]), Instruction.Create(OpCodes.Ret));
}

// Preserve the original auto-hide checks, adding the continuous bottom band.
var canHide = Method(app, "EmbyDesktop.Controls.PlayerOverlay", "get_CanAutoHideControls");
Mark(canHide);
Prefix(canHide, canHide.Body.Instructions[0], Instruction.Create(OpCodes.Ldarg_0),
    Instruction.Create(OpCodes.Call, Helper(app.MainModule, "PlayerHover", "KeepVisible")),
    Instruction.Create(OpCodes.Brfalse, canHide.Body.Instructions[0]), Instruction.Create(OpCodes.Ldc_I4_0), Instruction.Create(OpCodes.Ret));

// Paused playback shares the existing idle clock and every interaction guard.
var playingHide=canHide.Body.Instructions.Single(i=>i.Operand is FieldReference f&&f.Name=="_isPlaying");
playingHide.OpCode=OpCodes.Call;playingHide.Operand=Helper(app.MainModule,"PlayerFeedback","CanIdleHide");
BeforeReturns(Method(app,"EmbyDesktop.Services.MpvPlaybackSession","DesktopPlayerTick"),"PlayerSkipCountdown","Observe",preserveExclusiveEnds:true);
foreach(var name in new[]{"OnSeekRequested","OnEpisodeRequested","OnRetryPlaybackRequested","DisposeAsync","SeekAsync"})
{
    var method=Method(app,"EmbyDesktop.Services.MpvPlaybackSession",name);Mark(method);
    Prefix(method,method.Body.Instructions[0],Instruction.Create(OpCodes.Ldarg_0),Instruction.Create(OpCodes.Call,Helper(app.MainModule,"PlayerSkipCountdown",name=="SeekAsync"?"BeforeSeek":"Interrupt")));
}
// 1.2.2: keep the original seek and reporting; synchronize presentation after its position commit.
var seekState104=Types(app.MainModule.Types).Single(t=>t.FullName.StartsWith("EmbyDesktop.Services.MpvPlaybackSession/<SeekAsync>"));
var seekMove104=seekState104.Methods.Single(m=>m.Name=="MoveNext");Mark(seekMove104);
var seekOwner104=seekMove104.Body.Variables.Single(v=>v.VariableType.FullName=="EmbyDesktop.Services.MpvPlaybackSession");
var seekCommit104=seekMove104.Body.Instructions.Single(i=>i.OpCode==OpCodes.Stfld&&i.Operand is FieldReference f&&f.Name=="_position");
var seekLoad104=Instruction.Create(OpCodes.Ldloc,seekOwner104);
seekMove104.Body.GetILProcessor().InsertAfter(seekCommit104,seekLoad104);
seekMove104.Body.GetILProcessor().InsertAfter(seekLoad104,Instruction.Create(OpCodes.Call,Helper(app.MainModule,"PlayerSkipCountdown","SeekApplied")));
var startNext=Method(app,"EmbyDesktop.Services.MpvPlaybackSession","StartNextEpisodeCountdown");Mark(startNext);
var startNextOriginal=startNext.Body.Instructions[0];
Prefix(startNext,startNextOriginal,Instruction.Create(OpCodes.Ldarg_0),Instruction.Create(OpCodes.Ldarg_1),Instruction.Create(OpCodes.Call,Helper(app.MainModule,"PlayerSkipCountdown","StartNext")),Instruction.Create(OpCodes.Brfalse,startNextOriginal),Instruction.Create(OpCodes.Ret));
foreach(var pair in new[]{("ShowNextEpisodeCountdown","ShowNext"),("HideNextEpisodeActions","HideNext")})
{
    var method=Method(app,"EmbyDesktop.Controls.PlayerOverlay",pair.Item1);Mark(method);
    method.Body.Instructions.Clear();method.Body.Variables.Clear();method.Body.ExceptionHandlers.Clear();
    method.Body.Instructions.Add(Instruction.Create(OpCodes.Ldarg_0));
    if(method.Parameters.Count==1)method.Body.Instructions.Add(Instruction.Create(OpCodes.Ldarg_1));
    method.Body.Instructions.Add(Instruction.Create(OpCodes.Call,Helper(app.MainModule,"PlayerSkipCountdown",pair.Item2)));method.Body.Instructions.Add(Instruction.Create(OpCodes.Ret));
}
var countdownStart=Method(core,"EmbyDesktop.Core.Services.NextEpisodeCountdown","Start");Mark(countdownStart);
var fiveSeconds=countdownStart.Body.Instructions.Single(i=>i.OpCode==OpCodes.Ldc_I4&&Equals(i.Operand,5));fiveSeconds.Operand=3;
var pendingNext=Method(app,"EmbyDesktop.Services.MpvPlaybackSession","PlayPendingNextEpisode");Mark(pendingNext);
Prefix(pendingNext,pendingNext.Body.Instructions[0],Instruction.Create(OpCodes.Ldarg_0),Instruction.Create(OpCodes.Ldarg_1),Instruction.Create(OpCodes.Call,Helper(app.MainModule,"PlayerSkipCountdown","RememberNext")));
// Use the original authenticated client/cache for avatars, including restored shells.
var loadAvatar=Method(app,"EmbyDesktop.MainPage","LoadCurrentUserAvatarAsync");Mark(loadAvatar);
loadAvatar.Body.Instructions.Clear();loadAvatar.Body.Variables.Clear();loadAvatar.Body.ExceptionHandlers.Clear();
foreach(var op in new[]{OpCodes.Ldarg_0,OpCodes.Ldarg_1,OpCodes.Ldarg_2})loadAvatar.Body.Instructions.Add(Instruction.Create(op));
loadAvatar.Body.Instructions.Add(Instruction.Create(OpCodes.Call,Helper(app.MainModule,"AccountAvatars","Load")));loadAvatar.Body.Instructions.Add(Instruction.Create(OpCodes.Ret));
BeforeReturns(Method(app,"EmbyDesktop.MainPage","ShowShell"),"AccountAvatars","Refresh",preserveExclusiveEnds:true);
BeforeReturns(Method(app,"EmbyDesktop.MainPage","RefreshAccountPanel"),"AccountAvatars","Refresh",preserveExclusiveEnds:true);

// Only the missing-WinFsp case takes the read-only stream fallback.
var isoStart = Method(core, "EmbyDesktop.Core.Services.NetworkIsoMount", "StartAsync");
Mark(isoStart);
Prefix(isoStart, isoStart.Body.Instructions[0],
    Instruction.Create(OpCodes.Call, Helper(core.MainModule, "NetworkBluray", "NeedsFallback")),
    Instruction.Create(OpCodes.Brfalse, isoStart.Body.Instructions[0]),
    Instruction.Create(OpCodes.Ldarg, isoStart.Parameters[0]), Instruction.Create(OpCodes.Ldarg, isoStart.Parameters[1]),
    Instruction.Create(OpCodes.Ldarg, isoStart.Parameters[2]), Instruction.Create(OpCodes.Ldarg, isoStart.Parameters[5]),
    Instruction.Create(OpCodes.Call, Helper(core.MainModule, "NetworkBluray", "StartAsync")), Instruction.Create(OpCodes.Ret));
var isoDispose = Method(core, "EmbyDesktop.Core.Services.NetworkIsoMount", "DisposeAsync");
Mark(isoDispose);
Prefix(isoDispose, isoDispose.Body.Instructions[0], Instruction.Create(OpCodes.Ldarg_0),
    Instruction.Create(OpCodes.Call, Helper(core.MainModule, "NetworkBluray", "IsFallback")),
    Instruction.Create(OpCodes.Brfalse, isoDispose.Body.Instructions[0]), Instruction.Create(OpCodes.Ldarg_0),
    Instruction.Create(OpCodes.Call, Helper(core.MainModule, "NetworkBluray", "DisposeAsync")), Instruction.Create(OpCodes.Ret));
var resolveIso = Method(app, "EmbyDesktop.Services.MpvPlaybackSession", "ResolvePlaybackUriSafelyAsync");
Mark(resolveIso);
Prefix(resolveIso, resolveIso.Body.Instructions[0], Instruction.Create(OpCodes.Ldarg_0),
    Instruction.Create(OpCodes.Call, Helper(app.MainModule, "NetworkBluray", "IsFallbackSession")),
    Instruction.Create(OpCodes.Brfalse, resolveIso.Body.Instructions[0]), Instruction.Create(OpCodes.Ldarg_0),
    Instruction.Create(OpCodes.Call, Helper(app.MainModule, "NetworkBluray", "Resolve")), Instruction.Create(OpCodes.Ret));
var playIso = Method(app, "EmbyDesktop.Services.MpvPlaybackSession", "PlayCurrentItemAsync");
Mark(playIso);
Prefix(playIso, playIso.Body.Instructions[0], Instruction.Create(OpCodes.Ldarg_0),
    Instruction.Create(OpCodes.Call, Helper(app.MainModule, "NetworkBluray", "Register")));
// A single core prevents cached P/Invoke pointers from mixing native objects.
Prefix(playIso, playIso.Body.Instructions[0], Instruction.Create(OpCodes.Ldarg_0),
    Instruction.Create(OpCodes.Call, Helper(app.MainModule, "DolbyVision", "Configure")));
var startMpvState = Types(app.MainModule.Types).Single(t => t.FullName.StartsWith("EmbyDesktop.Services.MpvPlaybackSession/<StartAsync>"));
var startMpv = startMpvState.Methods.Single(m => m.Name == "MoveNext");
Mark(startMpv);
var oldCorePath = startMpv.Body.Instructions.Single(i => i.OpCode == OpCodes.Ldstr && Equals(i.Operand, "libmpv-2.dll")).Next;
if (oldCorePath.Operand is not MethodReference combinePath || combinePath.Name != "Combine") throw new InvalidOperationException("Unexpected core path shape");
var discardPath = Instruction.Create(OpCodes.Pop);
startMpv.Body.GetILProcessor().InsertAfter(oldCorePath, discardPath);
startMpv.Body.GetILProcessor().InsertAfter(discardPath, Instruction.Create(OpCodes.Call, Helper(app.MainModule, "DolbyVision", "CorePath")));
// Keep the original real-window Show and async awaiter. Only defer its existing
// media-load call until the background ISO directory/title preparation is ready.
var initialPlay = startMpv.Body.Instructions.Single(i => i.Operand is MethodReference m
    && m.DeclaringType.FullName == "EmbyDesktop.Services.MpvPlaybackSession" && m.Name == "PlayCurrentItemAsync");
var showPlayer = startMpv.Body.Instructions.Single(i => i.Operand is MethodReference m
    && m.DeclaringType.FullName == "Richasy.MpvKernel.WinUI.MpvPlayerWindow" && m.Name == "Show");
if (startMpv.Body.Instructions.IndexOf(showPlayer) >= startMpv.Body.Instructions.IndexOf(initialPlay)
    || initialPlay.Operand is not MethodReference originalInitialPlay || originalInitialPlay.Parameters.Count != 2)
    throw new InvalidOperationException("Unexpected real player preparation boundary");
var preparedPlay = Helper(app.MainModule, "BlurayPreparation", "PlayWhenPrepared");
if (preparedPlay.Parameters.Count != 3 || preparedPlay.ReturnType.FullName != originalInitialPlay.ReturnType.FullName
    || !preparedPlay.Parameters.Skip(1).Select(p => p.ParameterType.FullName).SequenceEqual(originalInitialPlay.Parameters.Select(p => p.ParameterType.FullName)))
    throw new InvalidOperationException("Prepared playback boundary signature mismatch");
initialPlay.OpCode = OpCodes.Call; initialPlay.Operand = preparedPlay;
var closePreparationState = Types(app.MainModule.Types).Single(t => t.FullName.StartsWith("EmbyDesktop.Services.MpvPlaybackSession/<CloseAsync>"));
var closePreparation = closePreparationState.Methods.Single(m => m.Name == "MoveNext");
Mark(closePreparation);
var beginClose = closePreparation.Body.Instructions.Single(i => i.Operand is MethodReference m
    && m.DeclaringType.FullName == "EmbyDesktop.Core.Services.PlaybackLifecycle" && m.Name == "BeginClose");
if (beginClose.Next.OpCode != OpCodes.Brtrue || beginClose.Next.Operand is not Instruction closeAccepted)
    throw new InvalidOperationException("Unexpected successful close boundary");
var closingSession = closePreparation.Body.Variables.Single(v => v.VariableType.FullName == "EmbyDesktop.Services.MpvPlaybackSession");
Prefix(closePreparation, closeAccepted, Instruction.Create(OpCodes.Ldloc, closingSession),
    Instruction.Create(OpCodes.Call, Helper(app.MainModule, "BlurayPreparation", "Cancel")),
    Instruction.Create(OpCodes.Ldloc, closingSession),
    Instruction.Create(OpCodes.Call, Helper(app.MainModule, "NativeDolby", "BeginClose")));
var dvWindowDispose=Method(windowUi,"Richasy.MpvKernel.WinUI.MpvPlayerWindow","DisposeAsync");
Mark(dvWindowDispose);
Prefix(dvWindowDispose,dvWindowDispose.Body.Instructions[0],Instruction.Create(OpCodes.Ldarg_0),
    Instruction.Create(OpCodes.Call,Helper(windowUi.MainModule,"NativeDolby","WindowClosing")));
BeforeReturns(Method(app, "EmbyDesktop.Services.MpvPlaybackSession", "OnCurrentFileLoaded"), "DolbyVision", "Report");
// Only change transport at the existing media-load boundary. Keep header
// filtering, signed-link refresh, resume offsets and loadfile options intact.
var playState = Types(app.MainModule.Types).Single(t => t.FullName.StartsWith("EmbyDesktop.Services.MpvPlaybackSession/<PlayCurrentItemAsync>"));
var playMove = playState.Methods.Single(m => m.Name == "MoveNext");
Mark(playMove);
var selectRoute = playMove.Body.Instructions.Single(i => i.Operand is MethodReference m && m.DeclaringType.Name == "PlaybackRouteSelectionPolicy" && m.Name == "Select");
selectRoute.OpCode = OpCodes.Call; selectRoute.Operand = Helper(app.MainModule, "PlaybackTransport", "Select");
var mediaUriLoad = playMove.Body.Instructions.Single(i => i.Operand is MethodReference m && m.DeclaringType.Name == "PlaybackRouteSelection" && m.Name == "get_PlaybackUri"
    && i.Next.Operand is MethodReference text && text.Name == "ToString").Next;
if (mediaUriLoad.Operand is not MethodReference uriText || uriText.Name != "ToString") throw new InvalidOperationException("Unexpected playback address shape");
mediaUriLoad.OpCode = OpCodes.Call; mediaUriLoad.Operand = Helper(app.MainModule, "PlaybackTransport", "MediaAddress");
var loadMedia = playMove.Body.Instructions.Single(i => i.Operand is MethodReference m && m.Name == "PlayAsync" && m.DeclaringType.Name == "MpvClient");
var playSession = playMove.Body.Variables.Single(v => v.VariableType.FullName == "EmbyDesktop.Services.MpvPlaybackSession");
Prefix(playMove, loadMedia, Instruction.Create(OpCodes.Ldloc, playSession),
    Instruction.Create(OpCodes.Call, Helper(app.MainModule, "PlaybackTransport", "PrepareMedia")));
var createMpv = startMpv.Body.Instructions.Single(i => i.Operand is MethodReference m && m.DeclaringType.Name == "MpvClient" && m.Name == "CreateAsync");
if (createMpv.Previous.OpCode != OpCodes.Ldnull) throw new InvalidOperationException("Unexpected native logger shape");
createMpv.Previous.OpCode = OpCodes.Call; createMpv.Previous.Operand = Helper(app.MainModule, "PlaybackTransport", "Logger");
var seekState = Types(app.MainModule.Types).Single(t => t.FullName.StartsWith("EmbyDesktop.Services.MpvPlaybackSession/<SeekAsync>"));
var seekMove = seekState.Methods.Single(m => m.Name == "MoveNext");
Mark(seekMove);
var timeSeek = seekMove.Body.Instructions.Single(i => i.Operand is MethodReference m && m.Name == "SetCurrentPositionAsync");
timeSeek.OpCode = OpCodes.Call; timeSeek.Operand = Helper(app.MainModule, "PlaybackTransport", "Seek");
var notifyMpv = Method(app, "EmbyDesktop.Services.MpvPlaybackSession", "OnMpvDataNotify");
Mark(notifyMpv);
Prefix(notifyMpv, notifyMpv.Body.Instructions[0], Instruction.Create(OpCodes.Ldarg_0),
    Instruction.Create(OpCodes.Ldarg, notifyMpv.Parameters[1]), Instruction.Create(OpCodes.Call, Helper(app.MainModule, "PlaybackTransport", "Notify")));
// Passive diagnostics: keep every original request and release instruction.
var telemetryActions = new (string Method, string Action, string Kind)[]
{
    ("OnTogglePlayRequested", "toggle-play", "none"),
    ("OnSeekRequested", "seek", "number"),
    ("OnVolumeChanged", "volume", "number"),
    ("OnSpeedChanged", "speed", "number"),
    ("OnAudioTrackRequested", "audio-track", "track"),
    ("OnSubtitleTrackRequested", "subtitle-track", "track"),
    ("OnFullScreenRequested", "fullscreen", "none"),
    ("OnExitFullScreenRequested", "exit-fullscreen", "none"),
    ("OnEpisodeRequested", "episode", "none"),
    ("OnRetryPlaybackRequested", "retry", "none"),
    ("OnClosePlaybackRequested", "close", "none")
};
foreach (var (name, action, kind) in telemetryActions)
{
    var method = Method(app, "EmbyDesktop.Services.MpvPlaybackSession", name);
    Mark(method);
    Prefix(method, method.Body.Instructions[0], Instruction.Create(OpCodes.Ldarg_0), Instruction.Create(OpCodes.Ldstr, action),
        kind == "none" ? Instruction.Create(OpCodes.Ldc_R8, double.NaN) : Instruction.Create(OpCodes.Ldarg, method.Parameters[1]),
        Instruction.Create(OpCodes.Call, Helper(app.MainModule, "PlaybackTelemetry", kind == "track" ? "Track" : "Action")));
}
var telemetryDispose = Method(app, "EmbyDesktop.Services.MpvPlaybackSession", "DisposeCoreAsync");
Mark(telemetryDispose);
Prefix(telemetryDispose, telemetryDispose.Body.Instructions[0],
    Instruction.Create(OpCodes.Ldarg_0), Instruction.Create(OpCodes.Call, Helper(app.MainModule, "NativeDolby", "BeginClose")),
    Instruction.Create(OpCodes.Ldarg_0), Instruction.Create(OpCodes.Call, Helper(app.MainModule, "PlaybackTelemetry", "Stop")));
var sessionDispose=Method(app,"EmbyDesktop.Services.MpvPlaybackSession","DisposeAsync");
var cleanupDelegate=sessionDispose.Body.Instructions.Single(i=>i.OpCode==OpCodes.Newobj&&i.Operand is MethodReference m&&m.DeclaringType is GenericInstanceType g&&g.ElementType.FullName=="System.Func`1"&&g.GenericArguments.Single().FullName=="System.Threading.Tasks.Task");
Mark(sessionDispose);
var dispatchOwner=Instruction.Create(OpCodes.Ldarg_0);
sessionDispose.Body.GetILProcessor().InsertAfter(cleanupDelegate,dispatchOwner);
sessionDispose.Body.GetILProcessor().InsertAfter(dispatchOwner,Instruction.Create(OpCodes.Call,Helper(app.MainModule,"PlayerShutdown","Dispatch")));
var eofCleanup=Types(app.MainModule.Types).Single(t=>t.Name.StartsWith("<HandleFileEndAsync>d__")).Methods.Single(m=>m.Name=="MoveNext");
var eofClose=eofCleanup.Body.Instructions.Single(i=>i.Operand is MethodReference m&&m.DeclaringType.FullName=="EmbyDesktop.Services.MpvPlaybackSession"&&m.Name=="CloseAsync");
Mark(eofCleanup);eofClose.OpCode=OpCodes.Call;eofClose.Operand=Helper(app.MainModule,"PlayerShutdown","Close");
// 1.2.2: keep the entire natural-end state machine; only wrap its Task.
var crossEnd = Method(app, "EmbyDesktop.Services.MpvPlaybackSession", "HandleFileEndAsync");
var crossOriginal = new MethodDefinition("HandleFileEndBeforeCrossSeasonAsync", MethodAttributes.Private | MethodAttributes.HideBySig, crossEnd.ReturnType);
crossEnd.DeclaringType.Methods.Add(crossOriginal);
crossOriginal.Body = crossEnd.Body;
crossOriginal.DebugInformation.SequencePoints.Clear();
crossEnd.Body = new MethodBody(crossEnd);
crossEnd.DebugInformation.SequencePoints.Clear();
crossEnd.DebugInformation.Scope = null;
Mark(crossEnd); Mark(crossOriginal);
var crossIl = crossEnd.Body.GetILProcessor();
crossIl.Append(Instruction.Create(OpCodes.Ldarg_0));
crossIl.Append(Instruction.Create(OpCodes.Ldarg_0));
crossIl.Append(Instruction.Create(OpCodes.Ldftn, crossOriginal));
crossIl.Append(Instruction.Create(OpCodes.Newobj, app.MainModule.ImportReference(typeof(Func<Task>).GetConstructor(new[]{typeof(object),typeof(IntPtr)})!)));
crossIl.Append(Instruction.Create(OpCodes.Call, Helper(app.MainModule, "CrossSeasonContinuation", "Handle")));
crossIl.Append(Instruction.Create(OpCodes.Ret));
foreach (var name in new[]{"CancelNextEpisode", "OnSeekRequested", "OnEpisodeRequested", "OnRetryPlaybackRequested", "DisposeAsync"})
{
    var cancel = Method(app, "EmbyDesktop.Services.MpvPlaybackSession", name);
    Mark(cancel);
    Prefix(cancel, cancel.Body.Instructions[0], Instruction.Create(OpCodes.Ldarg_0), Instruction.Create(OpCodes.Call, Helper(app.MainModule, "CrossSeasonContinuation", "Cancel")));
}
var nativeProperty = Method(kernelCore, "Richasy.MpvKernel.Core.MpvClient", "HandleObservePropertyChanged");
Mark(nativeProperty);
Prefix(nativeProperty, nativeProperty.Body.Instructions[0], Instruction.Create(OpCodes.Ldarg_0), Instruction.Create(OpCodes.Ldarg, nativeProperty.Parameters[0]),
    Instruction.Create(OpCodes.Call, Helper(kernelCore.MainModule, "PlaybackTelemetry", "Property")));
// Position metadata can be set to the saved resume offset while still Seeking.
// It is not a first frame. Keep the existing Playing/PlaybackRestart readiness.
var prematureReady = notifyMpv.Body.Instructions.Where(i => i.Operand is MethodReference m && m.Name == "MarkPlaybackStarted").ToArray();
if (prematureReady.Length != 3) throw new InvalidOperationException("Unexpected playback readiness shape");
prematureReady[0].OpCode = OpCodes.Pop; prematureReady[0].Operand = null;
// 1.2.2: progress-aware bounded startup and synchronous native end-reason gate.
var startupWatch = Types(app.MainModule.Types).Single(t => t.Name.StartsWith("<WatchForFirstFrameAsync>d__")).Methods.Single(m => m.Name == "MoveNext");
Mark(startupWatch);
var startupDelay = startupWatch.Body.Instructions.Single(i => i.Operand is MethodReference m && m.DeclaringType.FullName == "System.Threading.Tasks.Task" && m.Name == "Delay");
var startupSession = startupWatch.Body.Variables.Single(v => v.VariableType.FullName == "EmbyDesktop.Services.MpvPlaybackSession");
Prefix(startupWatch, startupDelay, Instruction.Create(OpCodes.Ldloc, startupSession));
startupDelay.Operand = Helper(app.MainModule, "BlurayStartup", "Delay");
startupWatch.Body.Instructions.Single(i => Equals(i.Operand, "FirstFrameTimeout.20s")).Operand = "FirstFrameTimeout";
var endEventEntry = Method(kernelCore, "Richasy.MpvKernel.Core.MpvClient", "HandleEvent");
Mark(endEventEntry);
Prefix(endEventEntry, endEventEntry.Body.Instructions[0], Instruction.Create(OpCodes.Ldarg_1),
    Instruction.Create(OpCodes.Call, Helper(kernelCore.MainModule, "PlaybackDiagnostics", "NormalizeEnd")),
    Instruction.Create(OpCodes.Starg, endEventEntry.Parameters[0]));
Prefix(endEventEntry, endEventEntry.Body.Instructions[0], Instruction.Create(OpCodes.Ldarg_0),
    Instruction.Create(OpCodes.Ldarg_1), Instruction.Create(OpCodes.Call, Helper(kernelCore.MainModule, "BlurayStartup", "IgnoreControlEnd")),
    Instruction.Create(OpCodes.Brfalse, endEventEntry.Body.Instructions[0]), Instruction.Create(OpCodes.Ret));
// End 1.2.2 startup hooks.
var retryIso = Method(app, "EmbyDesktop.Services.MpvPlaybackSession", "RefreshPlaybackRouteAsync");
Mark(retryIso);
Prefix(retryIso, retryIso.Body.Instructions[0], Instruction.Create(OpCodes.Ldarg_0),
    Instruction.Create(OpCodes.Call, Helper(app.MainModule, "NetworkBluray", "IsFallbackSession")),
    Instruction.Create(OpCodes.Brfalse, retryIso.Body.Instructions[0]), Instruction.Create(OpCodes.Ldarg_0),
    Instruction.Create(OpCodes.Call, Helper(app.MainModule, "NetworkBluray", "Replay")), Instruction.Create(OpCodes.Ret));

// Only the resume-card landscape branch is reordered. Existing cache decoding,
// refresh, initialization network gate and completion state handling remain intact.
var resumeState = Types(app.MainModule.Types).Single(t => t.Name.StartsWith("<LoadCardPosterAsync>d__"));
var resumeMove = resumeState.Methods.Single(m => m.Name == "MoveNext");
Mark(resumeMove);
var resumePage = resumeMove.Body.Variables.Single(v => v.VariableType.FullName == "EmbyDesktop.MainPage");
var candidateCall = resumeMove.Body.Instructions.Single(i => i.Operand is MethodReference m && m.Name == "GetLandscapeCandidates");
Prefix(resumeMove, candidateCall, Instruction.Create(OpCodes.Ldloc, resumePage));
candidateCall.Operand = Helper(app.MainModule, "ResumeArtwork", "Candidates");
var candidateField = resumeState.Fields.Single(f => f.FieldType.Name == "MediaArtworkCandidate");
var closureField = resumeState.Fields.Single(f => f.Name == "<>8__1");
var cardField = closureField.FieldType.Resolve().Fields.Single(f => f.Name == "card");
// Recheck actual visibility in the load entry, completion/retry decisions, and
// original download predicate. A queued first card must also be on screen.
foreach (var method in new[] { resumeMove }.Concat(closureField.FieldType.Resolve().Methods.Where(m => m.Name.Contains("IsStillNeeded"))))
{
    Mark(method);
    foreach (var instruction in method.Body.Instructions.Where(i => i.Operand is MethodReference m && m.Name == "get_IsNearViewport"))
        instruction.Operand = inViewport;
}
var itemGetter = resumeMove.Body.Instructions.Where(i => i.Operand is MethodReference m && m.Name == "get_Item").Select(i => (MethodReference)i.Operand).First();
var contained = resumeMove.Body.Instructions.Where(i => i.Operand is MethodReference m && m.Name == "SetContainedPoster").First();
contained.OpCode = OpCodes.Call;
contained.Operand = Helper(app.MainModule, "DetailProgress", "SetContained");
Prefix(resumeMove, contained.Next, Instruction.Create(OpCodes.Ldloc, resumePage),
    Instruction.Create(OpCodes.Ldarg_0), Instruction.Create(OpCodes.Ldfld, closureField),
    Instruction.Create(OpCodes.Ldfld, cardField), Instruction.Create(OpCodes.Callvirt, itemGetter),
    Instruction.Create(OpCodes.Ldarg_0), Instruction.Create(OpCodes.Ldfld, candidateField),
    Instruction.Create(OpCodes.Call, Helper(app.MainModule, "ResumeArtwork", "Remember")));

// Check the original cache downloader immediately before it creates a network token.
// This also catches requests queued before the background task started.
var posterState = Types(core.MainModule.Types).Single(t => t.Name.StartsWith("<GetOrDownloadAsync>d__"));
// Scope detail cache aliases to _detail. Preserve legacy browse dependencies
// by copying their exact image into the browse cache before a cache lookup.
foreach (string cacheMethod in new[] { "TryGetCached", "GetOrDownloadAsync", "RegisterExistingArtwork" })
{
    var method = Method(core, "EmbyDesktop.Core.Services.PosterCacheService", cacheMethod);
    Mark(method);
    Prefix(method, method.Body.Instructions[0], Instruction.Create(OpCodes.Ldarg_0),
        Instruction.Create(OpCodes.Ldarg, method.Parameters[0]),
        Instruction.Create(OpCodes.Call, Helper(core.MainModule, "ArtworkStorage", "PrepareBrowse")));
}
foreach (var (cacheMethod, helperMethod) in new[] { ("BuildSharedAliasPath", "Alias"), ("WorkAliasPaths", "WorkAliases") })
{
    var method = Method(core, "EmbyDesktop.Core.Services.PosterCacheService", cacheMethod);
    Mark(method);
    foreach (var ret in method.Body.Instructions.Where(i => i.OpCode == OpCodes.Ret).ToArray())
        Prefix(method, ret, Instruction.Create(OpCodes.Ldarg_0), Instruction.Create(OpCodes.Ldarg, method.Parameters[0]),
            Instruction.Create(OpCodes.Call, Helper(core.MainModule, "ArtworkStorage", helperMethod)));
}
var movePoster = posterState.Methods.Single(m => m.Name == "MoveNext");
Mark(movePoster);
var networkCall = movePoster.Body.Instructions.Single(i => i.Operand is MethodReference m && m.Name == "TryCreateNetworkCancellation");
int networkIndex = movePoster.Body.Instructions.IndexOf(networkCall);
var networkStart = movePoster.Body.Instructions[networkIndex - 5];
var fallback = networkCall.Next.Next;
if (fallback.OpCode != OpCodes.Ldarg_0 && fallback.OpCode != OpCodes.Ldarg) throw new InvalidOperationException("Unexpected poster fallback shape");
Prefix(movePoster, networkStart, Instruction.Create(OpCodes.Ldarg_0), Instruction.Create(OpCodes.Ldfld, posterState.Fields.Single(f => f.Name == "deferTrim")),
    Instruction.Create(OpCodes.Call, Helper(core.MainModule, "BackgroundArtwork", "AllowNetwork")), Instruction.Create(OpCodes.Brfalse, fallback));
var imageDownloadCall = Types(core.MainModule.Types).SelectMany(t => t.Methods).Where(m => m.HasBody)
    .SelectMany(m => m.Body.Instructions.Where(i => i.Operand is MethodReference r && r.Name == "DownloadAtomicallyAsync").Select(i => (method: m, instruction: i))).Single();
Mark(imageDownloadCall.method);
imageDownloadCall.instruction.OpCode = OpCodes.Call;
imageDownloadCall.instruction.Operand = Helper(core.MainModule, "ArtworkFeedback", "Download");
var imageRetry = Method(core, "EmbyDesktop.Core.Services.PosterCacheService", "GetRetryDelay");
Mark(imageRetry);
foreach (var ret in imageRetry.Body.Instructions.Where(i => i.OpCode == OpCodes.Ret).ToArray())
    Prefix(imageRetry, ret, Instruction.Create(OpCodes.Ldarg_0), Instruction.Create(OpCodes.Ldarg, imageRetry.Parameters[0]),
        Instruction.Create(OpCodes.Call, Helper(core.MainModule, "ArtworkFeedback", "RetryDelay")));

// Keep PlaybackInfo's session identity on every constructed server route.
// The original PreparePlaybackUriAsync retains selection, timeout, redirect
// and cancellation logic inside an isolated asynchronous scope.
var prepareRouteState = Types(app.MainModule.Types).Single(t => t.FullName.StartsWith("EmbyDesktop.MainPage/<PreparePlaybackWithRetryAsync>"));
var prepareRouteMove = prepareRouteState.Methods.Single(m => m.Name == "MoveNext");
var preparedInfo = prepareRouteState.Fields.Single(f => f.FieldType.FullName == "EmbyDesktop.Core.Models.PlaybackInfoResponse");
var isoRouteState = Types(app.MainModule.Types).Single(t => t.FullName.StartsWith("EmbyDesktop.MainPage/<StartNetworkIsoPlaybackAsync>"));
var isoRouteMove = isoRouteState.Methods.Single(m => m.Name == "MoveNext");
var preparedDisc = isoRouteState.Fields.Single(f => f.Name == "prepared");
var preparedInfoGetter = preparedDisc.FieldType.Resolve().Methods.Single(m => m.Name == "get_PlaybackInfo");
var refreshRouteState = Types(app.MainModule.Types).Single(t => t.FullName.StartsWith("EmbyDesktop.Services.MpvPlaybackSession/<RefreshPlaybackRouteAsync>"));
var refreshRouteMove = refreshRouteState.Methods.Single(m => m.Name == "MoveNext");
foreach (var routeMethod in new[] { prepareRouteMove, isoRouteMove, refreshRouteMove })
{
    Mark(routeMethod);
    var construct = routeMethod.Body.Instructions.Single(i => i.Operand is MethodReference m && m.DeclaringType.Name == "EmbyApiClient" && m.Name == "BuildPlaybackUri");
    if (routeMethod == prepareRouteMove)
        Prefix(routeMethod, construct, Instruction.Create(OpCodes.Ldarg_0), Instruction.Create(OpCodes.Ldfld, preparedInfo));
    else if (routeMethod == isoRouteMove)
        Prefix(routeMethod, construct, Instruction.Create(OpCodes.Ldarg_0), Instruction.Create(OpCodes.Ldfld, preparedDisc),
            Instruction.Create(OpCodes.Callvirt, app.MainModule.ImportReference(preparedInfoGetter)));
    else
        Prefix(routeMethod, construct, Instruction.Create(OpCodes.Ldloc,
            routeMethod.Body.Variables.Single(v => v.VariableType.FullName == "EmbyDesktop.Core.Models.PlaybackInfoResponse")));
    construct.OpCode = OpCodes.Call;
    construct.Operand = Helper(app.MainModule, "PlaybackRouteIdentity", "Build");
}
var prepareRouteCall = prepareRouteMove.Body.Instructions.Single(i => i.Operand is MethodReference m && m.DeclaringType.Name == "EmbyApiClient" && m.Name == "PreparePlaybackUriAsync");
Prefix(prepareRouteMove, prepareRouteCall, Instruction.Create(OpCodes.Ldarg_0), Instruction.Create(OpCodes.Ldfld, preparedInfo));
prepareRouteCall.OpCode = OpCodes.Call;
prepareRouteCall.Operand = Helper(app.MainModule, "PlaybackRouteIdentity", "Prepare");
var constructServerRoute = Method(core, "EmbyDesktop.Core.Services.EmbyApiClient", "BuildPlaybackUri");
Mark(constructServerRoute);
foreach (var routeReturn in constructServerRoute.Body.Instructions.Where(i => i.OpCode == OpCodes.Ret).ToArray())
    Prefix(constructServerRoute, routeReturn, Instruction.Create(OpCodes.Ldarg_0),
        Instruction.Create(OpCodes.Call, Helper(core.MainModule, "PlaybackRouteIdentity", "WithCurrent")));

// 1.2.2: same-origin media authentication and redirect boundary.
// Insert before final OptimizeMacros/write, after the existing route hooks.
// This snippet uses Program's Types, Method, Mark, Prefix and Helper locals.
var mediaPreflightState = Types(core.MainModule.Types).Single(t =>
    t.FullName.StartsWith("EmbyDesktop.Core.Services.EmbyApiClient/<ResolveMediaUriAsync>", StringComparison.Ordinal));
var mediaPreflightMove = mediaPreflightState.Methods.Single(m => m.Name == "MoveNext");
var mediaPreflightClient = mediaPreflightState.Fields.Single(f =>
    f.Name == "<>4__this" && f.FieldType.FullName == "EmbyDesktop.Core.Services.EmbyApiClient");
var mediaPreflightHeaders = mediaPreflightMove.Body.Instructions.Single(i => i.Operand is MethodReference m
    && m.DeclaringType.FullName == "EmbyDesktop.Core.Services.EmbyApiClient" && m.Name == "BuildEffectivePlaybackHeaders");
Mark(mediaPreflightMove);
Prefix(mediaPreflightMove, mediaPreflightHeaders, Instruction.Create(OpCodes.Ldarg_0),
    Instruction.Create(OpCodes.Ldfld, mediaPreflightClient));
mediaPreflightHeaders.OpCode = OpCodes.Call;
mediaPreflightHeaders.Operand = Helper(core.MainModule, "MediaRequestIdentity", "BuildHeaders");

var mediaSessionHeaders = Method(app, "EmbyDesktop.Services.MpvPlaybackSession", "BuildPlaybackHeaders");
var mediaSessionClient = mediaSessionHeaders.DeclaringType.Fields.Single(f =>
    f.Name == "_embyClient" && f.FieldType.FullName == "EmbyDesktop.Core.Services.EmbyApiClient");
var mediaSessionEffective = mediaSessionHeaders.Body.Instructions.Single(i => i.Operand is MethodReference m
    && m.DeclaringType.FullName == "EmbyDesktop.Core.Services.EmbyApiClient" && m.Name == "BuildEffectivePlaybackHeaders");
Mark(mediaSessionHeaders);
Prefix(mediaSessionHeaders, mediaSessionEffective, Instruction.Create(OpCodes.Ldarg_0),
    Instruction.Create(OpCodes.Ldfld, mediaSessionClient));
mediaSessionEffective.OpCode = OpCodes.Call;
mediaSessionEffective.Operand = Helper(app.MainModule, "MediaRequestIdentity", "BuildHeaders");

var mediaIsoState = Types(app.MainModule.Types).Single(t =>
    t.FullName.StartsWith("EmbyDesktop.MainPage/<StartNetworkIsoPlaybackAsync>", StringComparison.Ordinal));
var mediaIsoMove = mediaIsoState.Methods.Single(m => m.Name == "MoveNext");
var mediaIsoClient = mediaIsoState.Fields.Single(f =>
    f.FieldType.FullName == "EmbyDesktop.Core.Services.EmbyApiClient");
var mediaIsoStart = mediaIsoMove.Body.Instructions.Single(i => i.Operand is MethodReference m
    && m.DeclaringType.FullName == "EmbyDesktop.Core.Services.NetworkIsoMount" && m.Name == "StartAsync" && m.Parameters.Count == 6);
Mark(mediaIsoMove);
Prefix(mediaIsoMove, mediaIsoStart, Instruction.Create(OpCodes.Ldarg_0), Instruction.Create(OpCodes.Ldfld, mediaIsoClient));
mediaIsoStart.OpCode = OpCodes.Call;
mediaIsoStart.Operand = Helper(app.MainModule, "MediaRequestIdentity", "PrepareIso");

// The shared filter is used by Core preflight and NetworkIsoSource.OpenRangeAsync.
// Extend its existing refusal list without replacing the old comparisons.
var mediaSensitive = Method(core, "EmbyDesktop.Core.Services.EmbyApiClient", "IsSensitiveCrossOriginHeader");
Mark(mediaSensitive);
var mediaSensitiveOriginal = mediaSensitive.Body.Instructions[0];
var mediaSensitiveEquals = mediaSensitive.Body.Instructions.Select(i => i.Operand).OfType<MethodReference>().First(m =>
    m.DeclaringType.FullName == "System.String" && m.Name == "Equals" && m.HasThis
    && m.Parameters.Count == 2 && m.Parameters[0].ParameterType.FullName == "System.String"
    && m.Parameters[1].ParameterType.FullName == "System.StringComparison");
Prefix(mediaSensitive, mediaSensitiveOriginal,
    Instruction.Create(OpCodes.Ldarg_0), Instruction.Create(OpCodes.Ldstr, "X-Emby-Authorization"),
    Instruction.Create(OpCodes.Ldc_I4, (int)StringComparison.OrdinalIgnoreCase), Instruction.Create(OpCodes.Callvirt, mediaSensitiveEquals),
    Instruction.Create(OpCodes.Brfalse, mediaSensitiveOriginal), Instruction.Create(OpCodes.Ldc_I4_1), Instruction.Create(OpCodes.Ret));

// Classify the existing media403 response without exposing body values.
var mediaErrorState = Types(core.MainModule.Types).Single(t => t.FullName.StartsWith("EmbyDesktop.Core.Services.EmbyApiClient/<CreateApiExceptionAsync>"));
var mediaErrorMove = mediaErrorState.Methods.Single(m => m.Name == "MoveNext");
Mark(mediaErrorMove);
var mediaForbidden = mediaErrorMove.Body.Instructions.Single(i => i.OpCode == OpCodes.Ldstr && Equals(i.Operand, "媒体路线请求被拒绝（403），可能是直链已失效或上游校验不一致。"));
mediaForbidden.OpCode = OpCodes.Ldloc; mediaForbidden.Operand = mediaErrorMove.Body.Variables[3];
mediaErrorMove.Body.GetILProcessor().InsertAfter(mediaForbidden, Instruction.Create(OpCodes.Call, Helper(core.MainModule, "MediaFailureDiagnostics", "Forbidden")));
// End 1.2.2 media-authentication patch.

MpvHttpHeadersPatch.Apply(kernelCore, helper, Mark);
WallPosterPatch.Apply(app, helper, Mark);

// Expand the existing rotation in place. Preserve the original write lock,
// redaction, naming, export and failure behavior; no current log is opened here.
var logRotation = Method(app, "EmbyDesktop.Services.AppLog", "RotateIfNeeded");
Mark(logRotation);
foreach (var (oldValue, newValue) in new[] { (8388608, 16777216), (7, 15), (6, 14) })
{
    var limit = logRotation.Body.Instructions.Single(i => i.OpCode == OpCodes.Ldc_I4 && (int)i.Operand == oldValue);
    limit.Operand = newValue;
}
var retention = Method(app, "EmbyDesktop.Services.AppLog", "get_RetentionDescription");
Mark(retention);
retention.Body.Instructions.Single(i => i.OpCode == OpCodes.Ldstr).Operand = "持续跨启动保留；单个文件约 16 MiB，共 16 份（约 256 MiB）";
var logWriter = Method(app, "EmbyDesktop.Services.AppLog", "WriteCore");
Mark(logWriter);
Prefix(logWriter, logWriter.Body.Instructions[0], Instruction.Create(OpCodes.Ldarg, logWriter.Parameters[2]),
    Instruction.Create(OpCodes.Call, Method(app, "EmbyDesktop.Services.AppLog", "GetVersion")),
    Instruction.Create(OpCodes.Call, Helper(app.MainModule, "LogVersions", "Annotate")),
    Instruction.Create(OpCodes.Starg, logWriter.Parameters[2]));

const string shortcuts = "点击下方按键可自定义播放／暂停、静音、全屏及音量快捷键。\n← / →：定位；长按 → 临时 3 倍速，松开恢复。J / L：定位 10 秒。\n[ / ]：倍速 ±0.25；Backspace：恢复 1 倍速；Esc：退出全屏。\n输入框、字幕/音轨菜单和选集面板内保留原有键盘操作。";
foreach (var assembly in new[] { app, core })
foreach (var method in Types(assembly.MainModule.Types).SelectMany(t => t.Methods).Where(m => m.HasBody))
{
    foreach (var ins in method.Body.Instructions)
    {
        if (ins.OpCode != OpCodes.Ldstr || ins.Operand is not string value) continue;
        if (value.StartsWith("空格：播放/暂停") && value.Contains("进度条")) { ins.Operand = shortcuts; touched.Add(method.FullName); }
        else if (value is "0.2.5" or "0.2.5.0") { ins.Operand = value.Replace("0.2.5", "1.2.2"); touched.Add(method.FullName); }
    }
}
AudioControlPatch.Apply(app, helper);
SubtitleSelectionPatch.Apply(app, helper);
WindowClosePatch.Apply(app, windowUi, helper, touched);
// Stop the core while its parent windows and the UI message pump are alive.
// Preserve the complete original disposal body and its progress/once gates.
var releaseState=Types(app.MainModule.Types).Single(t=>t.FullName.StartsWith("EmbyDesktop.Services.MpvPlaybackSession/<DisposeCoreAsync>"));
var releaseBody=releaseState.Methods.Single(m=>m.Name=="MoveNext");
var releaseOwner=releaseBody.Body.Variables.Single(v=>v.VariableType.FullName=="EmbyDesktop.Services.MpvPlaybackSession");
var windowRelease=releaseBody.Body.Instructions.Single(i=>i.Operand is MethodReference m&&m.DeclaringType.FullName=="Richasy.MpvKernel.WinUI.MpvPlayerWindow"&&m.Name=="DisposeAsync");
Mark(releaseBody);
Prefix(releaseBody,windowRelease,Instruction.Create(OpCodes.Ldloc,releaseOwner));
windowRelease.OpCode=OpCodes.Call;windowRelease.Operand=Helper(app.MainModule,"PlayerShutdown","DisposeWindow");
// Trace the two synchronous host operations separately, without swallowing
// errors or changing their implementation/order relative to one another.
Mark(dvWindowDispose);
foreach(var instruction in dvWindowDispose.Body.Instructions){
    if(instruction.Operand is not MethodReference called)continue;
    if(called.DeclaringType.FullName=="Microsoft.UI.Xaml.Hosting.DesktopWindowXamlSource"&&called.Name=="Dispose"){
        instruction.OpCode=OpCodes.Call;instruction.Operand=Helper(windowUi.MainModule,"PlayerShutdown","DisposeXaml");
    }else if(called.DeclaringType.FullName=="Microsoft.UI.Windowing.AppWindow"&&called.Name=="Destroy"){
        instruction.OpCode=OpCodes.Call;instruction.Operand=Helper(windowUi.MainModule,"PlayerShutdown","DestroyHost");
    }
}

foreach (var changed in CachePathsPatch.Apply(app, core, helper)) touched.Add(changed);
BrowseCachePatch.Apply(app, core, helper, Mark);
VideoCachePatch.Apply(app, core, helper, Mark);
AndroidCachePatch.Apply(app, core, helper, Mark);
StartupResponsivenessPatch.Apply(app, core, helper, Mark);
DesktopThemePatch.Apply(app, core, helper, Mark);
Product004Patch.Apply(app, core, helper, Mark);
Product005Patch.Apply(app, core, helper, Mark);
Product007Patch.Apply(app, helper, Mark);
// Install this final guard after inherited before-return hooks, so its early
// return cannot acquire navigation/layout work during the compositor transition.
LocalMetadataPatch.Apply(app,core,helper,Mark);
var verticalChanged=Method(app,"EmbyDesktop.MainPage","VerticalScrollViewer_ViewChanged");Mark(verticalChanged);var verticalFirst=verticalChanged.Body.Instructions[0];
// Debounce only the ordinary scroll's persistence call; viewport, search
// append, navigation highlighting and explicit jump final save stay intact.
var rememberDuringScroll=verticalChanged.Body.Instructions.Single(i=>i.Operand is MethodReference m&&m.Name=="RememberBrowseOffset");
rememberDuringScroll.OpCode=OpCodes.Call;rememberDuringScroll.Operand=Helper(app.MainModule,"DesktopScroll","QueueRemember");
// End scroll persistence hook.
Prefix(verticalChanged,verticalFirst,Instruction.Create(OpCodes.Ldarg_0),Instruction.Create(OpCodes.Call,Helper(app.MainModule,"DesktopScroll","IsAnimating")),Instruction.Create(OpCodes.Brfalse,verticalFirst),Instruction.Create(OpCodes.Ret));
// Avoid zooming a measured tile into its neighboring cell or scroll clip.
var cardHover=Method(app,"EmbyDesktop.MainPage","PosterCard_PointerEntered");
foreach(var zoom in cardHover.Body.Instructions.Where(i=>i.OpCode==OpCodes.Ldc_R4 && Equals(i.Operand,1.02f)).ToArray()){Mark(cardHover);zoom.Operand=1.0f;}

BeforeReturns(Method(app,"EmbyDesktop.MainWindow","RestoreWindowPlacement"),"StartupWindow","Apply",preserveExclusiveEnds:true);
var restorePlacement=Method(app,"EmbyDesktop.MainWindow","RestoreWindowPlacement");
var restorePolicy=restorePlacement.Body.Instructions.Single(i=>i.Operand is MethodReference m&&m.DeclaringType.Name=="WindowPlacementPolicy"&&m.Name=="Restore");
restorePolicy.Operand=Helper(app.MainModule,"DesktopPlacement","Restore");

BeforeReturns(Method(app,"EmbyDesktop.MainPage","UpdateDesktopDetailButtons"),"UserStatePresentation","Refresh",preserveExclusiveEnds:true);
BeforeReturns(Method(app,"EmbyDesktop.MainPage","RefreshAccountPanel"),"ProfileOrder","Decorate",preserveExclusiveEnds:true);
var profileLoad=Types(app.MainModule.Types).Single(t=>t.Name.StartsWith("<RefreshServerProfilesAsync>" )).Methods.Single(m=>m.Name=="MoveNext");
var loadProfiles=profileLoad.Body.Instructions.Single(i=>i.Operand is MethodReference m&&m.DeclaringType.Name=="ServerProfileStore"&&m.Name=="LoadAsync");
Mark(profileLoad);loadProfiles.OpCode=OpCodes.Call;loadProfiles.Operand=Helper(app.MainModule,"ProfileOrder","Load");

// The requested tooltip policy covers original host calls and dynamic adapter
// controls. XBF/native automatic tips are suppressed at root attachment as well.
foreach(var inputAssembly in new[]{app,helper})
foreach(var inputMethod in Types(inputAssembly.MainModule.Types).SelectMany(t=>t.Methods).Where(m=>m.HasBody&&m.DeclaringType.FullName!="Yingyu.Update.DesktopInputBehavior"))
foreach(var inputCall in inputMethod.Body.Instructions.Where(i=>i.Operand is MethodReference m&&m.DeclaringType.FullName=="Microsoft.UI.Xaml.Controls.ToolTipService"&&m.Name=="SetToolTip").ToArray()){
    inputCall.OpCode=OpCodes.Call;inputCall.Operand=Helper(inputAssembly.MainModule,"DesktopInputBehavior","SetToolTip");
}

// Share one confirmation slot per XamlRoot. Duplicate requests return None,
// never queue a stale destructive action or share another dialog's Primary result.
// PlayerMenus already awaits the same Task<ContentDialogResult> signature.
var modalAwaiter=helperToolsAwaiter.Operand as MethodReference ?? throw new InvalidDataException("Missing dialog Task awaiter");
int protectedDialogs=0;
foreach(var method in Types(app.MainModule.Types).Where(t=>t.FullName=="EmbyDesktop.MainPage"||t.FullName.StartsWith("EmbyDesktop.MainPage/")).SelectMany(t=>t.Methods).Where(m=>m.HasBody))
foreach(var call in method.Body.Instructions.Where(i=>i.Operand is MethodReference m&&m.DeclaringType.FullName=="Microsoft.UI.Xaml.Controls.ContentDialog"&&m.Name=="ShowAsync").ToArray()){
    if(((MethodReference)call.Operand).Parameters.Count!=0||call.Next?.Operand is not MethodReference awaiter||awaiter.Name!="GetAwaiter")throw new InvalidDataException("Unexpected modal await pattern: "+method.FullName);
    Mark(method);call.Next.OpCode=OpCodes.Callvirt;call.Next.Operand=app.MainModule.ImportReference(modalAwaiter);
    call.OpCode=OpCodes.Call;call.Operand=Helper(app.MainModule,"ModalProtection","Show");protectedDialogs++;
}
if(protectedDialogs==0)throw new InvalidDataException("No confirmation dialogs protected");
Console.WriteLine("Protected confirmation entries: "+protectedDialogs);

ResponseSafetyPatch.Apply(core, kernelNative, helper, Mark);
foreach (var assembly in new[] { app, core, helper, windowUi, kernelCore, kernelNative })
{
    foreach (var reference in assembly.MainModule.AssemblyReferences)
        if (reference.Name is "Yingyu" or "Yingyu.Core") reference.Version = new Version(0, 9, 7, 0);
    if (assembly == app || assembly == core)
    {
        assembly.Name.Version = new Version(0, 9, 7, 0);
        foreach (var attribute in assembly.CustomAttributes)
            if (attribute.AttributeType.Name is "AssemblyFileVersionAttribute" or "AssemblyInformationalVersionAttribute")
                attribute.ConstructorArguments[0] = new CustomAttributeArgument(assembly.MainModule.TypeSystem.String,
                    attribute.AttributeType.Name == "AssemblyFileVersionAttribute" ? "1.2.2.0" : "1.2.2");
    }
    foreach (var method in Types(assembly.MainModule.Types).SelectMany(t => t.Methods).Where(m => m.HasBody && touched.Contains(m.FullName))) method.Body.OptimizeMacros();
    var regionErrors = Types(assembly.MainModule.Types).SelectMany(t => t.Methods).SelectMany(ExceptionRegions.Check).ToArray();
    if (regionErrors.Length != 0)
        throw new InvalidOperationException("Invalid exception-region control flow; payload rejected:\n" + string.Join("\n", regionErrors));
    assembly.Write(Path.Combine(stage, assembly.Name.Name + ".dll"), new WriterParameters { WriteSymbols = assembly != windowUi && assembly != kernelCore && assembly != kernelNative });
}

string depsFile = Path.Combine(stage, "Yingyu.deps.json");
var deps = System.Text.Json.Nodes.JsonNode.Parse(File.ReadAllText(depsFile))!.AsObject();
foreach (var target in deps["targets"]!.AsObject())
{
    var libraries = target.Value!.AsObject();
    foreach (string name in new[] { "Yingyu", "Yingyu.Core" })
    {
        var item = libraries[name + "/0.2.5"];
        if (item != null) { libraries.Remove(name + "/0.2.5"); libraries[name + "/1.2.2"] = item; }
    }
    foreach (var item in libraries.ToArray())
    {
        var dependencies = item.Value?["dependencies"]?.AsObject();
        if (dependencies == null) continue;
        if (dependencies.ContainsKey("Yingyu.Core")) dependencies["Yingyu.Core"] = "1.2.2";
        if (dependencies.ContainsKey("Yingyu.Core.Reference")) dependencies["Yingyu.Core.Reference"] = "1.2.2.0";
        if (item.Key is "Yingyu/1.2.2" or "Yingyu.Core/1.2.2") dependencies["Yingyu.Update"] = "1.2.2";
    }
    var referenceInfo = libraries["Yingyu.Core.Reference/0.2.5.0"];
    if (referenceInfo != null) { libraries.Remove("Yingyu.Core.Reference/0.2.5.0"); libraries["Yingyu.Core.Reference/1.2.2.0"] = referenceInfo; }
    foreach (var item in libraries)
    {
        if (item.Value?["runtime"] is not System.Text.Json.Nodes.JsonObject files) continue;
        foreach (var dll in files)
            if (dll.Key is "Yingyu.dll" or "Yingyu.Core.dll")
            {
                dll.Value!["assemblyVersion"] = "1.2.2.0";
                dll.Value["fileVersion"] = "1.2.2.0";
            }
    }
    libraries["Yingyu.Update/1.2.2"] = new System.Text.Json.Nodes.JsonObject
    {
        ["runtime"] = new System.Text.Json.Nodes.JsonObject { ["Yingyu.Update.dll"] = new System.Text.Json.Nodes.JsonObject { ["assemblyVersion"] = "1.2.2.0", ["fileVersion"] = "1.2.2.0" } }
    };
}
var libraryInfo = deps["libraries"]!.AsObject();
foreach (string name in new[] { "Yingyu", "Yingyu.Core" })
{
    var item = libraryInfo[name + "/0.2.5"];
    if (item != null) { libraryInfo.Remove(name + "/0.2.5"); libraryInfo[name + "/1.2.2"] = item; }
}
libraryInfo["Yingyu.Update/1.2.2"] = new System.Text.Json.Nodes.JsonObject { ["type"] = "project", ["serviceable"] = false, ["sha512"] = "" };
var referenceLibraryInfo = libraryInfo["Yingyu.Core.Reference/0.2.5.0"];
if (referenceLibraryInfo != null) { libraryInfo.Remove("Yingyu.Core.Reference/0.2.5.0"); libraryInfo["Yingyu.Core.Reference/1.2.2.0"] = referenceLibraryInfo; }
File.WriteAllText(depsFile, deps.ToJsonString(new JsonSerializerOptions { WriteIndented = true }), new UTF8Encoding(false));

void UpdateNativeVersion(string hostPath,bool required)=>VersionResourcePatch.Apply(hostPath,new Version(1,2,2,0),required);
UpdateNativeVersion(Path.Combine(stage, "Yingyu.exe"), true);
UpdateNativeVersion(Path.Combine(stage, "Yingyu.dll"), false);
UpdateNativeVersion(Path.Combine(stage, "Yingyu.Core.dll"), false);
var nativeSource = Path.Combine(root, "updates", "0.2.7", "native");
var nativeTarget = Path.Combine(stage, "Components", "NetworkBluray");
Directory.CreateDirectory(nativeTarget);
var nativeFiles = JsonSerializer.Deserialize<string[]>(File.ReadAllText(Path.Combine(nativeSource, "runtime-files.json")))!
    .ToHashSet(StringComparer.OrdinalIgnoreCase);
foreach (var file in Directory.EnumerateFiles(nativeSource, "*", SearchOption.AllDirectories))
{
    // Headers are build documentation; distribute runtime DLLs and their notices.
    var relative = Path.GetRelativePath(nativeSource, file);
    if (relative.Contains("include" + Path.DirectorySeparatorChar)) continue;
    if (relative.EndsWith(".dll", StringComparison.OrdinalIgnoreCase) && !nativeFiles.Contains(Path.GetFileName(relative))) continue;
    var destination = Path.Combine(nativeTarget, relative);
    Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
    File.Copy(file, destination, true);
}
var dolbySource = Path.Combine(root, "updates", "0.2.7", "dolby");
var dolbyTarget = Path.Combine(stage, "Components", "DolbyVision");
Directory.CreateDirectory(dolbyTarget);
foreach (var file in Directory.EnumerateFiles(dolbySource, "*", SearchOption.TopDirectoryOnly))
    if (!file.EndsWith(".a", StringComparison.OrdinalIgnoreCase)) File.Copy(file, Path.Combine(dolbyTarget, Path.GetFileName(file)), true);
// One private native core for all sessions. Keep the prior 90 native files as
// delivered; the resolver always selects this complete rebuilt dependency set.
var nativeSource037=Path.Combine(root,"updates","1.2.2-desktop","Native","runtime");
var nativeTarget037=Path.Combine(stage,"Components","NativeDolby");
using(var nativeManifest=JsonDocument.Parse(File.ReadAllText(Path.Combine(root,"updates","1.2.2-desktop","Native","native-runtime-manifest.json"))))
    foreach(var entry in nativeManifest.RootElement.GetProperty("files").EnumerateArray()) {
        var file=Path.Combine(nativeSource037,entry.GetProperty("file").GetString()!);
        if(Convert.ToHexStringLower(SHA256.HashData(File.ReadAllBytes(file)))!=entry.GetProperty("sha256").GetString())
            throw new InvalidDataException("Native Dolby runtime fingerprint mismatch: "+Path.GetFileName(file));
    }
foreach(var file in Directory.EnumerateFiles(nativeSource037,"*",SearchOption.AllDirectories)) {
    var destination=Path.Combine(nativeTarget037,Path.GetRelativePath(nativeSource037,file));
    Directory.CreateDirectory(Path.GetDirectoryName(destination)!);File.Copy(file,destination,true);
}
var manifest = new { version = "1.2.2", baselineVersion = "0.2.5", baselineFingerprints = expected, changedMethods = touched.OrderBy(x => x).ToArray(), functionalTests = "User will test manually; not run by agent" };
File.WriteAllText(Path.Combine(root, "updates", "1.2.2-desktop", "patch-manifest.json"), JsonSerializer.Serialize(manifest, new JsonSerializerOptions { WriteIndented = true }), new UTF8Encoding(false));
Console.WriteLine("Patched methods: " + touched.Count);
foreach (var name in touched.OrderBy(x => x)) Console.WriteLine(name);
