namespace Yingyu.Update;
public static class InteractionPolicy
{
    public const double HoverScale=1.035;
    public static double Inset(double width,double height)=>Math.Ceiling(Math.Max(width,height)*(HoverScale-1)/2)+1;
    public static string? Current(IEnumerable<KeyValuePair<string,int>> sections,int index)
        =>sections.Where(p=>p.Value<=index).OrderBy(p=>p.Value).LastOrDefault().Key;
}
