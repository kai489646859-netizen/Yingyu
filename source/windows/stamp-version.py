from pathlib import Path
import argparse,re,struct,shutil,json

parser=argparse.ArgumentParser(description="Stamp Yingyu Windows release binaries")
parser.add_argument("work_root", nargs="?", type=Path, default=Path(__file__).resolve().parent)
w=parser.parse_args().work_root.resolve()
out=w/"stamped"
out.mkdir(exist_ok=True)
for n in ("Yingyu.exe","Yingyu.dll","Yingyu.Core.dll"):
    p=w/"payload"/n
    data=p.read_bytes()
    old=struct.pack('<IIIIII',0xFEEF04BD,0x10000,0x10007,0x00000,0x10007,0x00000)
    new=struct.pack('<IIIIII',0xFEEF04BD,0x10000,0x10007,0x10000,0x10007,0x10000)
    assert data.count(old)==1,n
    data=data.replace(old,new)
    for length in (""," .0"):
        suffix=length.strip()
        data=data.replace(("1.7.0"+suffix+"\0").encode('utf-16le'),("1.7.1"+suffix+"\0").encode('utf-16le'))
    if p.suffix==".dll":
        data,count=re.subn(rb'\x01\x00(?:\x071\.7\.0\.0|\x051\.7\.0)\x00\x00',lambda m:m[0].replace(b'1.7.0',b'1.7.1'),data)
        assert count==2,(p,count)
        shutil.copy2(p.with_suffix(".pdb"),out/p.with_suffix(".pdb").name)
    (out/n).write_bytes(data)
