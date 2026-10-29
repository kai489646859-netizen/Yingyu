"""Post-process the pinned mpv + original integration; source edits only."""
from pathlib import Path
import json,sys,shutil
n=Path(__file__).resolve().parent
root=Path(sys.argv[1]).resolve()
def change(path,old,new):
 p=root/path;s=p.read_text(encoding='utf8')
 if s.count(old)!=1:raise RuntimeError(f'{path}: expected one anchor')
 p.write_text(s.replace(old,new),encoding='utf8',newline='\n')

# Source integrity checks above this gate are intentionally kept. Never alternate
# BL-only/FEL or enter the native byte carrier while playing the HDR10 route.
p=root/'video/out/yydv_mpv.c';s=p.read_text(encoding='utf8')
a=s.index('    if(d->context&&!d->ui_safe)return yydv_fallback(vo,YYDV_UI_VISIBLE);')
b=s.index('static int yydv_control(',a)
s=s[:a]+"    // HDR10 policy, after required EL/metadata/PTS validation.\n    // No transport DLL, NVAPI call or display mode switch.\n    return yydv_fallback(vo,YYDV_HDR10_POLICY);\n}\n\n"+s[b:]
p.write_text(s,encoding='utf8',newline='\n')
shutil.copyfile(n/'include/yydv.h',root/'video/out/yydv.h')
# Use actual display/swapchain luminance; never reinterpret source mastering data as display capability.
change('video/out/vo_gpu_next.c', '    if(p->native_dv.source_dolby && frame->current) {\n        target_csp=frame->current->params.color;\n        target_csp.transfer=PL_COLOR_TRC_PQ;\n        target_csp.primaries=PL_COLOR_PRIM_BT_2020;\n        if(!target_csp.hdr.max_luma)target_csp.hdr.max_luma=1000;\n        target_hint=true;target_unknown=false;\n    }\n', '')
translations=json.loads((n/'stats-zh-CN.json').read_text(encoding='utf8'))
p=root/'player/lua/stats.lua';s=p.read_text(encoding='utf8')
for old,new in translations.items():
 quoted=json.dumps(old,ensure_ascii=False)
 if quoted not in s:raise RuntimeError('Missing native stats string: '+old)
 s=s.replace(quoted,json.dumps(new,ensure_ascii=False))
s=s.replace('frame:gsub("^%l", string.upper)', '({fresh="新帧",redraw="重绘"})[frame] or frame:gsub("^%l", string.upper)')
s=s.replace('    font = "",','    font = "Microsoft YaHei",',1)
s=s.replace('    font_size = 20,','    font_size = 18,',1)
# Localize enum values only in their display fields; never alter properties,
# arbitrary filenames, metadata values, numeric calculations or codec IDs.
anchor='    attr.prefix_sep = attr.prefix_sep or o.prefix_sep'
extra='''    if attr.prefix == "量化范围：" then
        str = ({full="full（全范围）",limited="limited（有限范围）"})[str] or str
    elseif attr.prefix == "传递曲线：" then
        str = ({pq="pq（HDR 曲线）",hlg="hlg（广播 HDR）"})[str] or str
    elseif attr.prefix == "色彩矩阵：" and str == "dolbyvision" then
        str = "dolbyvision（杜比源数据）"
    end
'''
if s.count(anchor)!=1:raise RuntimeError('Native stats display seam changed')
s=s.replace(anchor,extra+anchor)
p.write_text(s,encoding='utf8',newline='\n')
print('HDR10 policy and native Chinese stats source applied; no product execution')
