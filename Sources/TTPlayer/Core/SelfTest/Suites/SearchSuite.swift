import Foundation
import AppKit

/// 即时搜索与筛选（requirements F05：关键字搜的是**整个播放器**，入口是一颗透明放大镜）。
///
/// 分段口径：文本与格式的判定是纯逻辑；跨页命中的次序、去重与来源标注在 `GlobalSearch`
/// 上单独测（它不认识存档与界面）；放大镜的开合、命中数与空状态走真实皮肤窗；格式档仍是
/// 页内条件（行号换算与现场还原归视图）；搜索态不能把命中表落进存档。
/// 大列表的输入与结果计时在性能基线那套（`PerfSuite`），本套只管行为对不对。
struct SearchSuite: SelfTestSuite {
    /// 本套独享的标记：挂在谁身上、该搜到谁就完全由这套自己排，
    /// 别的套件留在收藏/历史/媒体库里的东西都插不进来
    private let mark = "ZZ搜索记号ZZ"

    func run(_ ctx: SelfTestContext) {
        checkMatching(ctx)
        checkFormatOptions(ctx)
        checkIndex(ctx)
        checkMagnifier(ctx)
        checkThroughUI(ctx)
        checkCrossPage(ctx)
        checkSearchShortcut(ctx)
        checkSceneRestore(ctx)
        checkLateMetadata(ctx)
        checkPersistence(ctx)
        cleanup(ctx)
    }

    /// 造一条只写了名字的曲目（模拟元数据：不碰磁盘，标题/艺人/专辑直接给定）
    private func track(_ path: String, title: String = "", artist: String = "",
                       album: String = "") -> Track {
        let t = Track(url: URL(fileURLWithPath: path))
        t.title = title
        t.artist = artist
        t.album = album
        return t
    }

    /// 就地改标题当关键字用（不写盘）。顺手把艺人填上：搜索的「补读标签」只补
    /// 艺人还空着的那些条目，读回来的标签会把这里改的标题冲掉，测试就成了看运气
    private func name(_ t: Track, _ title: String, _ undo: inout [(Track, String, String)]) {
        undo.append((t, t.title, t.artist))
        t.title = title
        t.artist = "本套独占艺人"
    }

    private func restore(_ undo: [(Track, String, String)]) {
        for (t, title, artist) in undo { t.title = title; t.artist = artist }
    }

    /// 手算一遍文本命中（与实现的口径一致，但这里要的是「哪些行本该出现」这个已知答案）
    private func expectText(_ tracks: [Track], _ kw: String) -> [Int] {
        tracks.enumerated().compactMap { i, t in
            (t.title.contains(kw) || t.artist.contains(kw)
                || t.album.contains(kw) || t.fileName.contains(kw)) ? i : nil
        }
    }

    // MARK: - 判定：文本

    private func checkMatching(_ ctx: SelfTestContext) {
        let hit = TrackFilter(keyword: "READ").matcher()
        ctx.check("搜索-关键字非空才算条件", !hit.isEmpty)
        ctx.check("搜索-英文大小写不敏感（关键字大写）", hit.hit("Chapter Reading"))
        ctx.check("搜索-英文大小写不敏感（关键字小写）",
                  TrackFilter(keyword: "read").matcher().hit("READ ME"))
        ctx.check("搜索-子串命中且在中间", TrackFilter(keyword: "ead").matcher().hit("HeadLine"))
        ctx.check("搜索-不含关键字就是否", !hit.hit("千千静听"))

        // 中文与非 ASCII：字节折叠那条路走不通，必须落到大小写兜底
        let cn = TrackFilter(keyword: "静听").matcher()
        ctx.check("搜索-中文关键字命中", cn.hit("千千静听"))
        ctx.check("搜索-中文关键字不误命中", !cn.hit("千百度"))
        ctx.check("搜索-中英混排且拉丁部分大小写不同也能命中",
                  TrackFilter(keyword: "tt静").matcher().hit("混排TT静听"))
        ctx.check("搜索-中文串里不会误命中英文针",
                  !TrackFilter(keyword: "a千").matcher().hit("千a"))

        // 四个字段：标题/艺术家/专辑/文件名任一命中（专辑是 F05 新加的）
        let t = track("/m/demo01.wav", title: "第一", artist: "张三", album: "测试专辑")
        ctx.check("搜索-专辑命中", TrackFilter(keyword: "试专").matches(t))
        ctx.check("搜索-艺术家命中", TrackFilter(keyword: "张三").matches(t))
        ctx.check("搜索-标题命中", TrackFilter(keyword: "第一").matches(t))
        ctx.check("搜索-文件名命中（标签里没有也算）", TrackFilter(keyword: "demo01").matches(t))
        ctx.check("搜索-四字段都不含就不命中", !TrackFilter(keyword: "不存在").matches(t))

        ctx.check("搜索-空关键字是无条件", !TrackFilter.none.isActive)
        ctx.check("搜索-只敲空格与全角空格也算无条件",
                  !TrackFilter(keyword: "  \u{3000} ").isActive,
                  "keywordText='\(TrackFilter(keyword: "  \u{3000} ").keywordText)'")

        // 一次算出的映射：给的是原列表下标，且保持原有次序
        let list = [track("/a/1.wav", title: "zz"), track("/a/2.flac", title: "AB"),
                    track("/a/3.flac", title: "ab"), track("/a/4.wav", title: "cd")]
        ctx.check("搜索-映射给的是原列表行且保序",
                  TrackFilter(keyword: "AB").visibleRows(in: list) == [1, 2],
                  "rows=\(TrackFilter(keyword: "AB").visibleRows(in: list))")
        ctx.check("搜索-无条件时不建表（走恒等映射）",
                  TrackFilter.none.visibleRows(in: list).isEmpty)
    }

    // MARK: - 判定：格式档与组合

