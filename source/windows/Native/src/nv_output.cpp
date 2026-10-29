// Adapted from dane-9/xbmc 5da44c2547bae530354524ddc0a00cc5b5bae0da.
// SPDX-License-Identifier: GPL-2.0-or-later
#include "nv_output.h"
#include "yydv.h"
#include <nvapi.h>
#include <cmath>
#include <optional>
#include <string>
#include <vector>
#include <cstdint>
#include <algorithm>
namespace {
using namespace yingyu;
enum {LOGDEBUG,LOGWARNING,LOGERROR};
// SDK outcomes are returned through typed status; never persist display names.
struct CLog {template<class... T> static void Log(int,const char*,const T&...) {}};
struct HdmiVicFormat
{
  NvU16 width;
  NvU16 height;
  NvU16 hFrontPorch;
  NvU16 hSyncWidth;
  NvU16 hTotal;
  NvU16 vFrontPorch;
  NvU16 vSyncWidth;
  NvU16 vTotal;
  NvU32 pclk;
  NvU32 rrx1k;
  unsigned numerator;
  unsigned denominator;
};

constexpr HdmiVicFormat HDMI_VIC_FORMATS[] = {
    {3840, 2160, 1276, 88, 5500, 8, 10, 2250, 29670, 23976, 24000, 1001},
    {3840, 2160, 1276, 88, 5500, 8, 10, 2250, 29700, 24000, 24, 1},
    {3840, 2160, 1056, 88, 5280, 8, 10, 2250, 29700, 25000, 25, 1},
    {3840, 2160, 176, 88, 4400, 8, 10, 2250, 29670, 29970, 30000, 1001},
    {3840, 2160, 1056, 88, 5280, 8, 10, 2250, 59400, 50000, 50, 1},
    {3840, 2160, 176, 88, 4400, 8, 10, 2250, 59341, 59940, 60000, 1001},
    {3840, 2160, 176, 88, 4400, 8, 10, 2250, 59400, 60000, 60, 1},
    {1920, 1080, 638, 44, 2750, 4, 5, 1125, 7418, 23976, 24000, 1001},
    {1920, 1080, 638, 44, 2750, 4, 5, 1125, 7425, 24000, 24, 1},
    {1920, 1080, 528, 44, 2640, 4, 5, 1125, 7425, 25000, 25, 1},
    {1920, 1080, 88, 44, 2200, 4, 5, 1125, 7418, 29970, 30000, 1001},
    {1920, 1080, 528, 44, 2640, 4, 5, 1125, 14850, 50000, 50, 1},
    {1920, 1080, 88, 44, 2200, 4, 5, 1125, 14835, 59940, 60000, 1001},
    {1920, 1080, 88, 44, 2200, 4, 5, 1125, 14850, 60000, 60, 1},
};

// Low 16 bits of the timing status: subtype 0x1b (the driver's HDMI_VIC timing)
// with HDMI_VIC 0. Current drivers only put the HDMI OUI in the mode-7 vendor
// InfoFrame for an HDMI_VIC timing; with this tag they send the classic Dolby
// Vision InfoFrame (format 0x20, HDMI_VIC byte 0xfe), which names no mode.
// Reverting the timing ends Dolby Vision output. The value is inferred from
// the driver, not documented by NVIDIA.
constexpr NvU32 DOLBY_VISION_TIMING_STATUS = 0x1b00;
const HdmiVicFormat* FormatFor(long width, long height, double refresh)
{
  for (const HdmiVicFormat& format : HDMI_VIC_FORMATS)
  {
    if (format.width == width && format.height == height &&
        std::abs(refresh - static_cast<double>(format.numerator) / format.denominator) < 0.01)
      return &format;
  }
  return nullptr;
}

struct ActiveDisplay
{
  const HdmiVicFormat* format{nullptr};
  double refresh{0.0};
  bool hdmi{false};
  NvU32 technology=0xffffffffu;
  LONG queryResult=ERROR_NOT_FOUND;
};

// The output of Kodi's display, identified by its GDI source name.
ActiveDisplay GetActiveDisplay(const std::wstring& gdiName)
{
  ActiveDisplay display;
  UINT32 pathCount = 0;
  UINT32 modeCount = 0;
  LONG status = GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS, &pathCount, &modeCount);
  if (status != ERROR_SUCCESS || pathCount == 0) {display.queryResult=status!=ERROR_SUCCESS?status:ERROR_NOT_FOUND;return display;}

