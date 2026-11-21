# 开发环境与调试指南

面向要改 `src/` 或在三个平台复现问题的开发者。产品使用说明见 [README](../README.md)，
开发约定（门禁、分层、数据规则）见 [AGENTS.md](../AGENTS.md)，本文只讲环境准备、编译与调试。

## 1. 代码与依赖布局

- 产品代码在 `src/`，构建入口是仓库根的 `CMakeLists.txt`，语言标准由顶层固定为 C++20。
- 第三方依赖以 git submodule 冻结在 `3rd/`，默认从源码静态编译，不依赖系统包：
  `ffmpeg`、`zlib`、`xz`(liblzma)、`libarchive`、`bzip2`、`sdl3`、`ogg`、`vorbis`、`opus`、`lame`。
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
python3 -m pip install aqtinstall
python3 -m aqt install-qt linux desktop 6.8.3 linux_gcc_64 -m qt5compat -O "$HOME/Qt"
export CMAKE_PREFIX_PATH="$HOME/Qt/6.8.3/gcc_64"
```

系统 Qt 只用来提供 GL / xkb / dbus 等依赖库；实际链接的是 6.8.3。

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
- 发布用的 Linux AppImage 不在这里生成，而是由 `.github/workflows/release.yml` 在 ubuntu:22.04 容器里用
  linuxdeploy + linuxdeploy-plugin-qt 现打（Qt 库与插件一起打包，glibc/GL/X11/DBus 仍由系统提供）。
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