    private func checkFormatOptions(_ ctx: SelfTestContext) {
        let enc = "内层/歌.mp3".addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        let inZip = URL(string: "file:///tmp/album.zip#archive-entry=\(enc)")!
        let radio = Track(radio: URL(string: "http://fm.example.com/live.mp3")!)

        ctx.check("筛选-档名取实际后缀并大写", track("/a/x.flac").filterFormat == "FLAC")
        ctx.check("筛选-后缀大小写混写归同一档", track("/a/x.M4A").filterFormat == "M4A")
        ctx.check("筛选-归档条目按条目自己的后缀", Track(url: inZip).filterFormat == "MP3",
                  "url=\(inZip.absoluteString)")
        ctx.check("筛选-电台自成一档", radio.filterFormat == Track.radioFilterFormat,
                  "fmt=\(radio.filterFormat)")
        ctx.check("筛选-没有后缀算其他", track("/a/noext").filterFormat == "其他")

        let list = [track("/a/1.flac", title: "demo 一"), track("/a/2.wav", title: "demo 二"),
                    track("/a/3.flac", title: "别的"), radio]
        ctx.check("筛选-只勾格式",
                  TrackFilter(formats: ["FLAC"]).visibleRows(in: list) == [0, 2])
        ctx.check("筛选-格式与关键字组合取交集",
                  TrackFilter(keyword: "demo", formats: ["FLAC"]).visibleRows(in: list) == [0])
        ctx.check("筛选-组合到空集就是没结果",
                  TrackFilter(keyword: "别的", formats: ["WAV"]).visibleRows(in: list).isEmpty)
        ctx.check("筛选-多档并集",
                  TrackFilter(formats: ["FLAC", "电台"]).visibleRows(in: list) == [0, 2, 3])
        let opts = TrackFilter.formatOptions(in: list)
        ctx.check("筛选-菜单只列出现过的档（去重不列手里没有的）",
                  Set(opts) == ["FLAC", "WAV", "电台"] && opts.count == 3, "opts=\(opts)")
        ctx.check("筛选-摘要写清条件",
                  TrackFilter(keyword: "demo", formats: ["WAV", "FLAC"]).summary
                    == "「demo」 + FLAC/WAV",
                  "summary=\(TrackFilter(keyword: "demo", formats: ["WAV", "FLAC"]).summary)")
    }

    // MARK: - 全局索引：页序、去重、来源、截断（纯逻辑，不碰界面与存档）

    private func checkIndex(_ ctx: SelfTestContext) {
        let a = track("/m/a.wav", title: "甲 demo")
        let b = track("/m/b.flac", title: "乙 demo")
        let c = track("/m/c.mp3", title: "丙 live")
        let (ka, kb) = (a.identityKey, b.identityKey)
        // 用的是局部实例：`GlobalSearch.shared` 是控制器那份索引，自检不该拿它练手
        let gs = GlobalSearch()
        gs.build([(name: "收藏", tracks: [b, c]), (name: "深夜", tracks: [c, a]),
                  (name: "[默认]", tracks: [a, b, c])])
        let all = gs.matches(TrackFilter(keyword: "demo"))
        ctx.check("搜索-索引按页序去重（同首先出现的那页排前面）",
                  all.hits.map(\.track.identityKey) == [kb, ka],
                  "keys=\(all.hits.map { $0.track.fileName })")
        ctx.check("搜索-一条命中记住它所在的每一页",
                  gs.pages(of: ka) == ["深夜", "[默认]"] && gs.pages(of: kb) == ["收藏", "[默认]"],
                  "a=\(gs.pages(of: ka)) b=\(gs.pages(of: kb))")
        ctx.check("搜索-不复制曲目：命中用的还是原来那个对象",
                  all.hits.contains { $0.track === b } && all.hits.contains { $0.track === a })
        ctx.check("搜索-没命中的那条不进来",
                  !all.hits.contains { $0.track.identityKey == c.identityKey })

        // 上限截断：列得出来的与真命中的是两个数，标题行要能说清还差几条
        let big = GlobalSearch()
        big.build([(name: "[默认]",
                    tracks: (0..<50).map { track("/m/\($0).wav", title: "刷屏 demo") })])
        let cut = big.matches(TrackFilter(keyword: "demo"), limit: 8)
        ctx.check("搜索-命中到上限就截但总数如实报",
                  cut.hits.count == 8 && cut.total == 50, "hits=\(cut.hits.count) total=\(cut.total)")

        // 格式档按「不限格式的全部命中」统计：否则勾了一档就再也换不到别的档
        let fmt = gs.matches(TrackFilter(keyword: "demo", formats: ["FLAC"]))
        ctx.check("搜索-格式档菜单看的是全部命中里的档",
                  fmt.hits.count == 1 && fmt.formats == ["FLAC", "WAV"], "formats=\(fmt.formats)")
        ctx.check("搜索-空关键字不把全部列出来（由调用处退出搜索）",
                  gs.matches(TrackFilter(keyword: "  ")).hits.isEmpty
                    && gs.matches(TrackFilter.none).total == 0)
        ctx.check("搜索-索引建过就不脏，invalidate 之后要重建",
                  !gs.isStale && gs.indexedCount == 3)
        gs.invalidate()
        ctx.check("搜索-invalidate 之后读到的是没建过", gs.isStale && gs.indexedCount == 0)
    }

    // MARK: - 放大镜：一颗透明的键，点开成输入框，再点收回

