# AGENTS.md — Agent / 贡献者开发约定

面向在 TTPlayer 仓库里协作的 AI Agent 与人类贡献者。**动手之前先读这一页**，能避开本仓已经踩过的坑。

## TL;DR

1. 编译必须 **0 error 0 warning**（debug 与 release 都过）
2. 全量自检必须 **1293 PASS / 0 FAIL**（debug 全量实测约 291 s：radio 46 s、gapless 48 s、gain 88 s 是三大头；条数随功能增长，以当前仓库实跑为准；环境相关 SKIP 不算失败：TTA 真码流不入库、APE 真引擎需 `brew install mac`、归档 rar 本机无 CLI、本机拿不到「零输出设备」环境。另：`性能-常驻内存` 与 `性能-启动/首帧` 只认热轮，连着构建的忙轮会虚高，见 PerfSuite 注释）
3. 用户 `~/Library/Application Support/TTPlayer/state.json` **前后逐字节相同**（回归纪律；`scripts/selftest.sh` 自己用 shasum 校验，测试存档走 `TTPLAYER_TESTDIR`）
4. 本文只留开发约定，不写版本历史——每版改了什么、靠什么验证，看 `git log` 与 GitHub Release
5. 音频素材不入仓（除了 `testlib/` 现有的短样本）；FFmpeg 产物 `3rd/ffmpeg-build/` 走 `.gitignore`

## 环境搭建（新克隆第一次跑）

```sh
git submodule update --init --depth 1 3rd/ffmpeg
brew install nasm yasm                       # FFmpeg configure 需要
zsh scripts/build_ffmpeg.sh                  # 约 5 min，产出 3rd/ffmpeg-build/{include,lib}
swift build                                  # 应该 0 error 0 warning
./scripts/selftest.sh                        # 冒烟档，几秒
./scripts/selftest.sh all                    # 全量，release 门槛
```

归档流式播放链的是 macOS 自带的 libarchive（`/usr/lib/libarchive.2.dylib` + SDK 里的 `libarchive.tbd`），**不需额外安装或编译**；`Sources/CLibarchive` 只是一个 `package.swift` 里的链接桥接 target。

`build_app.sh` 会自动检查并调 `build_ffmpeg.sh`，首次 `zsh build_app.sh` 也能一把跑通，只是慢。

## 常用命令

| 目的 | 命令 |
| --- | --- |
| Debug 编译 | `swift build` |
| Release 编译 | `swift build -c release` |
| 直接跑二进制 | `.build/debug/TTPlayer` |
| 打 .app 包 | `zsh build_app.sh` → `build/TTPlayer.app` |
| 冒烟自检 | `./scripts/selftest.sh` |
| 全量自检 | `./scripts/selftest.sh all` / `all release` |
| 指定套件 | `./scripts/selftest.sh ui cover` |
| 打过的 app 自检 | `TTPLAYER_BIN=build/TTPlayer.app/Contents/MacOS/TTPlayer ./scripts/selftest.sh all` |
| 通用二进制打包 | `TTPLAYER_ARCHS="arm64 x86_64" TTPLAYER_VERSION=v1.0.0 zsh build_app.sh` |

系统刚睡醒时音频设备可能未就绪（`AVFAudio 35`），跑音频类套件前建议 `caffeinate -u -t 120 ./scripts/selftest.sh`。

## 自检环境变量（`AudioEngine` / `SelfTest` 消费）

| 变量 | 作用 |
| --- | --- |
| `TTPLAYER_SELFTEST=1` | 进入自检模式（不启动主 UI，跑完退出） |
| `TTPLAYER_SUITE=ui,import` | 只跑指定套件（逗号或空白分隔；`all` / `smoke` 是保留字） |
| `TTPLAYER_SILENT_OUTPUT=1` | **自检不送物理设备**：`mainMixerNode.outputVolume` 锁 0，频谱 tap 改接 `fadeNode` 上游（音量推子前）。硬件接到静音、tap 仍读到完整 PCM。不用 `osascript set volume muted` 那种全局 mute。 |
| `TTPLAYER_TESTDIR` | 自检工作目录（默认 `build/selftest/`） |
| `TTPLAYER_PROBE` | 探针输出目录（`selftest.log`、`tt_selftest.txt`、`shots/*.png`） |
| `TTPLAYER_SHOTDIR` | 截图目录 |

