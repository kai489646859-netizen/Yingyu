# 0.3.15：源母版与实际显示目标分离

重编 MPV，只撤销 vo_gpu_next.c 中把源色彩/母版亮度复制为显示目标的旧杜比 HDR 回退分支。保留后端 target_csp、自动目标亮度与上游色彩映射，无新曝光/gamma/黑位参数。与0.3.14相比只有这一个MPV源文件发生变化；RPU、FEL配对/代次、缺层/上传失败保护和中文stats保持。

源码位于 `.tools/native-dolby-0315/source/mpv-e470f8986e`，ASCII 编译副本由 `YINGYU_NATIVE_BUILD_ROOT` 指定，编译前 961 个输入冻结后复核。仅 `libmpv-2.dll` 更新，其他 130 个私有 DLL 保持，原生杜比输出桥接继续移除。

先执行 patch_mpv.py，再执行 patch_hdr10_stats.py，可以从固定原始源重现本版。只编译与静态核对，没有屏幕/媒体实播验证。

以下为0.3.14继承说明：

# 0.3.14 杜比转 HDR10 与中文 MPV 原生统计

用户撤销原生 DV 输出目标。MPV 本次重编，保持逐帧 RPU/FEL/PTS 完整性检查后直接进入 libplacebo HDR10 路线；不加载 transport DLL、不调用 NVAPI 或改变显示模式。旧桥接不再随新版运行时分发；旧源码/许可证仍作来源留存，MPV/FFmpeg 等组件的分发义务保持。原生输出的旧实现说明作为来源保留在下文，不代表当前启用。

`player/lua/stats.lua` 只修改显示文字、中文字体；数值来源、统计公式、分页和原生刷新机制保持。`patch_hdr10_stats.py` 在原 `patch_mpv.py` 之后运行以重现本次后处理。实际源在 `.tools/native-dolby-0314/source`，与由 `YINGYU_NATIVE_BUILD_ROOT` 指定的编译副本逐项核对。依赖继续复用 037 的固定闭包，去掉输出桥接 DLL，仅 `libmpv-2.dll` 重编。

不执行产品/媒体/GPU测试；偏色、闪烁和实际硬解仍由用户实播验收。

---
历史原生输出架构参考（当前停用）：

# 0.3.10 输出协商修正

本版实际重编内置MPV和杜比桥接；私有运行闭包仍为132 DLL，其中2项更新、130项保持。软件已增加能力结构版本兼容、修正24/59.94Hz的rrx1k常量，并把输出拒绝分解为阶段/实际返回码/能力版本/连接类型；没有移除设备能力或完整FEL保护，没有把未呈现的画面标为原生杜比。窗口化原片原生DV仍未实现。

NVAPI能力先查询V3，仅NVAPI_INCOMPATIBLE_STRUCT_VERSION才重试V2；V2/V3都必须实际返回Dolby和TV-led能力。成功查询但Dolby=false仍明确HDR回退，LLDV-only、非本后端连接和时序分别记录，不强行发送错误信号。D3D HRESULT与输出API状态分开，不将nativeResult=0当NVAPI成功。ABI修订为0x00010001，MPV、桥接和宿主解析严格匹配。

原生输入/精确EL配对、源重建shader和动态metadata打包数学保持。杜比格式/回退提示经MPV OSD绘入画面，避免WinUI提示又造成reason1；控件显隐/前后台的临时拒绝不反复消耗通知，真实原生输出决定变化可通过既有事件通知，总数每媒体有界6次，无新轮询。

构建工作目录由 `YINGYU_NATIVE_BUILD_ROOT` 指定，源码位于 `.tools/native-dolby-0310/source`；只读依赖由 `YINGYU_NATIVE_DEPS` 指定。`evidence/native-compile-inputs.json` 记录实际编译前的 40 个桥接/上游输入及 961 个 MPV 输入，完成后复核。只编译/静态核对不等于实机测试；版本的实机使用结论以对应 Release 记录为准。

以下为继承架构说明：

# 0.3.10 内置杜比后端

本目录是实际编译并接入 MPV 的 Windows 实现。Kodi 固定源码为 `5da44c2547bae530354524ddc0a00cc5b5bae0da`，MPV 固定源码归档为 `vendor/mpv/mpv-e470f8986e.tar.gz`。`patch_mpv.py` 对原始 MPV 做有唯一锚点检查的有限修改；`src` 是映屿接入层，`vendor/kodi` 保持上游字节。NVAPI 头和静态桩库有逐文件摘要，未安装任何驱动。

