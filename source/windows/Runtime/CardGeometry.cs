namespace Yingyu.Update;
public readonly record struct CardFit(double Width,double Height)
{
    public static CardFit Resolve(double width,double height,double pixelsX,double pixelsY)
    {
        if(!double.IsFinite(width)||!double.IsFinite(height)||width<=0||height<=0)return new(0,0);
        if(!double.IsFinite(pixelsX)||!double.IsFinite(pixelsY)||pixelsX<=0||pixelsY<=0)return new(width,height);
        double factor=Math.Min(width/pixelsX,height/pixelsY);
        return new(pixelsX*factor,pixelsY*factor);
    }
}
