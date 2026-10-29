"""Read PE imports and assemble the complete private runtime, without loading it."""
from pathlib import Path
import hashlib,json,os,shutil,sys
native=Path(__file__).resolve().parent
root=native.parents[2]
sys.path.insert(0,str(root/'.tools/pydeps'))
import pefile
prefix=Path(os.environ.get('YINGYU_NATIVE_DEPS', root/'.tools/native-deps/ucrt64')).resolve()
out=native/'runtime';out.mkdir(exist_ok=True)
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
mpv=Path(os.environ.get('YINGYU_MPV_DLL', native/'build-work/mpv-build/libmpv-2.dll')).resolve()
bridge=native/'build/Yingyu.NativeDolby.dll'
crt=Path(os.environ.get('YINGYU_VC_RUNTIME', root/'.tools/vc-runtime')).resolve()
available={p.name.lower():p for folder in [prefix/'bin',crt] for p in folder.glob('*.dll')}
system=Path(os.environ.get('SystemRoot','C:/Windows'))/'System32';closure={};system_names=set();pending=[mpv,bridge]
while pending:
    p=pending.pop();key=p.name.lower()
    if key in closure:continue
    q=out/p.name;shutil.copyfile(p,q);closure[key]={'file':p.name,'sha256':sha(q),'bytes':q.stat().st_size}
    with pefile.PE(str(p)) as pe:
        if pe.FILE_HEADER.Machine!=0x8664:raise RuntimeError('Not x64: '+str(p))
        imports=[i.dll.decode('ascii').lower() for group in ['DIRECTORY_ENTRY_IMPORT','DIRECTORY_ENTRY_DELAY_IMPORT'] for i in getattr(pe,group,[])]
    for name in imports:
        if name in available:pending.append(available[name])
        elif name.startswith(('api-ms-','ext-ms-')) or (system/name).is_file():system_names.add(name)
        else:raise RuntimeError('Unresolved private dependency: '+p.name+' -> '+name)
licenses=out/'Licenses';licenses.mkdir(exist_ok=True)
shutil.copytree(prefix/'share/licenses',licenses/'msys2',dirs_exist_ok=True)
for name in ['packages.lock.json','package-plan.json']:
    shutil.copyfile(root/'.tools/native-dolby'/name,licenses/name)
shutil.copyfile(native/'vendor/nvapi/License.txt',licenses/'NVAPI-LICENSE.txt')
mpvsource=root/'.tools/native-dolby-0310/source/mpv-e470f8986e'
for p in mpvsource.glob('Copyright*'):shutil.copyfile(p,licenses/p.name)
license_text='''Embedded Native Dolby implementation: GPL-3.0-or-later.
Kodi carrier/mapping/RPU/shaders: GPL-2.0-or-later, exact upstream commit
5da44c2547bae530354524ddc0a00cc5b5bae0da; copyright Team Kodi.
mpv: source e470f8986e plus the adjacent bounded integration patch.
NVAPI redistribution: see NVAPI-LICENSE.txt; the DLL uses the installed driver,
and does not install any driver or system module.
MSYS2 binary dependencies: exact package SHA256 and versions are included.
Official package sources: https://github.com/msys2/MINGW-packages
and https://repo.msys2.org/mingw/sources/ (matching source package versions).
All upstream source modifications and build scripts are retained with delivery.
'''
(licenses/'NativeDolby-NOTICE.txt').write_text(license_text,encoding='utf-8')
report={'files':sorted(closure.values(),key=lambda x:x['file'].lower()),'systemImports':sorted(system_names),'dllsLoaded':False,'gpuCallsExecuted':False}
(native/'native-runtime-manifest.json').write_text(json.dumps(report,indent=2),encoding='utf-8')
print('Private native runtime:',len(closure),'DLLs;',sum(p['bytes'] for p in closure.values()),'bytes')
