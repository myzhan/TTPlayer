# Qt 复刻全面复审：第二轮

> **用户后续已明确批准既有深色 Qt 样式，并要求本轮不修改任何样式。B27 中恢复蓝灰外观的建议已作废；Swift 只作为功能与测试基线。**
>
> 本文保留为修复前的审查快照。修复实现、验证结果和未关闭的验收边界见 [docs/review-fixes.md](docs/review-fixes.md)，测试对应关系见 [docs/qt-selftest-mapping.md](docs/qt-selftest-mapping.md)。不要把下文旧复现结果当作当前版本结果。

日期：2026-11-20。参考基线：`c66a60a` 的 Swift 行为，源码现位于 `legacy/Sources/TTPlayer/`；被审对象为当前未提交的 Qt working tree。第一轮记录保存在 [docs/review-2026-11-19.md](docs/review-2026-11-19.md)。

**结论：重写补齐了不少结构和界面，但仍不满足 1:1 功能与稳定性交付。现有自检全绿，仍能复现拖拽重排崩溃和 seek 接受旧位置 PCM。应先修这些正确性问题，再补无缝、电台、媒体库和系统整合。**

本次只更新审查文档并新增复现材料，没有修改产品实现，没有 commit/tag。下文分别标注“实测”“白盒实测”“源码确认”和“风险待实测”，不把潜在风险写成已发生的事故。

## 一、验证结果与边界

| 检查 | 结果 |
| --- | --- |
| 本机全新 CMake Debug 构建 | `/tmp/tt-review2-clean-debug`，configure/build 成功，无编译 warning/error |
| 本机全新 CMake Release 构建 | `/tmp/tt-review2-clean-release`，configure/build 成功，无编译 warning/error |
| 现有脚本 Debug 全量 | **221 PASS / 0 FAIL / 0 SKIP**，18 探针，日志 `/tmp/tt-review2-debug/selftest.log` |
| 现有脚本 Release 全量 | **221 PASS / 0 FAIL / 0 SKIP**，18 探针，日志 `/tmp/tt-review2-release/selftest.log` |
| 全新 Debug / Release 的 CTest | 各 **17/17 通过**；CTest 漏登记 PIN，见 B25 |
| 拖拽处理入口重复复现 | 首轮 30 个独立进程：6 次 SIGBUS、23 次错误首项 C、1 次仍是 A；运行器复核另 30 轮：3 次 SIGBUS、26 次 C、1 次 A。正确首项应为 B |
| seek 在途 PCM | 使用可控阻塞 StreamSource + 真实 FFmpeg 解码：**30/30 接受 seek 前的 PCM** |
| EOF 代际白盒检查 | EOF 通知排队后 stop，再处理事件，**30/30 仍触发旧 onFinished** |
| CUE 段尾 seek 白盒检查 | **30/30 落到 `eos=false && readPos>=endFrame` 的不可推进状态** |
| 其他复现 | 归档 M3U 往返丢 file URL scheme；Windows 盘符 token 被解析为 scheme `c`；恢复队列无 RG 标签 |
| 视觉 | 查看主窗、列表、EQ、设置四张新截图，并参考仓库 Swift 截图；未验证真实桌面玻璃合成 |
| Swift 回归入口 | `swift package --package-path legacy describe` 失败：`invalid custom path 'Sources/CLibarchive'` |

复现源码：[round2-probe.cpp](docs/review-evidence/round2-probe.cpp)，运行器：[run-round2.py](docs/review-evidence/run-round2.py)。从仓库根运行：

```sh
python3 docs/review-evidence/run-round2.py build
```

运行器适用于本机已有 Unix Makefiles 构建；用 `-fno-access-control` 链接真实产品对象，白盒控制线程/EOF 边界，不改产品文件。`reorder` 经过真实 `selectAt → reorderCurrentView`；seek 使用真实 Decoder，仅对字节源加可控闸门。EOF/CUE 边界检查不是硬件端到端播放取证。大回调缓冲检查为合成边界，见 B06。