`scripts/selftest.sh` 已经把上面这些串起来了，通常不用手设。

## 代码组织与约定

### 仓库分区

```
Sources/
├── CFFmpeg/                # SwiftPM 桥接目标（modulemap + shim）
├── CLibarchive/            # SwiftPM 桥接目标（modulemap + shim），链系统 -larchive，供归档流式读取
└── TTPlayer/
    ├── App/                # AppDelegate / 生命周期
    ├── Audio/              # AudioEngine（AVAudioEngine + EQ + Fade + Spectrum）·
    │                       # FFmpeg 解码 · Archive（libarchive 桥接 + AVIOContext）· RadioStream · FFT
    ├── Core/               # PlayerController · Events · NowPlaying · SelfTest
    ├── Models/             # Track · Playlist · CueSheet · CoverArt · Lyric ·
    │                       # MetadataReader · LibraryStore (state.json)
    ├── UI/                 # Theme · GlassStyle · SkinParts · 各控件视图
    ├── Windows/            # 主面板 · 播放列表 · 均衡器 · 歌词 · 封面 · 属性 · 菜单栏
    └── main.swift

AGENTS.md                   # 本文件：开发约定（环境 / 命令 / 分层 / 坑 / 验证 / 纪律），不写过程记录
docs/screenshots/            # README 里那几张图（自检 shot 拷进来入库）
scripts/                    # build_ffmpeg.sh · selftest.sh · gen_*.swift · probe_*.swift
3rd/ffmpeg                  # git submodule（n9.0），产物落 3rd/ffmpeg-build/（.gitignore）
testlib/                    # 自检素材（.gitignore，运行时现射）
.github/workflows/release.yml  # tag v* → 通用二进制 + GitHub Release
```

面向用户的README 不写开发内容（build 命令 / 目录结构 / 自检体系），一律写到这里。

### 分层不可越线

- **解码层 = FFmpeg**：所有音频解码统一走 `FFmpegDecoder`（`Sources/TTPlayer/Audio/FFmpeg.swift` / `FFmpegDecoder.swift` / `FFmpegProbe.swift`），不再自己写解码器、不再走 `AVURLAsset`/`AudioFileStream`
- **归档层 = libarchive**：zip/tar/7z/rar 不落地解压，统一由 `Audio/Archive.swift` 的 `EntryReader` 读条目，`ArchiveIO` 把条目包成自定义 `AVIOContext` 喂给同一条 `FFmpegDecoder` 通路（与电台同模式）；条目 URL 一律用 `file://…#archive-entry=<percentEncoded>`，不要把解压产物写回 `testlib/`
- **输出层 = AVAudioEngine**：`AudioEngine` 是 `playerNode → channelMixer → eq → fadeNode → mainMixerNode → outputNode` 的固定拓扑；`RadioStream` 用自定义 AVIOContext 喂 `avformat_open_input`
- 任何"我想加个 XX 编码器的 Swift 实现"的冲动 → 先看 FFmpeg 是否已覆盖；99% 是已覆盖，只需在 `AudioFormats.undeclaredExtensions` 补扩展名

### UI 皮肤的两条渲染路径

改玻璃透明化时**必须分别处理**：

1. **WellView 系**（显示区/列表）：统一类，改 `WellView.draw()` 就够
2. **自绘渐变类**：`TTButton(.glass face)` / `CoverView` / `LyricView` / `EQBodyView` **不走** WellView，各自直接 `NSGradient(...).draw`，需要逐个接入 `GlassStyle.wellAlpha` / `buttonAlpha` + `GlassStyle.didChange` 观察者

3. **GradientView 子类**：`bodyAlpha` 通过 `glassAlphaOverride ?? GlassStyle.bodyAlpha` 决定，子类按需设 `glassAlphaOverride`（`SegmentedGlassBar` 用 `buttonAlpha`，`bottomStrip` 用 `wellAlpha`）

### 单一 transparency 主参数

`GlassStyle` 只暴露一个 `transparency: CGFloat`（0~1）：
- `bodyAlpha = transparency`
- `wellAlpha = min(transparency + 0.10, 1.0)`（内嵌槽深一点保文字可读）
- `buttonAlpha = transparency`（按钮与壳同值，靠描边标识）

