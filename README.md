# TTPlayer（千千静听复刻版）

一款基于 Qt 的跨平台桌面音频播放器，向经典 TTPlayer 千千静听的皮肤与交互致敬。设计目标为**低资源占用 · 视觉品质 · 广泛格式支持**。

## 主要特性

- **格式覆盖广**：MP3 · AAC/M4A · FLAC · Apple Lossless · OGG（Vorbis/Opus）· APE · TTA · WAV/AIFF/CAF/AU/W64 等 PCM · DSF（DSD64/128/…）· Matroska 音频轨 · CUE 分轨 · 网络电台 · zip/tar/7z/rar 压缩包直听
- **听得干净**：无缝播放（专辑曲间不插空白）· ReplayGain 响度均衡（按曲目 / 按专辑，带峰值防削波与前置增益）· 10 段均衡器 + 8 组预设
- **管得住曲库**：媒体库目录自动跟踪（盘上有增删不必手动重扫）· 自建歌单与 m3u 导入导出 · 全局搜索 · 待播队列 · 收藏与两份最近播放历史 · 退出时的现场下次原样回来
- **电台齐活**：出厂自带一台电台（装上就在列表里，不想要直接删）· 自定义台名 · 分类管理 · 改地址搬家 · ICY「正在播放」· 断线按退避自动重连 · 连接质量统计
- **桌面应用**：支持 macOS、Windows、Linux；安装包需包含对应平台的 Qt 与输出依赖
- **资源控制**：有界音频缓冲、限额封面缓存，隐藏时暂停频谱绘制
- **可调半透明皮肤**：壳层、内嵌槽、按钮、传输带、底部条共用单一透明度参数，菜单里滑块实时调节
- **快捷键**：`空格` 播放/暂停 · `←` / `→` 上下曲 · `F1`~`F4` 四种播放方式 · `⌘O` 添加 · `⌘F` 搜索 · `⌘D` 收藏 · `⌘1` / `⌘E` / `⌘L` 列表 / 均衡器 / 歌词秀 · `⌥←` / `⌥→` / `⌥0` 歌词校准 · `⌘Q` 退出
- **系统整合**：菜单栏驻留后台继续播放 · 控制中心 / 锁屏 Now Playing · 输出设备任选 · 睡眠定时器

## 界面

沿用已确认的 Qt 深色样式：炭黑面板、浅色文字和橙色高亮。Swift 参考版仅用于对照功能与测试。

![Qt 深色主面板](docs/screenshots/qt-dark-main.png)

| 播放列表 | 均衡器 |
| :-: | :-: |
| ![Qt 播放列表](docs/screenshots/qt-dark-playlist.png) | ![Qt 均衡器](docs/screenshots/qt-dark-equalizer.png) |

## 安装

本轮 Qt 修复尚未发布。现有 Release 安装说明与这份工作树的 Qt 验证产物应区分；本轮验证入口与结果见 [修复记录](docs/review-fixes.md)。

### 通过 GitHub Release 安装（推荐）

