# 开发环境与调试指南

面向要改 `src/` 或在三个平台复现问题的开发者。产品使用说明见 [README](../README.md)，
开发约定（门禁、分层、数据规则）见 [AGENTS.md](../AGENTS.md)，本文只讲环境准备、编译与调试。

## 1. 代码与依赖布局

- 产品代码在 `src/`，构建入口是仓库根的 `CMakeLists.txt`，语言标准由顶层固定为 C++20。
- 第三方依赖以 git submodule 冻结在 `3rd/`，默认从源码静态编译，不依赖系统包：
  `ffmpeg`、`zlib`、`xz`(liblzma)、`libarchive`、`bzip2`、`sdl3`、`ogg`、`vorbis`、`opus`、`lame`、`fluidlite`、`libxmp`。
- 两个脚本产物目录不入仓：
  - `3rd/ffmpeg-build/`：`scripts/build_ffmpeg*.sh` 编出的静态 FFmpeg（含 `lib/`、`include/`）。
  - `3rd/codec-build/`：`scripts/codec_deps.sh` 编出的 mp3 / vorbis / opus 静态库。
- 所有构建产物统一放 `build/`：Debug 用 `build/`，Release 用 `build/release/`，
  打包用 `build/package/` 与 `build/dist/`。不要另开 `build-xxx` 目录。
- 自检素材只现场生成到临时目录，不入仓。

`src/` 按依赖方向分层，上层可以引用下层，反过来不行：

| 目录 | 职责 |
| --- | --- |
| `app/` | 进程外壳：`main.cpp`、`PlayerApplication`（文件打开事件）、`CrashHandler`、`InstanceGuard` |
| `models/` | 纯值对象：`Track`、`ReplayGain`、`PlayQueue`、`UserPlaylist`、`RadioStations` 等，不做 IO |
| `media/` | 单个媒体文件的字节层：FFmpeg / `Decoder` / `Archive` / 编码器、CUE·歌词·封面·m3u 解析、格式转换 |
| `audio/` | 输出与 DSP：`AudioEngine`、EQ、频谱、电台流 |
| `library/` | 曲目集合层：`Collections` 页装配、`LibraryStore` 存档、`Importer`、`GlobalSearch` |
| `playback/` | 播放控制：`PlayerController`（换曲、无缝、seek）与单调时钟 `Clock` |
| `ui/` | Qt Widgets 窗口、皮肤、主题、图标；只提交意图，不做阻塞 IO |
| `platform/` | 系统媒体会话（macOS Now Playing / Linux MPRIS / Windows SMTC） |
| `testing/` | 自检探针与套件注册表 `suites.txt` |

依赖方向：`models` → `media` → `audio` → `library` → `playback` → `ui`/`platform`，`app` 在最外层（入口、崩溃、单实例）。
唯一例外是 `ui/SkinWindow.cpp` 引 `app/Application.h`，用于把拖入的文件转给外壳打开。

```sh
git clone <repo> && cd TTPlayer
git submodule update --init --recursive --depth 1
```

`bzip2` 必须保留：libarchive 找不到内置 bzlib 时会退回外部 `bzip2 -d` 程序过滤器，
在 Windows 管道上会卡死。顶层 CMake 已在 configure 阶段对 `HAVE_BZLIB_H` 做硬校验。

### 序列音乐与默认音色

`MidiSequence` 有界解析 SMF 0/1、RMID、PPQN/tempo 与 SMPTE 时间基，将 KAR meta 词转成 LRC。
`SequencedAudioSource` 独占 FluidLite 或 xmp-lite 上下文，按需给出 48 kHz 双声道 Float32 RF64 字节流，
由 `Decoder` 原来的 FFmpeg PCM/swr 路径输出。七后缀共用格式白名单，不开放 libxmp 其余加载器。
随机定位从头重置、按不超过 1024 帧合成丢弃；冷定位成本随目标位置增长，长度查询不做渲染。
源数据限 MIDI 32 MiB/100 万事件/24 小时、模块 64 MiB；MIDI 尾音固定 2 秒，模块只播首个有效 sequence 一遍。
合成和样本加载都在原有后台 owner 中，音频设备回调不做 IO 或合成；初始化取消传入只读原子标志。

