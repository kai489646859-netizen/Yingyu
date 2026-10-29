#pragma once
#include <windows.h>
#include <memory>
#include <cstdint>
namespace yingyu {
enum OutputStage : uint32_t {
 OutputIdle, OutputMonitor, OutputDesktopColor, OutputNvInit, OutputDisplayId,
 OutputCapsV3, OutputCapsV2, OutputSinkDolby, OutputSinkInterface,
 OutputHdrSnapshot, OutputDisplayConfig, OutputTimingClass, OutputTimingEdid,
 OutputTimingCurrent, OutputTimingTrial, OutputTimingReadback, OutputSignalSet,
 OutputSignalReadback, OutputReady, OutputRestoreTiming, OutputRestoreSignal
};
enum OutputFlag : uint32_t {
 OutputNvInitialized=1, OutputIdKnown=2, OutputCapsKnown=4, OutputDolby=8,
 OutputStandardDolby=16, OutputHdmi=32, OutputDesktopKnown=64,
 OutputDesktopHdr=128, OutputTimingKnown=256, OutputSignalSent=512,
 OutputSignalConfirmed=1024
};
struct NvOutputDiagnostic {
 uint32_t stage=OutputIdle,flags=0,capsVersion=0,technology=0xffffffffu;
 int32_t result=0,initialCapsResult=0;
};
class NvOutput {
 struct Impl;
 std::unique_ptr<Impl> p;
public:
 NvOutput();~NvOutput();
 bool Enter(HWND window,int width,int height,int &reason);
 bool Verify();
 bool Active() const;
 bool Leave();
 NvOutputDiagnostic Diagnostic() const;
 void ResetDiagnostic();
};
}
