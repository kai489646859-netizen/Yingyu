using System.Reflection.PortableExecutable;
using System.Text;

// Keep the original resource tree and startup manifest in place.
// Append version data after the last section data without loading code.
internal static class VersionResourcePatch
{
    sealed class Node
    {
        internal ushort Type;
        internal string Key="";
        internal byte[] Value=[];
        internal List<Node> Children=new();
    }
    static int Align(int value)=>(value+3)&~3;
    static ushort U16(byte[] bytes,int offset)=>BitConverter.ToUInt16(bytes,offset);
    static uint U32(byte[] bytes,int offset)=>BitConverter.ToUInt32(bytes,offset);
    static Node Read(byte[] data,int start,int limit)
    {
        int end=checked(start+U16(data,start));
        if(end>limit||end<start+6)throw new InvalidDataException("Invalid version resource block");
        int at=start+6,key=at;
        while(at+2<=end&&U16(data,at)!=0)at+=2;
        if(at+2>end)throw new InvalidDataException("Unterminated version resource key");
        var node=new Node{Type=U16(data,start+4),Key=Encoding.Unicode.GetString(data,key,at-key)};
        at=Align(at+2);int count=checked(U16(data,start+2)*(node.Type==1?2:1));
        if(at+count>end)throw new InvalidDataException("Invalid version resource value");
        node.Value=data.AsSpan(at,count).ToArray();at=Align(at+count);
        while(at+6<=end){if(U16(data,at)==0)break;node.Children.Add(Read(data,at,end));at=Align(at+U16(data,at));}
        return node;
    }
    static byte[] Write(Node node)
    {
        using var stream=new MemoryStream();using var writer=new BinaryWriter(stream,Encoding.Unicode,true);
        writer.Write((ushort)0);writer.Write(checked((ushort)(node.Type==1?node.Value.Length/2:node.Value.Length)));writer.Write(node.Type);
        writer.Write(Encoding.Unicode.GetBytes(node.Key+"\0"));
        void Pad(){while(stream.Position%4!=0)writer.Write((byte)0);}
        Pad();writer.Write(node.Value);
        foreach(var child in node.Children){Pad();writer.Write(Write(child));}
        int length=checked((int)stream.Length);stream.Position=0;writer.Write(checked((ushort)length));return stream.ToArray();
    }
    static void Update(Node node,Version version,ref int fixedCount)
    {
        if(node.Key=="VS_VERSION_INFO"){
            if(node.Value.Length<52||U32(node.Value,0)!=0xfeef04bd)throw new InvalidDataException("Missing fixed version resource");
            uint ms=checked((uint)(version.Major<<16|version.Minor)),ls=checked((uint)(version.Build<<16|version.Revision));
            BitConverter.GetBytes(ms).CopyTo(node.Value,8);BitConverter.GetBytes(ls).CopyTo(node.Value,12);
            BitConverter.GetBytes(ms).CopyTo(node.Value,16);BitConverter.GetBytes(ls).CopyTo(node.Value,20);fixedCount++;
        }
        if(node.Key is "FileVersion" or "ProductVersion")node.Value=Encoding.Unicode.GetBytes(version.ToString(4)+"\0");
        foreach(var child in node.Children)Update(child,version,ref fixedCount);
    }
    internal static void Apply(string path,Version version,bool required)
    {
        var bytes=File.ReadAllBytes(path);var entries=new List<(int Entry,byte[] Value)>();
        using(var reader=new PEReader(new MemoryStream(bytes,false))){
            int Rva(int rva){foreach(var section in reader.PEHeaders.SectionHeaders)if(rva>=section.VirtualAddress&&rva<section.VirtualAddress+Math.Max(section.VirtualSize,section.SizeOfRawData))return checked(section.PointerToRawData+rva-section.VirtualAddress);throw new InvalidDataException("Resource RVA outside PE sections");}
            int directory=reader.PEHeaders.PEHeader!.ResourceTableDirectory.RelativeVirtualAddress;
            if(directory!=0){
                int root=Rva(directory);
                IEnumerable<(uint Id,uint Offset)> Items(int offset){int at=checked(root+offset),count=U16(bytes,at+12)+U16(bytes,at+14);for(int i=0;i<count;i++)yield return(U32(bytes,at+16+i*8),U32(bytes,at+20+i*8));}
                foreach(var type in Items(0).Where(e=>e.Id==16&&(e.Offset&0x80000000)!=0))
                foreach(var name in Items(checked((int)(type.Offset&0x7fffffff)))){
                    if(name.Id>ushort.MaxValue||(name.Offset&0x80000000)==0)throw new InvalidDataException("Unexpected version resource name");
                    foreach(var language in Items(checked((int)(name.Offset&0x7fffffff)))){
                        if(language.Id>ushort.MaxValue||(language.Offset&0x80000000)!=0)throw new InvalidDataException("Unexpected version resource language");
                        int data=checked(root+(int)language.Offset),at=Rva(checked((int)U32(bytes,data))),size=checked((int)U32(bytes,data+4));
                        entries.Add((data,bytes.AsSpan(at,size).ToArray()));
                    }
                }
            }
        }
        if(required&&entries.Count!=1)throw new InvalidDataException("Unexpected host version resource count");
        if(entries.Count==0)return;
        var rewritten=new List<(int Entry,byte[] Value)>();int fixedCount=0;
        foreach(var entry in entries){var node=Read(entry.Value,0,entry.Value.Length);Update(node,version,ref fixedCount);rewritten.Add((entry.Entry,Write(node)));}
        if(fixedCount!=entries.Count)throw new InvalidDataException("Unexpected fixed version resource count");
        // A longer version cannot grow into the adjacent manifest. Existing
        // section bytes and manifest RVAs, including NUL padding, stay intact.
        int pe=checked((int)U32(bytes,0x3c)),coff=pe+4,optional=coff+20;
        int count=U16(bytes,coff+2),table=optional+U16(bytes,coff+16);
        int last=table+(count-1)*40;
        int sectionAlignment=checked((int)U32(bytes,optional+32)),fileAlignment=checked((int)U32(bytes,optional+36));
        int Round(int value,int alignment)=>checked((value+alignment-1)/alignment*alignment);
        int sectionRva=checked((int)U32(bytes,last+12)),raw=checked((int)U32(bytes,last+20)),oldRawSize=checked((int)U32(bytes,last+16));
        if(raw+oldRawSize!=bytes.Length)throw new InvalidDataException("Unexpected overlay after last section");
        for(int i=0;i<count-1;i++)if(U32(bytes,table+i*40+12)>=sectionRva)throw new InvalidDataException("Last section not last in virtual memory");
        using var content=new MemoryStream();
        foreach(var item in rewritten){while(content.Position%4!=0)content.WriteByte(0);int offset=checked(oldRawSize+(int)content.Position);content.Write(item.Value);BitConverter.GetBytes(checked((uint)(sectionRva+offset))).CopyTo(bytes,item.Entry);BitConverter.GetBytes((uint)item.Value.Length).CopyTo(bytes,item.Entry+4);}
        int versionSize=checked((int)content.Length),rawSize=Round(oldRawSize+versionSize,fileAlignment);
        Array.Resize(ref bytes,checked(raw+rawSize));content.ToArray().CopyTo(bytes,raw+oldRawSize);
        void Set(int at,uint value)=>BitConverter.GetBytes(value).CopyTo(bytes,at);
        Set(last+8,(uint)(oldRawSize+versionSize));Set(last+16,(uint)rawSize);
        // Version data must remain readable even when the final section also
        // contains base relocations; retain those bytes and their directory.
        Set(last+36,(U32(bytes,last+36)&~0x02000000u)|0x40000000u);
        Set(optional+56,(uint)Round(sectionRva+oldRawSize+versionSize,sectionAlignment));
        Set(optional+8,checked(U32(bytes,optional+8)+(uint)(rawSize-oldRawSize)));
        Set(optional+64,0);
        File.WriteAllBytes(path,bytes);
    }
}
