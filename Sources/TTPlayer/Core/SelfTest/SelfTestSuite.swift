import Foundation

/// 套件开跑前要备好的东西。runner 统一准备，套件内部不必关心「上一套跑过什么」，
/// 所以任何一套都能单独跑（`TTPLAYER_SUITE=ui` 直接跑 UI 断言）。
enum SuiteNeed: Hashable {
    /// 三块皮肤窗已布局出首帧（窗口几何、按钮 lit、显示区文案都靠它）
    case windows
    /// 列表里装好 testlib 下全部支持的音频（demo01/demo02/cover.*/demo_dsd.dsf…）
    case library
    /// 一份可用的 GBK 存盘 CUE 分轨表（testlib/cuealbum.cue 及解析结果）
    case cueAlbum
}

/// 自检套件：一套一个领域，单跑与全量跑走同一段代码
protocol SelfTestSuite {
    func run(_ ctx: SelfTestContext)
}

/// 套件清单。名字就是 `TTPLAYER_SUITE` 里写的那个词
enum SuiteID: String, CaseIterable {
    case lyric
    case playlist
    case queue
    case spectrum
    case playback
    case cover
    case cue
    case format
    case decoder
    case importFiles = "import"
    case radio
    case archive
    case lists
    case search
    case scene
    case gapless
    case gain
    case device
    case sleep
    case shift
    case ui
    case perf
    case library
    case system

    /// 全量顺序：纯逻辑 → 真实音频链路 → 性能 → 待播队列与界面 → 系统集成。
    /// 性能排在开窗那几套之前是有意的：RSS 是「历史峰值」口径，队列面板与界面套件会
    /// 把 AppKit 的离屏位图、栅格缓存、窗口底板拉满（实测各 +14 MB / +40 MB，且不会归还），
    /// 那是框架内部缓存不是泄漏，如果 perf 排在其后会量到那条峰值（实测 154~156 MB），
    /// 量的不是常驻内存而是「曾经用过多少」。
    /// 门槛口径因此是「默认那几块窗 + 曲库就绪」，用户按需才开的窗不计进去。
    /// 媒体库那一套也排在 .perf 之后：它要扫两千个文件、挂真 FSEvents，会把键表与
    /// 磁盘缓存顶上去一截（RSS 是历史峰值口径），排在前面就等于拿自己踩的峰值量基线
    static let all: [SuiteID] = [.lyric, .playlist, .spectrum, .playback, .cover, .cue,
                                 .format, .decoder, .importFiles, .radio, .archive, .lists,
                                 .perf, .library, .search, .scene, .gapless, .gain, .device,
                                 .sleep, .shift, .queue, .ui, .system]

    /// 冒烟档：不碰音频设备、不开窗、不转码，几秒内跑完（改纯逻辑与绘制时用）
    static let smoke: [SuiteID] = [.lyric, .playlist, .spectrum]

    var title: String {
        switch self {
        case .lyric: return "歌词解析与匹配"
        case .playlist: return "列表模式与删除"
        case .queue: return "待播队列与播放上下文"
        case .spectrum: return "频谱分析与绘制回归"
        case .playback: return "真实播放链路"
        case .cover: return "封面与标签"
        case .cue: return "CUE 分轨"
        case .format: return "格式能力与转码矩阵"
        case .decoder: return "自带解码（DSD / TTA / APE）"
        case .importFiles: return "导入与拒收原因"
        case .radio: return "网络电台"
        case .archive: return "归档容器流式播放"
        case .lists: return "自建歌单与 m3u 往返"
        case .search: return "即时搜索与筛选"
        case .scene: return "退出后恢复播放现场"
        case .gapless: return "无缝播放衔接"
        case .gain: return "响度均衡与峰值防削波"
        case .device: return "输出设备选择与变更跟随"
        case .sleep: return "睡眠定时器与淡出"
        case .shift: return "歌词时间校准"
        case .ui: return "皮肤、面板与交互"
        case .perf: return "性能基线"
        case .library: return "媒体库扫描与重新定位"
        case .system: return "菜单栏与控制中心"
        }
    }