    private func checkMagnifier(_ ctx: SelfTestContext) {
        let p = ctx.player
        let panel = ctx.main.playlistPanel
        let view = panel.playlistView
        _ = ctx.resetLibrary()
        ctx.main.setListVisible(true)
        p.stop()
        p.switchGroup(.main)
        panel.collapseSearch()
        ctx.pump(0.1)
        // 平时：标题行只有这颗键，搜索框一个字的地方都不占
        ctx.check("搜索-平时只有一颗放大镜不占地方",
                  !panel.isSearchExpanded && panel.magnifierOnlyRow,
                  "搜索框宽=\(Int(panel.expandedSearchWidth))")
        // 键要挨在「歌曲列表」右边，而且展开前后不许挪窝：往右长的是输入框，不是整排控件
        let edgeShut = panel.magnifierLeftEdge
        ctx.check("搜索-放大镜紧贴标题右边", panel.magnifierHugsCaption && edgeShut > 0,
                  "x=\(Int(edgeShut)) caption=\(panel.listCaptionText)")
        guard let first = p.playlist.tracks.first else {
            ctx.check("搜索-放大镜前置（列表非空）", false); return
        }
        var undo: [(Track, String, String)] = []
        name(first, "放大镜\(mark)", &undo)
        panel.clickSearchToggle()
        ctx.pump(0.1)
        ctx.check("搜索-点一下放大镜展开输入框",
                  panel.isSearchExpanded && panel.searchControlsVisible
                    && panel.expandedSearchWidth > 40,
                  "w=\(Int(panel.expandedSearchWidth))")
        ctx.check("搜索-展开时放大镜不跟着动",
                  abs(panel.magnifierLeftEdge - edgeShut) < 0.5 && panel.magnifierHugsCaption,
                  "收起 x=\(Int(edgeShut)) 展开 x=\(Int(panel.magnifierLeftEdge))")
        panel.applySearchText(mark)
        let inSearch = ctx.waitUntil(2.0) { p.isSearching && view.totalCount == 1 }
        ctx.check("搜索-展开后敲字就进搜索态",
                  inSearch && p.activeGroup == .search
                    && view.visibleKeys == [first.identityKey],
                  "kw='\(panel.searchText)' n=\(view.totalCount)")
        ctx.check("搜索-临时页不摆进左栏也不跨进程",
                  !panel.groupTitles.contains(GroupKind.search.name)
                    && GroupKind.search.archiveValue == GroupKind.main.archiveValue
                    && GroupKind(archiveValue: "search") == nil,
                  "左栏=\(panel.groupTitles)")
        ctx.snapshot(panel.window, named: "shot_search_open")
        // 再点一下：收回 + 退出搜索 + 回到进来之前那一页，一个字都不留在框里
        panel.clickSearchToggle()
        let out = ctx.waitUntil(2.0) { !p.isSearching }
        ctx.check("搜索-再点一下收回并退出搜索",
                  out && !panel.isSearchExpanded && panel.searchText.isEmpty
                    && p.activeGroup == .main && panel.magnifierOnlyRow
                    && abs(panel.magnifierLeftEdge - edgeShut) < 0.5,
                  "展开=\(panel.isSearchExpanded) 组=\(p.activeGroup.name) kw='\(panel.searchText)'"
                    + " x=\(Int(panel.magnifierLeftEdge))")
        ctx.check("搜索-退出后表格又是完整那一页",
                  !view.isFiltering && view.totalCount == p.playlist.count,
                  "n=\(view.totalCount)/\(p.playlist.count)")
        restore(undo)
    }

    // MARK: - 真实界面：格式档（页内）、命中数、行号口径、空状态

