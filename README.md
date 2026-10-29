<div align="center">
  <img src="picture/Yingyu%20icon.png" alt="映屿图标" width="128">
  <h1>Yingyu · 映屿</h1>
  <p><strong>面向个人 Emby 媒体库的 Android 与 Windows 第三方客户端</strong></p>
  <p>原文件播放 · 媒体库管理 · 多账号 · 观看进度 · 手机/平板/桌面适配</p>
  <p><a href="README_EN.md">English</a></p>
  <p>
    <a href="https://github.com/kai489646859-netizen/Yingyu/releases/tag/android-v1.9.6"><img src="https://img.shields.io/badge/Android-1.9.6-19A974?style=for-the-badge&logo=android" alt="Android 1.9.6"></a>
    <a href="https://github.com/kai489646859-netizen/Yingyu/releases/tag/windows-v0.5.8"><img src="https://img.shields.io/badge/Windows-0.5.8-0078D4?style=for-the-badge&logo=windows11" alt="Windows 0.5.8"></a>
    <a href="https://github.com/kai489646859-netizen/Yingyu/releases"><img src="https://img.shields.io/github/downloads/kai489646859-netizen/Yingyu/total?style=for-the-badge&logo=github&label=Downloads" alt="GitHub 下载量"></a>
    <a href="LICENSE"><img src="https://img.shields.io/badge/License-GPL--3.0-blue?style=for-the-badge" alt="GPL-3.0"></a>
  </p>
</div>

> [!IMPORTANT]
> 映屿不提供影视、音频、字幕、服务器或账号。请仅连接你有权使用的 Emby 服务，并仅播放你拥有或已获授权的内容。

## 项目简介

映屿把 Emby 媒体库浏览、搜索、个人状态、观看记录和应用内播放整合在同一个界面中。Android 版面向手机和平板，Windows 版针对鼠标、键盘和桌面窗口重新适配。两个平台分别发布、分别编号，可在同一仓库的 Releases 中下载。当前公开版本均已经过作者实机使用验证，但不同服务器、设备、驱动、网络和片源仍可能存在兼容差异。