  std::vector<DISPLAYCONFIG_PATH_INFO> paths(pathCount);
  std::vector<DISPLAYCONFIG_MODE_INFO> modes(modeCount);
  status = QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS, &pathCount, paths.data(), &modeCount,
                              modes.data(), nullptr);
  if (status != ERROR_SUCCESS) {display.queryResult=status;return display;}

  for (UINT32 i = 0; i < pathCount; ++i)
  {
    const DISPLAYCONFIG_PATH_INFO& path = paths[i];
    DISPLAYCONFIG_SOURCE_DEVICE_NAME source{};
    source.header = {DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME, sizeof(source),
                     path.sourceInfo.adapterId, path.sourceInfo.id};
    if (DisplayConfigGetDeviceInfo(&source.header) != ERROR_SUCCESS ||
        _wcsicmp(source.viewGdiDeviceName, gdiName.c_str()) != 0)
      continue;

    display.technology=path.targetInfo.outputTechnology;
    display.hdmi = path.targetInfo.outputTechnology == DISPLAYCONFIG_OUTPUT_TECHNOLOGY_HDMI;
    if (path.targetInfo.modeInfoIdx >= modeCount ||
        modes[path.targetInfo.modeInfoIdx].infoType != DISPLAYCONFIG_MODE_INFO_TYPE_TARGET)
      return display;

    const DISPLAYCONFIG_VIDEO_SIGNAL_INFO& signal =
        modes[path.targetInfo.modeInfoIdx].targetMode.targetVideoSignalInfo;
    display.refresh = path.targetInfo.refreshRate.Denominator == 0
                          ? 0.0
                          : static_cast<double>(path.targetInfo.refreshRate.Numerator) /
                                path.targetInfo.refreshRate.Denominator;
    display.format = FormatFor(signal.activeSize.cx, signal.activeSize.cy, display.refresh);
    display.queryResult=ERROR_SUCCESS;
    return display;
  }
  return display;
}

// The tunnel is TV-led ("standard") Dolby Vision. Version 0 and 1 Dolby VSVDBs
// always include it; version 2 sinks state it in the interface field, where 0
// and 1 mean low-latency (player-led) only.
std::optional<NvU32> OpenDisplay(const std::wstring& gdiName,NvOutputDiagnostic& diagnostic,int& reason)
{
 diagnostic.stage=OutputNvInit;
 NvAPI_Status result=NvAPI_Initialize();diagnostic.result=result;
 if(result!=NVAPI_OK){reason=YYDV_NVAPI_UNAVAILABLE;return {};}
 diagnostic.flags|=OutputNvInitialized;
 std::string name;for(wchar_t c:gdiName)name+=static_cast<char>(c);
 NvU32 id=0;diagnostic.stage=OutputDisplayId;
 result=NvAPI_DISP_GetDisplayIdByDisplayName(name.c_str(),&id);diagnostic.result=result;
 if(result!=NVAPI_OK){reason=YYDV_DISPLAY_UNSUPPORTED;NvAPI_Unload();return {};}
 diagnostic.flags|=OutputIdKnown;
 NV_HDR_CAPABILITIES caps{};caps.version=NV_HDR_CAPABILITIES_VER3;
 diagnostic.stage=OutputCapsV3;diagnostic.capsVersion=3;
 result=NvAPI_Disp_GetHdrCapabilities(id,&caps);diagnostic.initialCapsResult=result;
 bool dolby=false;unsigned vsvdb=0,interfaceType=0;
 if(result==NVAPI_INCOMPATIBLE_STRUCT_VERSION){
  // Retry only the documented structure-version rejection. Never override a
  // successful query that explicitly reports no Dolby Vision capability.
  NV_HDR_CAPABILITIES_V2 v2{};v2.version=NV_HDR_CAPABILITIES_VER2;
  diagnostic.stage=OutputCapsV2;diagnostic.capsVersion=2;
  result=NvAPI_Disp_GetHdrCapabilities(id,reinterpret_cast<NV_HDR_CAPABILITIES*>(&v2));
  if(result==NVAPI_OK){dolby=v2.isDolbyVisionSupported!=0;vsvdb=v2.dv_static_metadata.VSVDB_version;interfaceType=v2.dv_static_metadata.interface_supported_by_sink;}
 }else if(result==NVAPI_OK){dolby=caps.isDolbyVisionSupported!=0;vsvdb=caps.dv_static_metadata.VSVDB_version;interfaceType=caps.dv_static_metadata.interface_supported_by_sink;}
 diagnostic.result=result;
 if(result!=NVAPI_OK){reason=YYDV_NVAPI_REJECTED;NvAPI_Unload();return {};}
 diagnostic.flags|=OutputCapsKnown;diagnostic.stage=OutputSinkDolby;
 if(!dolby){reason=YYDV_DISPLAY_UNSUPPORTED;NvAPI_Unload();return {};}
 diagnostic.flags|=OutputDolby;diagnostic.stage=OutputSinkInterface;
 if(vsvdb>=2&&interfaceType<2){reason=YYDV_LOW_LATENCY_ONLY;NvAPI_Unload();return {};}
 diagnostic.flags|=OutputStandardDolby;
 return id;
}

