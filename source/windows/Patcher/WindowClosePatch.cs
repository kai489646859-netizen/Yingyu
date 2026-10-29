using Mono.Cecil;
using Mono.Cecil.Cil;
using Mono.Cecil.Rocks;

// Limited edits to the existing close path. No player implementation is replaced.
internal static class WindowClosePatch
{
    internal static void Apply(AssemblyDefinition app, AssemblyDefinition window, AssemblyDefinition helper, HashSet<string> touched)
    {
        var w = window.MainModule.Types.Single(t => t.FullName == "Richasy.MpvKernel.WinUI.MpvPlayerWindow");
        var session = app.MainModule.Types.Single(t => t.FullName == "EmbyDesktop.Services.MpvPlaybackSession");
        var overlay = app.MainModule.Types.Single(t => t.FullName == "EmbyDesktop.Controls.PlayerOverlay");
        MethodDefinition Edit(TypeDefinition t, string n)
        {
            var m = t.Methods.Single(x => x.Name == n);
            touched.Add(m.FullName); m.Body.SimplifyMacros(); return m;
        }
        var destroying = new FieldDefinition("_updateHostDestroying", FieldAttributes.Private, window.MainModule.TypeSystem.Boolean);
        var completion = new FieldDefinition("_updateDisposeTask", FieldAttributes.Private, window.MainModule.ImportReference(typeof(Task)));
        w.Fields.Add(destroying); w.Fields.Add(completion);
        var disconnected = new FieldDefinition("_updateDisconnected", FieldAttributes.Private, app.MainModule.TypeSystem.Boolean);
        overlay.Fields.Add(disconnected);
        var disposed = w.Methods.Single(m => m.Name == "get_IsDisposed");

        var startup = Edit(session.NestedTypes.Single(t => t.Name.StartsWith("<StartAsync>")), "MoveNext");
        var subscribed = startup.Body.Instructions.Single(i => Call(i, "Microsoft.UI.Windowing.AppWindow", "add_Destroying"));
        var sessionLocal = startup.Body.Variables.Single(v => v.VariableType.FullName == session.FullName);
        var hostLocal = startup.Body.Variables.Single(v => v.VariableType.FullName == "Microsoft.UI.Windowing.AppWindow");
        var attach = helper.MainModule.Types.Single(t => t.FullName == "Yingyu.Update.PlayerWindowClosing").Methods.Single(m => m.Name == "Attach");
        Insert(startup, subscribed.Next, Instruction.Create(OpCodes.Ldloc, sessionLocal), Instruction.Create(OpCodes.Ldloc, hostLocal),
            Instruction.Create(OpCodes.Call, app.MainModule.ImportReference(attach)));

        // Disconnect can be called by both the session and window. The second
        // call must not touch controls after their XAML island has been closed.
        var disconnect = Edit(overlay, "Disconnect");
        var start = disconnect.Body.Instructions[0];
        Insert(disconnect, start, Instruction.Create(OpCodes.Ldarg_0), Instruction.Create(OpCodes.Ldfld, disconnected),
            Instruction.Create(OpCodes.Brfalse, start), Instruction.Create(OpCodes.Ret));
        Insert(disconnect, start, Instruction.Create(OpCodes.Ldarg_0), Instruction.Create(OpCodes.Ldc_I4_1), Instruction.Create(OpCodes.Stfld, disconnected));
        // The first guard's false branch must enter the one-time mark.
        disconnect.Body.Instructions[2].Operand = start.Previous.Previous.Previous;

        // Save/report using the existing sequence, then let DisposeCoreAsync
        // disconnect controls before destroying their host. Keep state locals.
        var close = Edit(session.NestedTypes.Single(t => t.Name.StartsWith("<CloseAsync>")), "MoveNext");
        var early = close.Body.Instructions.Single(i => i.Operand is FieldReference f && f.Name == "destroyWindow").Previous;
        var destroyCall = close.Body.Instructions.Single(i => Call(i, w.FullName, "Close"));
        for (var i = early; i != destroyCall.Next; i = i.Next) { i.OpCode = OpCodes.Nop; i.Operand = null; }

        // If the OS began destroying the host, don't query that native object
        // again. Still await its already-started MPV cleanup before mount disposal.
        var core = Edit(session.NestedTypes.Single(t => t.Name.StartsWith("<DisposeCoreAsync>")), "MoveNext");
        var getWindow = core.Body.Instructions.Single(i => Call(i, w.FullName, "GetWindow"));
        var check = core.Body.Instructions.Single(i => Call(i, w.FullName, "get_IsDisposed"));
        var guard = new[] { check.Previous.Previous, check.Previous, check, check.Next };
        var awaitStart = check.Next.Next;
        guard[3].Operand = awaitStart;
        foreach (var i in guard) core.Body.Instructions.Remove(i);
        Insert(core, getWindow.Previous.Previous, guard);

        // Timer and input notifications can resume after an await, or a listener
        // can close the window synchronously during UINotify. Check both edges.
        var notify = Edit(w, "HandleInteractiveNotify");
        Guard(notify, notify.Body.Instructions[0], disposed);
        var root = notify.Body.Instructions.First(i => i.Operand is FieldReference f && f.Name == "_rootGrid").Previous;
        Guard(notify, root, disposed);
        var resize = Edit(w, "UpdateXamlSourcePosition");
        Guard(resize, resize.Body.Instructions[0], disposed);

        var onDestroy = Edit(w, "OnWindowDestroying");
        Insert(onDestroy, onDestroy.Body.Instructions[0], Instruction.Create(OpCodes.Ldarg_0),
            Instruction.Create(OpCodes.Ldc_I4_1), Instruction.Create(OpCodes.Stfld, destroying));

        var dispose = Edit(w, "DisposeAsync");
        var il = dispose.Body.Instructions;
        var completed = il.Single(i => Call(i, "System.Threading.Tasks.ValueTask", "get_CompletedTask"));
        var vtCtor = window.MainModule.ImportReference(typeof(ValueTask).GetConstructor(new[] { typeof(Task) })!);
        var wrap = Instruction.Create(OpCodes.Newobj, vtCtor);
        Insert(dispose, completed, Instruction.Create(OpCodes.Ldarg_0), Instruction.Create(OpCodes.Ldfld, completion),
            Instruction.Create(OpCodes.Dup), Instruction.Create(OpCodes.Brtrue, wrap), Instruction.Create(OpCodes.Pop));
        completed.Operand = window.MainModule.ImportReference(typeof(Task).GetProperty(nameof(Task.CompletedTask))!.GetMethod!);
        dispose.Body.GetILProcessor().InsertAfter(completed, wrap);

        var hostDestroy = il.Single(i => Call(i, "Microsoft.UI.Windowing.AppWindow", "Destroy"));
        var hostBlock = new[] { hostDestroy.Previous.Previous, hostDestroy.Previous, hostDestroy };
        foreach (var i in hostBlock) il.Remove(i);
        var clientDispose = il.Single(i => Call(i, "Richasy.MpvKernel.Core.MpvClient", "DisposeAsync"));
        var clientStart = clientDispose.Previous.Previous;
        var skip = Instruction.Create(OpCodes.Ldarg_0);
        // Relocate the host destruction after DesktopWindowXamlSource.Dispose.
        // Prefix redirects the null-island branch to this new host guard.
        InsertRedirect(dispose, clientStart,
            skip, Instruction.Create(OpCodes.Ldfld, destroying), Instruction.Create(OpCodes.Brtrue, clientStart),
            Instruction.Create(OpCodes.Ldarg_0), Instruction.Create(OpCodes.Ldfld, (FieldReference)hostBlock[1].Operand), Instruction.Create(OpCodes.Brfalse, clientStart),
            hostBlock[0], hostBlock[1], hostBlock[2]);
        // Both explicit DisposeAsync callers and the OS Destroying handler get
        // the same Task after the first synchronous UI teardown has returned.
        var pending = new VariableDefinition(window.MainModule.ImportReference(typeof(ValueTask)));
        dispose.Body.Variables.Add(pending);
        dispose.Body.GetILProcessor().InsertAfter(clientStart, Instruction.Create(OpCodes.Dup));
        Insert(dispose, clientDispose.Next, Instruction.Create(OpCodes.Stloc, pending), Instruction.Create(OpCodes.Ldloca, pending),
            Instruction.Create(OpCodes.Call, window.MainModule.ImportReference(typeof(ValueTask).GetMethod(nameof(ValueTask.AsTask))!)),
            Instruction.Create(OpCodes.Stfld, completion), Instruction.Create(OpCodes.Ldarg_0), Instruction.Create(OpCodes.Ldfld, completion), Instruction.Create(OpCodes.Newobj, vtCtor));
    }

