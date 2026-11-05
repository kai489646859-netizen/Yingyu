namespace Yingyu.Update;
public static class StartupWindow
{
    public static void Apply(object owner)=>DesktopPlacement.Attach(owner);
}
