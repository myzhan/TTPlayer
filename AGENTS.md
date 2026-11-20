# AGENTS.md — TTPlayer 开发约定

当前产品位于 `src/`，使用 C++20 / Qt 6 Widgets / FFmpeg / libarchive；Windows/Linux 输出使用 SDL2，macOS 按 UID 打开 HAL AudioUnit。
Swift 参考实现保留在 `legacy/`；其历史约定见 [legacy/AGENTS.md](legacy/AGENTS.md)。
修改 Qt 行为时，应对照该实现及其自检，不能仅以编译成功作为验收。

**用户确认的视觉基线是当前 Qt 深色样式。本轮禁止修改配色、字体、布局、透明度规则和控件外观。Swift 只用于功能行为与测试覆盖对照，不能据此改回蓝灰样式。**

## 必须遵守

- Debug、Release 都必须 0 error / 0 warning。CMake 已开启 GCC/Clang 的 Wall/Wextra/Wpedantic 和 MSVC 的 W4。
- 全量自检必须 0 FAIL；报告实际 PASS / SKIP 数与环境。不得用增加重复断言的数量冒充覆盖对齐。
- 自检、截图、打包探针必须隔离 state.json 和 resume.json，真实用户档前后逐字节一致；不得用旧快照覆盖用户期间的修改。
- 没有明确指示，不 commit、不 push、不打 tag、不发布 Release。
- 音频素材只现场生成到测试目录；不把大音频、构建缓存、打包产物入仓。
- 中文沟通，实测优先；竞态至少重复 30 次，性能改动附测量口径和数据。
- 本文只写开发约定，不写过程记录。修复证据见 review.md 与 docs/。

## 构建

首次运行先初始化 FFmpeg 子模块：

```sh
git submodule update --init --depth 1 3rd/ffmpeg
```

macOS 使用 Qt 6.8.x（含 Core5Compat）、SDL2、nasm/yasm 和 FFmpeg CLI。
部署目标固定 macOS 12.0，所有链接依赖也必须支持 12.0；不能用较新的 Homebrew bottle
再提高最低系统版本来消除链接告警。CI 演示了官方 Qt 与现编 SDL 的设置。
`CMAKE_PREFIX_PATH` 可以传入这些依赖的安装目录。

```sh
zsh scripts/build_ffmpeg.sh
cmake -S . -B build -DCMAKE_BUILD_TYPE=Debug
cmake --build build -j 4
cmake -S . -B build-release -DCMAKE_BUILD_TYPE=Release
cmake --build build-release -j 4
```

Linux 依赖 Qt6 Widgets/Network/Core5Compat/Concurrent/DBus、SDL2、libarchive、zlib、FFmpeg CLI，
运行 `bash scripts/build_ffmpeg_linux.sh`。Windows 使用 MSVC 2022、Qt msvc2022_64、
vcpkg x64-windows 的 SDL2/libarchive/zlib；初始化 MSVC developer 环境后，
在继承该环境的 MSYS shell 中运行 `scripts/build_ffmpeg_msvc.sh`，再由 CMake 构建。
不要混链 MSVC 与 MinGW 的 C++ 库。具体的依赖版本、生成器和安装步骤见 [Qt CI 配置](.github/workflows/qt-ci.yml)。

### 运行当前 Qt 版

macOS 和 Linux 的普通单构型构建生成 `build/ttplayer` 和 `build-release/ttplayer`。Windows 使用 Visual Studio 多构型生成器时，可执行文件位于构建目录的 `Debug` 或 `Release` 子目录。可先运行 `--version` 确认输出包含 Qt 版本和架构。macOS 打包与启动使用：

```sh
python3 scripts/package.py
dist/ttplayer.app/Contents/MacOS/ttplayer --version
open dist/ttplayer.app
```

打包目录是 `dist/`，Swift 的 `legacy/build_app.sh` 用于历史参考实现。更新 README 配图前，请按[界面截图说明](docs/screenshots/README.md)隔离存档、准备示例曲库并核对截图内容。

## 验证入口

```sh
./scripts/selftest.sh                     # smoke: lyric / queue / spectrum
./scripts/selftest.sh affected            # 按修改层次挑档
./scripts/selftest.sh core
./scripts/selftest.sh all
./scripts/selftest.sh all release
./scripts/selftest.sh review gapless gain
ctest --test-dir build --output-on-failure
python3 scripts/package.py               # 只生成本地 dist，不发布
```