std::optional<NV_HDR_COLOR_DATA> GetHdr(NvU32 displayId,NvAPI_Status* observed=nullptr)
{
  NV_HDR_COLOR_DATA hdr{};
  hdr.version = NV_HDR_COLOR_DATA_VER;
  hdr.cmd = NV_HDR_CMD_GET;
  auto result=NvAPI_Disp_HdrColorControl(displayId,&hdr);if(observed)*observed=result;
  if(result!=NVAPI_OK)return {};
  return hdr;
}

NvAPI_Status SetHdrStatus(NvU32 displayId, NV_HDR_COLOR_DATA hdr)
{
  hdr.version = NV_HDR_COLOR_DATA_VER;
  hdr.cmd = NV_HDR_CMD_SET;
  return NvAPI_Disp_HdrColorControl(displayId, &hdr);
}

bool ReportedSdr(NvU32 displayId)
{
  NV_DISPLAY_OUTPUT_MODE mode{};
  return NvAPI_Disp_GetOutputMode(displayId, &mode) == NVAPI_OK &&
         mode == NV_DISPLAY_OUTPUT_MODE_SDR;
}

std::optional<NV_TIMING> GetTiming(NvU32 displayId,
                                   NV_TIMING_OVERRIDE type,
                                   NvU32 width = 0,
                                   NvU32 height = 0,
                                   float refresh = 0.0f, NvAPI_Status* observed=nullptr)
{
  NV_TIMING_INPUT input{};
  input.version = NV_TIMING_INPUT_VER;
  input.type = type;
  if (type != NV_TIMING_OVERRIDE_CURRENT)
  {
    input.width = width;
    input.height = height;
    input.rr = refresh;
  }
  NV_TIMING timing{};
  auto result=NvAPI_DISP_GetTiming(displayId,&input,&timing);if(observed)*observed=result;
  if(result!=NVAPI_OK)return {};
  return timing;
}

bool IsMovieTiming(const NV_TIMING& t, const HdmiVicFormat& format)
{
  return t.HVisible == format.width && t.VVisible == format.height && t.HBorder == 0 &&
         t.VBorder == 0 && t.HTotal == format.hTotal && t.VTotal == format.vTotal &&
         t.pclk + 1 >= format.pclk && t.pclk <= format.pclk + 1 &&
         t.HFrontPorch == format.hFrontPorch && t.HSyncWidth == format.hSyncWidth &&
         t.VFrontPorch == format.vFrontPorch && t.VSyncWidth == format.vSyncWidth &&
         t.HSyncPol == 0 && t.VSyncPol == 0 && t.interlaced == 0 &&
         t.etc.rrx1k + 1 >= format.rrx1k && t.etc.rrx1k <= format.rrx1k + 1;
}

