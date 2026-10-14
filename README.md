<div align="center">
  <img src="picture/Yingyu icon.png" alt="Yingyu Icon" width="120">
  <h1>Yingyu · 映屿</h1>
  
  <p>
    <img src="https://img.shields.io/badge/Platform-Android-green.svg" alt="Platform">
    <img src="https://img.shields.io/badge/License-GPL%20v3-blue.svg" alt="License">
  </p>
  
  <p><strong>Yingyu（映屿）</strong>是一款基于 Emby 和 MPV 的跨平台影视客户端。支持登录 Emby 服务器，提供原文件播放、媒体库浏览、多账号管理与跨设备进度同步。</p>
  
  <p>📢 <strong>当前状态</strong>：本项目为跨平台版本归档仓库。已归档 Android 版本，Windows 版本正在规划中。</p>
</div>

---

## 📸 界面展示

### 📱 移动端体验 (竖屏)
<div align="center">
  <img src="picture/竖版媒体库展示.jpg" alt="竖版媒体库" width="220">
  <img src="picture/竖版账号页面展示.jpg" alt="竖版账号" width="220">
  <img src="picture/竖版设置展示.jpg" alt="竖版设置" width="220">
  <p><em>移动端媒体库、账号与设置界面</em></p>
</div>

### 📐 平板与横屏体验
<div align="center">
  <img src="picture/平板首页展示.jpg" alt="平板首页" width="280">
  <img src="picture/横板媒体库展示.jpg" alt="横板媒体库" width="280">
  <p><em>平板首页与横屏媒体库</em></p>
</div>

<div align="center">
  <img src="picture/横板账户展示.jpg" alt="横板账户" width="280">
  <img src="picture/横板设置展示.jpg" alt="横板设置" width="280">
  <p><em>横屏账户与设置界面</em></p>
</div>

---

## 📖 功能介绍

### 1. 多账号与服务器管理
支持添加多个 Emby 服务器，随时一键切换。完美支持多用户登录，互不干扰。
<div align="center">
  <img src="picture/应用设置展示01.jpg" alt="应用设置1" width="200">
  <img src="picture/应用设置展示02.jpg" alt="应用设置2" width="200">
  <img src="picture/应用设置展示03.jpg" alt="应用设置3" width="200">
  <img src="picture/应用设置展示04.jpg" alt="应用设置4" width="200">
  <p><em>丰富的应用设置选项</em></p>
</div>

### 2. 原码播放与强大解码
底层深度集成 MPV 播放器核心，支持直接播放原文件（拒绝强制转码），支持多种字幕格式与音轨切换。

### 3. 媒体库浏览与海报墙
直观展示 Emby 服务器的媒体资源，支持分类浏览、搜索，手机与平板自适应。

### 4. 日志可视化与隐私保护
提供直观的日志可视化功能，方便排查播放问题。不上传签名私钥、账户凭据或用户媒体日志，数据仅保存在本地与你的 Emby 服务器中。
<div align="center">
  <img src="picture/日志可视化展示.jpg" alt="日志可视化" width="300">
  <p><em>日志可视化展示</em></p>
</div>

---

## 📥 下载与安装

| 平台 | 已归档版本 | 安装包 (Assets) |
| :--- | :--- | :--- |
| **Android** | [0.7.1 (最新)](https://github.com/kai489646859-netizen/Yingyu/releases/tag/android-v0.7.1) | `Yingyu-0.7.1.apk` |
| Android 历史版本 | [0.6.9](https://github.com/kai489646859-netizen/Yingyu/releases/tag/android-v0.6.9) | `Yingyu-0.6.9.apk` |
| Windows | 后续安排 | *当前仓库尚未发布* |

**⚠️ 安装必读：**
1. **签名与升级**：Android 同签名升级可直接覆盖，保留账户、观看进度与设置，**千万不要先卸载**。
2. **版本降级**：旧版仅作历史归档，不能把较低版本直接覆盖安装到高版本上。
3. **校验文件**：每个版本同时附带对应的 `Yingyu-版本号-source.zip` 和 `SHA256SUMS.txt`。

---

## 🚀 安装后的使用方法

### 第一步：添加 Emby 服务器
1. 打开 Yingyu 客户端，点击“添加服务器”。
2. 输入你的 Emby 服务器地址、账号和密码，完成登录。

### 第二步：浏览与播放
1. 登录成功后，首页展示媒体库（参考上方界面展示）。
2. 点击任意电影，点击“播放”，调用内置 MPV 播放器。

### 第三步：设置与日志排查
1. 点击侧边栏的“设置”，管理账号或添加新服务器。
2. 若遇到播放问题，可在设置中查看“日志可视化”，获取报错信息后再向开发者反馈。

---

## 📝 更新记录与发布规则

- [Android 完整逐版记录 (CHANGELOG-Android.md)](CHANGELOG-Android.md)
- [版本归档和发布规则 (RELEASE_POLICY.md)](RELEASE_POLICY.md)

## 🛠️ 技术细节与反馈

- **技术栈**：Android 客户端使用 Emby + MPV。
- **反馈渠道**：欢迎在 Issues 中提供设备型号、系统版本及日志截图（注意脱敏）。

## 📄 开源协议与致谢

本项目应用与对应源码按 **GPL-3.0** 交付。
第三方组件遵循各自许可证；本项目为第三方开源客户端，与 Emby 官方无直接关联。

---
<div align="center">
  <em>如果映屿对你有帮助，欢迎扫码支持开发者继续维护：</em><br>
  <img src="picture/赞赏码.png" alt="赞赏码" width="200">
</div>
