# AGENTS.md — Agent / 贡献者开发约定

面向在 TTPlayer 仓库里协作的 AI Agent 与人类贡献者。**动手之前先读这一页**，能避开本仓已经踩过的坑。

## TL;DR

1. 编译必须 **0 error 0 warning**（debug 与 release 都过）
2. 全量自检必须 **1390 PASS / 0 FAIL**（debug 全量实测 225.8 s、release 实测 202.5 s：gain 54 s、gapless 38~48 s、radio 24 s 是三大头，分档与提速口径见《自检分档与计时》；条数随功能增长，以当前仓库实跑为准；环境相关 SKIP 不算失败：本机一轮是 3 条——TTA 真码流不入库、归档 rar 本机无 CLI、本机拿不到「零输出设备」环境，APE 真引擎那条需 `brew install mac`。另：`性能-常驻内存` 与 `性能-启动/首帧` 只认热轮，连着构建的忙轮会虚高（实测：连着 `build_app.sh` 就跑的打包版报 199.3 MB 超 190 门槛，机器凉下来单跑 perf 同一个二进制是 145.9 MB），见 PerfSuite 注释）
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
| 中档自检 | `./scripts/selftest.sh core` / `core release`（全量剔掉取证三套，实测 1111 项 / 99.2 s）|
| 按改动挑档 | `./scripts/selftest.sh affected`（只挑档不跑：`TTPLAYER_DRYRUN=1`）|
| 全量自检 | `./scripts/selftest.sh all` / `all release` |
| 看时间花在哪 | `TTPLAYER_TIMING=1 ./scripts/selftest.sh all`（跑完多打「最慢 25 条 + 分套件余额」）|
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
| `TTPLAYER_TIMING=1` | 每条断言记「上一条到这一条」的墙钟差，跑完打计时榜（`SuiteID` 里 `timingTop` 控制条数）。前置/收尾没落在断言上的时间走「余额」那一行 |
| `TTPLAYER_DRYRUN=1` | 配 `affected` 用：只打印挑到哪一档就退出，不跑测试（改分类器时验分类器）|
| `TTPLAYER_AFFECTED_FILES` | 直接给文件名单（空白分隔）让 `affected` 判档，不看 git（验分类器本身用）|

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

### 自检分档与计时

全量的耗时大头是「取证三套」`SuiteID.timed`（gapless / gain / radio）：它们只能跑真实时钟，
改一行文案不该拿它们陪跑，所以拆了三档：

- `smoke`（lyric/playlist/spectrum）——不碰设备、不开窗，几秒
- `core` = `all − timed`——改 UI / 曲库 / 列表 / 存档这一层用它，实测 1111 项 / 99.2 s
  （里面带着 `.perf`，连着构建的忙轮会让常驻内存虚高，拿到 `性能-常驻内存` 失败先隔一分钟单跑 perf）
- `all`——发版门槛，也是 `affected` 判到音频层时的档

`affected` 只看改动落在哪一层，不去拆「只跑了 gain 还是只跑了 radio」（那要在 shell 里再抄一份
`SuiteID.all` 的顺序表，漂移不起）：docs/图片/CI → `smoke`；`UI/`、`Windows/`、`Models/`
（非 `Radio*` / 非 `ReplayGain*`）→ `core`；其余与认不出的路径 → `all`，保守兜底。

已经做过且有实测对比的提速（不要回退）：

- **gain 88.3 → 54.0 s**：取证 `span` 1.0 → 0.3（素材是 880 Hz 正弦，0.3 s = 264 周期，
  截断误差上界 ~0.03% ≪ 容差 3%）+ 基准 RMS 缓存（同条件只测一次），
  配套断言 `响度均衡-同条件重测一致` 是「复用合法」的凭据，它自己故意不走缓存
- **radio 43.1 → 23.7 s**：`RadioPlayer.retryScale`（自检 0.125）只压**排下去的等待**，
  出厂 `retryDelay` 2/4/8/8 保持纯净供断言钉档位；自检里的 `pump` 一律按 `retryWait(...)` 表达式写，
  不要再写魔法秒数