解码与增强层配对仍在内置 MPV 中执行。P5/兼容0、P7/兼容6、P8/兼容1或6进入原生候选。每帧取当前原始 AVDOVIMetadata，FEL 需要同一时间戳的真实增强层，MEL 允许已确认零残差。原生路径直接使用 Kodi reshape/composer、元数据 transport 和 BGRA8 Dolby 字节载体，跳过 libplacebo 的普通色彩映射；BGRA8 载体不表示把内容变为 SDR。

当前原生输出移植自参考实现的 NVIDIA NVAPI TV-led HDMI 路径。只尝试当前已有的1080p/2160p受支持时序，不改分辨率或刷新率，不保存自定义时序。必须全屏、前台、无普通 WinUI 覆盖，桌面 HDR 关闭且驱动接受信令。无 NVIDIA、拒绝时序、窗口播放、控制栏/弹窗、需要特殊色彩的图形字幕等情况下，保留完整增强层进入明确的 HDR 回退。用户主动调整 gamma 时也保留其 HDR 路径。没有外部播放器、盒子、第二个外部播放进程或额外内核模块。

普通文字字幕及原生状态提示在打包前合成；保留并按实际画幅转换 L5 有效区域，不统一清零。控制栏和信息窗保持原交互，显示前异步通知退出载体；原生呈现线程核对许可，界面线程不等待内核/Win32消息；关闭后再尝试原生。稳定拒绝不逐帧反复清除 HDR 提示。退出、定位、换片、窗口变化复核代次并恢复信令；恢复失败明确暂停。

标准蓝光 M2TS 的 HDMV BL/EL 双 PID 由 FFmpeg9 的 Dolby Vision stream group 识别。明确双轨 HEVC group 缺容器 Profile 时补齐 P7/兼容6，已有明确配置保持；不为所有 HEVC 猜杜比。未知无配置的原始单轨 HEVC、异常非标准分轨不在已完成的自动识别范围。

`native-dolby-status` 返回实际载体提交/呈现次数、FEL重建/呈现次数、帧完整性、代次、错误枚举及 HRESULT。只有 active、完整、无 fatal、实际 presented>0 才显示原生；FEL提示还要求 felPresented>0。呈现次数包含同帧重复呈现，不能当独立解码帧数。核心配对或晚期 EL 上传失败也合并到此状态，并异步暂停音视频，拒绝基础层独播。

构建入口只负责编译与静态核对，不启动产品、打开媒体或调用 GPU。GNU 工具需要物理 ASCII 路径，使用 `YINGYU_NATIVE_BUILD_ROOT` 指定 source/build，依赖由 `YINGYU_NATIVE_DEPS` 指定；工具安装及包锁在工程 `.tools/native-dolby`。`build_native.py` 编译 shader、MSVC 桥接和 MPV；`package_native.py` 静态解析 PE 导入闭包并随包带上私有依赖。MPV 保留调试信息，桥接保留匹配 PDB，`evidence` 保留中间失败及最终编译记录。

0.3.8针对0.3.7实播反馈：P7已识别而reason1持续，未证明NVAPI曾尝试。新增UI阻挡明细，排除透明梯度、无厚度边线、零尺寸/空裁剪；许可用core原子状态保存，避免VO重建丢许可。字幕不适用不再永久混为UI遮挡；仍不把未经适配的字幕颜色说成原生成功。UI许可和原生OSD命令改异步，状态显示读取事件缓存；Unloaded不往返内核。界面销毁和会话关闭前先解绑诊断；原停止/自然结束清理委托保留并调度到原UI线程，不在后台线程直接销毁XAML。

窗口化原生杜比仍未完成：Windows系统DV桌面与HDR窗口是存在的，但这条Kodi载体路线不能直接缩成窗口并保证原片RPU/FEL交接和窗外桌面色彩。窗口仍明确HDR回退；不能把系统支持标志或PQ窗口当成已验证原片窗口DV。详见仓库排查记录/0.3.8-窗口化原生杜比输出边界.md。

编译、驱动状态检查代码及计数不等于物理杜比信号、屏幕色准或长播验收。实际安装、P5/P7/P8画面、FEL贡献、字幕/定位及稳定性由用户实播验证。出现问题从应用原日志中心导出；无需USB、外部工具或另装模块。
