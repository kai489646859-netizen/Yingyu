# Yingyu Android source snapshot

This is the directly browsable application-layer snapshot for **Yingyu Android 1.9.6 / code224**.

Included:

- `lib/`: Flutter application, Emby integration, UI and playback orchestration.
- `android/`: Android host, Java/C++ bridge and build configuration.
- `test/`: unit, scenario and host-side regression tests.
- Flutter package metadata and analysis configuration.

Not duplicated in Git:

- the large pinned third-party dependency source tree;
- release APK, native libraries and symbols;
- local validation evidence and private build staging.

The complete corresponding archive is `Yingyu-1.9.6-source.zip` on the [Android 1.9.6 release](https://github.com/kai489646859-netizen/Yingyu/releases/tag/android-v1.9.6). Its SHA-256 is published on the same page.

The retained `UPSTREAM_LICENSE-MIT.txt` records the upstream MIT notice. Yingyu project changes are distributed under the repository GPL-3.0 license; bundled third-party components retain their own licenses.

See [`BUILDING.md`](../../BUILDING.md), [`THIRD_PARTY_NOTICES.md`](../../THIRD_PARTY_NOTICES.md) and [`OPEN_SOURCE_AND_DISCLAIMER.md`](../../OPEN_SOURCE_AND_DISCLAIMER.md).

