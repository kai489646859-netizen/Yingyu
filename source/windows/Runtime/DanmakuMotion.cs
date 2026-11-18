namespace Yingyu.Update;

internal static class DanmakuMotion
{
    internal static double Speed(double speed)=>Math.Max(.25,speed);

    internal static double SpeedRatio(double before,double after)=>Speed(after)/Speed(before);

    internal static double Position(double previous,double start,double exit,double velocity,double elapsed)
        =>Math.Min(previous,Math.Max(exit,start-elapsed*velocity));
}
