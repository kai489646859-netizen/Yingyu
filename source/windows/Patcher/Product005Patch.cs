using Mono.Cecil;
using Mono.Cecil.Cil;

static class Product005Patch
{
    static IEnumerable<TypeDefinition> All(IEnumerable<TypeDefinition> types)
    { foreach(var t in types){yield return t;foreach(var n in All(t.NestedTypes))yield return n;} }
    public static void Apply(AssemblyDefinition app,AssemblyDefinition core,AssemblyDefinition helper,Action<MethodDefinition> mark)
    {
        var card=app.MainModule.GetType("EmbyDesktop.ViewModels.MediaCardViewModel");
        void Constant(string name,bool floating,int value)
        {
            var method=card.Methods.Single(m=>m.Name==name);mark(method);
            method.Body.Instructions.Clear();method.Body.ExceptionHandlers.Clear();method.Body.Variables.Clear();
            method.Body.Instructions.Add(floating?Instruction.Create(OpCodes.Ldc_R8,(double)value):Instruction.Create(value==0?OpCodes.Ldc_I4_0:OpCodes.Ldc_I4_1));
            method.Body.Instructions.Add(Instruction.Create(OpCodes.Ret));
        }
        // The contained-image template uses Uniform. All media cards show the
        // complete image; resume always keeps the horizontal frame and footer.
        Constant("get_ContainedPosterOpacity",true,1); Constant("get_FilledPosterOpacity",true,0);
        Constant("get_UsesPortraitResumeLayout",false,0); Constant("get_ShowContainedLandscape",false,1);
        Constant("get_ShowResumeFooter",false,1); Constant("get_UsesLandscapeFallback",false,0);
        // Apply the same resume-only visibility rule to cached startup shells,
        // not just successful fresh-server merges. Poster walls are untouched.
        var update=app.MainModule.GetType("EmbyDesktop.MainPage").Methods.Single(m=>m.Name=="UpdateMediaCards");mark(update);
        var il=update.Body.GetILProcessor();var start=update.Body.Instructions[0];
        il.InsertBefore(start,Instruction.Create(OpCodes.Ldarg_2));il.InsertBefore(start,Instruction.Create(OpCodes.Ldarg_3));
        il.InsertBefore(start,Instruction.Create(OpCodes.Call,app.MainModule.ImportReference(helper.MainModule.GetType("Yingyu.Update.ResumeSync").Methods.Single(m=>m.Name=="DisplayItems"))));
        il.InsertBefore(start,Instruction.Create(OpCodes.Starg,update.Parameters[1]));
        int pending=0,reconcile=0;
        foreach(var method in All(app.MainModule.Types).Where(t=>t.Name.StartsWith("<FetchHomeSnapshotAsync>")||t.Name.StartsWith("<RefreshResumeItemsAsync>")).SelectMany(t=>t.Methods).Where(m=>m.HasBody))
        foreach(var call in method.Body.Instructions.Where(i=>i.Operand is MethodReference m&&m.DeclaringType.FullName=="EmbyDesktop.MainPage").ToArray())
        {
            var name=((MethodReference)call.Operand).Name;
            string? hook=name switch {"LoadPendingResumeItemsAsync"=>"NoCachedPending","ReconcilePlaybackProgressAsync"=>"KeepServer",_=>null};
            if(hook==null)continue;mark(method);call.OpCode=OpCodes.Call;
            call.Operand=app.MainModule.ImportReference(helper.MainModule.GetType("Yingyu.Update.ResumeSync").Methods.Single(m=>m.Name==hook));
            if(name=="LoadPendingResumeItemsAsync")pending++;else reconcile++;
        }
        if(pending!=2||reconcile!=1)throw new InvalidOperationException("Unexpected resume response reconciliation shape");
    }
}
