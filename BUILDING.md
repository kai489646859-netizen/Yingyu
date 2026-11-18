# Building and reproducibility

## Release source of truth

Every public binary has a matching source archive and SHA-256 file on its GitHub Release. Those archives are the authoritative rebuild inputs. The `source/` directory is a browsable application-layer snapshot and intentionally omits large dependency archives, payloads, generated evidence, binaries, signing material and symbols.

## Android

The Android application uses Flutter plus an Android Java/C++ host and pinned native playback dependencies.

1. Download `Yingyu-2.6.5-source.zip` from the matching release.
2. Verify it using the published SHA-256.
3. Read the archive's build metadata and fixed dependency records.
4. Use your own Android SDK/NDK, Flutter toolchain and signing configuration.
5. Never reuse or request the maintainer's signing private key.

The Git snapshot alone is sufficient for code review but not a byte-identical native rebuild because the large pinned dependency closure is intentionally release-only.

## Windows

The Windows package is a bounded reconstruction/integration project. It is not the original upstream application project.

1. Download `Yingyu-1.7.1-source-and-symbols.zip` from the matching release.
2. Verify its SHA-256.
3. Review the included source, host-patch material, native source records, packaging scripts and delivery manifest.
4. Supply the preserved baseline payload and required toolchain described by the archive.
5. Use your own package-signing environment if signing is required.

The browsable snapshot intentionally omits preserved baseline payloads and build-time binary dependencies; use the matching release archive as the authoritative reconstruction input.

Static or host-side validation does not replace device, GPU, audio, server and long-play testing. Public versions have been used on real hardware by the maintainer, while compatibility with every environment is not guaranteed.