FluidLite 固定 `4a01cf1c67419e71da971d209f2855bbf4f3bab8`（LGPL-2.1-or-later），
libxmp 固定 `5d4f6aa2c7dcdf8e9cd8129fe579d45b36a302da`（4.7.4，MIT），只链接 lite 静态目标。
SF3 开启、stb_vorbis 关闭，vorbisfile/vorbis/ogg 必须来自现有 `codec-build` 的同构型产物。
默认音色是 FluidR3Mono_GM.sf3 v2.315（MIT），`prepare_soundfont.py` 校验 Debian 数据包的固定大小及
SHA-256 后，只提取音色和版权文件；不安装软件包、不跟随链接。首次 CMake 配置需联网下载约 18.7 MB，
已校验的 `build/assets/` 可离线复用；损坏缓存明确报错。Qt BIG_RESOURCES 将音色嵌入主程序，运行时无下载。

精准自检使用 `./scripts/selftest.sh MIDI MODULE DECODER FORMAT ARCHIVE CONVERT LYRIC GAPLESS PLAYBACK`，
加 `release` 验证 Release。MIDI 档包含 30 次独立音色初始化及真实 producer 定位/停止/换曲，超时预算 600 秒；
`TTPLAYER_SEQUENCE_BENCH=1` 额外记录 5/30 分钟冷定位，普通回归不付这笔成本。

### 许可证与静态库重链接

安装目录的 `legal/`（Windows）、`share/ttplayer/legal/`（Linux）、
`ttplayer.app/Contents/Resources/legal/`（macOS）包含 FluidLite 的版权声明、LGPL 2.1 全文、
libxmp/音色 MIT 许可、构建信息和 `corresponding-source.tar.gz`。程序自身 MIT 许可不替代第三方许可。
用户可修改这些库、为调试这些修改进行逆向工程，并用修改版重建/重链接本程序。

源码包包含此次工作树对应的全部产品及静态依赖源码、构建脚本、音色数据包缓存和逐文件 SHA-256 清单；
清单的 `symlinks` 列出按符号链接归档的条目，其 SHA-256 按链接目标路径的原始字节计算。例如 FluidLite 的 `example/FluidLite` 保留为指向 `..` 的链接。
源码包不包含用户存档、Git 历史、Qt SDK 或构建缓存。采用 LGPL 2.1 §6(a) 的源代码重链接方式，而非只给下载链接。
`build-info.json` 的 `binary_sha256` 按 `binary_sha256_scope` 说明记录链接产物；Qt 部署与代码签名在安装之后
改写主程序字节，重建产物与发布包本就不逐位相同，该哈希只用于识别对应的源码世代。
解开压缩包后进入 `TTPlayer/`，无需再初始化子模块，按本文的平台章节安装 Qt/编译器/CMake 等工具并构建：

1. 修改 `3rd/fluidlite/`（或其他静态依赖）源码；各目录内 `.source-revision` 记录对应版本。
2. macOS 执行 `zsh scripts/build_ffmpeg.sh --force`；Linux 用 `bash scripts/build_ffmpeg_linux.sh --force`；
   Windows 在 MSVC developer 环境的 MSYS2 shell 执行 `bash scripts/build_ffmpeg_msvc.sh --force`。
3. 执行 `cmake -S . -B build/release -DCMAKE_BUILD_TYPE=Release -DCMAKE_PREFIX_PATH=<Qt路径>`，
   再执行 `cmake --build build/release --config Release -j 4`，即把修改后的 FluidLite/xmp 静态重链接进程序。
4. 需要可搬动包时按本文打包章节执行；macOS 自建 bundle 需重新 adhoc 签名，不要求开发者签名凭证。

源码包已经包含默认音色缓存，因此音色准备不需要再次联网；Qt 与构建工具仍由开发者环境提供。
从源码包构建时脚本读取 `.source-revision`，修改后使用 `--force` 避免复用旧静态依赖。
发布前必须检查这些材料随二进制一同分发，并实际从源码包重建，不能用许可证文字代替重链接材料。

## 2. 三平台通用要求

| 组件 | 要求 |
| --- | --- |
| CMake | ≥ 3.21（Windows 多构型用 Visual Studio 17 2022 生成器） |
| Python | 3.x，自检与打包脚本用它；`ctest` 的每个探针也由它启动 |
| Qt | 6.8.x，组件 Widgets / Gui / Core / Network / Core5Compat / Concurrent / Sql（Linux 另需 DBus） |
| FFmpeg CLI | 自检夹具生成需要 `ffmpeg` 命令在 `PATH` 上 |
| 7z 工具 | 需要覆盖 `.7z` 与加密 ZIP 夹具时提供 `7z` 或 `7zz` |