新增分层时**不要**再加静态常量，从这个主参数派生。

### 皮肤布局版本

改窗口尺寸 / 面板划分 / 三窗排布 → **必须** 递增 `MainWindowController.skinLayoutVersion`（当前 = 6）。旧 `state.json` 里的 `skinLayout` 不匹配时 `migrateSkinLayout` 会一次性丢几何重排。

### state.json 持久化

- `AppState`（`LibraryStore.swift`）用**宽容解码**：每字段 `decodeIfPresent` + 兜底默认值。加字段必须同步加 `case`，否则旧档解到新档缺 key 会整份失败、退化成空默认、把用户曲库丢掉
- 用户 `~/Library/Application Support/TTPlayer/state.json` 是回归基线，跑自检前后应 **逐字节相同**（`scripts/selftest.sh` 用 shasum 对比并透传失败）；自检自己的存档走 `TTPLAYER_TESTDIR`，两者不得串

### 关闭 / 最小化

- **×** = `NSApp.terminate(nil)`（直退进程）
- **—** = `dock.hideGroup()`（隐藏到菜单栏后台继续播）

不要按 macOS 常规直觉改回"× 关闭只关窗"。这是用户明确要求。

### 音频热路径

- 频谱重绘 **24 fps**（不是 30）；`wantsLayer = true` 自成图层；窗口遮挡/熄屏时 `tick()` 直接 return 不重绘
- 64 根柱子 → **整块渐变 + 柱子路径裁一次 + 柱尖高光一次填充**，不要每根柱子各画一次渐变（会退化回 8 个百分点 CPU）
- 封面共享：内嵌图按图片字节 SHA-256、外部图按 "路径+大小+mtime" 做 key，`NSMapTable.strongToWeakObjects()`；小档 112px 常驻、大档 256px 按需 + 8 MB LRU

## 常见坑