bool HasHdmiVicTiming(NvU32 displayId, const HdmiVicFormat& format)
{
  const std::optional<NV_TIMING> current = GetTiming(displayId, NV_TIMING_OVERRIDE_CURRENT);
  const bool tagged = current && IsMovieTiming(*current, format) &&
                      (current->etc.status & 0xffff) == DOLBY_VISION_TIMING_STATUS;
  if (!tagged)
    CLog::Log(LOGERROR, "Dolby Vision output: the HDMI_VIC 0 timing is missing (status {:#x}).",
              current ? current->etc.status : 0);
  return tagged;
}

bool ApplyHdmiVicTiming(NvU32 displayId, const HdmiVicFormat& format, bool& applied,NvOutputDiagnostic& diagnostic)
{
  // The EDID lookup can return the 1000/1001 variant; the current mode is the
  // one Kodi switched to.
  diagnostic.stage=OutputTimingEdid;NvAPI_Status result=NVAPI_OK;
  std::optional<NV_TIMING> timing =
      GetTiming(displayId, NV_TIMING_OVERRIDE_EDID, format.width, format.height,
                static_cast<float>(format.numerator) / format.denominator,&result);diagnostic.result=result;
  if (!timing || !IsMovieTiming(*timing, format)){
    diagnostic.stage=OutputTimingCurrent;timing=GetTiming(displayId,NV_TIMING_OVERRIDE_CURRENT,0,0,0,&result);diagnostic.result=result;
  }
  if (!timing || !IsMovieTiming(*timing, format))
  {
    CLog::Log(
        LOGERROR, "Dolby Vision output: the EDID {}x{}/{:.3f} timing is not the expected one.",
        format.width, format.height, static_cast<double>(format.numerator) / format.denominator);
    return false;
  }
  timing->etc.status = (timing->etc.status & 0xffff0000u) | DOLBY_VISION_TIMING_STATUS;
  NV_CUSTOM_DISPLAY custom{};
  custom.version = NV_CUSTOM_DISPLAY_VER;
  custom.width = format.width;
  custom.height = format.height;
  custom.depth = 32;
  custom.colorFormat = NV_FORMAT_A8R8G8B8;
  custom.srcPartition = {0.0f, 0.0f, 1.0f, 1.0f};
  custom.xRatio = 1.0f;
  custom.yRatio = 1.0f;
  custom.timing = *timing;
  // A trial timing is never saved to the display's mode list.
  NvU32 id = displayId;
  diagnostic.stage=OutputTimingTrial;
  const NvAPI_Status status = NvAPI_DISP_TryCustomDisplay(&id, 1, &custom);diagnostic.result=status;
  if (status != NVAPI_OK)
  {
    CLog::Log(LOGERROR, "Dolby Vision output: HDMI_VIC 0 custom timing rejected ({}).",
              static_cast<int>(status));
    return false;
  }
  applied = true;diagnostic.stage=OutputTimingReadback;
  // The driver applies the timing with a mode set.
  for (unsigned attempt = 0; attempt < 20; ++attempt)
  {
    const std::optional<NV_TIMING> current = GetTiming(displayId,NV_TIMING_OVERRIDE_CURRENT,0,0,0,&result);diagnostic.result=result;
    if (current && IsMovieTiming(*current,format) && (current->etc.status & 0xffff) == DOLBY_VISION_TIMING_STATUS)
      return true;
    Sleep(100);
  }
  CLog::Log(LOGERROR, "Dolby Vision output: the HDMI_VIC 0 timing was not applied.");
  return false;
}

void RevertHdmiVicTiming(NvU32 displayId)
{
  NvU32 id = displayId;
  const NvAPI_Status status = NvAPI_DISP_RevertCustomDisplayTrial(&id, 1);
  if (status != NVAPI_OK)
    CLog::Log(LOGWARNING, "Dolby Vision output: reverting the HDMI_VIC timing failed ({}).",
              static_cast<int>(status));
}