**隔离说明：**测试、截图使用隔离存档；两次分档脚本各自的用户档前后守卫均通过。但整个审查期间用户档 SHA-256 从 `738950433ce429a1d8a68da4c176ed8238a88996aceece47ab5e4e85a0ac37aa` 变为 `e1a825b97667ddf4e3fe812698b5eebdc5b7cab46d85a1547958e1f585288346`，且发现旧 `./build-qt/ttplayer-qt` 仍在运行，`MainWindow.cpp` 也有期间更新。本轮不能声称用户档整体不变，亦不能把变化归因于某个进程；没有回滚该存档。行号对应读取时快照，接手时以函数名定位并重跑复现。

未完成：Windows/Linux 实机、真实输出设备、物理设备 PCM、长时间内存/CPU、TSan、所有格式矩阵、联网真实电台。全新 Qt 构建复用已有 FFmpeg 静态库，不等于依赖也从零重建。

## 二、必须优先处理的正确性问题

### B01 · P0 · 列表拖拽使用不同容器的 begin/end，已复现崩溃

位置：`src/ui/PlaylistWindow.cpp:338`，`reorderCurrentView`：

```cpp
QSet<int>(m_view->selectedRows().cbegin(), m_view->selectedRows().cend())
```

**实测。**两次 `selectedRows()` 产生两个临时 QList，迭代器不属于同一容器，构造 QSet 越界读取。A/B/C 只选 A，拖到最后应得到 B/C/A；首轮 30 次独立进程无一次得到正确首项，6 次退出码 `-10`（SIGBUS），其余得到 C 或 A。保存运行器后另跑 30 轮，3 次 SIGBUS，其余仍全部错误。现有 MULTI 探针主要验证选区和纯移动算法，没兜住真正的窗口提交入口。

修复：先把 `selectedRows()` 保存为局部变量，再由同一容器构造集合。验收必须经过拖拽提交入口，单选、离散多选、Shift 区间、页切换、排序态各重复至少 30 次；增加 ASan/UBSan 检查，不能只改模型测试。

### B02 · P1 · seek 不作废同一个 Decoder 的在途解码结果

位置：`src/audio/AudioEngine.cpp:92` 的 `pumpLoop`，以及 `seekSeconds`。

**白盒实测 30/30。**producer 解码前快照 `dec/from` 并解锁；UI seek 清环、设置新位置；旧 read 返回后只检查 Decoder 指针是否相同，仍把旧位置样本 push，并对新 `m_readPos` 加旧 got。位置显示已经跳转，但先听到旧样本，且新目标开头的一段可能被跳过。现有 `m_gen` 没有被这条提交路径用于校验。

修复：seek 也推进读取代际；提交 PCM/EOF 前同时验证 decoder、generation 与本次 read 对应的位置。用本轮 GateSource 闸门复现做回归，检查输出样本和连续帧号，不只测 `position()`。

### B03 · P1 · EOF 排队通知在停止或换曲后仍能推进队列

位置：`AudioEngine.cpp:352`，`callback → invokeMethod`；`PlayerController::onTrackFinished`。

**白盒实测 30/30。**闭包只验证 weak_ptr 存活，没有捕获/核对装载 generation。旧 EOF 已排队时用户 stop/换曲，闭包仍触发控制器推进，可能重新开声或跳过新曲。仅在 play/stop 中递增 `m_gen` 并不能防护。

修复：通知带 generation/段身份，并在交付时校验当前用户播放意图；seek 也需要作废旧通知。验收：EOF 排队后 stop、seek、双击另一曲、替换上下文，旧通知均不得生效。

### B04 · P1 · CUE seek 到末尾后永远静音等待，不自然推进

位置：`AudioEngine::seekSeconds`、`pumpLoop` 的 wait predicate。

**白盒实测 30/30。**seek 无上限夹取且总置 `m_eos=false`；目标到 `m_endFrame` 或更后时 producer 条件 `readPos < endFrame` 永远不成立，回调又依赖 `m_eos` 才发 EOF。拖到进度条最右即可进入该状态；本轮验证的是状态/谓词，没有把它冒充实际设备长播测试。