    static bool Call(Instruction i, string owner, string name) => i.Operand is MethodReference m && m.DeclaringType.FullName == owner && m.Name == name;
    static void Insert(MethodDefinition m, Instruction at, params Instruction[] items)
    { var il = m.Body.GetILProcessor(); foreach (var i in items) il.InsertBefore(at, i); }
    static void Guard(MethodDefinition m, Instruction at, MethodReference disposed)
    {
        InsertRedirect(m, at, Instruction.Create(OpCodes.Ldarg_0), Instruction.Create(OpCodes.Call, disposed),
            Instruction.Create(OpCodes.Brfalse, at), Instruction.Create(OpCodes.Ret));
    }
    static void InsertRedirect(MethodDefinition m, Instruction at, params Instruction[] items)
    {
        var old = m.Body.Instructions.ToArray();
        foreach (var i in old) {
            if (i.Operand == at) i.Operand = items[0];
            else if (i.Operand is Instruction[] targets) for (int n=0;n<targets.Length;n++) if(targets[n]==at)targets[n]=items[0];
        }
        foreach (var h in m.Body.ExceptionHandlers) {
            if(h.TryStart==at)h.TryStart=items[0]; if(h.TryEnd==at)h.TryEnd=items[0];
            if(h.HandlerStart==at)h.HandlerStart=items[0]; if(h.HandlerEnd==at)h.HandlerEnd=items[0]; if(h.FilterStart==at)h.FilterStart=items[0];
        }
        Insert(m, at, items);
    }
}