    private func checkThroughUI(_ ctx: SelfTestContext) {
        let p = ctx.player
        let panel = ctx.main.playlistPanel
        let view = panel.playlistView
        _ = ctx.resetLibrary()
        ctx.main.setListVisible(true)
        p.switchGroup(.main)
        panel.collapseSearch()
        let n = p.playlist.count
        guard n >= 4 else { ctx.check("搜索-曲库前置", false, "n=\(n)"); return }

        // 期望值按当前列表手算：哪些行是 WAV，次序就是原列表次序
        let wav = p.playlist.tracks.enumerated()
            .filter { $0.element.filterFormat == "WAV" }.map(\.offset)
        guard wav.count >= 2, wav.first ?? 0 > 0 else {
            ctx.check("筛选-前置（至少两条 WAV 且首行不是 WAV）", false, "wav=\(wav)"); return
        }

        // 1) 只勾格式：它仍是「这一页」的条件，行号映射与结果数都对得上原列表
        panel.toggleFormatForTest("WAV")
        ctx.check("筛选-勾格式后只看得到该档",
                  view.isFiltering && view.visibleRowCount == wav.count,
                  "n=\(view.visibleRowCount) 应=\(wav.count)")
        ctx.check("筛选-结果行映射到原列表行",
                  (0..<view.visibleRowCount).compactMap { view.sourceRow(forDisplay: $0) } == wav,
                  "应=\(wav)")
        ctx.check("筛选-原列表一条不少", p.playlist.count == n, "n=\(p.playlist.count)")
        ctx.check("筛选-结果数写在标题与统计里",
                  panel.listCaptionText.contains("匹配 \(wav.count)")
                    && panel.infoText.contains("匹配 \(wav.count)"),
                  "caption=\(panel.listCaptionText) info=\(panel.infoText)")
        // 序号列写的是原列表位置：用户拿它对照完整列表，不能写成「结果第 2 条」
        let secondText = view.titleText(row: 1) ?? ""
        ctx.check("筛选-序号仍是原列表位置", secondText.hasPrefix("\(wav[1] + 1)."),
                  "text='\(secondText)' 应='\(wav[1] + 1).'")

        // 2) 播放/收藏/排队都以曲目身份动手
        let src = view.sourceRow(forDisplay: 0) ?? -1
        let keys = p.playlist.tracks.map { $0.identityKey }
        guard src > 0, keys.indices.contains(src) else {
            ctx.check("搜索-行号口径前置（结果首行不是原列表首行）", false, "src=\(src)"); return
        }
        view.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        _ = view.playFromDisplayRow(0)
        ctx.check("搜索-双击播的是那一首而不是结果行号",
                  p.playlist.currentIndex == src && p.currentTrack?.identityKey == keys[src],
                  "idx=\(p.playlist.currentIndex ?? -1) 应=\(src)")
        p.stop()
        if p.isFavorite(p.playlist.tracks[src]) { _ = p.toggleFavorite(p.playlist.tracks[src]) }
        view.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        view.menuToggleFavorite()
        ctx.check("搜索-收藏落在同一首上",
                  p.isFavorite(p.playlist.tracks[src]) && p.groups.favoriteKeys.contains(keys[src]),
                  "fav=\(p.groups.favoriteKeys.count)")
        view.menuToggleFavorite()
        ctx.check("搜索-取消收藏也只动这一首",
                  !p.isFavorite(p.playlist.tracks[src]) && !p.groups.favoriteKeys.contains(keys[src]))
        view.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        view.menuPlayLater()
        ctx.check("搜索-稍后播放排的是那一首",
                  p.queue.pending.last?.track.identityKey == keys[src],
                  "tail=\(p.queue.pending.last?.track.fileName ?? "nil")")
        view.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        view.menuPlayNext()
        ctx.check("搜索-下一首播放插的也是那一首",
                  p.queue.pending.first?.track.identityKey == keys[src],
                  "head=\(p.queue.pending.first?.track.fileName ?? "nil")")
        p.clearPendingQueue()

        // 3) 快捷查找（原有能力）与搜索框共用一套判定，筛选态只在可见行里环形找
        let probe = p.playlist.tracks[src].title
        ctx.check("搜索-快捷查找能在结果里找到下一首",
                  view.focusNextMatch(after: nil, keyword: probe)
                    && view.selectedSourceRows.first == src,
                  "kw=\(probe) sel=\(view.selectedSourceRows)")
        ctx.check("搜索-快捷查找不跳到被筛掉的行",
                  view.selectedSourceRows.isSubset(of: IndexSet(wav)),
                  "sel=\(view.selectedSourceRows) wav=\(wav)")
        ctx.check("搜索-快捷查找没匹配时如实说找不到",
                  !view.focusNextMatch(after: nil, keyword: "绝不可能出现的串ZZZ"))

        // 4) 关键字：搜的是整个播放器，命中表换掉这一页（不再是「匹配几分母」）
        panel.toggleFormatForTest("WAV")          // 再点一次 = 取消勾选，回到无条件
        guard let flac = p.playlist.tracks.first(where: { $0.filterFormat == "FLAC" }) else {
            ctx.check("筛选-前置（曲库里得有一条 FLAC）", false); return
        }
        var undo: [(Track, String, String)] = []
        name(p.playlist.tracks[wav[0]], "甲\(mark)", &undo)
        name(p.playlist.tracks[wav[1]], "乙\(mark)", &undo)
        name(flac, "丙\(mark)", &undo)
        let hitKeys = [p.playlist.tracks[wav[0]].identityKey,
                       p.playlist.tracks[wav[1]].identityKey, flac.identityKey]
        panel.applySearchText(mark)
        let got = ctx.waitUntil(2.0) { p.isSearching && view.totalCount == 3 }
        ctx.check("搜索-关键字把命中装进临时页",
                  got && Set(view.visibleKeys) == Set(hitKeys) && p.playlist.count == 3,
                  "n=\(view.totalCount) keys=\(view.visibleKeys.count)")
        ctx.check("搜索-命中表的标题行说搜什么与几条命中",
                  panel.listCaptionText.contains("搜索「\(mark)」")
                    && panel.listCaptionText.contains("（3）")
                    && panel.infoText.contains("全局命中 3"),
                  "caption=\(panel.listCaptionText) info=\(panel.infoText)")

        // 5) 格式档与关键字组合：命中按同一套档重算，但菜单仍列得出别的档
        panel.toggleFormatForTest("WAV")
        let combo = ctx.waitUntil(2.0) { view.visibleRowCount == 2 }
        ctx.check("搜索-与格式组合后只剩交集",
                  combo && Set(view.visibleKeys) == Set([hitKeys[0], hitKeys[1]]),
                  "n=\(view.visibleRowCount)")
        let menuOpts = panel.formatMenuState.map(\.name)
        ctx.check("搜索-格式菜单不会被当前档锁死（换得到 FLAC）",
                  menuOpts.count == 2 && panel.formatMenuState.contains { $0.name == "FLAC" && !$0.on },
                  "opts=\(menuOpts)")
        panel.toggleFormatForTest("WAV")          // 撤档 → 三条命中回来
        _ = ctx.waitUntil(2.0) { view.visibleRowCount == 3 }
        ctx.snapshot(panel.window, named: "shot_search_combo")

        // 6) 无结果：命中表是空的，但用户那一页一条都没少
        panel.applySearchText("绝不可能出现的串ZZZ")
        let empty = ctx.waitUntil(2.0) { p.isSearching && view.totalCount == 0 }
        ctx.check("搜索-无结果时表格是空的", empty && view.visibleRowCount == 0,
                  "n=\(view.totalCount)")
        ctx.check("搜索-无结果有空状态且说得清是全局搜过",
                  panel.showsEmptyHint && panel.emptyHintFitsList
                    && panel.emptyHintText.contains("整个播放器"),
                  "hint=\(panel.emptyHintText)")
        ctx.snapshot(panel.window, named: "shot_search_empty")
        view.menuRemove()
        panel.applySearchText("")
        let back = ctx.waitUntil(2.0) { !p.isSearching }
        ctx.check("搜索-空结果里删除不动手，退出去还是完整那一页",
                  back && p.playlist.count == n && !view.isFiltering,
                  "n=\(p.playlist.count) 应=\(n)")

        // 7) 搜索中换页 = 退出搜索：条件与框里的字一起清掉，不留一张假的结果页
        panel.applySearchText(mark)
        _ = ctx.waitUntil(2.0) { p.isSearching }
        p.switchGroup(.favorites)
        ctx.pump(0.2)
        ctx.check("搜索-点左栏别的页就退出搜索并收回输入框",
                  !p.isSearching && p.activeGroup == .favorites && !panel.isSearchExpanded
                    && panel.searchText.isEmpty && !view.isFiltering,
                  "kw='\(panel.searchText)' 展开=\(panel.isSearchExpanded)")
        p.switchGroup(.main)
        ctx.check("搜索-搜索控件在标题行里没被盖住",
                  panel.captionClearOfSearch, "caption=\(panel.listCaptionText)")

        // 8) 最窄一档：歌单名与搜索控件挤在同一行，只能截断不能重叠（面板宽度跟着主窗走）
        let frameBefore = ctx.main.window.frame
        var thin = frameBefore
        thin.size.width = MainWindowController.minWidth
        ctx.main.window.setFrame(thin, display: true)
        ctx.pump(0.1)
        panel.focusSearch()
        ctx.pump(0.1)
        ctx.check("搜索-最窄一档放大镜与输入框都还在",
                  panel.isSearchExpanded && panel.searchControlsVisible
                    && panel.captionClearOfSearch,
                  "宽=\(Int(panel.expandedSearchWidth)) 面板宽=\(Int(panel.window.frame.width))")
        panel.applySearchText("这是一条长得不能再长一点的中文关键字" + mark)
        _ = ctx.waitUntil(2.0) { p.isSearching }
        ctx.check("搜索-最窄一档标题截断不压住搜索控件",
                  panel.captionClearOfSearch && panel.searchControlsVisible
                    && abs(ctx.main.window.frame.width - MainWindowController.minWidth) < 2,
                  "w=\(Int(ctx.main.window.frame.width)) caption=\(panel.listCaptionText)")
        // 挤到最窄也要先看见命中数（截只能截尾巴）
        ctx.check("搜索-最窄一档命中数没被截掉",
                  panel.listCaptionText.hasPrefix("搜索「") && panel.listCaptionText.contains("（0）")
                    && panel.emptyHintFitsList,
                  "caption=\(panel.listCaptionText)")
        ctx.snapshot(panel.window, named: "shot_search_thin")
        panel.collapseSearch()
        ctx.pump(0.2)
        ctx.main.window.setFrame(frameBefore, display: true)
        ctx.pump(0.1)
        restore(undo)
    }

