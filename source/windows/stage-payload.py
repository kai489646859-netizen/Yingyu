import hashlib,json,shutil
from pathlib import Path
import sys
w=Path(sys.argv[1]).resolve()
base=w.parent/'Yingyu-Windows-1.7.0-work'
old=json.loads((base/'validation/payload-manifest.json').read_text())['payloadSha256']
def sha(path):
    with path.open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()
replacements={
    'Yingyu.exe':w/'stamped/Yingyu.exe',
    'Yingyu.Core.dll':w/'stamped/Yingyu.Core.dll',
    'Yingyu.dll':w/'stamped/Yingyu.dll',
    'Yingyu.Update.dll':w/'helper-build/Yingyu.Update.dll',
    'Yingyu.Update.pdb':w/'helper-build/Yingyu.Update.pdb',
    'Yingyu.Update.deps.json':w/'helper-build/Yingyu.Update.deps.json',
}
for n,h in old.items():
    src=w/'payload'/n
    assert sha(src)==h,n
    dst=w/'release'/n
    dst.parent.mkdir(parents=True,exist_ok=True)
    shutil.copy2(replacements.get(n,src),dst)
deps=w/'release/Yingyu.deps.json'
data=json.loads(deps.read_text('utf-8-sig'))
for key in ('targets','libraries'):
    nodes=data[key].values() if key=='targets' else [data[key]]
    for node in nodes:
        for name in list(node):
            component,version=name.rsplit('/',1)
            if component not in ('Yingyu','Yingyu.Update'):continue
            val=node.pop(name)
            node[component+'/1.7.1']=val
            if component=='Yingyu.Update' and key=='targets':
                val['runtime']['Yingyu.Update.dll']['fileVersion']='1.7.1.0'
                val['runtime']['Yingyu.Update.dll']['assemblyVersion']='1.3.4.0'
            if component=='Yingyu' and key=='targets':
                dependencies=val.get('dependencies',{})
                if 'Yingyu.Update' in dependencies:dependencies['Yingyu.Update']='1.7.1'
deps.write_text(json.dumps(data,ensure_ascii=False,indent=2),encoding='utf8')
hashes={n:sha(w/'release'/n) for n in old}
changed=sorted(n for n in old if hashes[n]!=old[n])
expect=set(replacements)|{'Yingyu.deps.json'}
assert len(hashes)==947 and set(changed)==expect,(changed,expect)
script='Components/EpisodeIntroStart.lua'
shutil.copy2(w/'source/Runtime/EpisodeIntroStart.lua',w/'release'/script)
hashes[script]=sha(w/'release'/script)
assert set(hashes)=={f.relative_to(w/'release').as_posix() for f in (w/'release').rglob('*') if f.is_file()}
(w/'validation/payload-manifest.json').write_text(json.dumps(dict(files=948,changed=changed,added=[script],payloadSha256=hashes),indent=2)+'\n')
print('948 payload files; added one packaged file; differences:',', '.join(changed))
