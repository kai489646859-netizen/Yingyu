# Yingyu Windows source snapshot

This is the directly browsable integration snapshot for **Yingyu Windows 1.7.1**.

Included:

- `Runtime/`: desktop behavior and application integration source.
- `HostPatch/`: bounded host patching source; binary build-time dependencies remain release-archive-only.
- `Native/`: native integration and retained upstream notices, excluding large archives and binary import libraries.
- `ThirdParty/`: source attribution retained by the release.
- packaging and verification entry points.

This is a reconstruction/integration project rather than the original upstream application project. A clean build also requires the preserved baseline payload and fixed dependency closure from the complete source-and-symbols archive. It must not be described as a standalone upstream source tree.

The public snapshot omits preserved baseline payloads, build-time binary dependencies and release products. The complete release archive retains the canonical source, symbols, build records and matching third-party notices.

The authoritative archive is `Yingyu-1.7.1-source-and-symbols.zip` on the [Windows 1.7.1 release](https://github.com/kai489646859-netizen/Yingyu/releases/tag/windows-v1.7.1). Its SHA-256 is published on the same page.

See [`BUILDING.md`](../../BUILDING.md), [`THIRD_PARTY_NOTICES.md`](../../THIRD_PARTY_NOTICES.md) and [`OPEN_SOURCE_AND_DISCLAIMER.md`](../../OPEN_SOURCE_AND_DISCLAIMER.md).