统一实现是 `scripts/selftest.py`，可在 Windows 直接用 Python 调用。
默认每次增量构建当前源码；指定 `TTPLAYER_BIN` 时由调用者保证该二进制已更新。
`TTPLAYER_PROBE` 指定报告目录，其中 `run.json` 保存源码、二进制 SHA-256 和环境。
`TTPLAYER_DRYRUN=1` 只列挑档结果；`TTPLAYER_AFFECTED_FILES` 可直接传待分类的路径。
套件注册表只有 `src/testing/suites.txt` 一处，脚本与 CTest 都读取它。
完整行为映射与平台边界见 [docs/qt-selftest-mapping.md](docs/qt-selftest-mapping.md)。

自检默认 offscreen + SDL dummy。物理输出验证可用 `TTPLAYER_AUDIO_DRIVER=coreaudio`
（macOS），仍必须保留 `TTPLAYER_SILENT_OUTPUT=1`；采样发生在最终静音门之前。
真实设备拔插、锁屏、系统媒体按键和桌面合成应另做实机检查，不把 dummy 当硬件证据。
发布门槛：双构型全量、打包版冒烟；改输出链额外跑打包版全量与 ASan/UBSan。

Swift 基线从仓库根运行：

```sh
swift build --package-path legacy
swift build --package-path legacy -c release
TTPLAYER_BIN="$PWD/legacy/.build/debug/TTPlayer" TTPLAYER_TESTDIR=/tmp/ttplayer-swift-debug zsh legacy/scripts/selftest.sh all
TTPLAYER_BIN="$PWD/legacy/.build/release/TTPlayer" TTPLAYER_TESTDIR=/tmp/ttplayer-swift-release zsh legacy/scripts/selftest.sh all
```

## 分层和生命周期

- 所有解码走 Decoder / FFmpeg，所有归档走 libarchive 自定义 AVIO；归档不落地解压。
- 本地、CUE、归档、电台统一 resolver/importer，稳定身份不得互相截断或重造。
- Qt 线程只提交用户意图和 UI 更新；开流、扫描、预取放后台。结果绑定 generation 与取消标志。
- producer 独占 Decoder IO；设备 callback 只消费有界 PCM 环，不做 IO、不等待网络、不分配采样缓冲。
- seek 必须作废在途 PCM 和旧 EOF；切歌、停止、取消均不得被晚回调重新点亮。
- worker 必须有 owner。销毁先取消、收束 worker，最后释放接收对象；SDL 退出晚于引擎析构。
- EQ、音量、RG 与输出参数统一走引擎锁接口；不要重新暴露可由 UI 直接写的 DSP 引用。
- 无缝在输出侧接 PCM，不能退回 EOF 后等 UI 再换曲；切段须携带队列条目身份和各自 RG。
- 下一首播放 / 稍后播放保留 QueueSource；拖动不改来路。浏览页不重建播放上下文。

## 数据与界面

- registry、默认列表成员、媒体库扫描贡献互相独立。离线根目录不能当作确认删除。
- 每字段宽容解码、旧档保守兜底；未知字段保留，新增字段必须成对读写。
- state.json 原子保存；resume.json 每 5 秒及暂停/停止落盘，避免每次进度重写整库。
- 保存失败必须反馈；坏 JSON 备份失败不得覆盖原文件。
- 搜索先保存选区/滚动现场，退出按身份恢复；搜索删除摘掉可写页引用，媒体库保留。
- 改窗口尺寸/面板划分必须递增 MainWindow 中 kSkinLayoutVersion。
- × 直接退出；— 隐藏整组继续播放。无托盘平台保留最小化恢复入口。
- 频谱保持 24 fps，隐藏/不可曝光时停绘制及 analyzer；64 柱采用合并路径绘制。
- 保持既有深色 GlassStyle：壳、槽、按钮共用同一 alpha；不得按 Swift 的分层规则改动。
- 封面最多解码到 256 px，显示小档 112 px，缓存预算 8 MiB；热路径不重新开音频取图片字节。
- README 面向用户，构建、自检、目录结构只写本文与 docs。