修复：合法化段内位置，到尾立即建立一致的 EOF 状态并走同一推进策略。覆盖 CUE 中间段、末段、恰好 duration、超过 duration、暂停态 seek、恢复档位置越界。

### B05 · P1 · 冷启动恢复队列丢元数据与 ReplayGain

位置：`src/ui/MainWindow.cpp`，`restoreLibrary` 的两轮 `resolveToken`。

**实测。**主表恢复后经过 `probeRestoredTrack`，但 resumeQueue 另造新 Track，不复用已解析的注册表，也不探测。得到 `catalog_RG_loaded=1 resume_RG_loaded=0`；恢复后的当前曲标题/技术参数可退成文件名/空值，RG 决策没有标签，后续待播同样受影响。

修复：恢复所有引用经过统一 registry/resolver，必要时探测；同一 identity 的播放对象和浏览对象应共享元数据。用真实 RG 素材恢复，比较恢复前后的 title/artist、增益决定和 PCM RMS。

### B06 · P2 · 大音频回调遇欠载时没有清完整个输出缓冲

位置：`AudioEngine::callback` 的 `have < slice` 分支后 `break`。

**白盒条件实测 30/30。**输入请求 8192 帧、暂存片长 4096，环空时只清第一片便退出，后半片保留哨兵值。当前常见设备请求为 2048，本轮没有证实实际设备请求了 8192；这是函数声称支持任意分片请求时的边界错误。

修复：先清全部输出缓冲，或欠载时清剩余所有帧。检查 0/部分/完整环数据和多个请求长度；不得输出未初始化/旧缓冲数据。

## 三、音频和电台：结构已改，行为仍未完成

### B07 · P1 · 无缝仍然在 EOF 后由主线程切换

位置：`AudioEngine::callback`、`PlayerController::onTrackFinished` / `schedulePrefetch`。

**源码确认。**只预开下一曲 Decoder；当前环空后填静音，主线程收到 EOF 才换曲并清环，再等 producer 填入新样本。输出边界没有续接下一段 PCM。设置文案“切歌不留空白”与实现不符，第一轮 R07 尚未关闭。

任务：按段在输出侧连续消费，切段与 RG/CUE/位置元数据一致提交；UI 通知可以晚到。迁移 Swift `GaplessSuite` 的真实衔接帧检测，包含相邻 CUE、MP3/AAC padding、单曲循环、队列改变和不同 RG 的相邻曲。

### B08 · P1 · 电台 ICY、重连、质量状态机仍缺失

位置：`src/audio/RadioStream.cpp`、`PlayerController::onRadioOpened` / `onTrackFinished`。

**源码确认。**仍发送 `Icy-MetaData: 0`；没有 ICY 拆包、正在播放曲名、连接/缓冲/退避状态、2/4/8/8 自动重连、手动重试和质量统计。失败/断线进入普通 EOF 推进，而非直播重连。

**测试映射有误：**`RADIO` 实际是预置台种入/黑名单探针，不是 `docs/qt-selftest-mapping.md` 所说的掉线/重连/世代号 harness。不能把它作为本项已验收证据。

验收：对照 legacy `RadioStream.swift`、`RadioQuality.swift`、`RadioSuite.swift`，从产品入口跑真实本地 HTTP 剧本，验证重试延迟、晚回调、停止语义、台名与 ICY 显示。

### B09 · P1 · 电台异步装载期间旧曲仍在播，暂停又保留旧直播

位置：`loadAndPlay` 的 radio 分支、`startRadioAsync`、`togglePlay`。

**源码确认。**发起新台开流时没有先停/淡出旧引擎。队列已切新台，声音和位置却可继续来自旧曲；新台无响应会长期保持不一致。暂停电台仅暂停 SDL/producer，网络继续拉到背压，恢复后消费旧缓存；Swift 原版是暂停断流、恢复重连听当下。

任务：独立维护 wantedPlay/连接态/当前发声段，新台装载与旧声退场有明确边界；直播暂停应取消会话并在恢复时重连。用两个不同音高源验证界面身份与 PCM 一致，包含无响应台。

### B10 · P1 · detached 开流线程缺少控制器销毁协议

