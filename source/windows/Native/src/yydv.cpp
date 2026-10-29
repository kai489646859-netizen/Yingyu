// Embedded source reconstruction/carrier backend. No player process or driver.
// SPDX-License-Identifier: GPL-3.0-or-later
#define YYDV_BUILD
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include "yydv.h"
#include "nv_output.h"
#include "DvBlob.h"
#include "DvGpuCarrier.h"
#include <d3d11.h>
#include <dxgi1_4.h>
#include <wrl/client.h>
#include <algorithm>
#include <cmath>
#include <cstring>
#include <limits>
#include <memory>
#include <mutex>
#include <vector>

using Microsoft::WRL::ComPtr;
using namespace DVTUNNEL;
namespace {
LRESULT CALLBACK CarrierProc(HWND h,UINT m,WPARAM w,LPARAM l)
{
 if(m==WM_NCHITTEST)return HTTRANSPARENT;
 if(m==WM_MOUSEACTIVATE)return MA_NOACTIVATE;
 if(m>=WM_MOUSEFIRST&&m<=WM_MOUSELAST){PostMessageW(GetParent(h),m,w,l);return 0;}
 return DefWindowProcW(h,m,w,l);
}
bool Registered()
{
 static std::once_flag once;static bool ok=false;
 std::call_once(once,[]{WNDCLASSW c{};c.lpfnWndProc=CarrierProc;c.hInstance=GetModuleHandleW(nullptr);c.lpszClassName=L"Yingyu.NativeDolby.Carrier.v1";ok=RegisterClassW(&c)!=0||GetLastError()==ERROR_CLASS_ALREADY_EXISTS;});return ok;
}
DvRect Fit(unsigned w,unsigned h,unsigned cw,unsigned ch)
{
 unsigned dw=cw,dh=ch;
 if(uint64_t(w)*ch>=uint64_t(h)*cw)dh=std::min(ch,unsigned(std::llround(double(h)*cw/w/2))*2);
 else dw=std::min(cw,unsigned(std::llround(double(w)*ch/h/2))*2);
 unsigned left=((cw-dw)/2)&~1u,top=((ch-dh)/2)&~1u;return {left,top,left+dw,top+dh};
}
// Keep the original active area when no transform is applied. If the source is
// scaled/letterboxed, transform L5 offsets into the actual carrier canvas.
bool ActiveArea(std::vector<uint8_t>& bytes,unsigned sw,unsigned sh,const DvRect& r,unsigned cw,unsigned ch,const yydv_frame& frame)
{
 if(bytes.size()<71||!sw||!sh)return false;size_t pos=71;unsigned count=bytes[70];
 for(unsigned i=0;i<count;i++){
  if(pos>bytes.size()||bytes.size()-pos<5)return false;
  size_t len=(size_t(bytes[pos])<<24)|(size_t(bytes[pos+1])<<16)|(size_t(bytes[pos+2])<<8)|bytes[pos+3];uint8_t level=bytes[pos+4];pos+=5;
  if(len>bytes.size()-pos)return false;
  if(level==5){
   if(len!=8)return false;unsigned a[4];for(int j=0;j<4;j++)a[j]=(unsigned(bytes[pos+j*2])<<8)|bytes[pos+j*2+1];
   if(a[0]+a[1]>=sw||a[2]+a[3]>=sh)return false;
   unsigned b[4]={r.left+unsigned(std::llround(double(a[0])*(r.right-r.left)/sw)),cw-r.right+unsigned(std::llround(double(a[1])*(r.right-r.left)/sw)),r.top+unsigned(std::llround(double(a[2])*(r.bottom-r.top)/sh)),ch-r.bottom+unsigned(std::llround(double(a[3])*(r.bottom-r.top)/sh))};
   if(frame.osd_bgra&&frame.osd_left<frame.osd_right&&frame.osd_top<frame.osd_bottom&&frame.osd_right<=cw&&frame.osd_bottom<=ch){b[0]=std::min(b[0],frame.osd_left);b[1]=std::min(b[1],cw-frame.osd_right);b[2]=std::min(b[2],frame.osd_top);b[3]=std::min(b[3],ch-frame.osd_bottom);}
   for(int j=0;j<4;j++){if(b[j]>65535)return false;bytes[pos+j*2]=uint8_t(b[j]>>8);bytes[pos+j*2+1]=uint8_t(b[j]);}
  }pos+=len;
 }return pos==bytes.size();
}
struct Context {
 HWND parent=nullptr,window=nullptr;
 HMONITOR monitor=nullptr;
 yingyu::NvOutput output;
 ComPtr<ID3D11Device> device;
 ComPtr<ID3D11DeviceContext> immediate;
 ComPtr<IDXGISwapChain1> swap;
 ComPtr<ID3D11Texture2D> base,enhancement,packed,composited,gui;
 CDvGpuCarrier carrier;
 yydv_status status{};
 unsigned width=0,height=0;
 bool pending=false,pendingFel=false,lastFrameValid=false,lastHasGui=false;
 ULONGLONG retryAfter=0,lastVerify=0;
 explicit Context(HWND h):parent(h){status.size=sizeof(status);status.abi=YYDV_ABI;status.last_pts=std::numeric_limits<double>::quiet_NaN();if(Registered())window=CreateWindowExW(WS_EX_NOACTIVATE,L"Yingyu.NativeDolby.Carrier.v1",L"",WS_CHILD|WS_CLIPSIBLINGS,0,0,1,1,parent,nullptr,GetModuleHandleW(nullptr),nullptr);}
 ~Context(){Suspend(YYDV_OK);carrier.Release();swap.Reset();if(window)DestroyWindow(window);}
 void CaptureOutput(){auto d=output.Diagnostic();status.output_stage=d.stage;status.output_flags=d.flags;status.output_caps_version=d.capsVersion;status.output_technology=d.technology;status.output_result=d.result;status.initial_caps_result=d.initialCapsResult;}
 void Suspend(unsigned reason){if(window)ShowWindow(window,SW_HIDE);bool restored=output.Leave();CaptureOutput();pending=false;lastFrameValid=false;status.active=0;status.reason=restored?reason:YYDV_RESTORE_FAILED;if(!restored)status.fatal=1;}
 int Fallback(unsigned reason){Suspend(reason);return status.fatal?YYDV_FATAL:YYDV_FALLBACK;}
 int Fatal(unsigned reason){Suspend(reason);status.fatal=1;status.frame_complete=0;return YYDV_FATAL;}
 void Reset(uint64_t epoch){Suspend(YYDV_OK);if(status.reason==YYDV_RESTORE_FAILED)return;output.ResetDiagnostic();status={};status.size=sizeof(status);status.abi=YYDV_ABI;status.epoch=epoch;status.last_pts=std::numeric_limits<double>::quiet_NaN();pendingFel=false;retryAfter=0;}
 bool Fullscreen()
 {
  RECT rc{};POINT origin{};MONITORINFO info{sizeof(info)};HMONITOR hm=MonitorFromWindow(parent,MONITOR_DEFAULTTONEAREST);
  if(!GetClientRect(parent,&rc)||!ClientToScreen(parent,&origin)||!GetMonitorInfoW(hm,&info))return false;
  return std::abs(origin.x-info.rcMonitor.left)<=1&&std::abs(origin.y-info.rcMonitor.top)<=1&&std::abs((rc.right-rc.left)-(info.rcMonitor.right-info.rcMonitor.left))<=1&&std::abs((rc.bottom-rc.top)-(info.rcMonitor.bottom-info.rcMonitor.top))<=1;
 }
 bool Device()
 {
  HMONITOR hm=MonitorFromWindow(parent,MONITOR_DEFAULTTONEAREST);RECT rc{};if(!GetClientRect(parent,&rc)||rc.right<=0||rc.bottom<=0)return false;
  unsigned w=unsigned(rc.right),h=unsigned(rc.bottom);
  if(device&&monitor==hm&&width==w&&height==h)return true;
  Suspend(YYDV_OK);if(status.reason==YYDV_RESTORE_FAILED)return false;carrier.Release();base.Reset();enhancement.Reset();packed.Reset();composited.Reset();gui.Reset();swap.Reset();immediate.Reset();device.Reset();
  ComPtr<IDXGIFactory2> factory;if(FAILED(CreateDXGIFactory1(IID_PPV_ARGS(&factory))))return false;
  ComPtr<IDXGIAdapter1> chosen;
  for(UINT i=0;;i++){
   ComPtr<IDXGIAdapter1> adapter;if(factory->EnumAdapters1(i,&adapter)==DXGI_ERROR_NOT_FOUND)break;
   for(UINT j=0;;j++){ComPtr<IDXGIOutput> out;if(adapter->EnumOutputs(j,&out)==DXGI_ERROR_NOT_FOUND)break;DXGI_OUTPUT_DESC desc{};if(SUCCEEDED(out->GetDesc(&desc))&&desc.Monitor==hm){chosen=adapter;break;}}
   if(chosen)break;
  }
  if(!chosen)return false;
  D3D_FEATURE_LEVEL level{};D3D_FEATURE_LEVEL levels[]={D3D_FEATURE_LEVEL_11_1,D3D_FEATURE_LEVEL_11_0};
  HRESULT hr=D3D11CreateDevice(chosen.Get(),D3D_DRIVER_TYPE_UNKNOWN,nullptr,D3D11_CREATE_DEVICE_BGRA_SUPPORT,levels,2,D3D11_SDK_VERSION,&device,&level,&immediate);
  status.native_result=hr;if(FAILED(hr))return false;
  HRESULT detail{};std::string message;if(!carrier.Initialize(device.Get(),detail,message)){status.native_result=detail;return false;}
  if(!window)return false;
  SetWindowPos(window,HWND_TOP,0,0,int(w),int(h),SWP_NOACTIVATE);
  DXGI_SWAP_CHAIN_DESC1 desc{};desc.Width=w;desc.Height=h;desc.Format=DXGI_FORMAT_B8G8R8A8_UNORM;desc.SampleDesc.Count=1;desc.BufferUsage=DXGI_USAGE_RENDER_TARGET_OUTPUT;desc.BufferCount=2;desc.Scaling=DXGI_SCALING_NONE;desc.SwapEffect=DXGI_SWAP_EFFECT_FLIP_DISCARD;desc.AlphaMode=DXGI_ALPHA_MODE_IGNORE;
  hr=factory->CreateSwapChainForHwnd(device.Get(),window,&desc,nullptr,nullptr,&swap);status.native_result=hr;if(FAILED(hr))return false;
  factory->MakeWindowAssociation(window,DXGI_MWA_NO_ALT_ENTER);
  ComPtr<IDXGISwapChain3> s3;if(SUCCEEDED(swap.As(&s3)))if(FAILED(status.native_result=s3->SetColorSpace1(DXGI_COLOR_SPACE_RGB_FULL_G22_NONE_P709)))return false;
  D3D11_TEXTURE2D_DESC td{};td.Width=w;td.Height=h;td.MipLevels=td.ArraySize=1;td.Format=desc.Format;td.SampleDesc.Count=1;td.Usage=D3D11_USAGE_DEFAULT;td.BindFlags=D3D11_BIND_SHADER_RESOURCE|D3D11_BIND_RENDER_TARGET;
  if(FAILED(status.native_result=device->CreateTexture2D(&td,nullptr,&packed))||FAILED(status.native_result=device->CreateTexture2D(&td,nullptr,&composited)))return false;
  monitor=hm;width=w;height=h;return true;
 }
 bool Upload(const yydv_picture& pic,ComPtr<ID3D11Texture2D>& texture)
 {
  if(pic.size!=sizeof(pic)||pic.width==0||pic.height==0||pic.width>8192||pic.height>8192||pic.width%2||pic.height%2||!pic.planes[0]||!pic.planes[1])return false;
  size_t pitch=size_t(pic.width)*2;if(pic.stride[0]<int(pitch)||pic.stride[0]>1<<24)return false;
  std::vector<uint8_t> data(pitch*(pic.height+pic.height/2));
  if(pic.format==YYDV_P010){
   if(pic.stride[1]<int(pitch)||pic.stride[1]>1<<24)return false;
   for(unsigned y=0;y<pic.height;y++)std::memcpy(data.data()+pitch*y,pic.planes[0]+size_t(pic.stride[0])*y,pitch);
   for(unsigned y=0;y<pic.height/2;y++)std::memcpy(data.data()+pitch*(pic.height+y),pic.planes[1]+size_t(pic.stride[1])*y,pitch);
  }else if(pic.format==YYDV_YUV420P10){
   if(!pic.planes[2]||pic.stride[1]<int(pic.width)||pic.stride[2]<int(pic.width)||pic.stride[1]>1<<24||pic.stride[2]>1<<24)return false;
   for(unsigned y=0;y<pic.height;y++){auto in=reinterpret_cast<const uint16_t*>(pic.planes[0]+size_t(pic.stride[0])*y);auto out=reinterpret_cast<uint16_t*>(data.data()+pitch*y);for(unsigned x=0;x<pic.width;x++){if(in[x]>1023)return false;out[x]=uint16_t(in[x]<<6);}}
   for(unsigned y=0;y<pic.height/2;y++){auto u=reinterpret_cast<const uint16_t*>(pic.planes[1]+size_t(pic.stride[1])*y);auto v=reinterpret_cast<const uint16_t*>(pic.planes[2]+size_t(pic.stride[2])*y);auto out=reinterpret_cast<uint16_t*>(data.data()+pitch*(pic.height+y));for(unsigned x=0;x<pic.width/2;x++){if(u[x]>1023||v[x]>1023)return false;out[2*x]=uint16_t(u[x]<<6);out[2*x+1]=uint16_t(v[x]<<6);}}
  }else return false;
  D3D11_TEXTURE2D_DESC old{};if(texture)texture->GetDesc(&old);if(old.Width!=pic.width||old.Height!=pic.height){texture.Reset();D3D11_TEXTURE2D_DESC d{};d.Width=pic.width;d.Height=pic.height;d.MipLevels=d.ArraySize=1;d.Format=DXGI_FORMAT_P010;d.SampleDesc.Count=1;d.Usage=D3D11_USAGE_DEFAULT;d.BindFlags=D3D11_BIND_SHADER_RESOURCE;if(FAILED(device->CreateTexture2D(&d,nullptr,&texture)))return false;}
  immediate->UpdateSubresource(texture.Get(),0,nullptr,data.data(),UINT(pitch),0);return true;
 }
 bool UploadGui(const yydv_frame& frame)
 {
  if(!frame.osd_bgra)return true;
  if(!frame.osd_srgb||frame.osd_width!=width||frame.osd_height!=height||frame.osd_stride<width*4||frame.osd_stride>(1u<<26))return false;
  if(!gui){D3D11_TEXTURE2D_DESC d{};d.Width=width;d.Height=height;d.MipLevels=d.ArraySize=1;d.Format=DXGI_FORMAT_B8G8R8A8_UNORM;d.SampleDesc.Count=1;d.Usage=D3D11_USAGE_DEFAULT;d.BindFlags=D3D11_BIND_SHADER_RESOURCE;if(FAILED(device->CreateTexture2D(&d,nullptr,&gui)))return false;}
  immediate->UpdateSubresource(gui.Get(),0,nullptr,frame.osd_bgra,frame.osd_stride,0);return true;
 }
 int Render(const yydv_frame& f)
 {
  if(f.size!=sizeof(f)||f.base.size!=sizeof(f.base))return Fatal(YYDV_PIXELS_UNSUPPORTED);
  if(status.epoch!=f.epoch)Reset(f.epoch);
  if(status.fatal)return YYDV_FATAL;
  pending=false;pendingFel=false;status.frame_complete=0;status.source_profile=f.profile;status.last_pts=f.base.pts;
  if(!IsSupportedProfile(int(f.profile),int(f.compatibility)))return Fallback(YYDV_PROFILE_UNSUPPORTED);
  if(!f.metadata||f.metadata_size<sizeof(AVDOVIMetadata)||f.metadata_size>1024*1024)return Fatal(YYDV_METADATA_MISSING);
  if(ClassifyMetadata(f.metadata,f.metadata_size,int(f.profile),int(f.compatibility))!=DvVerdict::ACCEPTED)return Fatal(YYDV_METADATA_INVALID);
  auto single=ReadSingleLayerMapping(f.metadata,f.metadata_size);auto mapping=single?single:ReadComposerMapping(f.metadata,f.metadata_size);if(!mapping)return Fatal(YYDV_METADATA_INVALID);
  status.residual_required=mapping->residual;
  if(!std::isfinite(f.base.pts))return Fatal(YYDV_PTS_INVALID);
  if(mapping->residual){
   if(f.profile!=7||f.enhancement.size!=sizeof(f.enhancement)||!f.enhancement.planes[0])return Fatal(YYDV_EL_MISSING);
   if(!std::isfinite(f.enhancement.pts)||std::abs(f.enhancement.pts-f.base.pts)>0.000001)return Fatal(YYDV_PTS_INVALID);
   if(f.enhancement.width*2!=f.base.width||f.enhancement.height*2!=f.base.height)return Fallback(YYDV_PIXELS_UNSUPPORTED);
  }
  status.frame_complete=1;
  if(!f.ui_safe)return Fallback(YYDV_UI_VISIBLE);
  if(!Fullscreen())return Fallback(YYDV_WINDOWED);
  if(GetForegroundWindow()!=GetAncestor(parent,GA_ROOT))return Fallback(YYDV_NOT_FOREGROUND);
  if(f.osd_bgra&&!f.osd_srgb)return Fallback(YYDV_SUBTITLE_COLOR_UNSUPPORTED);
  ULONGLONG now=GetTickCount64();if(!output.Active()&&now<retryAfter)return YYDV_FALLBACK;
  if(!Device()){retryAfter=now+5000;return Fallback(YYDV_DEVICE_LOST);}
  if(mapping->residual&&!carrier.ComposerAvailable())return Fallback(YYDV_COMPOSER_UNAVAILABLE);
  if(!Upload(f.base,base)||mapping->residual&&!Upload(f.enhancement,enhancement))return Fallback(YYDV_UPLOAD_FAILED);
  DvTables tables{};DvReshapeLut lut{};if(!BuildTables(*mapping,tables)||single&&!BuildReshapeLut(tables,lut))return Fallback(YYDV_METADATA_INVALID);
  auto metadata=SerializeDisplayMetadata(f.metadata,f.metadata_size);if(!metadata)return Fallback(YYDV_PACKET_FAILED);
  unsigned dw=f.display_width?f.display_width:f.base.width,dh=f.display_height?f.display_height:f.base.height;
  DvRect picture=Fit(dw,dh,width,height);if(picture.IsEmpty()||!ActiveArea(metadata->bytes,f.base.width,f.base.height,picture,width,height,f))return Fallback(YYDV_PACKET_FAILED);
  auto packets=Packetize(metadata->bytes);if(!packets)return Fallback(YYDV_PACKET_FAILED);
  DvPicture bl{base.Get(),0,f.base.width,f.base.height},el{enhancement.Get(),0,f.enhancement.width,f.enhancement.height};
  bool scaled=picture.right-picture.left!=f.base.width||picture.bottom-picture.top!=f.base.height||!single&&(width!=f.base.width||height!=f.base.height);
  DvCarrierParams params{picture,&*packets,scaled?picture:DvRect{}};
  bool packedOk=single?carrier.PackReshape(bl,scaled?0:picture.left,scaled?0:picture.top,lut,params,packed.Get()):carrier.PackCompose(bl,mapping->residual?&el:nullptr,tables,params,packed.Get());
  if(!packedOk){status.native_result=device->GetDeviceRemovedReason();return Fallback(YYDV_COMPOSE_FAILED);}
  if(f.osd_bgra){
   const double bt709to2020[3][3]={{0.627404,0.329283,0.0433136},{0.069097,0.919540,0.0113612},{0.0163916,0.0880132,0.895595}};
   auto transform=BuildGuiTransform(metadata->colour,bt709to2020);
   if(!transform||!UploadGui(f)||!carrier.CompositeGui(packed.Get(),packets->size(),gui.Get(),composited.Get(),*transform))return Fallback(YYDV_GUI_FAILED);
  }
  int reason=YYDV_OK;if(!output.Active()&&!output.Enter(parent,int(width),int(height),reason)){retryAfter=now+5000;return Fallback(unsigned(reason));}
  if(now-lastVerify>=500){lastVerify=now;if(!output.Verify())return Fallback(YYDV_NVAPI_REJECTED);}
  status.frames_packed++;if(mapping->residual)status.fel_composed++;pendingFel=mapping->residual;pending=true;lastFrameValid=true;lastHasGui=f.osd_bgra!=nullptr;status.reason=YYDV_OK;return YYDV_PACKED;
 }
 int Present()
 {
  if(!pending&&!lastFrameValid)return status.fatal?YYDV_FATAL:YYDV_FALLBACK;
  pending=false;
  if(!output.Active())return Fallback(YYDV_NVAPI_REJECTED);
  if(!Fullscreen()||GetForegroundWindow()!=GetAncestor(parent,GA_ROOT))return Fallback(YYDV_NOT_FOREGROUND);
  ULONGLONG now=GetTickCount64();if(now-lastVerify>=500){lastVerify=now;if(!output.Verify())return Fallback(YYDV_NVAPI_REJECTED);}
  ComPtr<ID3D11Texture2D> target;HRESULT copy=swap->GetBuffer(0,IID_PPV_ARGS(&target));if(FAILED(copy)){status.native_result=copy;return Fallback(YYDV_DEVICE_LOST);}
  immediate->CopyResource(target.Get(),lastHasGui?composited.Get():packed.Get());immediate->Flush();
  ShowWindow(window,SW_SHOWNOACTIVATE);HRESULT hr=swap->Present(1,0);status.native_result=hr;
  if(hr!=S_OK)return Fallback(YYDV_PRESENT_FAILED);
  status.frames_presented++;if(pendingFel)status.fel_presented++;status.active=1;status.reason=YYDV_OK;return YYDV_PACKED;
 }
};
}
extern "C" {
uint32_t YYDV_CALL yydv_abi(void){return YYDV_ABI;}
yydv_context YYDV_CALL yydv_create(void* parent){try{return parent?new Context(static_cast<HWND>(parent)):nullptr;}catch(...){return nullptr;}}
int YYDV_CALL yydv_render(yydv_context p,const yydv_frame* f){if(!p||!f)return YYDV_FATAL;try{return static_cast<Context*>(p)->Render(*f);}catch(...){return static_cast<Context*>(p)->Fatal(YYDV_DEVICE_LOST);}}
int YYDV_CALL yydv_present(yydv_context p){if(!p)return YYDV_FATAL;try{return static_cast<Context*>(p)->Present();}catch(...){return static_cast<Context*>(p)->Fallback(YYDV_DEVICE_LOST);}}
void YYDV_CALL yydv_reset(yydv_context p,uint64_t e){if(p)static_cast<Context*>(p)->Reset(e);}
void YYDV_CALL yydv_suspend(yydv_context p,uint32_t r){if(p)static_cast<Context*>(p)->Suspend(r);}
int YYDV_CALL yydv_get_status(yydv_context p,yydv_status* status){if(!p||!status||status->size!=sizeof(*status))return 0;auto context=static_cast<Context*>(p);context->CaptureOutput();*status=context->status;return 1;}
void YYDV_CALL yydv_destroy(yydv_context p){delete static_cast<Context*>(p);}
}
