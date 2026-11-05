using System.Globalization;
namespace Yingyu.Update;
internal static class DesktopTime
{
    internal static bool TryParse(string text,out double seconds)
    {
        seconds=0;var parts=text.Trim().Split(':');if(parts.Length is <1 or >3)return false;
        for(int i=0;i<parts.Length;i++){
            if(!int.TryParse(parts[i],NumberStyles.None,CultureInfo.InvariantCulture,out int value)||value<0||(i>0&&value>=60))return false;
            seconds=seconds*60+value;if(seconds>365*24*3600)return false;
        }return true;
    }
}