`CMAKE_PREFIX_PATH` 用于指向 Qt 安装目录。Unix 用冒号分隔，Windows 用分号。

## 3. macOS

### 准备

```sh
xcode-select --install
brew install nasm yasm pkg-config ffmpeg
python3 -m pip install aqtinstall
python3 -m aqt install-qt mac desktop 6.8.3 clang_64 -m qt5compat -O "$HOME/Qt"
export CMAKE_PREFIX_PATH="$HOME/Qt/6.8.3/macos"
```

部署目标固定 12.0：顶层 CMake 默认写入 `CMAKE_OSX_DEPLOYMENT_TARGET=12.0` 并显式取
`xcrun --show-sdk-path`。所选 Qt / 依赖必须同样支持 12.0，不能为了消除链接告警提高最低系统版本。

### 编译

```sh
zsh scripts/build_ffmpeg.sh                       # 静态 FFmpeg + 外部编码库，可重复执行
cmake -S . -B build -DCMAKE_BUILD_TYPE=Debug
cmake --build build -j 4
cmake -S . -B build/release -DCMAKE_BUILD_TYPE=Release
cmake --build build/release -j 4
```

`build_ffmpeg.sh` 幂等：源码 commit、脚本与架构不变且库齐全时直接跳过；`--force` 强制重编。
需要 universal 产物时用 `TTPLAYER_ARCHS="arm64 x86_64" zsh scripts/build_ffmpeg.sh`。

### 运行与打包

```sh
./build/ttplayer --version          # 输出 Qt 版本与架构
python3 scripts/package.py          # 生成 build/dist/ttplayer.app，不发布
./build/dist/ttplayer.app/Contents/MacOS/ttplayer --version
open ./build/dist/ttplayer.app
```

### 调试

```sh
lldb -- ./build/ttplayer
# (lldb) run
```

打包后的 app 被重签名过，调试器要指向 `Contents/MacOS/ttplayer`；
调试符号在 `build/package/` 的构建树里，不要指向 `dist` 之外的旧产物。

## 4. Linux（Ubuntu 24.04 为基线）

### 准备

```sh
sudo apt-get update
sudo apt-get install -y build-essential nasm yasm pkg-config zlib1g-dev ffmpeg \
    qt6-base-dev qt6-5compat-dev libgl1-mesa-dev libxkbcommon-dev libdbus-1-dev
sudo apt-get install -y python3-venv
python3 -m venv build/aqt-venv
build/aqt-venv/bin/python -m pip install aqtinstall==3.3.0
case "$(uname -m)" in
    x86_64) qt_host=linux; qt_arch=linux_gcc_64; qt_dir=gcc_64 ;;
    aarch64) qt_host=linux_arm64; qt_arch=linux_gcc_arm64; qt_dir=gcc_arm64 ;;
    *) echo "不支持的 Linux 架构" >&2; exit 1 ;;
esac
build/aqt-venv/bin/python -m aqt install-qt "$qt_host" desktop 6.8.3 "$qt_arch" -m qt5compat -O "$HOME/Qt"
export CMAKE_PREFIX_PATH="$HOME/Qt/6.8.3/$qt_dir"
```

系统 Qt 只用来提供 GL / xkb / dbus 等依赖库；实际链接的是官方 6.8.3。arm64 原生构建使用 Ubuntu 24.04+，官方 Qt arm64 包要求 glibc 2.39+，不能放入 Ubuntu 22.04 容器后声称兼容 glibc 2.35。

### 编译

```sh
bash scripts/build_ffmpeg_linux.sh
cmake -S . -B build -DCMAKE_BUILD_TYPE=Debug
cmake --build build -j 4
```

Linux 的单构型要进 PIE 可执行文件，外部编码库由脚本带 `-fPIC` 编好，不要手工改。

### 运行与调试

```sh
./build/ttplayer --version
gdb --args ./build/ttplayer
# (gdb) run
```

无显示环境（容器 / SSH）下加 `QT_QPA_PLATFORM=offscreen`；真实音频输出需要 ALSA/PulseAudio。