    // MARK: - 跨页：命中来自好几页，删除按身份动手

    private func checkCrossPage(_ ctx: SelfTestContext) {
        let p = ctx.player
        let panel = ctx.main.playlistPanel
        let view = panel.playlistView
        for id in p.userLists.ids { _ = p.deleteList(id: id) }
        _ = ctx.resetLibrary()
        p.stop()
        p.switchGroup(.main)
        panel.collapseSearch()
        let tracks = p.playlist.tracks
        guard tracks.count >= 5 else {
            ctx.check("搜索-跨页前置（曲库至少五行）", false, "n=\(tracks.count)"); return
        }
        var undo: [(Track, String, String)] = []
        let a = tracks[0], b = tracks[1]
        name(a, "跨页甲\(mark)", &undo)
        name(b, "跨页乙\(mark)", &undo)
        let ka = a.identityKey, kb = b.identityKey
        _ = p.toggleFavorite(b)                       // B 同时在 [默认] 与收藏里
        let wasFav = p.isFavorite(b)
        guard let made = p.createList(named: "深夜\(mark)") else {
            ctx.check("搜索-跨页前置（能建歌单）", false); restore(undo); return
        }
        let listID = made.id
        // 建歌单会把在看的页切到新歌单上：找 C 得回到完整列表里找
        p.switchGroup(.main)
        // C 只活在那张歌单里：它不在 [默认]，只能从「别的页」被搜出来
        //（排除甲乙两条：它们已经被改过名，拿它们的文件名词干当关键字就测不出「跨页」了）
        guard let c = tracks.first(where: { t in
            let stem = (t.fileName as NSString).deletingPathExtension
            return t !== a && t !== b && stem.count >= 4
                && tracks.filter { $0.fileName.contains(stem) }.count == 1
        }) else {
            ctx.check("搜索-跨页前置（有一条文件名独占的歌）", false,
                      "names=\(tracks.map(\.fileName))"); restore(undo); return
        }
        let kc = c.identityKey
        _ = p.addTracks([c], toList: listID)
        p.switchGroup(.main)
        if let i = p.playlist.index(ofKey: kc) { p.removeTracks(at: IndexSet(integer: i)) }
        let mainAfterExit = p.playlist.tracks.filter { $0.identityKey != kc }.map { $0.identityKey }
        let stem = (c.fileName as NSString).deletingPathExtension

        // 1) 关键字命中 [默认] 里的两首，收藏那一页不产生第二条
        panel.focusSearch()
        panel.applySearchText(mark)
        let two = ctx.waitUntil(2.0) { p.isSearching && view.totalCount == 2 }
        ctx.check("搜索-同一首在好几页里只算一条命中",
                  two && view.visibleKeys == [ka, kb], "keys=\(view.visibleKeys.count)")
        ctx.check("搜索-来源标注只说多说的那一页（收藏里有它就写出来）",
                  p.searchAnnotation(for: kb) == "（\(GroupKind.favorites.name)）"
                    && p.searchAnnotation(for: ka).isEmpty,
                  "b='\(p.searchAnnotation(for: kb))' a='\(p.searchAnnotation(for: ka))'")
        ctx.check("搜索-来源标注写在行末",
                  (view.titleText(row: 1) ?? "").contains(GroupKind.favorites.name),
                  "text=\(view.titleText(row: 1) ?? "")")

        // 2) 只在别的页里的歌也搜得到：[默认] 已经没有它了
        panel.applySearchText(stem)
        let one = ctx.waitUntil(2.0) { view.totalCount == 1 }
        ctx.check("搜索-不在当前页的歌也能搜出来",
                  one && view.visibleKeys == [kc] && !mainAfterExit.contains(kc),
                  "kw=\(stem) keys=\(view.visibleKeys) 默认列=\(mainAfterExit.count)")
        ctx.check("搜索-从别的页来的命中说得出它在哪",
                  p.searchAnnotation(for: kc).contains("深夜\(mark)"),
                  "anno='\(p.searchAnnotation(for: kc))'")
        ctx.check("搜索-搜索态不能清空也不能排序",
                  panel.makeSortMenu().items.first?.isEnabled == false
                    && panel.makeListMenu().items.first { $0.title.contains("清空") }?.isEnabled == false,
                  "排序=\(panel.makeSortMenu().items.first?.title ?? "nil")")
        let hitsBefore = view.totalCount
        p.clearPlaylist()
        ctx.check("搜索-清空在搜索态被拒（命中表不是一份列表）",
                  p.playlist.count == hitsBefore && p.activeGroup == .search,
                  "n=\(p.playlist.count)")

        // 3) 在结果里删一行 = 从存着它的那些页一并摘掉（这里那张歌单的引用要跟着没）
        view.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        view.menuRemove()
        let gone = ctx.waitUntil(2.0) { p.isSearching && view.totalCount == 0 }
        ctx.check("搜索-删掉结果里那一行也摘掉了歌单里的引用",
                  gone && !p.userLists.keys(of: listID).contains(kc),
                  "n=\(view.totalCount) 歌单=\(p.userLists.keys(of: listID).count)")
        // 回到 [默认] 再搜一次那两个标记：B 是「收藏里也有」的那一条，
        // 从结果里删它必须连 [默认] 那份一起删掉（只删命中表就是假删除）
        panel.applySearchText(mark)
        let back2 = ctx.waitUntil(2.0) { view.totalCount == 2 }
        ctx.check("搜索-回到 [默认] 那两首还在结果里", back2, "n=\(view.totalCount)")
        view.table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        view.menuRemove()
        _ = ctx.waitUntil(2.0) { view.totalCount == 1 }
        panel.applySearchText("")
        _ = ctx.waitUntil(2.0) { !p.isSearching }
        ctx.check("搜索-从结果删一条真的从列表与收藏里都没了",
                  !p.playlist.tracks.contains { $0.identityKey == kb }
                    && !p.groups.favoriteKeys.contains(kb),
                  "n=\(p.playlist.count) fav=\(p.groups.favoriteKeys.contains(kb))")
        ctx.check("搜索-搜索态没有留在左栏与状态里",
                  p.activeGroup == .main && !p.isSearching && p.searchKeyword.isEmpty
                    && p.searchOverflow == 0 && p.searchFormatOptions.isEmpty,
                  "组=\(p.activeGroup.name) kw='\(p.searchKeyword)'")
        _ = mainAfterExit    // 上面已经用它验过「[默认] 没有 C」，这里只是说明不是没写完

        for id in p.userLists.ids { _ = p.deleteList(id: id) }
        if wasFav, p.isFavorite(a) { _ = p.toggleFavorite(a) }
        restore(undo)
    }

