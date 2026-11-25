# Third-party notices

Yingyu-Theater includes or interoperates with third-party software. This summary is informational; the license files and source records in the matching release archive are controlling.

| Component or group | Typical role | License/source location |
| --- | --- | --- |
| mpv | playback core | `LICENSE.GPL`, `LICENSE.LGPL`, pinned source and build records in release source archives |
| FFmpeg | demuxing and codecs | upstream license files and fixed source in release source archives |
| libplacebo | GPU rendering and color processing | upstream license and fixed source in release source archives |
| libbluray | Blu-ray playlist/title handling | `COPYING` and source in the Android archive |
| libdovi | Dolby Vision metadata processing | upstream license and source records in the release archive |
| Flutter and Dart SDK | Android application framework and language runtime | upstream BSD notices and SDK license records in the Android source archive |
| media_kit / media_kit_video | Flutter-to-mpv playback integration | package licenses, pinned modified source and `UPSTREAM.md` records in the Android source archive |
| http, crypto, xml, shared_preferences, cached_network_image, flutter_cache_manager and other Dart packages | networking, parsing, preferences and image caching | each package's `LICENSE`; the Android app also exposes an open-source license view |
| .NET runtime and libraries | Windows managed runtime | Microsoft notices and license files retained with the matching Windows source/release records |
| Windows App SDK / WinUI | Windows application framework | Microsoft license and notices applicable to the shipped runtime |
| Mono.Cecil | bounded build-time host patching | MIT license retained in the complete Windows source-and-symbols archive |
| Richasy/winui-kernel | limited Windows title/window adaptation | MIT license and pinned attribution under `source/windows/ThirdParty/winui-kernel` |
| NVIDIA NVAPI material | NVIDIA integration headers/import material where present | NVIDIA license retained in the Windows source archive |
| Kodi-derived Dolby material | retained source/reference integration where present | pinned source record and upstream notices in the Windows source archive |
| rclone | optional network/disc helper included by the Windows payload | `COPYING` retained beside the shipped component |
| Inno Setup | Windows installer builder | Inno Setup license; build tool itself is not committed to this repository |

The repository's GPL-3.0 license covers Yingyu-Theater project modifications distributed here. Third-party files remain under their own licenses; nothing in this repository expands trademark, patent, media-content or service rights.

For complete corresponding source, exact versions and build configuration, use the source archive attached to the same binary release. The Windows installer also contains `THIRD-PARTY-NOTICES.txt` and component-local license directories. If a notice appears incomplete, open an Issue without attaching private media or credentials.