位置：`PlayerController.cpp:218`，`startRadioAsync`；类无显式 destructor 取消/收束 job。

**风险待实测。**线程捕获裸 `this`，之后从后台调用 `invokeMethod(this, ...)`。Qt 丢弃已排队事件不保证向一个已销毁 QObject 指针投递本身安全；控制器销毁、QApplication/网络栈退出与 detach 线程没有同步边界。正常退出也只 `engine->stop(); SDL_Quit()`，未统一取消控制器在途开流。

任务：有 owner 的 worker/job、销毁先取消并收束，再释放目标对象；不要用“进程同生命周期”注释代替协议。慢首包/无响应下关程序、销毁 controller、连续换台至少 30 次，配 ASan 和超时抓栈。

### B11 · P1 · EQ 的原有缺口仍在：竞争、前置、音量不同步

位置：`AudioEngine::eq()`、`src/audio/EQ.*`、`EqWindow`。

**源码确认。**UI 经裸引用写 EQ 系数和 enabled，回调同时读，没有锁/参数快照；这是 C++ 数据竞争。独立 EQ 前置增益依旧不存在（RG 前置不是替代品）。EQ 音量固定初值且直接写 engine，绕过主窗 `m_vol/m_muted`，可绕过静音并在保存时恢复旧音量。`play()` 启动输出后才设置新曲 RG，首缓冲增益交接也尚未原子化。

任务：统一音量/静音状态入口，DSP 用安全快照交接，曲目增益与段样本同时生效。验收 TSan/参数压力 + 真实 PCM，不只看 UI 读数。

### B12 · P1 · 输出设备仍按显示名处理，无热插拔闭环

位置：`AudioEngine::outputDevices` / `openDevice` / `setOutputDevice`。

**源码确认。**SDL 显示名仍被注释成 CoreAudio UID；缺少默认设备变化、拔插、实际设备反馈。指定设备失败回退默认后，偏好名仍显示旧值。固定解码率/float stereo 打开，失败没有能力协商或重采样策略。换设备失败也没有完整同步播放状态。

验收设备名重复、固定设备拔掉/回来、默认输出改变、不同采样率、无设备；区分偏好/实际/降级原因，迁移 legacy `DeviceSuite`。

### B13 · P1 · 播放与睡眠边界仍与原版不等价

位置：`togglePlay`、`stop`、`sleepTick`、`applySleepFade`。

**源码确认。**无当前游标时播放键既不启动已排队首项，也不启动浏览列表第一项；原版两个分支均存在。`AfterTrack` 计划在手动 stop 时没有立即取消；其最后十秒淡出也未实现，只有 Countdown 分支开始淡出。顺序播完仅 pause，保留 EOF decoder，需验证再次按播放能否按原版重播。

任务：逐项迁移 `PlaybackSuite` / `SleepSuite`；空上下文、仅入队未播放、停止后重播、AfterTrack 停止/手动换曲/到尾、取消淡出恢复增益均经过产品入口。

### B14 · P1 · pause 仍在持引擎锁时调用 SDL 暂停

位置：`AudioEngine::pause`。

**风险待实测。**后台 IO 已移出回调，这是实质改进；但 pause 持 `m_mutex` 调 SDL，而回调也要同锁。代码其他设备操作已专门避开这类锁顺序，pause 未统一。本轮未复现死锁，不能将其算作已修好或已发生事故。

任务：按目标 SDL 后端实际调用栈确认等待关系；统一 pause/close 的无锁设备控制协议，播放态反复 pause/resume/切设备并抓超时栈。

## 四、身份、持久化和媒体库仍有数据风险

### B15 · P1 · 归档歌单往返仍会破坏身份

位置：`PlaylistM3U::toIdentityKey` / `resolveFilePart`、`Collections::resolveToken`。

**实测。**`file:///.../album.zip#archive-entry=disc%2Fa.flac` 导出再导入后变成 `/.../album.zip#archive-entry=disc%2Fa.flac`。Archive resolver 期待 file URL；此时条目解码入口/identityKey 与原对象不一致。现有 IDENTITY 没覆盖这条 M3U 产品链。

