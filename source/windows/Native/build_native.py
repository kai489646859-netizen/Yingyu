"""Compile only. Never starts the player, opens media, or calls GPU APIs."""
import os, subprocess, sys, shutil
from pathlib import Path
root=Path(__file__).resolve().parents[3]
native=Path(__file__).resolve().parent
storage=root/'.tools/native-dolby'
tools=Path(os.environ.get('YINGYU_NATIVE_BUILD_ROOT', native/'build-work')).resolve()
deps=Path(os.environ.get('YINGYU_NATIVE_DEPS', root/'.tools/native-deps/ucrt64')).resolve()
out=native/'build'
out.mkdir(exist_ok=True)
env=os.environ.copy()
env['PYTHONPATH']=str(storage/'python')
env['PATH']=str(deps/'bin')+os.pathsep+str(storage/'python/bin')+os.pathsep+str(Path(sys.executable).parent)+os.pathsep+env['PATH']
env['PKG_CONFIG_PATH']=str(deps/'lib/pkgconfig')
env['CC']=str(deps/'bin/gcc.exe');env['CXX']=str(deps/'bin/g++.exe')
def run(args,cwd=out):
    print('BUILD:',*map(str,args),flush=True)
    subprocess.run(list(map(str,args)),cwd=cwd,env=env,check=True)
if '--mpv' not in sys.argv:
    sdk=Path(os.environ.get('YINGYU_WINDOWS_SDK', 'C:/Program Files (x86)/Windows Kits/10')).resolve()
    sdk_version=os.environ.get('YINGYU_WINDOWS_SDK_VERSION','10.0.26100.0')
    fxc=Path(os.environ.get('YINGYU_FXC', sdk/f'bin/{sdk_version}/x64/fxc.exe')).resolve()
    for p in sorted((native/'vendor/kodi/shaders').glob('*.hlsl')):
        if p.stem=='dovi_el_horizontal':continue # include, not entry point
        profile='vs_5_0' if p.stem.endswith('_vs') else 'ps_5_0' if p.stem.endswith('_ps') else 'cs_5_0'
        run([fxc,'/nologo','/O3','/T',profile,'/E','main','/Vn',p.stem,'/Fh',out/(p.stem+'.h'),p])
    msvc=Path(os.environ.get('YINGYU_MSVC_ROOT', root/'.tools/msvc')).resolve()
    shutil.copytree(deps/'include/libavutil',out/'ffheaders/libavutil',dirs_exist_ok=True)
    env['INCLUDE']=';'.join(map(str,[msvc/'include',sdk/f'Include/{sdk_version}/ucrt',sdk/f'Include/{sdk_version}/um',sdk/f'Include/{sdk_version}/shared',sdk/f'Include/{sdk_version}/winrt',out/'ffheaders',native/'include',native/'vendor/kodi',native/'vendor/nvapi',out]))
    env['LIB']=';'.join(map(str,[msvc/'lib/x64',sdk/f'Lib/{sdk_version}/ucrt/x64',sdk/f'Lib/{sdk_version}/um/x64']))
    sources=[native/'src/yydv.cpp',native/'src/nv_output.cpp',native/'vendor/kodi/DvMappingTables.cpp',native/'vendor/kodi/DvRpuTransport.cpp',native/'vendor/kodi/DvGpuCarrier.cpp']
    run([msvc/'bin/Hostx64/x64/cl.exe','/nologo','/utf-8','/std:c++20','/O2','/Zi','/MD','/EHsc','/W4','/DNOMINMAX','/D_WIN32_WINNT=0x0A00','/DWIN32_LEAN_AND_MEAN','/LD',*sources,'/link','/OUT:Yingyu.NativeDolby.dll','/PDB:Yingyu.NativeDolby.pdb',native/'vendor/nvapi/amd64/nvapi64.lib','d3d11.lib','dxgi.lib','user32.lib','gdi32.lib','advapi32.lib'])
else:
    env['PKG_CONFIG']=str(deps/'bin/pkgconf.exe')
    build=tools/'mpv-build'
    source=tools/'source/mpv-e470f8986e'
    args=[sys.executable,'-m','mesonbuild.mesonmain','setup',build,source,'--buildtype=debugoptimized','-Db_ndebug=true','-Dcplayer=false','-Dlibmpv=true','-Dtests=false','-Dfuzzers=false','-Dmanpage-build=disabled','-Dlua=luajit','-Dlibcurl=enabled','-Dd3d11=enabled','-Ddirect3d=enabled','-Dd3d-hwaccel=enabled','-Dgl-win32=enabled','-Dvulkan=enabled']
    if (build/'build.ninja').exists():args.insert(4,'--reconfigure')
    run(args,tools)
    run([sys.executable,'-m','mesonbuild.mesonmain','compile','-C',build,'-j','8'],tools)
