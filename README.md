<div align="center">
  <img src="picture/Yingyu%20icon.png" alt="映屿图标" width="128">
  <h1>Yingyu · 映屿</h1>
  <p><strong>面向个人 Emby 媒体库的 Android 与 Windows 第三方客户端</strong></p>
  <p>原文件播放 · 媒体库管理 · 多账号 · 观看进度 · 手机/平板/桌面适配</p>
  <p><a href="README_EN.md">English</a></p>
  <p>
    <a href="https://github.com/kai489646859-netizen/Yingyu/releases/tag/android-v2.6.5"><img src="https://img.shields.io/badge/Android-2.6.5-19A974?style=for-the-badge&logo=android" alt="Android 2.6.5"></a>
    <a href="https://github.com/kai489646859-netizen/Yingyu/releases/tag/windows-v1.7.1"><img src="https://img.shields.io/badge/Windows-1.7.1-0078D4?style=for-the-badge&logo=windows11" alt="Windows 1.7.1"></a>
    <a href="https://github.com/kai489646859-netizen/Yingyu/releases"><img src="https://img.shields.io/github/downloads/kai489646859-netizen/Yingyu/total?style=for-the-badge&logo=github&label=Downloads" alt="GitHub 下载量"></a>
    <a href="LICENSE"><img src="https://img.shields.io/badge/License-GPL--3.0-blue?style=for-the-badge" alt="GPL-3.0"></a>
  </p>
</div>

> [!IMPORTANT]
> 映屿不提供影视、音频、字幕、弹幕、服务器或账号资源。请仅连接你有权使用的 Emby 服务，并仅播放你拥有或已获授权的内容。

## 项目简介

映屿把 Emby 媒体库浏览、搜索、个人状态、观看记录和应用内播放整合在同一个界面中。Android 版面向手机和平板，Windows 版针对鼠标、键盘和桌面窗口重新适配。两个平台分别发布、分别编号，可在同一仓库的 Releases 中下载。两个平台均有作者实机使用记录；每个最终构建的实际验证范围以对应 Release 为准，不同服务器、设备、驱动、网络和片源仍可能存在兼容差异。

| 平台 | 当前公开版本 | 安装要求 | 下载 |
| --- | --- | --- | --- |
| Android | **2.6.5 / code294** | Android 8.0+ | [Android 2.6.5](https://github.com/kai489646859-netizen/Yingyu/releases/tag/android-v2.6.5) |
| Windows | **1.7.1** | Windows 10/11 x64 | [Windows 1.7.1](https://github.com/kai489646859-netizen/Yingyu/releases/tag/windows-v1.7.1) |

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

### Android 2.6.5

- 首页与“查看全部”统一显示继续观看进度；缺少总时长时保留已观看时间，并修复窄屏分集卡片标签溢出。
- HDR 输出按实际片源和屏幕能力选择：SDR 保持 SDR，HDR10/HLG 优先同类输出，杜比兼容转换按可用路径回退。
- 杜比转 SDR、HDR10 与 HLG 时减少额外局部对比增强，改善肤色偏黄和高光过曝；亮度与暗部增强支持当前影片实时预览和恢复原画。
- 改善大型 ISO/BDMV 原盘的 CLPI 定位、弱网接续、首帧供数和章节容错，同时保留普通媒体的独立缓存策略。
- 加入应用内正式版更新、系统媒体控制、弹幕来源纠正与反馈导出；继续观看、已看状态和跨设备同步按最终规则合并。

完整累计变化见 [Android 更新历史](CHANGELOG-Android.md)。

### Windows 1.7.1

- 切换分集时可直接从已设置的片头结束位置开始；首页继续观看补足同集时长，换服务器后精选封面按当前账号重新加载。
- 继续观看合并续播、已看和待播放记录；完善完成状态、进度条、刷新回退以及本机待同步恢复。
- 网络点播使用最多 5 GiB 前向磁盘缓存，并修复提前结束误判、播放时钟停滞、关闭释放和控制栏输入问题。
- SDR、HDR10、HLG、HDR10+ 与杜比兼容路径按片源和显示能力协商；HDR 转 SDR 使用保高光映射，并协调显示器 ICC、HDR 峰值和动态元数据。
- 改善原盘首帧、定位预滚、双层流衔接、窗口光标、横图补图、资源标签、音轨文字和倍速弹幕显示。

完整累计变化见 [Windows 更新历史](CHANGELOG-Windows.md)。

## 下载与安装

### Android

在 [Android 2.6.5 发布页](https://github.com/kai489646859-netizen/Yingyu/releases/tag/android-v2.6.5) 下载 `Yingyu-2.6.5.apk`。2.2.5 及之后版本可直接覆盖安装，**不要先卸载**。2.2.4 及更早公开版使用不同应用身份和签名，会与当前版共存，不能直接覆盖。

### Windows

在 [Windows 1.7.1 发布页](https://github.com/kai489646859-netizen/Yingyu/releases/tag/windows-v1.7.1) 下载 `Yingyu-Setup-x64-1.7.1.exe`。关闭正在运行的映屿后覆盖安装；安装程序沿用既有应用身份和目录，不要求卸载旧版或清空个人数据。安装包当前未使用代码签名，Windows 可能显示“未知发布者”。

每个发布页同时提供与二进制对应的源码归档、调试符号、SHA-256 校验文件，以及累计更新说明和测试结果。

```powershell
Get-FileHash .\Yingyu-2.6.5.apk -Algorithm SHA256
Get-FileHash .\Yingyu-Setup-x64-1.7.1.exe -Algorithm SHA256
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

## 贡献者

- [kai489646859-netizen](https://github.com/kai489646859-netizen)：项目维护、产品决策、实机使用与发布。
- [Codex](https://github.com/codex)：协助开发、调试、验证与发行维护。

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