修复：按 token 类型解析，归档保持规范 URL，普通文件和 CUE 保持各自规范键；不能统一截 `#` 后再拼字符串。覆盖空格、中文、`#`、`%`、同包多条目以及歌单/收藏/重启链。

### B16 · P1 · Windows 普通路径不能可靠恢复

位置：`Collections::resolveToken`、M3U/CUE 的 `resolveFilePart/resolveFile`。

**本机解析实测。**`C:/Music/song.flac` 被作为 QUrl，得到 `scheme=c`、`isLocalFile=false`；播放层随后 `toLocalFile()` 为空。其余路径函数只按 `/` 开头识别绝对路径，对盘符、UNC 未完整处理。

任务：先区分本地绝对路径/UNC 与协议 URL，使用平台路径 API；在 Windows 原生路径、file URL、相对 M3U、CUE、跨进程重启全链验证。macOS 上构造 token 只能证明当前解析缺陷，不代替 Windows 实机测试。

### B17 · P1 · 媒体库与默认列表仍共用所有权，离线扫描会删注册对象

位置：`Collections::m_all/m_libraryKeys`、`MainWindow::rescanLibrary` / `restoreLibrary`。

**源码确认。**媒体库是 m_all 的扫描子集；默认页却直接返回整个 m_all，所以扫描内容自动混进默认列表。在默认页删除扫描曲又从 registry 移除，媒体库页随之消失。重扫删除 stale 键时不区分“扫描贡献 + 用户手工添加”双重归属；目录暂时离线也被当删文件。重启靠当前扫描反推贡献，未保留可靠离线快照。

任务：registry 与页面成员、扫描根贡献分别存储，离线与确认删除分开；同一曲可以同时属于默认和媒体库。验收默认加 A 后再扫描含 A 的目录，移除/离线目录不删除用户默认 A，反向删默认也不影响媒体库。

### B18 · P1 · 导入/扫描仍未共用完整 importer，且同步阻塞 UI

位置：`loadDirOrFiles`、`LibraryStore::scanFolders`、`rescanLibrary`、`schedulePrefetch`。

**源码确认。**手动目录仍只扫一层；扫描目录只按 playableExtensions 收音频，没有 CUE/M3U/归档统一展开。M3U 读普通 CUE/归档行也没有完整展开；EXTINF 标题仍被跳过，GBK CUE 靠 ASCII TRACK 判断解码成功会留下乱码。对不可播/坏文件多为静默跳过。

watcher 已新增，但回调触发同步全库扫描和逐曲开 Decoder，开流/元数据/预取本地与归档也在 UI 执行，缺进度、取消和增量发布。大库冻结属于待 bench 风险，本轮未报出未经实测的耗时数字。

任务：统一递归 importer、后台扫描和取消代际，保留拒收原因；用 legacy `ImportSuite/LibrarySuite/CueSuite` 覆盖手动打开、目录、拖入、歌单、归档以及非 UTF-8。

### B19 · P1 · 现场只有正常退出快照；空默认列表会跳过独立队列恢复

位置：`MainWindow::saveState` / `restoreLibrary`、`PlayerController` 的 tick/pause/stop。

**源码确认。**resume 被塞进整份 state，未见原版每 5 秒的小现场档及 pause/stop 即时落盘；崩溃/强退会恢复陈旧现场。`restoreLibrary` 在 urls/tracks 为空时提前 return，即使 resumeQueue 或独立歌单仍有可播项也不恢复。`restoreResume` 先 play 再 seek/pause，默认不开声的恢复并没有输出层保证不响。

任务：独立且节流的现场持久化；正常退出、暂停/停止、强退明确策略；恢复与默认列表是否为空解耦；未确认 autoPlay 前不能开放设备输出。queue source/position 等输入要 sanitize。

### B20 · P1 · Swift 数据迁移只透传未知键，没有功能迁移

位置：`LibraryStore::Loaded/load/save`、`Collections::loadFrom`。

