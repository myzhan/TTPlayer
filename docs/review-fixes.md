# Qt 审查修复与验收记录

对应 [第二轮 review](../review.md) 的 B01～B27，以及其关联的第一轮问题。下表记录 Qt 实现和对应的回归入口。

用户已明确要求保留既有深色 Qt 界面，**本轮不修改任何样式**。B27 的蓝灰复刻建议作废；Swift 只用于功能与测试对照。原 Qt 配色、字体、统一 alpha 和紧凑布局已恢复，基线见 [approved-dark-style.json](review-evidence/approved-dark-style.json) 与 `screenshots/qt-dark-*.png`。

## 实现与对应回归

| 问题 | 当前实现 | 回归入口 |
| --- | --- | --- |
| B01 拖拽崩溃 | 将 selectedRows 保存为局部容器，消除跨临时容器迭代器；经过真实窗口重排提交 | REVIEW、MULTI，重复 30 次 |
| B02 seek 旧 PCM | seek 推进代际；producer 提交同时核对 decoder 与 generation | REVIEW，可控 GateSource，30 次 |
| B03 旧 EOF | 排队 EOF 交付检查代际，stop/换曲后拒绝旧通知 | REVIEW，30 次 |
| B04 CUE 段尾 | clamp 到段范围，末尾正确标记 EOS，不陷入不可推进状态 | REVIEW、CUE |
| B05 恢复标签/RG | 后台 probe 后共享同一 Track；URL token 按 canonical identity 找 registry 对象 | SCENE、RESUME、GAIN |
| B06 回调清零 | 先清完整输出缓冲，再写实际可读帧 | REVIEW，大缓冲边界 |
| B07 无缝 | 后台准备下一段 PCM，输出侧交接，携带队列 UUID、位置及每曲 RG | GAPLESS、QUEUE，回调与压缩格式矩阵 |
| B08 电台状态机 | ICY 拆包与编码、2/4/8/8 退避、上限、手动重试、致命 HTTP、30 秒质量窗口 | RADIOLIVE 全七种 HTTP 剧本，各 30 次压力动作 |
| B09 直播暂停/换台 | 开新流先停旧音频；暂停取消连接但保留台身份与质量会话，恢复重新连接 | RADIOLIVE、RADIOCAT |
| B10 worker 生命周期 | 开流/预取 worker 有 owner，取消后 join；晚回调校验 token/接收对象 | REVIEW、RADIOLIVE、ASan/UBSan |
| B11 EQ | 锁保护 DSP 参数、前置增益、reset 与音量/mute 同路更新 | GAIN、SETTINGS、UI |
| B12 输出设备 | mac 按 UID 找 AudioDeviceID 并打开 HAL AudioUnit；Windows/Linux SDL；区分偏好/实际/回退原因，轮询恢复与重采样 | DEVICE；mac 同名双 UID、移除和重建临时设备 |
| B13 播放/睡眠 | 无上下文/独立队列播放、AfterTrack、取消、手停和连续时钟；恢复失败保持原项暂停 | PLAYBACK、SLEEP、SCENE |
| B14 暂停死锁 | 设备暂停移出引擎锁范围，SDL 生命周期晚于引擎 | PLAYBACK、RADIOLIVE，进程外超时 |
| B15 归档身份 | M3U 保留完整 file URL 与 percent-encoded archive-entry，流式读取 | IDENTITY、LISTS、ARCHIVE |
| B16 Windows token | 盘符/UNC 在 scheme 解析前识别，CUE/归档身份不截断 | IDENTITY；原生 Windows 待 CI |
| B17 媒体库归属 | registry、defaultKeys、libraryKeys 分离；离线保留快照，删除页面成员不误删另一贡献 | OWNERSHIP、LIBRARY、WATCH |
| B18 导入/UI 阻塞 | 统一递归 importer，CUE/M3U/归档、EXTINF、GB18030、拒收原因；扫描/导入/恢复/probe/预取/递归 watcher 枚举后台运行，取消代际隔离 | IMPORT、WATCH、SCENE；海量网络卷 bench 仍需专项 |
| B19 播放现场 | 独立 resume 每 5 秒及状态变化落盘；空默认页仍恢复队列；定位/增益/autoPlay 在输出前提交 | SCENE、RESUME；真实回调 PCM 验证恢复段 |
| B20 Swift 迁移 | 消费独立 resume、libraryKeys、编辑与设置；宽容缺字段、source sanitize、缺 CUE 保留原身份 | SYSTEM、RESUME、IDENTITY |
| B21 保存失败 | QSaveFile 检查短写/commit；坏 JSON 备份失败拒绝覆盖；失败经既有状态栏反馈；恢复期间禁止半库落盘 | SAVE、SYSTEM、SCENE |
| B22 搜索/排序 | 来源与格式、Esc、按身份保存选区/滚动、跨页删除可写引用并保留库、排序持久化 | SEARCH、UI、SL |
| B23 编辑/管理 | 属性使用选中项；编辑、定位、改台地址和根重定位统一迁移引用/队列/歌词校准，固定页权限检查 | LIBRARY、LISTS、SEARCH、RADIOCAT |
| B24 资源/系统 | 112/256 封面与 8 MiB 缓存、隐藏停频谱、原始源参数/流标签、跨窗快捷键与输入保护；mac Now Playing/Win SMTC/Linux MPRIS | COVER、UI、SPECTRUM、SYSTEM；系统面板仍需逐平台验收 |
| B25 自检可靠性 | 主线程动作、外部超时、40 suite 单一注册表、每次构建、源码/二进制指纹、跨平台用户档守卫；增加真实 PCM/格式/性能专项 | `scripts/selftest.py`、CTest；完整映射见下文 |
| B26 交付 | Qt install/deploy/本地 package、mac 12 依赖链、跨平台 CI；修复 legacy 桥接与构建路径 | 本机 Qt 双构型/打包及既有 Swift 双构型基线；Win/Linux CI 尚未远端执行 |
| B27 样式 | 按用户最新指令保留原深色，冻结 52 个 QColor、字体与 alpha，保持原尺寸/标题栏 | UI、WIDTH；桌面玻璃合成未由 offscreen 证明 |

