# AGENTS.md — TTPlayer 开发约定

当前产品位于 `src/`，使用 C++20 / Qt 6 Widgets / FFmpeg / libarchive；Windows/Linux 输出使用 SDL2，macOS 按 UID 打开 HAL AudioUnit。
修改行为时，应对照 `src/testing` 自检，不能仅以编译成功作为验收。

**用户确认的视觉基线是当前 Qt 深色样式。本轮禁止修改配色、字体、布局、透明度规则和控件外观。**

## 必须遵守

- Debug、Release 都必须 0 error / 0 warning。CMake 已开启 GCC/Clang 的 Wall/Wextra/Wpedantic 和 MSVC 的 W4。
- 全量自检（双构型 `selftest.sh all`）必须 0 FAIL，但它只在提交后 CI 与发布前跑；本地改动只跑 `affected` 或点名 suite，相关档必须 0 FAIL。报告实际 PASS / SKIP 数与环境。不得用增加重复断言的数量冒充覆盖对齐。
- 自检、截图、打包探针必须隔离用户存档（`TTPLAYER_QT_STATE` 指到临时目录，`state.db` 随同目录隔离），真实用户档前后逐字节一致；不得用旧快照覆盖用户期间的修改。
- 没有明确指示，不 commit、不 push、不打 tag、不发布 Release。
- 音频素材只现场生成到测试目录；不把大音频、构建缓存、打包产物入仓。
- 中文沟通，实测优先；竞态至少重复 30 次，性能改动附测量口径和数据。
- 本文只写开发约定，不写过程记录；修复证据看 git 历史。

## 构建

首次运行先初始化 FFmpeg 子模块（冻结在 n9.0，见下）：

```sh
git submodule update --init --depth 1 3rd/ffmpeg
```

macOS 使用 Qt 6.8.x（含 Core5Compat）、SDL2、nasm/yasm 和 FFmpeg CLI。
部署目标固定 macOS 12.0，所有链接依赖也必须支持 12.0；不能用较新的 Homebrew bottle
再提高最低系统版本来消除链接告警。CI 演示了官方 Qt 与现编 SDL 的设置。
`CMAKE_PREFIX_PATH` 可以传入这些依赖的安装目录。

FFmpeg 源码冻结为 **9.0**（子模块 pin 在 tag `n9.0`）：`scripts/ffmpeg_components.sh` 里的
`FFMPEG_RELEASE` 是唯一版本声明，四个 `build_ffmpeg*.sh` 都会校验 `3rd/ffmpeg/RELEASE`，
不符直接失败。升级要一起改：`git -C 3rd/ffmpeg checkout nX.Y`、改 `FFMPEG_RELEASE`、
重编静态库、同步本文。CI 会打印源码版本与系统 `ffmpeg` CLI 版本；CLI 只用来生成自检素材，
不进入发布物，发布物只链 9.0 的静态库。
语言标准统一 C++20（`.cpp` 与 `.mm` 同档、关 GNU 扩展），只在 CMakeLists.txt 的
`CMAKE_CXX_*` / `CMAKE_OBJCXX_*` 两组变量定义，其他地方不写 `-std=`；升级语言档次只改这两组。

```sh
zsh scripts/build_ffmpeg.sh
cmake -S . -B build -DCMAKE_BUILD_TYPE=Debug
cmake --build build -j 4
cmake -S . -B build/release -DCMAKE_BUILD_TYPE=Release
cmake --build build/release -j 4
```

Linux 依赖 Qt6 Widgets/Network/Core5Compat/Concurrent/DBus、SDL2、libarchive、zlib、FFmpeg CLI，
运行 `bash scripts/build_ffmpeg_linux.sh`。Windows 使用 MSVC 2022、Qt msvc2022_64、
vcpkg x64-windows 的 SDL2/libarchive/zlib；初始化 MSVC developer 环境后，
在继承该环境的 MSYS shell 中运行 `scripts/build_ffmpeg_msvc.sh`，再由 CMake 构建。
不要混链 MSVC 与 MinGW 的 C++ 库。具体的依赖版本、生成器和安装步骤见 [CI 配置](.github/workflows/ci.yml)。
MSVC 的 FFmpeg 脚本默认同时构建 Release（/MD）与 Debug（/MDd），Debug 静态库放在
`3rd/ffmpeg-build/debug/`；CMake 按构型选库。Debug 自检还需把 vcpkg 的 `debug/bin`
加入 DLL 搜索路径，不能只提供 Release 的 `bin`。