**源码确认。**没有读取 Swift 独立 `resume.json`；`libraryKeys`、`trackEdits`、EQ 前置/预设、部分窗口状态等未消费。透传 JSON 不能使用户编辑/现场在 Qt 生效。恢复 resumeQueue 的 source 直接 static_cast，缺合法值校验；缺失 CUE 的 fallback 把 sheet 当普通文件，身份不再是原 #track token。

任务：明确版本化迁移，保留原始备份/稳定身份；缺字段用保守默认，缺文件标失效，不伪装成另一首曲。Swift state + resume fixture 做跨版本迁移验收。

### B21 · P2 · QSaveFile 已修复替换路径，但错误没有反馈到产品

位置：`LibraryStore::save`、`MainWindow::saveState` / 布局迁移。

**源码确认。**原先 remove→rename 窗口已改为 QSaveFile，应认可；但上层忽略 bool，磁盘/权限失败用户仍以为保存成功。坏 JSON 备份用 rename 且不检查结果，写入失败边界还需补测。布局版本不符时清空临时 panelFrames 后，又把旧 `s.panelFrames` 赋给成员，旧面板几何仍可能被套回。

任务：统一保存错误上报和重试/保留旧档策略；布局迁移的实际消费值与写回值一致。现有 SAVE 通过仅证明它断言的路径。

## 五、仍需补齐的用户工作流与资源约束

### B22 · P1 · 搜索/排序/选区尚未恢复原版语义

位置：`PlaylistWindow::applySearch/clearSearch/removeRows/sortView`、`PlaylistView::reload`。

**源码确认。**格式筛选和来源页展示仍缺；Esc 仍只有注释，无对应按键处理；退出搜索没有恢复原选区/滚动。选区按行号夹取而非身份恢复，切页/排序后可能指向别的曲。搜索中删除仍按原 viewId 操作跨页命中；媒体库页搜索还会统一拒绝删除。排序只改展示、不持久化，仅升序，搜索态也允许排序，与 Swift 定义不同。索引失效后 UI 命中列表是否即时更新也未完整连接。

任务：对照 `SearchSuite` 建逐入口回归，先保存 sceneBeforeSearch；定义搜索态删除目标及来源，排序与持久化策略按原版，不拿暂时显示正确当验收。

### B23 · P2 · 管理与编辑只补了部分入口

位置：`PlaylistView::contextMenuEvent`、`PlaylistWindow::buildListMenu`、主窗 properties 接线、`Collections::updateRadioAddress`。

**源码确认。**电台分类与别名已存在；改地址/重试等完整流程仍缺，`updateRadioAddress` 只迁别名和归属，不重写实际 Track、收藏、歌单、历史、现场。属性仍取当前播放曲而非选中行；轨目编辑、文件管理器显示、失效重定位、列表清空和相关权限/反馈不完整。固定页重命名/删除检查只排除了默认和收藏，新增其他固定页仍会进入不适用的歌单对话流程。

验收：用户能选中“非当前曲”查看/编辑；改台地址后所有引用同键迁移、旧预置台不复种；按 legacy Playlist/UserList/Library/Radio suite 逐项打勾。

### B24 · P2 · 资源和系统整合的旧问题仍在

| 项目 | 当前证据与要求 |
| --- | --- |
| 封面缓存 | `CoverArt.cpp` 仍全局强持有未降采样原图，无界；每次查询先重开文件取 bytes，再找缓存。恢复 112px/256px 与 8MB LRU 或实测等价策略，附大库内存/IO bench |
| 隐藏性能 | `SpectrumView` 仍只 show/hide 停 timer，没有遮挡/熄屏判断，也未联动关闭 analyzer；24fps 已保留，应单测遮挡/熄屏 CPU |
| 系统媒体 | 无 Now Playing / Windows 媒体会话 / Linux MPRIS 实现；托盘不等价于系统媒体控制 |
| 快捷键 | 仍只有主窗 Ctrl+Space 与若干组合；原版空格、左右曲、F1～F4、歌词校准/目录打开等未完整接，子窗焦点下也要测 |
| 窗口恢复 | 整组隐藏/恢复已补；但 `m_listVisible` 仍只读写，不随开合更新/启动应用，EQ 等可见性也未完整恢复。无托盘平台仍需验证隐藏后可恢复 |
| 歌词 | 整盘 CUE 偏移、模糊匹配和 GB18030 已补；同一归一化键撞车时索引保留任意一份，后续“唯一命中”无法看到原歧义，需补两份近似词的拒配测试 |
| 元数据 | 普通文件标签和真实码率已接；Decoder 仍只快照容器 tags，channelCount 恒为 2（输出声道），输入技术参数/流级标签不完整，不能当原始源属性 |