## 5. Windows x64（MSVC 2022）

### 准备

1. Visual Studio 2022，勾选「使用 C++ 的桌面开发」与 Windows SDK。
2. MSYS2，在 **MSYS** 环境安装 `make nasm yasm pkgconf`。
3. Qt `6.8.3 msvc2022_64` + `qt5compat`（aqtinstall 或官方安装器）。
4. `ffmpeg` 命令可用（`choco install ffmpeg`），自检夹具生成需要它。
5. 在「x64 Native Tools Command Prompt」或已执行 `vcvars64` 的 shell 里操作，
   保证 MSVC 与 MSYS 工具在同一环境变量下。

```powershell
python -m pip install aqtinstall
python -m aqt install-qt windows desktop 6.8.3 win64_msvc2022_64 -m qt5compat -O "$env:USERPROFILE\Qt"
$env:CMAKE_PREFIX_PATH = "$env:USERPROFILE\Qt\6.8.3\msvc2022_64"
```

### 编译

先编静态 FFmpeg（Release + Debug 两档，MSYS shell 里执行，继承 MSVC 环境）：

```sh
bash scripts/build_ffmpeg_msvc.sh
# 只编一档：TTPLAYER_FFMPEG_CONFIG=Debug bash scripts/build_ffmpeg_msvc.sh
```

再配置多构型工程：

```powershell
cmake -S . -B build -G "Visual Studio 17 2022" -A x64
cmake --build build --config Debug -j 4
cmake --build build --config Release -j 4
```

可执行文件在 `build\Debug\ttplayer.exe` 与 `build\Release\ttplayer.exe`。
Debug 档运行若提示缺 `ucrtbased.dll` / `vcruntime140d.dll`，把
`%VCToolsRedistDir%debug_nonredist\x64\Microsoft.VC143.DebugCRT` 加进 `PATH`（CI 就是这么做的）。

### 运行与调试

```powershell
.\build\Release\ttplayer.exe --version
```

- 用 Visual Studio 打开 `build\TTPlayer.sln`，把 `ttplayer` 设为启动项目，选 Debug/Release 直接 F5。
- 或命令行 `devenv /debugexe build\Debug\ttplayer.exe`。
- 迷你转储与调用栈依赖 `dbghelp`（已在链接行里）；崩溃文本见第 7.3 节。
- 绿色版：Windows 的存档跟 `ttplayer.exe` 同目录（`state.db`），不写 `%APPDATA%`。
- 分发目录由 `cmake --install build --config Release --prefix build/dist` 生成；CMake 从 MSVC
  可再分发目录部署 Release VC DLL 到 `bin/`，与 exe 同目录，用户无需安装 VC Redistributable。
  不改变 `/MD`，不发布 Debug CRT；Windows 10+ 的 UCRT 等系统 DLL 仍由系统提供。
- 部署后运行 `python scripts/package.py --verify-windows build/dist`：隔离存档、清理开发工具搜索
  路径并启动打包版，检查实际加载的 VC DLL 来自 exe 目录。`package.py` 在 Windows 上也会自动做此验证。

## 6. 常用选项

| 选项 | 默认 | 用途 |
| --- | --- | --- |
| `TTPLAYER_VENDORED` | ON | 从 `3rd/` 源码编 zlib/xz/libarchive/bzip2/SDL3；OFF 时退回系统库 |
| `TTPLAYER_CLANG_TIDY` | OFF | 构建时顺带跑 clang-tidy（比编译慢一个量级，日常用 `scripts/lint.py`） |
| `TTPLAYER_BUNDLE` | OFF | 生成 macOS `.app`（`scripts/package.py` 会打开） |
| `FFMPEG_ROOT` | `3rd/ffmpeg-build` | 预编静态 FFmpeg 的根目录 |
| `CODEC_ROOT` | `3rd/codec-build` | 外部编码库根目录 |

## 7. 运行与调试

### 7.1 启动参数与自检开关

```sh
./build/ttplayer --version        # 版本 + Qt + 架构
./build/ttplayer --dump-formats   # 支持的扩展名（排障用）
```

无头自检的环境组合（与 `scripts/selftest.py` 一致）：

