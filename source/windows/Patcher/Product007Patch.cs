using Mono.Cecil;
using Mono.Cecil.Cil;
static class Product007Patch
{
    public static void Apply(AssemblyDefinition app,AssemblyDefinition helper,Action<MethodDefinition> mark)
    {
        var page=app.MainModule.GetType("EmbyDesktop.MainPage");
        var hook=app.MainModule.ImportReference(helper.MainModule.GetType("Yingyu.Update.DesktopNavigation").Methods.Single(m=>m.Name=="Update"));
        foreach(string name in new[]{"UpdateAlphabetNavigation","VerticalScrollViewer_ViewChanged","MediaGridScrollViewer_SizeChanged","HideAlphabetNavigation"})
        {
            var m=page.Methods.Single(m=>m.Name==name);mark(m);var il=m.Body.GetILProcessor();
            foreach(var ret in m.Body.Instructions.Where(i=>i.OpCode==OpCodes.Ret).ToArray())
            {ret.OpCode=OpCodes.Ldarg_0;ret.Operand=null;var call=Instruction.Create(OpCodes.Call,hook);il.InsertAfter(ret,call);il.InsertAfter(call,Instruction.Create(OpCodes.Ret));}
        }
        // Only favorites bypass cached library snapshots. The existing reader
        // owns pagination, authentication, cancellation and server error display.
        var load=page.Methods.Single(m=>m.Name=="LoadFilteredAsync");mark(load);var ip=load.Body.GetILProcessor();var start=load.Body.Instructions[0];
        ip.InsertBefore(start,Instruction.Create(OpCodes.Ldarg_3));ip.InsertBefore(start,Instruction.Create(OpCodes.Brfalse,start));
        ip.InsertBefore(start,Instruction.Create(OpCodes.Ldc_I4_1));ip.InsertBefore(start,Instruction.Create(OpCodes.Starg,load.Parameters[4]));
    }
}
