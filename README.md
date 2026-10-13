# Yingyu · 映屿

映屿的跨平台版本归档仓库。按 Android、Windows 分别整理安装包和更新记录。

## 下载

| 平台 | 已归档版本 | 安装包 |
| --- | --- | --- |
| Android | [0.7.1](https://github.com/kai489646859-netizen/Yingyu/releases/tag/android-v0.7.1) | `Yingyu-0.7.1.apk` |
| Android 历史版本 | [0.6.9](https://github.com/kai489646859-netizen/Yingyu/releases/tag/android-v0.6.9) | `Yingyu-0.6.9.apk` |
| Windows | 后续安排 | 当前仓库尚未发布 Windows 安装包 |

请在相应版本的 **Assets** 中下载 APK；Android 同签名升级可保留账户、观看进度与设置，不要先卸载。旧版用于历史归档，不能把较低版本直接覆盖安装到高版本上。

每个版本同时附带对应的 `Yingyu-版本号-source.zip` 和 `SHA256SUMS.txt`。请使用手工附带的源码包：GitHub 自动生成的 Source code 只包含本归档仓库中的说明文件。

## 更新记录

- [Android 完整逐版记录](CHANGELOG-Android.md)
- [版本归档和发布规则](RELEASE_POLICY.md)

发布包按已确认的阶段版本选择，合并中间的小更新，不为每次小修复单独保留下载入口。后续版本必须经作者实测并明确允许后才上传；本仓库未配置自动构建或自动发布。

## 说明

Android 客户端使用 Emby 与 MPV；提供原文件播放、媒体库浏览、多账号和进度同步。实际格式、流畅度和设备兼容性以对应版本说明为准。

应用与对应源码按 GPL-3.0 交付，第三方组件遵循各自许可证；许可证和依赖来源随对应源码保留。