### B25 · P1 · 自检已建骨架，但映射、线程用法和构建刷新仍有问题

位置：`src/testing/RadioHarness.cpp`、`src/main.cpp`、`scripts/selftest.sh`、CMake、映射文档。

- RADIO 是种台测试，文档却说重连；R01 “已移植”主要指投影模型，不能代替真实切页。MULTI 没有覆盖 B01 的窗口入口。
- RADIOLIVE 的 `runBounded` 在 std::thread 调控制器，跨线程修改 QObject/QTimer 和队列，再在主线程 processEvents，偏离产品实际线程模型；测试还直接 `engine->stop()`，不是完整的 `controller.stop()`。压力轮默认 0，默认只跑 stall，不覆盖全部剧本。
- 脚本只有二进制不存在才 build，源码变更后直接 `selftest.sh` 可测旧二进制。必须显式 build 或做可靠的增量更新。
- 脚本登记 18 个探针（含 PIN），CTest 只有 17 个；文档仍写 17/202，与本次 18/221 不符。
- 缺真实衔接、RG RMS、设备切换、scene PCM、perf 和完整格式矩阵；shell 全绿不构成发布达标。
- 自检 runner 仅 zsh、守卫仅 macOS 路径，独立 CTest 不带整体用户档守卫；Windows/Linux 应有等价入口。日志显示状态 `ok` 只按 FAIL 行决定，非零 exit 但无 FAIL 行时会误导（最终 RC 虽会失败）。

任务：让动作在正确线程执行，外部进程 watchdog 负责超时；真入口/真实状态断言；注册表单一来源；每次测试记录二进制/源码指纹和环境，避免对旧构建下结论。

### B26 · P1 · 三平台交付与 legacy 回归仍未闭环

**源码确认与本机实测。**CMake 仍只 add_executable，无 install/CPack/Qt plugin 部署；macOS 最低版本仍默认 15，原版是 12；Windows FFmpeg 脚本 MINGW64 与 UCRT 依赖提示仍不一致。没有活动的 `.github/workflows/release.yml`，它被搬到 legacy，不再触发 GitHub Actions。

legacy `Package.swift` 指向不存在的 `Sources/CLibarchive`，FFmpeg 路径变为不存在的 `legacy/3rd/...`；`legacy/build_app.sh` 也仍相对调用已搬走的 FFmpeg 脚本。本次 `swift package describe` 已失败，因此不能继续承诺 Swift 双构型回归可跑。README/AGENTS 仍主要描述旧入口，与新目录不符。

任务：保留一个实际可构建的 Swift 参考基线，或提供固定历史 checkout 的可重复回归方法；Qt 三平台 clean build/打包/启动/音频/文件关联/持久化 CI；明确支持版本与依赖部署，不以平台 if 分支证明可运行。

### B27 · P2 · 当前视觉是重新设计，尚无 1:1 验收证据

新截图可见：子窗已统一自绘，标题徽章/置顶/LR 电平/顺序图标等已补，这些不应继续列为完全缺失。但当前深灰橙色主题、尺寸、字体、控件形态与仓库浅蓝 Swift 截图明显不同；`GlassStyle` 还把原来的 body/well/button 派生规则改成统一 glassAlpha。

如果另有用户批准重新设计，应记录该设计基线；在本轮可见的 1:1 要求下，不能仅以“用了同名控件”判视觉完成。四张截图位于 `/tmp/tt-review2-SHOT*.png`；offscreen 无法证明壁纸透出、模糊和置顶平台效果。运行中还出现字体别名和 `Unknown property caret-color` 警告；编译 0 warning 不等于运行日志干净。

