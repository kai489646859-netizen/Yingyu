namespace Yingyu.Update;

internal sealed class DanmakuFeatured
{
    internal readonly record struct Decision((string Text,int Mode) Key,int Repeat,bool Drop);

    readonly Dictionary<(string Text,int Mode),(double Time,int Count)> repeats=new();
    double lastRolling=double.NegativeInfinity;

    internal Decision Check(DanmakuComment comment,double now,int activeRolling)
    {
        var text=new string(comment.Text.Where(ch=>!char.IsWhiteSpace(ch)&&!char.IsPunctuation(ch)).ToArray());
        var key=(text.Length==0?comment.Text.Trim():text.ToUpperInvariant(),comment.Mode);
        int repeat=repeats.TryGetValue(key,out var previous)&&now-previous.Time<=12?previous.Count+1:1;
        bool redundant=repeat>=3&&repeat%2!=0;
        if(redundant)Remember(key,repeat,now);

        // Thin unique comments only when a burst already has three rolling
        // comments in flight. Leave sparse stretches and every lane available.
        bool crowded=comment.Mode==1&&repeat==1&&activeRolling>=3&&now-lastRolling<.40;
        return new(key,repeat,redundant||crowded);
    }

    internal void Shown(Decision decision,double now)
    {
        Remember(decision.Key,decision.Repeat,now);
        if(decision.Key.Mode==1)lastRolling=now;
    }

    void Remember((string Text,int Mode) key,int count,double now)
    {
        if(repeats.Count>=256&&!repeats.ContainsKey(key))repeats.Clear();
        repeats[key]=(now,count);
    }

    internal void Reset()
    {
        repeats.Clear();
        lastRolling=double.NegativeInfinity;
    }
}
