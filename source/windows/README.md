# Yingyu Windows source snapshot

This is the directly browsable integration snapshot for **Yingyu Windows 0.5.8**.

Included:

- `Runtime/`: desktop behavior and application integration source.
- `Patcher/`: bounded patching and packaging source.
- `Native/`: native integration, reproducible patch scripts and retained upstream notices, excluding large archives and binary import libraries.
- `ThirdParty/`: source attribution retained by the release.
- packaging and verification entry points.

This is a reconstruction/integration project rather than the original upstream application project. A clean build also requires the preserved baseline payload and fixed dependency closure from the complete source-and-symbols archive. It must not be described as a standalone upstream source tree.

Local machine paths used during the original release build have been parameterized in this public snapshot. `build.ps1` accepts `YINGYU_DOTNET`, `YINGYU_PYTHON`, `YINGYU_AUDIT_DIR`, `YINGYU_INNO_ISCC` and `YINGYU_OUTPUT_DIR`; the native scripts accept the `YINGYU_NATIVE_*`, `YINGYU_MPV_*`, `YINGYU_MSVC_ROOT`, `YINGYU_WINDOWS_SDK`, `YINGYU_WINDOWS_SDK_VERSION`, `YINGYU_FXC` and `YINGYU_VC_RUNTIME` variables used by their respective inputs. The complete release archive retains the canonical build evidence.

The complete archive is `Yingyu-0.5.8-source-and-symbols.zip` on the [Windows 0.5.8 release](https://github.com/kai489646859-netizen/Yingyu/releases/tag/windows-v0.5.8). Its SHA-256 is published on the same page.

See [`BUILDING.md`](../../BUILDING.md), [`THIRD_PARTY_NOTICES.md`](../../THIRD_PARTY_NOTICES.md) and [`OPEN_SOURCE_AND_DISCLAIMER.md`](../../OPEN_SOURCE_AND_DISCLAIMER.md).