从 [Releases 页面](https://github.com/myzhan/TTPlayer/releases) 下载最新版本 `TTPlayer-vX.Y.Z-macOS-universal.zip`：

```sh
unzip TTPlayer-vX.Y.Z-macOS-universal.zip
mv TTPlayer.app ~/Applications/
xattr -dr com.apple.quarantine ~/Applications/TTPlayer.app
open ~/Applications/TTPlayer.app
```

发布包采用 ad-hoc 签名，未经 Apple 公证。首次启动需通过上述 `xattr` 命令移除隔离属性，或在 Finder 中右键图标选择"打开"。

### 从源码构建

前置条件：macOS 12+、Xcode 15+ 命令行工具、`brew install nasm yasm`。

```sh
git clone --recurse-submodules https://github.com/myzhan/TTPlayer.git
cd TTPlayer
zsh build_app.sh
open build/TTPlayer.app
```

`build_app.sh` 会先调用 `scripts/build_ffmpeg.sh` 从 submodule 编译 FFmpeg 静态库（首次约需 5 分钟），随后打包 `.app`。开发流程详见 [`AGENTS.md`](AGENTS.md)。

## 支持格式

| 类别 | 范围 |
| --- | --- |
| 有损编码 | MP3（含 MP2/M2A/MPA）· AAC / ADTS（含 HE-AAC）· Vorbis / Opus（`.ogg`）|
| 无损编码 | WAV / AIFF / CAF / AU / W64 里的 PCM（8/16/24/32-bit、float、μ-law/A-law、IMA ADPCM）· FLAC · ALAC · APE（`.ape/.apl/.mac`）· TTA |
| Hi-Res / DSD | 24 / 32-bit PCM · DSF（DSD64 / 128 / …，解出后降 8 倍到 PCM 基准率）|
| 容器 | m4a / mp4 / m4b · mov（拖单文件时试其音轨，目录扫描不收）· mkv / mka / mks / webm · caf · au / snd · w64 |
| 网络流 | HTTP / HTTPS 直播流（ICY metadata）|
| 分轨与歌单 | CUE sheet（内嵌或外挂）· m3u / m3u8 |
| 归档容器 | zip · tar · tar.gz · tar.bz2 · 7z · rar（拖入压缩包直接听，无需先解压）|
| 标签与封面 | ID3v1 / v2 · Vorbis Comment · MP4 ilst · APEv2 · FLAC PICTURE · M4A 内嵌封面 |

白名单以运行时枚举内置 FFmpeg 解复用器声明的扩展名为准，不在表里的后缀会在导入时给一句拒收原因。同专辑曲目共用一份封面位图；显示小档 112 px，解码上限 256 px，并纳入 8 MiB LRU 缓存。已知限制与逐项实测见 [Releases](https://github.com/myzhan/TTPlayer/releases)。

## 系统要求

- macOS 12 Monterey 或更新版本；Windows 10 或更新版本；具备桌面环境的 Linux
- 安装包与处理器架构对应。Qt 跨平台版的体积与旧 Swift 版不同，具体以下载包为准
- 当前截图展示已确认的 Qt 深色样式；验证状态见 [修复记录](docs/review-fixes.md)

## 常见问题

**首次启动提示"已损坏，无法打开"**
ad-hoc 签名的 app 未经 Apple 公证，Gatekeeper 会阻止打开。执行 `xattr -dr com.apple.quarantine /path/to/TTPlayer.app`，或在 Finder 中右键图标选择"打开"。

**如何终止进程**
`⌘Q`；或点击菜单栏图标选择"退出"；或点击主面板 `×`。本项目的 `×` 语义为终止进程（不同于 macOS 常规窗口关闭），后台驻留请使用 `—`。

**皮肤未呈现透明效果**
确认菜单中"半透明玻璃"已勾选，并将下方"透明度"滑块向左调整。若桌面壁纸为纯黑或纯色低对比图像，视觉差异不明显。

**F1~F4 按了没反应**
Mac 键盘默认把功能键分配给亮度 / 播放控制。请在系统设置 → 键盘中启用"将 F1、F2 等键用作标准功能键"，或按住 `Fn` 再按；菜单里也有同样的四种播放方式。

**某些文件拖进来没反应**
播放器按后缀白名单放行。本 build 的 FFmpeg 未编入解码器的（`.tak`、Musepack、Shorten、RealAudio、MIDI / Tracker 模块）会给出具体原因；可以通过全局搜索的格式筛选查看已导入的格式。

**DSD 文件无声或异常**
`.dsf` 由 FFmpeg 解出 DSD 流后再降采样 8 倍到 PCM 基准率（DSD64 → 44.1 kHz、DSD128 → 88.2 kHz）。若音频设备不支持高采样率，请把输出设备切到 44.1 kHz 或 48 kHz 那一档，或在菜单 → 输出设备里固定到别的设备。

**媒体库和 `[默认]` 列表有什么区别？**
「媒体库」是目录扫描出来的只读视图：盘上有什么就是什么，不能删行也不能清空，想少收一片目录去菜单 → 媒体库里移除。`[默认]` 才是你自己攒的播放列表，导入、拖入、排序、清空都作用于它。

**响度均衡为什么默认关闭？**
它会把不同母带的相对响度拉平，属于"改掉原曲听感"的处理，因此不像无缝播放那样默认开启。需要时按曲目或按专辑打开，没有 ReplayGain 标签的曲子仍保持原音量。

## 许可

[MIT](LICENSE)。本项目代码按 MIT 开源；FFmpeg 组件遵循其自身 LGPL/GPL 许可，从源码静态编译链入仅供个人使用，若需再分发请自行核对 FFmpeg 授权条款。

## 相关

- 开发约定与贡献指南（环境 / 命令 / 分层 / 常见坑 / 验证）：[`AGENTS.md`](AGENTS.md)；每版实测数据与安装包见 [Releases](https://github.com/myzhan/TTPlayer/releases)
- Issue 与建议：<https://github.com/myzhan/TTPlayer/issues>