```sh
QT_QPA_PLATFORM=offscreen \
SDL_AUDIODRIVER=dummy \
TTPLAYER_SELFTEST=1 \
TTPLAYER_SILENT_OUTPUT=1 \
TTPLAYER_TESTDIR=/tmp/fixtures \
TTPLAYER_QT_STATE=/tmp/isolation/state.json \
TTPLAYER_QT_LYRIC_PROBE=1 \
./build/ttplayer
```

- `TTPLAYER_QT_<SUITE>_PROBE=1` 只点亮一个套件，套件名见 `src/testing/suites.txt`。
- `TTPLAYER_SILENT_OUTPUT=1` 是最终静音门，采样发生在它之前，所以断言仍然成立。
- 验证真实输出链时用 `TTPLAYER_AUDIO_DRIVER=coreaudio`（macOS），并保留静音门。
- `TTPLAYER_QT_STATE` 指到临时目录即隔离存档：`state.db` 与 `crash.log` 都跟着走，
  真实用户档不会被读写。

### 7.2 调试器

- macOS：`lldb -- ./build/ttplayer`；断点可打在 `src/audio/AudioEngine.cpp`、
  `src/playback/PlayerController.cpp`、`src/testing/Regression.cpp`。
- Linux：`gdb --args ./build/ttplayer`。
- Windows：VS 打开 `build\TTPlayer.sln`，或 `devenv /debugexe build\Debug\ttplayer.exe`。
- 线程相关 bug 先看 AGENTS.md 的「分层和生命周期」：开流/扫描在后台，设备回调只消费 PCM 环。

### 7.3 崩溃日志

`CrashHandler` 在启动早期安装，致命错误写到与存档同目录的 `crash.log`：

- macOS：`~/Library/Application Support/TTPlayer/crash.log`
- Linux：`~/.local/share/TTPlayer/crash.log`
- Windows：`ttplayer.exe` 同目录
- 隔离自检：`TTPLAYER_QT_STATE` 所指目录

验证捕获链路可用故意崩溃：

```sh
TTPLAYER_QT_STATE=/tmp/tt-crash/state.json TTPLAYER_QT_CRASH_TEST=segv ./build/ttplayer
cat /tmp/tt-crash/crash.log
```

取值：`segv` / `null`（空指针）、`abort`、`throw`（逃逸异常）。

### 7.4 存档与素材隔离

- 真实存档：Unix 在 `QStandardPaths::AppDataLocation`，Windows 在 exe 同目录；
  落盘文件是 SQLite `state.db`，旧 `state.json` / `resume.json` 首次启动一次性迁移并改名留底。
- 自检必须用 `TTPLAYER_QT_STATE` 隔离，前后逐字节比对用户档（`selftest_guard.py` 负责）。
- 夹具目录由 `TTPLAYER_TESTDIR` 指定；`scripts/selftest_fixtures.py` 会在临时目录现场生成。
  缺 `ffmpeg` CLI 会直接报错，缺 `7z` 会把 7z / 加密 ZIP 记为 FIXTURE SKIP。

## 8. 自检与 CTest

```sh
./scripts/selftest.sh                     # smoke：LYRIC / QUEUE / SPECTRUM
./scripts/selftest.sh affected            # 按改动路径挑档
./scripts/selftest.sh core                # 除计时档外的全部套件
./scripts/selftest.sh all                 # Debug 全量
./scripts/selftest.sh all release         # Release 全量
./scripts/selftest.sh review gapless      # 指定套件
ctest --test-dir build --output-on-failure
```

- 统一实现是 `scripts/selftest.py`，Windows 可直接 `python scripts/selftest.py all`。
- 默认每次增量构建当前源码；`TTPLAYER_BIN` 指定二进制时由调用者保证它是新的。
- `TTPLAYER_PROBE` 指定报告目录，`run.json` 记录源码 / 二进制 SHA-256 与环境。
- 单套件超时 120 秒。超时会保留 stdout 与 stderr（含套件自己打的进度轨迹），
  失败时还会把隔离目录里的 `crash.log` 复制到 `failures/` 下。
- CTest 的每个探针与 `selftest.sh` 同源：`qt.fixtures` 先造素材，其余 `qt.<SUITE>` 各自隔离。
- 真实设备拔插、锁屏、系统媒体按键、桌面合成必须在实机验证，dummy 驱动不算硬件证据。

## 9. 代码检查

工具版本固定 18.1.8（与 CI 的 LLVM 18 对齐），版本不符时 `scripts/lint.py` 直接报错退出。