1. **`deinit` 里对 semaphore 二次 `wait`**：`RadioStreamDecoder.close()` 显式 close 后 deinit 不能再 wait 无上限（会永久阻塞主线程在 `semaphore_wait_trap`）。用 `joined` 布尔开关保证幂等。
2. **kAudioHardwarePropertyNullAudioDevice 在 macOS 不存在**（iOS-only）。想让自检不出声只能走 AU 拓扑：`mainMixer.outputVolume = 0` + tap 挪到 `fadeNode` 上游。
3. **`NSVisualEffectView` 在 borderless 窗上 `behindWindow` blending 需要容器开 `wantsLayer`**，否则不参与 WindowServer 合成，看起来完全没透。
4. **autocorrect 干扰中文**：SearchReplace 之后**必须**看 diff，`喼 / 喑 / 隐忠 / 仍就是` 这类错别字立刻改。
5. **`swift build` 的链接顺序**：`avformat → avcodec → swresample → avutil`，缺 `-lz -lm -lpthread -framework CoreFoundation/CoreVideo/CoreMedia` 会 undefined symbols。
6. **SwiftPM `-Xcc` 传头路径**：`cSettings.unsafeFlags -I` 只作用于 CFFmpeg 自身；Swift 侧 `import CFFmpeg` 走 clang importer，还要 `swiftSettings.unsafeFlags(["-Xcc", "-I..."])`，否则 umbrella header 里的 `<libavutil/...>` 找不到。
7. **APE 标签样本要写在 `NSTemporaryDirectory()/ttplayer-ape`**，别写 `testlib/` 根目录，否则会被 `scanLibrary()` 当曲库把 m3u 展开/转码矩阵全打乱。
8. **电台的「过期回调」有三种，各挡一处**（F11）：① 退避定时器要登记连接代号（`RadioPlayer.generation`），否则用户在断线退避中点了「重试」，新流刚连上就被旧定时器掐掉重连；② `startRadioPlayback()` 撞上一个还挂着「要切的台」的淡出时必须直接返回，否则 `resetRadioFade()` 会把那条待办一起丢掉，重试按下去没反应（自检表现为会话号不翻页）；③ 晚到的 `.playing` 状态不能把界面点亮——`engine.stop()` 之后 `isRadio` 依旧为真，靠它挡不住，只认 `radioWantsPlay`。
9. **`LocalRadioStream` 的 `config` 只对下一个连接生效**（`handle()` 里快照）：改剧本要靠重连才生效；`lastDropBy` 说的是「最近一次掉线由谁掐」，剧本不再掐线了它也不会自己变回去，验「不再掉线」得看连接数冻住。
10. **电台 `stop()` 是「装载着但停住」**（跟本地文件一致，再按播放就是重连这个台）：`isRadio` 不会被抹掉，自检要拿它当「擦干净」的证据就错；凭据是 `!isPlaying && radioStateText == "未连接"`。
11. **音频取证不能单点读一窗**：① 频谱——`SpectrumView` 按窗口 occlusion 驱动 `analyzer.setEnabled(false)`，窗口不可见时 PCM 再真 `bars` 也是 0，自检一律走 `ctx.spectrumEnergy`（测量期间临时 enable、多次取 max）；② 设备切换——换设备/重建输出链/拔插之后马上 `measure` 会撞上旧缓冲尾巴与重排期的咔哒（实测全量跑里 RMS 0.36 / 音高能量 0.008，单跑复现不出来），走 `DeviceSuite.measureSettled` 连采几窗取音高最强的一窗（拿到干净窗就 break，不白等）。
12. **自绘 `TTButton` 用 anchor 约束前必须关 `translatesAutoresizingMaskIntoConstraints`**：不关的话 AppKit 会按它的初始 frame 补一组**必需**的 `minX/width/minY/height` 约束，顺着 `toggle.trailing == field.leading - 4` 这类兄弟关系把整条标题行的宽度锁死（放大镜那颗就曾经把搜索框钉在 264pt、把列表标题压成 4pt），而且**不打印冲突日志** —— 只能靠 dump `listWell.constraints` 的 description 才看得见。这类“宽度怎么改常量都不生效”的现象先查 autoresizing 约束，不要去猜“哪个控件自带固有宽度”。
13. **搜索态里 `controller.playlist` 就是命中表**（F05 全局搜索）：任何“原列表还剩多少行”、“这首歌不在当前页”的断言都得先 `collapseSearch()` 退出后再读，否则会拿命中表当原列表，验证的是假命题。同理，面板把关键字交给控制器**之前**必须先 `playlistView.noteSceneBeforeSearch()`（那一刻表格装的还是原页），而 `sceneBeforeSearch` 只能在退出分支消费并置 nil，进分支干空会把刚采到的现场抹掉。

## 变更前后必做的验证

```sh
# 1. 双构型编译
swift build && swift build -c release

# 2. 全量自检（debug + release + 打包版三选二，改 UI/解码必跑齐）
caffeinate -u -t 180 ./scripts/selftest.sh all
caffeinate -u -t 180 ./scripts/selftest.sh all release

# 3. 打包 + Info.plist lint
zsh build_app.sh && plutil -lint build/TTPlayer.app/Contents/Info.plist

# 4. state.json 逐字节校验
sha1sum testlib/state.json  # 与变更前对比

# 5. 目视（改 UI 必做）：open build/TTPlayer.app 或看 build/selftest/shots/*.png
```

## 提交 / 发布纪律

- **不主动 commit**，用户没明确说 "commit / 提交 / 落一下" 就只留在 working tree
- **不主动 push tag**：`v*` tag 会触发 `.github/workflows/release.yml` 直接发 GitHub Release
- Commit message 建议格式：`v1.N: <一句话>` + 空行 + 正文展开（本版改了什么、靠什么验证）；发布说明由 release.yml 自动生成
- 若改了 `Package.swift` / `scripts/build_ffmpeg.sh` / FFmpeg submodule 指针，release note 要单开一段说明

## 沟通约定（写给 AI Agent）

- **实测优先于演绎**：任何"我觉得这里应该是 X 引起的"→ 先复现 + 采样（≥30 次防抖 / `sample` 抓栈 / `footprint` 归因），拿到量化数据再动手或回复
- **性能意识**：热路径不重算不变量；常量字符串别拼接；正则提到包级；改动要附 bench 前后对比。收益微小就回退，别为复杂度找借口
- **不必逐句请示**：docs 查询、web 搜索、读源码、跑自检/编译，直接做完汇报结论
- **回复语言**：中文；技术术语与代码符号保留原文