- **shift / sleep 各 −6 s**：等的是 `!isPlaying`，不是 `!isRadio`（见坑 #10）

不能裁的：gapless 的衔接帧数（本身要真播）、device / library / scene 那几套里的设备切换与
FSEvents 延迟（被测行为就是它）。`core` 跑绿不等于取证过了，发版仍需 `all`。

### 皮肤布局版本

改窗口尺寸 / 面板划分 / 三窗排布 → **必须** 递增 `MainWindowController.skinLayoutVersion`（当前 = 6）。旧 `state.json` 里的 `skinLayout` 不匹配时 `migrateSkinLayout` 会一次性丢几何重排。

### state.json 持久化

- `AppState`（`LibraryStore.swift`）用**宽容解码**：每字段 `decodeIfPresent` + 兜底默认值。加字段必须同步加 `case`，否则旧档解到新档缺 key 会整份失败、退化成空默认、把用户曲库丢掉
- 用户 `~/Library/Application Support/TTPlayer/state.json` 是回归基线，跑自检前后应 **逐字节相同**（`scripts/selftest.sh` 用 shasum 对比并透传失败）；自检自己的存档走 `TTPLAYER_TESTDIR`，两者不得串

### 出厂电台默认入表

内置电台（`Models/RadioPresets.swift`）不再有菜单入口：入口埋得深等于没有，启动时由
`PlayerController.seedPresetRadios()` 直接把它塞进 [默认] 列表，不想要就在列表里删。四句话能记牢：

- **删过就不回来**：`AppState.declinedRadioKeys` 是黑名单，逐行删除 / 在电台页清空 / 改了地址
  （旧身份进黑名单）都会记一笔；旧档缺这一项 = 谁也没删过 = 升级后补种一台
