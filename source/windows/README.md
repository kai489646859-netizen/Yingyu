# Yingyu Windows source snapshot

This is the directly browsable integration snapshot for **Yingyu Windows 1.3.4**.

Included:

- `Runtime/`: desktop behavior and application integration source.
- `Patcher/`: bounded patching and packaging source.
- `Native/`: native integration and retained upstream notices, excluding large archives and binary import libraries.
- `ThirdParty/`: source attribution retained by the release.
- packaging and verification entry points.

This is a reconstruction/integration project rather than the original upstream application project. A clean build also requires the preserved baseline payload and fixed dependency closure from the complete source-and-symbols archive. It must not be described as a standalone upstream source tree.

Local release-machine paths are parameterized in this public snapshot. `build.ps1` accepts `YINGYU_DOTNET`, `YINGYU_PYTHON`, `YINGYU_AUDIT_DIR`, `YINGYU_INNO_ISCC` and `YINGYU_OUTPUT_DIR`; native scripts accept the `YINGYU_NATIVE_*`, `YINGYU_MPV_*`, `YINGYU_MSVC_ROOT`, `YINGYU_WINDOWS_SDK`, `YINGYU_WINDOWS_SDK_VERSION`, `YINGYU_FXC` and `YINGYU_VC_RUNTIME` variables used by their inputs. The complete release archive retains canonical build evidence.

The authoritative archive is `Yingyu-1.3.4-source-and-symbols.zip` on the [Windows 1.3.4 release](https://github.com/kai489646859-netizen/Yingyu/releases/tag/windows-v1.3.4). Its SHA-256 is published on the same page.

See [`BUILDING.md`](../../BUILDING.md), [`THIRD_PARTY_NOTICES.md`](../../THIRD_PARTY_NOTICES.md) and [`OPEN_SOURCE_AND_DISCLAIMER.md`](../../OPEN_SOURCE_AND_DISCLAIMER.md).
