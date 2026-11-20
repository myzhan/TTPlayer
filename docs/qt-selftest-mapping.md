# Qt 自检与 Swift 参考覆盖映射

参考实现：`legacy/Sources/TTPlayer/Core/SelfTest/`。Swift 注册表实际是 **24 个 suite**，
不要沿用旧文档的“26 个”。Qt 保留旧探针并增加专项套件，单一注册表为
`src/testing/suites.txt`。断言数量不表示覆盖等价；下面列出执行入口、证据层次与仍需实机验证的边界。

**视觉约束：用户已确认既有深色样式，本轮禁止修改样式。Swift 仅作为功能与测试参考。UI 额外冻结了修改前 Qt 的 52 个配色常量、字体和原有透明度规则。**

## 运行与隔离

- `./scripts/selftest.sh all` / `all release`：自动构建当前源码；指定 TTPLAYER_BIN 才跳过构建。
- `core` 排除 GAPLESS / GAIN / RADIO / RADIOLIVE / WATCH；`smoke` 只跑 LYRIC / QUEUE / SPECTRUM。
- Windows：`python scripts/selftest.py all`，入口与 shell 包装器相同。
- `ctest --test-dir <build> --output-on-failure`：同注册表，每项有外部进程超时。
- runner 生成临时素材、独立 state/resume；结束对真实 macOS/Linux/Windows 用户档做 SHA-256 守卫。
- `run.json` 保存二进制与源码指纹、平台、套件及用户档基线；`selftest.log` 保存逐项结果。
- 失败退出码、没有任何断言、超时均判失败；环境缺失单独报 SKIP。
- 所有 Qt 控制器动作在主线程执行。取消、无响应的 watchdog 放进程外，不跨线程调用 QObject。
- SDL dummy 验证 FFmpeg→producer→PCM 环→真实 SDL callback；采样在最终静音门之前。
  这不等于物理设备输出、硬件热插拔或桌面合成取证。

## 24 个参考 suite 的对应关系