- **不开播**：`playNow: false`，不能抢掉用户上次听的那一首
- **同一条通路**：一律走 `addRadio`（归一化 + 去重），不另开通路、不自建 Track
- **台名不写档**：`RadioPresets.name(for:)` 按地址兜底，`aliases` 里永远不该多出一条“谁也没写过”的别名

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
10. **电台 `stop()` 是「装载着但停住」**（跟本地文件一致，再按播放就是重连这个台）：`isRadio` 不会被抹掉，自检要拿它当「擦干净」的证据就错；凭据是 `!isPlaying && radioStateText == "未连接"`。这条不只是正确性：拿 `waitUntil { !isRadio }` 当等待条件必然白等满超时（实测 `shift` 与 `sleep` 各多烧 6 s，改 `!isPlaying` 后全量直接少 12 s）。
11. **音频取证不能单点读一窗**：① 频谱——`SpectrumView` 按窗口 occlusion 驱动 `analyzer.setEnabled(false)`，窗口不可见时 PCM 再真 `bars` 也是 0，自检一律走 `ctx.spectrumEnergy`（测量期间临时 enable、多次取 max）；② 设备切换——换设备/重建输出链/拔插之后马上 `measure` 会撞上旧缓冲尾巴与重排期的咔哒（实测全量跑里 RMS 0.36 / 音高能量 0.008，单跑复现不出来），走 `DeviceSuite.measureSettled` 连采几窗取音高最强的一窗（拿到干净窗就 break，不白等）。
12. **自绘 `TTButton` 用 anchor 约束前必须关 `translatesAutoresizingMaskIntoConstraints`**：不关的话 AppKit 会按它的初始 frame 补一组**必需**的 `minX/width/minY/height` 约束，顺着 `toggle.trailing == field.leading - 4` 这类兄弟关系把整条标题行的宽度锁死（放大镜那颗就曾经把搜索框钉在 264pt、把列表标题压成 4pt），而且**不打印冲突日志** —— 只能靠 dump `listWell.constraints` 的 description 才看得见。这类“宽度怎么改常量都不生效”的现象先查 autoresizing 约束，不要去猜“哪个控件自带固有宽度”。
13. **搜索态里 `controller.playlist` 就是命中表**（F05 全局搜索）：任何“原列表还剩多少行”、“这首歌不在当前页”的断言都得先 `collapseSearch()` 退出后再读，否则会拿命中表当原列表，验证的是假命题。同理，面板把关键字交给控制器**之前**必须先 `playlistView.noteSceneBeforeSearch()`（那一刻表格装的还是原页），而 `sceneBeforeSearch` 只能在退出分支消费并置 nil，进分支干空会把刚采到的现场抹掉。
14. **预取只能在当前曲已经排进节点之后发起**：`schedulePrefetch()` 要跟在 `engine.play()` 后面（`startLoad` 就是这个次序），不要搬到“装载完但还暂停”的入口上——实测在 `restorePlaybackScene` 里直接预取，恢复后开声采到的是本曲**从头**的声音（`现场-放出来的是那一段的真实 PCM` 拿到第 0 段而不是第 8 段，CUE 那条同样退到镜像第 0 段），因为此时 `feed` 还是空的，下一曲的段能抢在本曲之前排进节点。暂停后恢复、启动自动续播同样缺这一笔（补在开声那一步，`prepareNext` 自带同键去重，重复调用不会重开解码）。
15. **两种用户意图不能拿一个共用布尔值加位置去猜**（F03 队列）：`insertNext`（「下一首播放」）与 `appendLater`（「稍后播放」）都只记 `explicit = true`，推进时再拿「紧邻当前项且 explicit」当插队判据，边界一重叠就分不开——上下文只剩一条、或当前曲就在基础序列末尾时，刚追加的稍后项正好坐在 `cursor+1`，单曲循环被它打断（实测 30/30）；反过来拿它往整个尾部扫又会把未播的基础条目跨过去、让它们永久消失。改法是给 `QueueItem` 记一条不可变的来路 `source: QueueSource`，`explicit`/`playNext` 都从它派生，插队只认「位置 + 来路」两个条件都得上。两条连带规矩：拖动重排只改次序不改来路（拖到最前面的稍后项不伪造插队意图），以及存档新增字段要成对加齐（`ResumeScene.queueNext` 的 `case` + `decodeIfPresent` + `sanitized` 长度对齐 + `source(at:)` 合成，旧档缺字段只能保守重建为 `.later`）。

## 变更前后必做的验证

```sh
# 1. 双构型编译
swift build && swift build -c release

# 2. 迭代期按改动挑档（不碰音频链就不要拿取证三套陪跑；它只挑档，不是发布门槛）
./scripts/selftest.sh affected            # 判到哪一档就跑哪一档（smoke / core / all）
./scripts/selftest.sh core                # 改 UI / 曲库 / 列表 / 存档这一层的中档

# 3. 发布门槛：debug + release 全量各一遍（交付物是 release，debug 才能抱住只有
#    `#if DEBUG` 能看见的那一段），打包版只跑冒烟（与 release 全量信息重叠最大）
caffeinate -u -t 300 ./scripts/selftest.sh all
caffeinate -u -t 300 ./scripts/selftest.sh all release
zsh build_app.sh && plutil -lint build/TTPlayer.app/Contents/Info.plist
TTPLAYER_BIN=build/TTPlayer.app/Contents/MacOS/TTPlayer ./scripts/selftest.sh
# 只有改了解码 / 输出链拓扑，才补一遍打包版全量

# 4. state.json 逐字节校验
sha1sum testlib/state.json  # 与变更前对比

# 5. 目视（改 UI 必做）：open build/TTPlayer.app 或看 build/selftest/shots/*.png
```

“debug 与 release 各跑一遍”不是凑数：`PerfSuite` 的预算本就按构型分档（DEBUG 600 / 6.0，
release 500 / 2.0），多线程竞态的窗口也会随优化挪位置。日常 commit 只需 debug；
发版门槛 = release 全量 + 打包版冒烟。

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