任务：同素材/状态/尺寸/DPI 逐窗对照（含空、播放、搜索、电台、失败）；真实桌面验证玻璃和窗口交互；平台字体按 metrics 定宽，不固定中文字符数。

## 六、第一轮 R01～R27 的关闭状态

“已修主因”仅指本轮确认的那一部分，不表示整套功能已验收。

| 第一轮 ID | 本轮判断 | 本轮关联 |
| --- | --- | --- |
| R01 切页参数 | 已修主因，改用 SkinListView 当前行并同步程序化选择 | B25 仍需真 UI 回归 |
| R02 存搜索命中缩库 | 已改为存主表；所有权模型仍不完整 | B17 |
| R03 现场恢复 | 已有队列/来源/游标存档，未达到 PCM/元数据/强退语义 | B05/B19/B20 |
| R04 CUE/归档 | CUE resolver 与 token 保存已补，归档 M3U 仍坏 | B15/B16/B20 |
| R05 标签 | 普通标签/码率已接，恢复队列和流级属性仍缺 | B05/B24 |
| R06 原子存档 | QSaveFile 已修替换主因；产品错误反馈不足 | B21 |
| R07 无缝 | 未完成 | B07 |
| R08 IO 解耦 | producer/有界环/异步台开流已补，新增 seek/EOF 竞态 | B02/B03/B10/B14 |
| R09 电台状态机 | 未完成 | B08/B09 |
| R10 输出设备 | 未完成 | B12 |
| R11 EQ | 主要缺口仍在 | B11 |
| R12 媒体库 | watcher 已补，统一扫描/离线/取消仍缺 | B17/B18 |
| R13 历史/电台管理 | 固定页/历史/分类/别名已补，编辑/改地址等未齐 | B20/B23 |
| R14 搜索 | 仍部分 | B22 |
| R15 列表/导入 | 多选/重排/主窗 M3U 入口已补，但重排崩溃 | B01/B18/B23 |
| R16 歌词 | CUE 时间轴与编码已有实质补充，歧义匹配待补 | B24 |
| R17 主窗控件 | 图标/徽章/置顶/LR/顺序图标已补 | B27 视觉仍需验收 |
| R18 玻璃 | 子窗自绘/透明背景已有；派生规则改变，真实桌面未验 | B27 |
| R19 显隐 | 整组显隐与 × 退出主因已修；平台 fallback 未验 | B24 |
| R20 几何 | clamp/版本/面板几何已补，可见性和迁移消费仍有洞 | B21/B24 |
| R21 快捷键 | 仍未齐 | B24 |
| R22 字体 | 已去 Apple 专用字体，仍有警告和定宽 | B27 |
| R23 系统整合 | 未完成 | B24 |
| R24 封面缓存 | 未完成 | B24 |
| R25 遮挡/熄屏 | 未完成 | B24 |
| R26 平台交付 | 未完成，且原版回归/活动发布 workflow 被移走 | B26 |
| R27 自检 | 脚本/CTest/映射已有，覆盖与可信度不足 | B25 |

## 七、接手顺序与验收约束

1. 修 B01 崩溃、B02 seek、B03 EOF、B04 段尾、B05 恢复元数据；用附带复现先证明红，再修绿。B06 顺手补输出全初始化边界。
2. 修音频会话所有权/销毁/参数交接，再完成真正无缝、电台重连、设备与睡眠语义。所有异步结果绑定代际和用户意图。
3. 分离 registry、默认页、扫描贡献、派生页；统一 importer/resolver/迁移与现场协议，随后补用户操作入口。
4. 修正测试模型和映射，真实 PCM/失败路径/正确 UI 线程是门槛；旧探针保留但不冒充未测功能。
5. 确定视觉验收基线，完成三平台交付和可运行的参考回归。审查期工作区仍在变化，交付前需在固定源码快照重新构建并完整复验。

每项回报 B 编号、根因、变更、修复前后证据、平台/构型与未覆盖项。不要只给“已重写”“编译通过”或 PASS 数量；本轮已经证明这些指标能同时为绿，而真实入口仍然崩溃。