| 平台 | 当前公开版本 | 安装要求 | 下载 |
| --- | --- | --- | --- |
| Android | **1.9.6 / code224** | Android 8.0+ | [Android 1.9.6](https://github.com/kai489646859-netizen/Yingyu/releases/tag/android-v1.9.6) |
| Windows | **0.5.8** | Windows 10/11 x64 | [Windows 0.5.8](https://github.com/kai489646859-netizen/Yingyu/releases/tag/windows-v0.5.8) |

## 主要功能

| 类别 | 能力 |
| --- | --- |
| 媒体库 | 首页分区、完整媒体库、搜索与筛选、电影/剧集详情、季与选集、多版本选择 |
| 搜索 | 片名、原名和本地文字资料搜索；演员与作品关系搜索；Windows 版进入搜索页后可直接输入 |
| 账户与状态 | 多服务器/多账号、继续观看、收藏、已看状态、观看进度与异常时的本机待同步 |
| 播放 | 内置 MPV、原文件播放、续播/从头播放、定位、倍速、章节、音轨、字幕与字幕延迟 |
| 来源兼容 | 普通媒体、STRM、302/反向代理来源，以及 ISO/BDMV 播放列表读取 |
| 画面 | HDR/杜比信息识别和兼容处理；最终能力取决于片源、系统、GPU/设备和显示器 |
| 外观与交互 | 深浅主题、自适应海报墙；Android 触屏手势与横竖屏；Windows 鼠标、键盘、悬停和窗口布局 |
| 诊断 | 脱敏日志、错误与播放阶段诊断；源码、调试符号和 SHA-256 随发行版提供 |

## 最新版本摘要

### Android 1.9.6

- 新增聚合搜索、演员即时搜索、按字扩展搜索与头像/作品关系优化，减少等待完整目录后才能检索的情况。
- 改善继续观看、跨设备进度、提示文字、视频截图及播放器控制栏显示。
- 增加可选的杜比/HDR 兼容映射与更明确的回退边界，不把兼容映射宣称为原生杜比认证输出。
- 保留用户已确认正常的 2× 播放；针对 3× 播放持续修正输入、追赶、有效画面保留及呈现时限。1.9.6 修复了“已有后继画面但仍按过短时限处理”的路径。
- 已完成实机使用、构建、静态/隔离检查、签名、16 KiB、原生库和符号核对；3× 表现仍可能随设备、片源和刷新率变化。

完整累计变化见 [Android 更新历史](CHANGELOG-Android.md)。

### Windows 0.5.8

- 延续桌面媒体库、详情、选集、内置播放、主题、缓存和本地资料搜索能力。
- 修复搜索页输入后仍停留在“猜你喜欢”、没有开始显示结果的问题。
- 进入搜索页后自动把光标交给输入框；停笔约 280ms 自动搜索，同时保留回车、搜索按钮、快速改词和取消旧任务。
- 已完成实机使用验证；浅色/深色各 81 项搜索流程检查及各 39 项侧栏/音量检查通过。检查结果不代表所有 Windows、GPU、服务器和输入法组合都绝对一致。

完整累计变化见 [Windows 更新历史](CHANGELOG-Windows.md)。

## 下载与安装

### Android

在 [Android 1.9.6 发布页](https://github.com/kai489646859-netizen/Yingyu/releases/tag/android-v1.9.6) 下载 `Yingyu-1.9.6.apk`。从旧版升级时直接覆盖安装，**不要先卸载**，否则本机账号、设置和缓存可能丢失。

### Windows

在 [Windows 0.5.8 发布页](https://github.com/kai489646859-netizen/Yingyu/releases/tag/windows-v0.5.8) 下载 `Yingyu-Setup-x64-0.5.8.exe`。关闭正在运行的映屿后覆盖安装；安装程序沿用既有应用身份和目录，不要求卸载旧版或清空个人数据。

每个发布页同时提供与二进制对应的源码归档、调试符号、SHA-256 校验文件，以及累计更新说明和验证边界。

```powershell
Get-FileHash .\Yingyu-1.9.6.apk -Algorithm SHA256
Get-FileHash .\Yingyu-Setup-x64-0.5.8.exe -Algorithm SHA256
```

## 快速开始

1. 安装并打开对应平台的映屿。
2. 添加 Emby 服务器地址并登录。地址可以包含协议、端口和反向代理路径。
3. 从首页、媒体库或搜索进入详情页，选择媒体版本、季/集或直接播放。
4. 映屿默认请求原文件播放，不主动要求服务器转码；能否原画取决于服务器返回、权限、Range、网络和设备解码能力。
5. 遇到问题时从应用内导出诊断日志。公开提交前请遮盖服务器地址、账号、令牌、私人域名、文件名和媒体直链。

完整支持范围见[兼容性矩阵](COMPATIBILITY.md)，常见问题见 [FAQ](FAQ.md)。

## HDR、杜比与原盘边界

- 映屿基于 MPV、FFmpeg、libplacebo 等组件进行播放与兼容处理，最终效果依赖片源、硬件解码、系统图形栈、驱动和显示设备。
- 支持识别和处理部分 HDR/杜比信息不等于 Dolby 官方认证，也不保证所有 Profile、双层 FEL、直通、窗口模式或所有设备效果。
- ISO/BDMV 播放列表读取不等同于完整蓝光菜单、BD-J 或所有交互能力。
- “能够打开”不等于颜色、声音、字幕、定位、倍速和连续播放均已完整验收。

## 开源、第三方组件与免责声明

映屿项目修改以 GPL-3.0 发布，第三方组件继续遵循各自许可证。仓库提供可在线浏览的 [Android/Windows 应用层源码快照](source/README.md)；完整固定依赖、构建记录和对应源码继续随每个 Release 提供。详细说明见[第三方通知](THIRD_PARTY_NOTICES.md)及[开源与免责声明](OPEN_SOURCE_AND_DISCLAIMER.md)。

- 本项目是独立的第三方客户端，与 Emby LLC、Dolby Laboratories、MPV 项目及截图中媒体作品的权利人不存在隶属、授权或背书关系。相关名称和商标归各自权利人所有。
- 本软件按现状提供，不保证适用于所有服务器、设备、网络或媒体格式。安装、升级、配置和播放的风险由使用者自行承担。
- 本项目不绕过访问控制、不提供媒体资源，也不鼓励侵权。使用者应遵守所在地法律、服务器规则与相关服务条款。

## 问题反馈

欢迎使用 [Android / Windows 分类 Issue 表单](https://github.com/kai489646859-netizen/Yingyu/issues/new/choose)。使用咨询和兼容讨论请前往 [Discussions](https://github.com/kai489646859-netizen/Yingyu/discussions)，安全问题请按[安全策略](SECURITY.md)私下报告。请勿公开上传密码、API Key、Access Token、完整媒体地址或私人媒体截图。

## 文档

- [Android 更新历史](CHANGELOG-Android.md)
- [Windows 更新历史](CHANGELOG-Windows.md)
- [源码快照](source/README.md)
- [兼容性矩阵](COMPATIBILITY.md)
- [构建与复现](BUILDING.md)
- [安装包身份与签名](SIGNING.md)
- [发行检查清单](RELEASE_CHECKLIST.md)
- [FAQ](FAQ.md)
- [支持与问题反馈](SUPPORT.md)
- [安全策略](SECURITY.md)与[隐私说明](PRIVACY.md)
- [贡献指南](CONTRIBUTING.md)
- [第三方通知](THIRD_PARTY_NOTICES.md)
- [版本发布规则](RELEASE_POLICY.md)
- [开源与免责声明](OPEN_SOURCE_AND_DISCLAIMER.md)
- [全部 Releases](https://github.com/kai489646859-netizen/Yingyu/releases)

---

<div align="center">
  <p>如果映屿对你有帮助，欢迎支持后续维护：</p>
  <img src="picture/赞赏码.png" alt="赞赏码" width="360">
</div>