| Swift suite | Qt 入口 | 已落地的主要行为 | 证据与边界 |
| --- | --- | --- | --- |
| lyric | LYRIC、SEARCH、SHIFT | 多标签/offset/GB18030、整盘 CUE 轴、模糊唯一匹配与撞名拒配 | 文件与模型；匹配缓存增删仍需更多专项压力 |
| playlist | PLAYLIST、MULTI、GROUPS、REVIEW | 模式、列表成员、真实窗口重排、多选、当前项保护 | 重排真实提交入口 30 次；并非只测纯移动算法 |
| queue | QUEUE、RESUME | Next/Later 来源、模式推进、稳定 peek、手动下一首、删除/清空/非法重排 | 240 个不同模式/游标/来源组合聚合验收，保留原 16 条 |
| spectrum | SPECTRUM、UI | 880 Hz FFT 能量、disabled、24 fps、隐藏停 timer/analyzer | 实际分析器；桌面遮挡/熄屏需实机 |
| playback | PLAYBACK、REVIEW、GAPLESS | 无上下文播放、待播首项、暂停/恢复/停止/重播、seek/EOF 代际 | FFmpeg 与真实回调；GateSource 的 seek 边界重复 30 次 |
| cover | COVER | 外图、原始尺寸、112/256 缩放、清缓存、48 专辑淘汰与 8 MiB 预算 | 真实图片解码和缓存成本；没有把原图尺寸当常驻尺寸 |
| cue | CUE、IDENTITY、IMPORT、SCENE | 75 fps、INDEX、全局艺术家/专辑、分轨身份、缺 sheet 保留身份、镜像抑制 | 文件解析/恢复；播放走同一 Decoder |
| format | FORMAT | MP3/AAC/FLAC/ALAC/Vorbis/Opus、PCM/ADPCM、WMA/TTA/WavPack、DSF/DFF、可选真实 APE | 独立 FFmpeg CLI 编码及 Python DSD fixture；真实解码帧数 |
| decoder | DECODER、FORMAT、REVIEW | 采样率/声道、精确重复 seek、帧数、取消、坏文件拒收 | 真实 FFmpeg；DSD/TTA/APE 在 FORMAT，不能说 DECODER 单套全包 |
| import | IMPORT、SL、IDENTITY、WATCH | 递归、去重、CUE/归档/M3U 统一入口、EXTINF、拒收原因 | 临时文件；扫描与手动导入均在后台 |
| radio | RADIO、RADIOCAT、RADIOLIVE、REVIEW、SYSTEM | 种台/黑名单、分类、ICY 拆包、异步取消、2/4/8/8、重试上限/手动重试、403 终止、质量窗口、PCM 起播与补缓冲、短流收尾 | 本地 HTTP 真实剧本；RADIO 本身只是种台，不能冒充重连 |
| archive | ARCHIVE、IDENTITY、LISTS | zip/tar/gz/bz2/可选 7z、加密拒绝、seek PCM、中文/空格/特殊字符 URL、M3U 往返 | 流式 libarchive，不落地解压；RAR/RAR5 未现场生成 |
| lists | LISTS、SL、GROUPS、SEARCH | 歌单名字、重复/重排/独立引用、M3U、删除/收藏分流 | 持久化与真实面板删除路径 |
| search | SEARCH、UI、SL | 跨页/格式/来源、退出选区、排序持久化、搜索删除、保留媒体库 | 真窗口入口；排序与匹配均按身份 |
| scene | SCENE、RESUME、SAVE、SYSTEM | 队列来源/历史/游标、暂停恢复、自动续播、独立 resume、Swift fixture、编辑信息 | SCENE 读取真实 SDL 回调，验证恢复位置对应的 PCM 幅度 |
| gapless | GAPLESS、QUEUE | 输出侧直接交接、CUE 段范围、各段 RG、队列条目身份 | 30 次回调边界、实际设备回调短段，以及六种压缩格式跨格式逐帧衔接；整专辑 padding 矩阵仍需扩充 |
| gain | GAIN、SETTINGS、SCENE | Off/Track/Album、前置/峰值、非法标签、电台 unity、恢复标签 | 真实回调 RMS 对基线/同条件重测/Track -6 dB/峰值限制；不是只验公式 |
| device | DEVICE、SETTINGS | 偏好/实际/回退原因、暂停态、默认/指定设备、mac UID、设备轮询、重采样交接 | dummy 与 CoreAudio 均已测；同名设备双 UID、临时设备移除/重建已实测；物理 USB 拔插/零设备仍未等价验收 |
| sleep | SLEEP、SETTINGS | 倒计时/AfterTrack/取消/手停、最后 10 秒淡出、连续单调时钟、7 天上限 | 时钟注入可测；不主动让用户机器睡眠 |
| shift | SHIFT、LYRIC、SETTINGS | 步进、±30 秒、归零、歌词轴、原文件不改、设置持久化 | 实际 controller 装载与原文件字节 |
| ui | UI、DOCK、WIDTH、PIN、GROUPVIS、MULTI | 无边框/尺寸/图标、面板、EQ/音量、跨窗 F 键与输入保护、拖入、显隐、既有深色样式基线 | offscreen 绘制与事件；真实玻璃、置顶/桌面焦点另验 |
| perf | PERF、COVER | 10000 曲搜索正确性/耗时、mac 常驻 RSS、封面 8 MiB 预算 | 记录实际值；未将旧 Swift CPU 数字套用到 Qt |
| library | LIBRARY、WATCH、IMPORT、SYSTEM | 双重归属、离线保留、后台扫描取消、目录变动、根重定位、引用/队列迁移、旧库快照 | 临时目录与真 watcher；网络卷/海量目录仍需独立 bench |
| system | SYSTEM、GROUPVIS、UI | 原子存档、Swift resume/编辑迁移、托盘显隐、快捷键 | mac Now Playing / Windows SMTC / Linux MPRIS 有实现，系统面板需逐平台实机 |

## 新增回归的取证方法

REVIEW 的 seek 测试使用可控 GateSource：旧位置 read 挂起，UI seek，然后释放 read；
检查实际新环 PCM，重复 30 次。EOF 排队后 stop 检查旧通知不再交付。
GAPLESS 直接检查跨段回调没有中间零窗，再走公开 controller 与 SDL 回调验证。
GAIN 先测 Off 基准 RMS，重测基准证明复用成立，再比较实际 Track/峰值限制输出。
SCENE 恢复 ramp 第 1 秒并真实开声采样，区别于从头恢复；最终物理输出仍静音。

REVIEW 在 48 kHz 下直接向输出环送入已知 PCM，验证起播前保留首秒、实际短读后进入补缓冲、恢复出声和不足两秒的 EOF 尾段。RADIOLIVE 另起本地 HTTP 服务测试网络行为。UI 连续 30 帧比较实际发生变化的像素与重绘区域，频谱衰减结束后验证无需再重绘。

## 验证结果与平台边界

这些入口已补齐，但尚不能把“所有 Swift 1411 个断言逐一等价移植”写成结论。
Windows/Linux 原生运行、设备热插拔/系统休眠、系统媒体面板、桌面透明合成，以及
压缩格式的整专辑衔接矩阵仍须后续平台与专项取证。
2026-11-20 的 macOS arm64 电台与绘制修复后，Debug、Release、ASan+UBSan 和打包 app 全量各为 **862 PASS / 0 FAIL / 0 SKIP**。此前审查修复阶段的 CTest 在 Debug、Release 各通过 **41/41**。启动恢复另覆盖异步让出事件循环、恢复期间不存半库和过期代际拒交付。
完整结果及 ASan 首轮异常记录见 [review-fixes.md](review-fixes.md)；原审查保留在 [review.md](../review.md)。
