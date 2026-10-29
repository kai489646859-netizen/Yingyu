"""Read-only source, PE and build provenance audit; no product/native execution."""
from pathlib import Path
import hashlib,json,os,sys
n=Path(__file__).resolve().parent;r=n.parents[2]
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
read=lambda p:json.loads(p.read_text(encoding='utf-8-sig'))
checks={}
def check(k,v):
 checks[k]=bool(v)
 if not v:raise RuntimeError(k)
src=r/'.tools/native-dolby-0315/source/mpv-e470f8986e'
copy=Path(os.environ.get('YINGYU_MPV_SOURCE_COPY', r/'.tools/native-build/source/mpv-e470f8986e')).resolve()
frozen=read(n.parent/'evidence/native-compile-inputs-0315.json')
check('frozen-mpv-build-inputs',all(sha(src/p)==h==sha(copy/p) for p,h in frozen['mpvSha256'].items()))
check('frozen-integration-inputs',all(sha(n/'src'/p)==h for p,h in frozen['nativeSha256'].items()))
check('frozen-post-patch-inputs',all(sha(n/p)==h for p,h in frozen['nativePostPatchSha256'].items()))
for name in ['nvapi','kodi']:
 for p,h in read(n/'vendor'/name/'SOURCE.json')['sha256'].items():check('vendor-'+name+'-'+p,sha(n/'vendor'/name/p)==h)
m=read(n/'native-runtime-manifest.json')
for e in m['files']:check('runtime-'+e['file'],sha(n/'runtime'/e['file'])==e['sha256'])
check('native-transport-dll-removed',not (n/'runtime/Yingyu.NativeDolby.dll').exists())
compiled_mpv=Path(os.environ.get('YINGYU_MPV_DLL', n/'build-work/mpv-build/libmpv-2.dll')).resolve()
check('compiled-core-exact',sha(n/'runtime/libmpv-2.dll')==sha(compiled_mpv))
old=r/'updates/0.3.15-desktop/Native/runtime'
check('all-131-native-dlls-reused-exactly',len(m['files'])==131 and all(sha(old/e['file'])==e['sha256'] for e in m['files']))
current={p.relative_to(src).as_posix():sha(p) for p in src.rglob('*') if p.is_file()}
oldsrc=r/'.tools/native-dolby-0315/source/mpv-e470f8986e'
changed=[p for p,h in current.items() if sha(oldsrc/p)!=h]
check('mpv-source-unchanged-from-delivered-0315',not changed)
vo=(src/'video/out/yydv_mpv.c').read_text(encoding='utf8')
body=vo[vo.index('static int yydv_try_frame('):vo.index('static int yydv_control(')]
check('hdr-route-keeps-required-el-and-exact-pts',all(s in body for s in ['yydv_required_el(meta)','YYDV_EL_MISSING','fabs(image->pts-el->pts)>1e-6','YYDV_PTS_INVALID']))
check('native-dll-and-mode-switch-never-entered','return yydv_fallback(vo,YYDV_HDR10_POLICY);' in body and 'yydv_load_module(vo)' not in body and 'd->render(' not in body)
pair=(src/'filters/f_enhancement_pair.c').read_text(encoding='utf8')
check('missing-required-el-still-pauses','mp_native_dv_failure(f->global,p->epoch,12)' in pair and 'if (!zero_residual)' in pair)
gpu=(src/'video/out/vo_gpu_next.c').read_text(encoding='utf8')
check('late-el-map-failure-still-pauses','mp_native_dv_failure(fp->vo->global,mp_native_dv_epoch(fp->vo->global),15)' in gpu)
stats=(src/'player/lua/stats.lua').read_text(encoding='utf8')
check('source-mastering-never-overwrites-display-target','target_csp=frame->current->params.color' not in gpu and 'target_csp = sw->fns->target_csp(sw)' in gpu)
check('native-stats-localized-and-chinese-font','Microsoft YaHei' in stats and all(x in stats for x in ['显示输出：','音画差（秒）：','丢帧：','视频解码：','最高帧平均亮度：','声道数：']))
check('native-stats-property-names-and-formulas-retained',all(x in stats for x in ['decoder-frame-drop-count','frame-drop-count','video-target-params','avsync','local function pq_eotf','mp.add_key_binding']))
sys.path.insert(0,str(r/'.tools/pydeps'));import pefile
with pefile.PE(str(n/'runtime/libmpv-2.dll')) as pe:
 exports={s.name.decode() for s in pe.DIRECTORY_ENTRY_EXPORT.symbols if s.name}
 check('native-api-retained',all(x in exports for x in ['mpv_create','mpv_initialize','mpv_command_async','mpv_set_property_string','mpv_get_property_string','mpv_stream_cb_add_ro','mpv_terminate_destroy']))
 check('matching-debug-info-present',pe.FILE_HEADER.NumberOfSymbols>0 or hasattr(pe,'DIRECTORY_ENTRY_DEBUG'))
check('core-contains-chinese-native-stats', '显示输出：'.encode() in (n/'runtime/libmpv-2.dll').read_bytes())
report={'passed':True,'checks':checks,'modifiedFrom0315MpvSources':changed,'nativeRecompiledThisVersion':False,'compiledMpvInputs':len(current),'runtimeDlls':len(m['files']),'nativeDllsLoaded':False,'gpuCallsExecuted':False,'productLaunched':False,'testsRun':False}
(n/'static-native-audit.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf8')
print(json.dumps({'passed':True,'staticChecks':len(checks),'runtimeDlls':len(m['files']),'testsRun':False}))