    var needs: Set<SuiteNeed> {
        switch self {
        case .lyric, .playlist, .spectrum:
            return []
        case .queue:
            // 前两段纯逻辑，后四段要真控制器 + 曲库 + 队列面板窗口
            return [.windows, .library]
        case .playback, .cover, .decoder, .importFiles:
            return [.windows, .library]
        case .cue:
            return [.windows, .library, .cueAlbum]
        case .format:
            return [.windows, .library, .cueAlbum]
        case .ui:
            return [.windows, .library, .cueAlbum]
        case .radio:
            // 只看窗口与表格：素材自己造在临时目录里，不出网、不读曲库
            return [.windows]
        case .archive:
            // 归档素材现场 zip/tar 造在临时目录，不依赖曲库；但 play 链路需要窗口就位
            return [.windows]
        case .lists:
            // 歌单要往真实列表里拿曲目（含 CUE 分轨与归档条目的身份写法）
            return [.windows, .library, .cueAlbum]
        case .search:
            // 搜索框、格式键、右键菜单、⌘F 都是面板上的真控件：要窗口与曲库，不要分轨表
            return [.windows, .library]
        case .scene:
            // 现场恢复要真引擎（采实际输出链 PCM）、要曲库、也要自己造 CUE/归档素材
            return [.windows, .library, .cueAlbum]
        case .gapless:
            // 衔接处的 PCM 只能从真实输出链上抄；素材（两半 + 四种格式）自己造在临时目录
            return [.windows, .library, .cueAlbum]
        case .gain:
            // 幅度比值只能从真实输出链上抄，电台那段要起本地 ICY 服务器；
            // 素材（同一条正弦换标签）自己造在临时目录，不读曲库
            return [.windows]
        case .device:
            // 设备是全局状态、素材（三档采样率）现造在临时目录；要窗口是因为「当前实际输出」
            // 那一行与子菜单的勾也得直接断言
            return [.windows]
        case .sleep:
            // 淡出只能从真实输出链上量（fadeNode 取流）；菜单勾选项与状态行后缀要窗口
            return [.windows, .library]
        case .shift:
            // 查行只能拿真实播放位置验（seek + 引擎报的那一秒）；菜单项、歌词秀校准行与
            // 主显示区那两行都得直接断言，所以要窗口。素材（wav + .lrc + 分轨表）全自己在临时目录造
            return [.windows, .library]
        case .perf, .system:
            return [.windows, .library]
        case .library:
            // 素材自己造在临时目录，但要真窗口（左栏、右键菜单、菜单子项都得直接断言），
            // 也要 [默认] 列表已就绪——「扫描不动播放列表」那条得有东西才谈得上不动
            return [.windows, .library]
        }
    }

    func makeSuite() -> SelfTestSuite {
        switch self {
        case .lyric: return LyricSuite()
        case .playlist: return PlaylistSuite()
        case .queue: return QueueSuite()
        case .spectrum: return SpectrumSuite()
        case .playback: return PlaybackSuite()
        case .cover: return CoverSuite()
        case .cue: return CueSuite()
        case .format: return FormatSuite()
        case .decoder: return DecoderSuite()
        case .importFiles: return ImportSuite()
        case .radio: return RadioSuite()
        case .archive: return ArchiveSuite()
        case .lists: return UserListSuite()
        case .search: return SearchSuite()
        case .scene: return SceneSuite()
        case .gapless: return GaplessSuite()
        case .gain: return ReplayGainSuite()
        case .device: return DeviceSuite()
        case .sleep: return SleepSuite()
        case .shift: return ShiftSuite()
        case .ui: return UISuite()
        case .perf: return PerfSuite()
        case .library: return LibrarySuite()
        case .system: return SystemSuite()
        }
    }
}
