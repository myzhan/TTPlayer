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
    case spectrum
    case playback
    case cover
    case cue
    case format
    case decoder
    case importFiles = "import"
    case radio
    case archive
    case ui
    case perf
    case system

    /// 全量顺序：纯逻辑 → 真实音频链路 → 性能 → 界面 → 系统集成。
    /// 性能排在界面之前是有意的：RSS 是「历史峰值」口径，界面套件会把 AppKit 的离屏位图、
    /// 栅格缓存、窗口底板拉满（实测 +40 MB，且不会归还），那是框架内部缓存不是泄漏，
    /// 如果 perf 排在其后会量到那条峰值（实测 154~156 MB），量的不是常驻内存而是「曾经用过多少」。
    static let all: [SuiteID] = [.lyric, .playlist, .spectrum, .playback, .cover, .cue, .format,
                                 .decoder, .importFiles, .radio, .archive, .perf, .ui, .system]

    /// 冒烟档：不碰音频设备、不开窗、不转码，几秒内跑完（改纯逻辑与绘制时用）
    static let smoke: [SuiteID] = [.lyric, .playlist, .spectrum]

    var title: String {
        switch self {
        case .lyric: return "歌词解析与匹配"
        case .playlist: return "列表模式与删除"
        case .spectrum: return "频谱分析与绘制回归"
        case .playback: return "真实播放链路"
        case .cover: return "封面与标签"
        case .cue: return "CUE 分轨"
        case .format: return "格式能力与转码矩阵"
        case .decoder: return "自带解码（DSD / TTA / APE）"
        case .importFiles: return "导入与拒收原因"
        case .radio: return "网络电台"
        case .archive: return "归档容器流式播放"
        case .ui: return "皮肤、面板与交互"
        case .perf: return "性能基线"
        case .system: return "菜单栏与控制中心"
        }
    }

    var needs: Set<SuiteNeed> {
        switch self {
        case .lyric, .playlist, .spectrum:
            return []
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
        case .perf, .system:
            return [.windows, .library]
        }
    }

    func makeSuite() -> SelfTestSuite {
        switch self {
        case .lyric: return LyricSuite()
        case .playlist: return PlaylistSuite()
        case .spectrum: return SpectrumSuite()
        case .playback: return PlaybackSuite()
        case .cover: return CoverSuite()
        case .cue: return CueSuite()
        case .format: return FormatSuite()
        case .decoder: return DecoderSuite()
        case .importFiles: return ImportSuite()
        case .radio: return RadioSuite()
        case .archive: return ArchiveSuite()
        case .ui: return UISuite()
        case .perf: return PerfSuite()
        case .system: return SystemSuite()
        }
    }
}