```sh
brew install llvm@18                # keg-only，不覆盖系统 / 其他 LLVM
export PATH="/opt/homebrew/opt/llvm@18/bin:$PATH"   # 或只给 CLANG_FORMAT / CLANG_TIDY
# 另一种装法：python3 -m pip install clang-format==18.1.8 clang-tidy==18.1.8

python3 scripts/lint.py format            # 改动行格式检查
python3 scripts/lint.py format --fix      # 就地重排
python3 scripts/lint.py tidy              # 需要 build/compile_commands.json
python3 scripts/lint.py all --all --build-dir build   # 整仓（CI 口径）
```

`clang-tidy` 需要先 configure 过工程以生成编译数据库（顶层已开 `CMAKE_EXPORT_COMPILE_COMMANDS`）。
若 `PATH` 上有别的 clang-format，用 `CLANG_FORMAT=/path/to/clang-format-18.1.8` 显式指定。

## 10. 打包

```sh
python3 scripts/package.py
```

- macOS：`build/dist/ttplayer.app`，脚本会重签名；packaging 资源在 `packaging/`。
- Linux / Windows：安装到 `build/dist`，生成对应可执行与桌面文件。
- 发布用的 Linux AppImage 不在这里生成，而是由 `.github/workflows/release.yml` 的双架构矩阵现打：
  x86_64 使用 `ubuntu-24.04` runner + `ubuntu:22.04` 容器（glibc 2.35+），arm64 使用
  `ubuntu-24.04-arm` runner + `ubuntu:24.04` 容器（glibc 2.39+）。linuxdeploy、Qt 插件和
  appimagetool 按 x86_64 / aarch64 下载原生工具，产物命名为 `TTPlayer-<版本>-linux-x86_64.AppImage`
  与 `TTPlayer-<版本>-linux-arm64.AppImage`。Qt 库与插件内置，glibc/GL/X11/DBus 仍由系统提供；
  两档都检查包内 ELF 架构、glibc 符号门槛和 offscreen / xcb 启动，新 arm64 档另跑双构型全量自检。
  本机没有 Linux 环境时，只能靠 workflow_dispatch 试跑验证，不要用 macOS 产物代推结论。
- 打包脚本只生成本地产物，不发布、不打 tag。
- 更新 README 截图前，先按 [截图说明](screenshots/README.md) 隔离存档并核对内容。

## 11. 常见问题

**找不到 Qt6**
`CMAKE_PREFIX_PATH` 没指到 Qt 6.8.x 的安装根。Unix 用冒号分隔多个路径，Windows 用分号；
清掉 `build/CMakeCache.txt` 后重新 configure。

**configure 报 libarchive 没有启用内置 bzip2**
说明 `BZIP2_FOUND` / `BZIP2_LIBRARIES` 没指向 vendored `bz2static`。不要关掉
`ENABLE_BZip2`；检查 `3rd/bzip2` 子模块是否已初始化。

**tar.bz2 打开卡住 / 超时**
旧版曾因 libarchive 退回外部 `bzip2 -d` 程序过滤器而卡死（Windows 管道上不返回）。
现在必须走内置 bz2，configure 阶段会硬拦。若看到卡住，先确认没有 `-DENABLE_BZip2=OFF`
或系统 bz2 覆盖了 vendored target。

**clang-format 报版本不对**
`PATH` 上是 Homebrew 的 23.x。用 `/opt/homebrew/opt/llvm@18/bin` 或
`CLANG_FORMAT` 指向 18.1.8，不要用其他版本检查。

**Windows Debug 起不来**
缺 Debug CRT DLL，把 `debug_nonredist\x64\Microsoft.VC143.DebugCRT` 加进 `PATH`；
Debug/Release 不能混链 C++ 运行时，也不要混 MSVC 与 MinGW 的库。

**CMake 改了缓存变量但构建没变化**
换个构建目录，或删掉 `build/CMakeCache.txt` 重新 configure：子目录已有的生成文件不会自动重写。

**自检报 FIXTURE SKIP**
夹具生成阶段缺少工具。`ffmpeg` 缺失会直接失败；`7z` 缺失只会跳过 7z / 加密 ZIP 两档，
日志里会同时出现 `FIXTURE SKIP` 与对应的 `REVIEW_PROBE ... SKIP`，不会伪装成 PASS。