bool DesktopHdrOn(const std::wstring& name,NvOutputDiagnostic& diagnostic) {
 diagnostic.stage=OutputDesktopColor;
 UINT32 pc=0,mc=0;LONG code=GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS,&pc,&mc);
 if(code!=ERROR_SUCCESS){diagnostic.result=code;return false;}
 std::vector<DISPLAYCONFIG_PATH_INFO> paths(pc);std::vector<DISPLAYCONFIG_MODE_INFO> modes(mc);
 code=QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS,&pc,paths.data(),&mc,modes.data(),nullptr);
 if(code!=ERROR_SUCCESS){diagnostic.result=code;return false;}
 for(UINT32 i=0;i<pc;i++){
  DISPLAYCONFIG_SOURCE_DEVICE_NAME source{};source.header={DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME,sizeof(source),paths[i].sourceInfo.adapterId,paths[i].sourceInfo.id};
  if(DisplayConfigGetDeviceInfo(&source.header)!=ERROR_SUCCESS||_wcsicmp(name.c_str(),source.viewGdiDeviceName)!=0)continue;
  DISPLAYCONFIG_GET_ADVANCED_COLOR_INFO info{};info.header={DISPLAYCONFIG_DEVICE_INFO_GET_ADVANCED_COLOR_INFO,sizeof(info),paths[i].targetInfo.adapterId,paths[i].targetInfo.id};
  code=DisplayConfigGetDeviceInfo(&info.header);diagnostic.result=code;
  if(code==ERROR_SUCCESS){diagnostic.flags|=OutputDesktopKnown;if(info.advancedColorEnabled)diagnostic.flags|=OutputDesktopHdr;return info.advancedColorEnabled!=0;}
  return false;
 }
 diagnostic.result=ERROR_NOT_FOUND;return false;
}
}
namespace yingyu {
struct NvOutput::Impl {NvU32 display=0;NV_HDR_COLOR_DATA original{};bool initialized=false,trial=false,active=false;std::wstring name;NvOutputDiagnostic diagnostic;};
NvOutput::NvOutput():p(std::make_unique<Impl>()){}
NvOutput::~NvOutput(){Leave();}
bool NvOutput::Active()const{return p->active;}
NvOutputDiagnostic NvOutput::Diagnostic()const{return p->diagnostic;}
void NvOutput::ResetDiagnostic(){if(!p->active&&!p->trial)p->diagnostic={};}
bool NvOutput::Enter(HWND window,int width,int height,int& reason){
 if(p->active){bool valid=Verify();reason=valid?YYDV_OK:YYDV_NVAPI_REJECTED;return valid;}
 auto& diagnostic=p->diagnostic;diagnostic={};diagnostic.stage=OutputMonitor;
 MONITORINFOEXW monitor{};monitor.cbSize=sizeof(monitor);
 if(!GetMonitorInfoW(MonitorFromWindow(window,MONITOR_DEFAULTTONEAREST),&monitor)){diagnostic.result=GetLastError();reason=YYDV_DISPLAY_UNSUPPORTED;return false;}
 p->name=monitor.szDevice;
 diagnostic.stage=OutputDisplayConfig;auto active=GetActiveDisplay(p->name);diagnostic.result=active.queryResult;diagnostic.technology=active.technology;
 if(active.queryResult!=ERROR_SUCCESS){reason=YYDV_DISPLAY_UNSUPPORTED;return false;}
 if(active.hdmi)diagnostic.flags|=OutputHdmi;
 if(DesktopHdrOn(p->name,diagnostic)){reason=YYDV_DESKTOP_HDR;return false;}
 if(!(diagnostic.flags&OutputDesktopKnown)){reason=YYDV_DISPLAY_UNSUPPORTED;return false;}
 auto display=OpenDisplay(p->name,diagnostic,reason);if(!display)return false;
 p->initialized=true;p->display=*display;diagnostic.stage=OutputHdrSnapshot;
 NvAPI_Status result=NVAPI_OK;auto hdr=GetHdr(p->display,&result);diagnostic.result=result;
 if(!hdr){reason=YYDV_NVAPI_REJECTED;Leave();return false;}p->original=*hdr;
 if(p->original.hdrMode==NV_HDR_MODE_DOLBY_VISION){if(!ReportedSdr(p->display)){reason=YYDV_NVAPI_REJECTED;Leave();return false;}p->original.hdrMode=NV_HDR_MODE_OFF;}
 diagnostic.stage=OutputTimingClass;
 const HdmiVicFormat* format=active.format;
 if(!active.hdmi){reason=YYDV_CONNECTION_UNSUPPORTED;Leave();return false;}
 if(!format||format->width!=width||format->height!=height){reason=YYDV_TIMING_UNSUPPORTED;Leave();return false;}
 diagnostic.flags|=OutputTimingKnown;
 // Keep the current resolution/refresh and never save the trial timing.
 p->trial=false;
 if(!ApplyHdmiVicTiming(p->display,*format,p->trial,diagnostic)){reason=YYDV_TIMING_UNSUPPORTED;Leave();return false;}
 NV_HDR_COLOR_DATA target=p->original;target.hdrMode=NV_HDR_MODE_DOLBY_VISION;target.hdrColorFormat=NV_COLOR_FORMAT_RGB;target.hdrDynamicRange=NV_DYNAMIC_RANGE_VESA;target.hdrBpc=NV_BPC_8;
 diagnostic.stage=OutputSignalSet;p->active=true;result=SetHdrStatus(p->display,target);diagnostic.result=result;
 if(result!=NVAPI_OK){reason=YYDV_NVAPI_REJECTED;Leave();return false;}
 diagnostic.flags|=OutputSignalSent;
 if(!Verify()){reason=YYDV_NVAPI_REJECTED;Leave();return false;}
 reason=YYDV_OK;return true;
}
bool NvOutput::Verify(){
 if(!p->active)return false;
 auto& diagnostic=p->diagnostic;diagnostic.stage=OutputSignalReadback;
 NvAPI_Status result=NVAPI_OK;auto hdr=GetHdr(p->display,&result);diagnostic.result=result;
 auto current=GetActiveDisplay(p->name);
 bool valid=current.hdmi&&current.format&&HasHdmiVicTiming(p->display,*current.format)&&hdr&&hdr->hdrMode==NV_HDR_MODE_DOLBY_VISION&&hdr->hdrColorFormat==NV_COLOR_FORMAT_RGB&&hdr->hdrDynamicRange==NV_DYNAMIC_RANGE_VESA&&hdr->hdrBpc==NV_BPC_8;
 if(valid){diagnostic.flags|=OutputSignalConfirmed;diagnostic.stage=OutputReady;}
 return valid;
}
bool NvOutput::Leave(){
 if(!p)return true;
 bool ok=true;
 if(p->trial){NvU32 id=p->display;auto result=NvAPI_DISP_RevertCustomDisplayTrial(&id,1);if(result==NVAPI_OK)p->trial=false;else {ok=false;p->diagnostic.stage=OutputRestoreTiming;p->diagnostic.result=result;}}
 if(p->active){
  bool restored=false;
  for(unsigned n=0;n<3&&!restored;n++){
   NvAPI_Status set=SetHdrStatus(p->display,p->original);auto observed=GetHdr(p->display);
   restored=set==NVAPI_OK&&observed&&
     (observed->hdrMode==p->original.hdrMode||(p->original.hdrMode==NV_HDR_MODE_OFF&&ReportedSdr(p->display)))&&
     observed->hdrColorFormat==p->original.hdrColorFormat&&
     observed->hdrDynamicRange==p->original.hdrDynamicRange&&observed->hdrBpc==p->original.hdrBpc;
   if(!restored)Sleep(25);
  }
  if(restored)p->active=false;else {ok=false;p->diagnostic.stage=OutputRestoreSignal;}
 }
 if(ok&&p->initialized){NvAPI_Unload();p->initialized=false;p->display=0;}
 return ok;
}
}