## 启动崩溃与产物辨识

本轮打包曾因缺少 `@rpath/libSDL2-2.0.0.dylib` 崩溃，随后发现图标导出/打包自检需要的 offscreen plugin 未部署。CMake 现在先部署真实 SDL dylib，再运行 macdeployqt，并复制 offscreen plugin；打包最后做 ad-hoc codesign。最终交付目录为 `dist/ttplayer.app`，`--version` 标明 Qt，`otool -L` 可核对 Qt 依赖。

启动命令行文件现在先恢复已有曲库，再导入输入，避免新文件替换旧库；显式输入抑制旧现场自动续播。恢复是异步的，保存请求等待完整恢复后提交；过期恢复不能覆写新结果。

## 电台缓冲与前台播放 CPU

电台按输出采样率保留最多 12 秒 PCM，起播和耗尽后先积累 2 秒。不可定位的直播流切换采样率时直接配置重采样器。CoreAudio 回归覆盖了 44.1 kHz 电台在 48 kHz 设备上播放。

频谱和电平表共用刷新时钟，静态窗壳复用底图。相同测试流、窗口全程可见、实际每秒绘制约 25 帧时，30 秒平均 CPU 从 16.6% 降至 10.1%。更新后的 macOS Debug、Release、ASan+UBSan 和打包版全量自检各 **862 PASS / 0 FAIL / 0 SKIP**。

## 验证口径与未完成边界

修复前 Qt 为 221 PASS。第二轮审查修复后，Debug、Release、ASan+UBSan 及部署后 app 全量各 **852 PASS / 0 FAIL / 0 SKIP**，Debug/Release CTest 各 **41/41**。日志分别位于 `/tmp/tt-final-debug`、`/tmp/tt-final-release`、`/tmp/tt-final-asan-repeat`、`/tmp/tt-final-packaged`，各目录含 `run.json` 与 `selftest.log`。产品双构型编译 0 warning / 0 error，签名严格校验、Info.plist 和 diff 空白检查通过。

该轮 app 的 CoreAudio DEVICE/GAPLESS/SCENE/GAIN 为 **174 PASS / 0 FAIL**；普通启动路径 30 次 **0 崩溃、30 次进入播放**，复制真实 profile 到临时目录的无输入启动也正常退出，真实用户档 SHA-256 守卫未变化。该轮打包的二进制 SHA-256 为 `74baf0026df74ebb1f6c2b0ee1157e97d75c7bb81f18de67af63719a605c0589`。

ASan 首轮 WATCH 曾在输出任何断言前被系统终止；mac crash report 的栈为 `_os_unfair_lock_unowned_abort → sanitizer StackDepot/Allocator → Security CodeSigning → Qt SandboxChecker`。该轮不能记作全绿；单独重跑、随后整轮 852 项以及 WATCH 连续 30 次均通过。保留 `/tmp/tt-final-asan.log`、`/tmp/tt-final-asan-watch-30.json` 与系统 `ttplayer-2026-11-20-171643.ips`，避免隐藏不稳定结果。

Swift 参考基线此前 Debug/Release 各 1411 个断言通过，**不是 Qt 逐断言等价移植的证明**。24 个 Swift suite 与 40 个 Qt suite 的行为对应见 [qt-selftest-mapping.md](qt-selftest-mapping.md)。

此前原生 CoreAudio 的 DEVICE+GAPLESS 为 120 PASS；正常 Qt 打包路径隔离启动 30 次无崩溃且均进入播放。回调人工渲染测试曾与开启的物理设备竞争，改为只在人工渲染矩阵关闭设备；公开播放的真实设备回调仍独立测试，不能混写为生产无缝缺陷。

以下仍需验收，不能宣称已实现全平台 1:1：Windows/Linux 原生编译运行与系统媒体面板、物理 USB 拔插/零设备/睡眠唤醒、桌面玻璃/焦点/置顶、RAR/RAR5 真样本，以及整专辑 padding 与海量网络卷性能矩阵。mac 本机 ASan/UBSan 不等价于 TSan。依赖 FFmpeg 上游编译告警与产品 0 warning 口径分开。

所有测试和启动探针使用隔离 state/resume，并校验真实用户档。历史复现程序仍用于保留修复前证据，不应把其旧断言结果当当前验收结论。