### 运行当前 Qt 版

macOS 和 Linux 的普通单构型构建生成 `build/ttplayer` 和 `build/release/ttplayer`。Windows 使用 Visual Studio 多构型生成器时，可执行文件位于构建目录的 `Debug` 或 `Release` 子目录。可先运行 `--version` 确认输出包含 Qt 版本和架构。macOS 打包与启动使用：

```sh
python3 scripts/package.py
build/dist/ttplayer.app/Contents/MacOS/ttplayer --version
open build/dist/ttplayer.app
```

打包目录是 `build/dist/`（构建产物统一在 `build/` 下：Debug 用 `build/`、Release 用 `build/release/`、
打包用 `build/package/` 与 `build/dist/`）。更新 README 配图前，请按[界面截图说明](docs/screenshots/README.md)隔离存档、准备示例曲库并核对截图内容。

## 代码检查

规则在 `.clang-format` 与 `.clang-tidy`，工具固定 18.1.8（与 CI 的 LLVM 18 对齐）：

```sh
pip install clang-format==18.1.8 clang-tidy==18.1.8
python3 scripts/lint.py all --all      # 整仓：src/ 全部文件 + 全部编译单元（与 CI 同口径）
python3 scripts/lint.py all            # 只查改动行/改动文件，提交前快速自查
python3 scripts/lint.py format --fix --all   # 一次性整仓重排（改规则后跑）
```

- 门槛：`src/` 整仓 0 告警。格式与静态检查都已还清历史债，CI 跑全仓，新增任何不合规行直接挂。
- 检查范围只含 `src/`：`docs/` 是证据快照，`3rd/` 是第三方，不参与。
- 新增/关闭一条检查时，把理由写进 `.clang-tidy` 注释，不留“不知道为什么关”的项。
- tidy 依赖 `build/compile_commands.json`（CMake 默认已开）；CI 用 `--build-dir build-ci`。
- 构建时顺带跑：`-DTTPLAYER_CLANG_TIDY=ON`（默认关，比编译慢一个量级）。

## 验证入口

```sh
./scripts/selftest.sh                     # smoke: lyric / queue / spectrum
./scripts/selftest.sh affected            # 本地首选：按改动文件挑档
./scripts/selftest.sh UI SYSTEM           # 影响面明确时直接点名 suite
./scripts/selftest.sh review gapless gain
./scripts/selftest.sh all                 # 只在 CI / 发布前跑，本地不跑
./scripts/selftest.sh all release         # 发布前双构型
ctest --test-dir build --output-on-failure   # 跑全部注册 suite，同样归 CI / 发布
python3 scripts/package.py               # 只生成本地 build/dist，不发布
```

### 本地只跑精准档

本地验证要精准，不为求稳反复跑全量：

- 改完先 `./scripts/selftest.sh affected`；已知影响面时直接点名 suite（如改电平/频谱就 `./scripts/selftest.sh UI`，改持久化就 `SYSTEM SAVE`）。
- 挑档存疑时用 `TTPLAYER_DRYRUN=1` 看清单，或用 `TTPLAYER_AFFECTED_FILES` 直接传路径复核；不要用全量兜底。
- 跨层改动（持久化格式、输出链、线程生命周期）要把相关 suite 一并点名，仍不跑 `all`。
- 全量只留两处：提交后 CI（`.github/workflows/ci.yml` 的 Full selftest，Linux/Windows 双构型）与发布前的双构型全量 + 打包版冒烟；改输出链额外跑打包版全量与 ASan/UBSan。
- 本地验收报告写实际跑过的档与 PASS / SKIP，不拿全量 PASS 数当本地交付证据。

