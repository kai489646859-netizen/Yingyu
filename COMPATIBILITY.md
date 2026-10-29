# Compatibility matrix

| Area | Android | Windows |
| --- | --- | --- |
| Current release | 1.9.6 / code224 | 0.5.8 |
| Supported OS | Android 8.0+ | Windows 10/11 x64 |
| Primary UI | phone and tablet touch layouts | desktop window, mouse and keyboard |
| Server | user-provided Emby service | user-provided Emby service |
| Normal files | original-file playback when the server and device permit | original-file playback when the server and system permit |
| STRM / redirect | supported within authorization, header, redirect and Range constraints | supported within authorization, header, redirect and Range constraints |
| ISO / BDMV | playlist/title reading; not complete BD-J/menu support | implementation-specific disc path; not a universal menu guarantee |
| HDR / Dolby | detection and compatibility processing; not Dolby certification | detection and compatibility processing; not Dolby certification |
| Update model | cover-install; do not uninstall first | close the app and cover-install |

Both current releases have been used on real hardware. Results can still differ by Emby version, reverse proxy, storage provider, network throughput, codec/profile, bitrate, decoder, GPU driver, refresh rate and display.

Successful file opening is not proof that every color, enhancement layer, subtitle, audio track, seek, speed and long-play path is supported. Report reproducible incompatibilities using the platform-specific Issue form.