    // MARK: - ⌘F 与「正在输入」的键盘归属

    private func checkSearchShortcut(_ ctx: SelfTestContext) {
        let p = ctx.player
        let main = ctx.main
        let panel = main.playlistPanel
        panel.collapseSearch()
        main.setListVisible(true)
        // 造键盘事件时得说清这条键是给哪个窗口的：`isEditingText` 先看 event.window，
        // 「平时」和「正在框里打字」两种现场只能靠目标窗口区分
        func key(_ target: NSWindow, _ chars: String, code: UInt16,
                 mods: NSEvent.ModifierFlags) -> NSEvent? {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0,
                             windowNumber: Int(target.windowNumber), context: nil,
                             characters: chars, charactersIgnoringModifiers: chars,
                             isARepeat: false, keyCode: code)
        }
        guard let f = key(panel.window, "f", code: 3, mods: .command),
              let m = key(main.window, "m", code: 46, mods: []),
              let mTyped = key(panel.window, "m", code: 46, mods: []),
              let f1 = key(panel.window, "\u{F704}", code: 122, mods: []) else {
            ctx.check("搜索-能造出键盘事件", false); return
        }
        // 先在「没有在输入」的状态下确认 m 会被播放器吃掉（静音开关），再对比进框之后
        panel.window.makeFirstResponder(nil)
        main.window.makeFirstResponder(nil)
        let mutedBefore = p.isMuted
        let tookM = main.handleKey(m)
        if p.isMuted != mutedBefore { p.toggleMute() }
        ctx.check("搜索-平时按 M 是静音开关", tookM && p.isMuted == mutedBefore, "took=\(tookM)")
        // 入口不能只有快捷键：「菜单」那一项里也要搜得到，而且说的必须是全局口径
        //（拆成 buildPopupMenu 就是为了能断言）
        let entry = main.buildPopupMenu().items.first { $0.title.contains("搜索全部曲目") }
        ctx.check("搜索-菜单里的搜索入口写的是全局口径且快捷键就是 ⌘F",
                  entry?.keyEquivalent == "f" && entry?.keyEquivalentModifierMask == .command
                    && entry?.action != nil,
                  "item=\(entry?.title ?? "没有") key=\(entry?.keyEquivalent ?? "")")
        // 收起着的时候按 ⌘F：先展开再把键盘交给它，不然用户只会敲下一堆空字
        ctx.check("搜索-⌘F 展开放大镜并把键盘交给搜索框",
                  main.handleKey(f) && panel.isSearchExpanded && panel.searchHasKeyboard,
                  "展开=\(panel.isSearchExpanded) firstResponder=\(type(of: panel.window.firstResponder as Any))")
        // 焦点在框里时敲 m 只是打字，不能顺手把播放器静音了
        let muted2 = p.isMuted
        ctx.check("搜索-输入框里打字不抢键",
                  !main.handleKey(mTyped) && p.isMuted == muted2,
                  "keyWindow=\(NSApp.keyWindow?.title ?? "nil") resp=\(type(of: panel.window.firstResponder as Any))")
        // F1~F4 不可能是打字键：在框里也照旧切播放模式
        let was = p.playMode
        let switched = main.handleKey(f1) && p.playMode == .order
        p.setMode(was)
        ctx.check("搜索-输入框里 F1~F4 照旧切播放模式", switched)
        panel.collapseSearch()
        ctx.pump(0.2)
        main.window.makeFirstResponder(nil)
    }

    // MARK: - 清除筛选与退出搜索都要还原现场

    private func checkSceneRestore(_ ctx: SelfTestContext) {
        let p = ctx.player
        let panel = ctx.main.playlistPanel
        let view = panel.playlistView
        // 这一场验的是纯 UI 的「还原现场」，不能让前面留下的播放与删行参与：
        // 整曲一播完队列就推进，选中行会跟着出声的那一首跑（F03 的既定行为）。
        // 全量跑到这一场时前面已经播过好几轮，实测读到 sel=0（单独跑 search、只接前 15 套都复现不出来）
        panel.collapseSearch()
        p.stop()
        _ = ctx.resetLibrary()
        p.switchGroup(.main)
        // 滚得动才有「还原滚动位置」可言：真实曲库就七八行，垫一批模拟元数据把它撑过长列表
        let fillers = (0..<24).map { track("/tmp/ttsearch/filler\(String(format: "%03d", $0)).mp3",
                                          title: "填充曲目 \(String(format: "%03d", $0))") }
        _ = p.playlist.add(contentsOf: fillers)
        NotificationCenter.default.post(name: .ttPlaylistChanged, object: nil)
        ctx.pump(0.2)
        let n = p.playlist.count
        guard n >= 20, view.documentOverflowViewport else {
            ctx.check("搜索-还原前置（列表长到需要滚动）", false, "n=\(n)"); return
        }

        // 现场：选中最后一行并滚过去
        let last = n - 1
        _ = view.focusRow(sourceRow: last)
        let origin = view.scrollOrigin
        panel.toggleFormatForTest("MP3")        // 页内条件：只有那 24 条填充是 MP3
        ctx.pump(0.2)
        view.table.scrollRowToVisible(0)
        ctx.check("搜索-筛选里现场确实变了",
                  view.isFiltering && view.visibleRowCount == 24
                    && view.scrollOrigin != origin && origin.y > 0,
                  "n=\(view.visibleRowCount) y=\(view.scrollOrigin.y) 原=\(origin.y)")
        panel.toggleFormatForTest("MP3")        // 取消勾选 = 清除条件，现场该原样回来
        ctx.pump(0.2)
        ctx.check("搜索-清除后恢复原列表", !view.isFiltering && view.visibleRowCount == n,
                  "n=\(view.visibleRowCount) 应=\(n)")
        ctx.check("搜索-清除后恢复选中", view.selectedSourceRows.contains(last),
                  "sel=\(view.selectedSourceRows) 应含 \(last)")
        ctx.check("搜索-清除后恢复滚动位置", abs(view.scrollOrigin.y - origin.y) <= 1,
                  "y=\(view.scrollOrigin.y) 应=\(origin.y)")

        // 列表在筛选期间被改短了：还原的位置只能夹在「还滚得动」的范围里，不能停在一片空白上
        _ = view.focusRow(sourceRow: n - 1)
        let keepOrigin = view.scrollOrigin
        panel.toggleFormatForTest("MP3")
        ctx.pump(0.2)
        let cutFrom = n - 20
        p.removeTracks(at: IndexSet(integersIn: cutFrom..<n))
        ctx.pump(0.2)
        let shortened = p.playlist.count
        // 清除入口就是右键菜单里那一项：菜单打开时才重建标题，先走一次同一条路
        view.refreshContextMenus()
        let itemTitle = view.clearFilterItemTitle
        ctx.check("搜索-筛选里右键菜单给出清除入口与范围",
                  itemTitle?.contains("清除筛选") == true
                    && itemTitle?.contains("不只是结果") == false,
                  "item=\(itemTitle ?? "nil")")
        view.menuClearFilter()          // 与鼠标点那一项同一个 action
        ctx.pump(0.3)
        ctx.check("搜索-列表变短时滚动位置夹到还能滚的底",
                  !view.isFiltering && view.visibleRowCount == shortened
                    && abs(view.scrollOrigin.y - view.maxScrollY) <= 1
                    && view.maxScrollY < keepOrigin.y,
                  "y=\(view.scrollOrigin.y) max=\(view.maxScrollY) 原=\(keepOrigin.y)")

        // 退出搜索也一样：命中表把这一页换掉了，退回来不该停在列表顶上
        let deep = shortened - 1
        _ = view.focusRow(sourceRow: deep)
        let deepOrigin = view.scrollOrigin
        guard deepOrigin.y > 0 else {
            ctx.check("搜索-退出搜索还原前置（滚得动）", false, "y=\(deepOrigin.y)"); return
        }
        let kw = String(p.playlist.tracks[deep].title.prefix(4))
        panel.applySearchText(kw)
        _ = ctx.waitUntil(2.0) { p.isSearching }
        ctx.check("搜索-进搜索时这一页换成命中表", view.totalCount != shortened,
                  "n=\(view.totalCount)/\(shortened)")
        panel.collapseSearch()
        _ = ctx.waitUntil(2.0) { !p.isSearching }
        ctx.check("搜索-退出搜索把选中与滚动位置还回来",
                  view.selectedSourceRows.contains(deep)
                    && abs(view.scrollOrigin.y - deepOrigin.y) <= 1,
                  "sel=\(view.selectedSourceRows) 应含 \(deep) y=\(view.scrollOrigin.y) 应=\(deepOrigin.y)")
        _ = ctx.resetLibrary()
    }

    // MARK: - 元数据晚到与防抖

    private func checkLateMetadata(_ ctx: SelfTestContext) {
        let p = ctx.player
        let panel = ctx.main.playlistPanel
        let view = panel.playlistView
        panel.collapseSearch()
        p.switchGroup(.main)
        let tracks = p.playlist.tracks
        guard tracks.count >= 3 else { ctx.check("搜索-元数据前置", false); return }
        var undo: [(Track, String, String)] = []

        // 先拿一个谁都不含的关键字（命中表是空的），再把其中一首「改到命中」
        let late = "迟到的标签\(mark)"
        let victim = tracks[tracks.count - 1]
        let victimKey = victim.identityKey
        panel.focusSearch()
        panel.applySearchText(late)
        let none = ctx.waitUntil(2.0) { p.isSearching && view.totalCount == 0 }
        ctx.check("搜索-晚到前确实没结果", none, "n=\(view.totalCount)")
        name(victim, "\(victim.title) \(late)", &undo)
        NotificationCenter.default.post(name: .ttTrackChanged, object: nil,
                                        userInfo: ["track": victim])
        let caught = ctx.waitUntil(2.0) { view.visibleKeys == [victimKey] }
        ctx.check("搜索-元数据晚到结果会跟上（不必再敲一个字）", caught,
                  "n=\(view.totalCount) keys=\(view.visibleKeys.count)")
        ctx.check("搜索-晚到的那行写的就是新标签",
                  (view.titleText(row: 0) ?? "").contains(late),
                  "text=\(view.titleText(row: 0) ?? "")")

        // 元数据一条条来的风暴（导入一万首就是这样）：既不能每条通知都扫一遍全库，
        // 也不能因为通知一直来就永远不刷新。200 条一起发，结果要正确、输入要有回音
        let storm = [tracks[0], tracks[1]]
        for (i, t) in storm.enumerated() { name(t, "风暴\(mark)\(i)", &undo) }
        let wantKeys = storm.map { $0.identityKey }
        let t0 = Date()
        for _ in 0..<200 {
            NotificationCenter.default.post(name: .ttTrackChanged, object: nil,
                                            userInfo: ["track": victim])
        }
        panel.applySearchText("风暴\(mark)")
        let expect = wantKeys            // 次序就是 [默认] 里的页序，独享标记不会有别人混进来
        let ok = ctx.waitUntil(2.0) { view.visibleKeys == expect }
        let ms = Date().timeIntervalSince(t0) * 1000
        // 门槛含防抖 120 ms 与「通知风暴合并重跑」那 350 ms，余量留给慢机器
        ctx.check("搜索-元数据风暴里输入照样有回音", ok && ms < 1500,
                  "n=\(view.totalCount) 应=\(expect.count) 用时=\(Int(ms)) ms")
        // 重跑不能把用户那一页换掉：命中表是临时页，存档说的仍是 [默认]；
        // 退出去之后原来那几条歌一条都不能少（在搜索态里读 playlist 读的就是命中表，
        // 所以这一条要等退出之后再验）
        panel.collapseSearch()
        _ = ctx.waitUntil(2.0) { !p.isSearching }
        ctx.check("搜索-风暴里的重跑不动用户那一页的内容",
                  p.persistGroup == .main && p.playlist.count >= 3,
                  "组=\(p.persistGroup.name) n=\(p.playlist.count)")
        restore(undo)
        ctx.pump(0.2)
    }

    // MARK: - 搜索态不落进存档

    private func checkPersistence(_ ctx: SelfTestContext) {
        let p = ctx.player
        let panel = ctx.main.playlistPanel
        let view = panel.playlistView
        for id in p.userLists.ids { _ = p.deleteList(id: id) }
        _ = ctx.resetLibrary()
        p.switchGroup(.main)
        panel.collapseSearch()
        let all = p.playlist.tracks.map { $0.identityKey }
        guard let hit = p.playlist.tracks.first, let keep = p.playlist.tracks.last else {
            ctx.check("搜索-存档前置", false); return
        }
        var undo: [(Track, String, String)] = []
        name(hit, "存档\(mark)", &undo)
        // 进搜索前停在一张自建歌单上：存档要说的就是这一张，不是 [默认]，更不是临时页
        guard let made = p.createList(named: "存档\(mark)") else {
            ctx.check("搜索-存档前置（能建歌单）", false); restore(undo); return
        }
        _ = p.addTracks([keep], toList: made.id)
        p.switchGroup(.playlist(made.id))
        ctx.pump(0.2)
        panel.focusSearch()
        panel.applySearchText(mark)
        let inSearch = ctx.waitUntil(2.0) { p.isSearching }
        guard inSearch, view.totalCount == 1 else {
            ctx.check("搜索-存档前置（搜出一条）", false, "n=\(view.totalCount)")
            panel.collapseSearch(); restore(undo); return
        }
        ctx.check("搜索-搜索态写盘说的是进来之前那一页",
                  p.persistGroup == .playlist(made.id) && p.persistListID == made.id
                    && p.activeGroup == .search,
                  "persist=\(p.persistGroup.name) 组=\(p.activeGroup.name)")
        p.persistNow()
        let saved = LibraryStore.load()
        ctx.check("搜索-存档写的仍是完整列表而不是命中表", saved.trackPaths == all,
                  "paths=\(saved.trackPaths.count) 应=\(all.count) 命中=\(view.totalCount)")
        ctx.check("搜索-存档记的在看待的是那一张歌单", saved.viewListID == made.id,
                  "viewListID=\(saved.viewListID)")
        ctx.check("搜索-播放现场也不会把临时页写进去",
                  p.snapshotScene().group == "playlist:\(made.id)",
                  "group=\(p.snapshotScene().group)")
        panel.collapseSearch()
        ctx.pump(0.2)
        p.switchGroup(.main)
        for id in p.userLists.ids { _ = p.deleteList(id: id) }
        p.persistNow()
        restore(undo)
    }

    /// 套尾把条件、临时页与本套留下的档案改动还原干净：
    /// 后面的队列/界面套件不该看到一张搜过的表，也不该看到这套建的歌单与收藏
    private func cleanup(_ ctx: SelfTestContext) {
        let p = ctx.player
        let panel = ctx.main.playlistPanel
        let view = panel.playlistView
        panel.collapseSearch()
        ctx.pump(0.2)
        view.clearFilter()
        for id in p.userLists.ids { _ = p.deleteList(id: id) }
        p.switchGroup(.main)
        _ = ctx.resetLibrary()          // 改过的标题都只在内存里：重新导入一遍就回到盘上的样子
        p.stop()
        ctx.check("搜索-收尾回到无筛选的完整列表",
                  !panel.isSearchExpanded && !p.isSearching && !view.isFiltering
                    && view.visibleRowCount == p.playlist.count,
                  "展开=\(panel.isSearchExpanded) n=\(view.visibleRowCount)/\(p.playlist.count)")
        ctx.check("搜索-收尾不留下临时页与本套的歌单",
                  p.activeGroup == .main && p.userLists.isEmpty,
                  "组=\(p.activeGroup.name) 歌单=\(p.userLists.count)")
        p.persistNow()
    }
}