统一实现是 `scripts/selftest.py`，可在 Windows 直接用 Python 调用。
默认每次增量构建当前源码；指定 `TTPLAYER_BIN` 时由调用者保证该二进制已更新。
`TTPLAYER_PROBE` 指定报告目录，其中 `run.json` 保存源码、二进制 SHA-256 和环境。
`TTPLAYER_DRYRUN=1` 只列挑档结果；`TTPLAYER_AFFECTED_FILES` 可直接传待分类的路径。
套件注册表只有 `src/testing/suites.txt` 一处，脚本与 CTest 都读取它。

自检默认 offscreen + SDL dummy。物理输出验证可用 `TTPLAYER_AUDIO_DRIVER=coreaudio`
（macOS），仍必须保留 `TTPLAYER_SILENT_OUTPUT=1`；采样发生在最终静音门之前。
真实设备拔插、锁屏、系统媒体按键和桌面合成应另做实机检查，不把 dummy 当硬件证据。
发布门槛：双构型全量、打包版冒烟；改输出链额外跑打包版全量与 ASan/UBSan。这一档在发布前执行，不在日常改动里执行。
发布产物由 `.github/workflows/release.yml` 生成：推 `v*` tag 会构建 Linux x86_64 tar.gz、Windows x64 zip、macOS arm64 dmg 并发布 Release；手动 workflow_dispatch 只产出 artifacts。Linux job 会校验 tag 与 `CPACK_PACKAGE_VERSION` 一致，macOS 包为 adhoc 签名、未公证。

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
- 存档是 SQLite（`state.db`）：设置/列表/现场分表存，写操作走事务；`saveResume` 每 5 秒及暂停/停止只写现场表，不重写整库。
- 存档位置：macOS/Linux 在 AppDataLocation；Windows 是绿色版，库与 `ttplayer.exe` 同目录（不写 `%APPDATA%`），整个文件夹可拷贝/删除。Windows 首启会把 `%APPDATA%/TTPlayer` 的旧 `state.db`（含 `-wal`/`-shm`）或旧 JSON 复制过来，不删源文件。
- Windows 单实例锁按 exe 目录区分（同一目录只跑一个，两个拷贝各跑各的），不按 AppData。
- Windows 发布目录必须可写（不要放 `Program Files` 等只读位置）；不可写时 `save` 返回失败并提示，不静默丢。
- 旧 JSON 首次启动自动迁移一次并改名 `.migrated-<时间戳>` 留底；未知顶层键进 `v1_meta` 的 `legacy_unknown`。
- 表名带世代前缀（`v1_settings`、`v1_list_items` 等），前缀必须与 `PRAGMA user_version` 一致。改 schema 三步：全文件把 `v1_` 换成新世代 → 在 `kMigrations` 尾部追一条搬数据的迁移（CREATE 新表 / INSERT SELECT / DROP 旧表）→ `kSchemaVersion` 加一，cpp 里 `static_assert` 会对上数组长度。
- 迁移在一个事务里做，失败回滚并保留原库等下次重试，不自动删档；迁移失败按无存档处理并提示保存失败。更高版本的库只读，不回写。
- 表名版本化之前建的库（裸表名 + user_version=1）首次打开时就地 `ALTER TABLE RENAME` 到 `v1_`，数据不动、版本不递增。
- 每字段宽容读、旧库保守兜底；新增字段必须成对读写（存与取都要改）。
- 保存失败必须反馈；坏档（JSON 或 SQLite）备份失败不得覆盖原文件。
- 搜索先保存选区/滚动现场，退出按身份恢复；搜索删除摘掉可写页引用，媒体库保留。
- 改窗口尺寸/面板划分必须递增 MainWindow 中 kSkinLayoutVersion。
- × 直接退出；— 隐藏整组继续播放。无托盘平台保留最小化恢复入口。
- 频谱保持 24 fps，隐藏/不可曝光时停绘制及 analyzer；64 柱采用合并路径绘制。
- 保持既有深色 GlassStyle：主窗/播放列表/均衡器/歌词四个主面板的壳、槽、按钮共用同一 alpha；设置/属性/待播队列/专辑封面等辅助窗不跟随透明度、始终保持不透明（重叠时文字才读得清）；不得改动这套统一透明度。
- 封面最多解码到 256 px，显示小档 112 px，缓存预算 8 MiB；热路径不重新开音频取图片字节。
- README 面向用户，构建、自检、目录结构只写本文与 docs。
