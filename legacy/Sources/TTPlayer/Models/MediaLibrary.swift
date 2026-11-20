import Foundation
import CoreServices

/// 媒体库（F08）：一批「音乐目录」+ 扫出来的条目引用 + 目录监控 + 重新定位。
///
/// 三条规矩撑起整个功能：
/// 1. 库里只存**引用**（`Track.identityKey` 那一套写法），不复制、不移动、不改写任何原始文件；
/// 2. 媒体库与歌单、待播队列相互分开：扫到新歌只进库，绝不自动开播或往队列里插队；
/// 3. 「目录在线、文件没了」才把条目从库里摘掉；整个目录不在线（外置盘拔了、网络盘断了）
///    只标失效并留住，等它回来自动恢复。
///
/// 扫描复用既有导入规则（`LibraryStore.Importer` 的 cue 分轨 / m3u 展开 / 归档扁平入表），
/// 所以拖目录与扫目录拿到的是同一串键，不会因为走了两条路就出现「同一个位置两种结果」。
final class MediaLibrary {
    static let shared = MediaLibrary()

    /// 一趟扫描的账：给自检报耗时与规模，也给菜单那行状态用
    struct ScanStats {
        var filesScanned = 0
        var entries = 0
        var seconds = 0.0
        /// 因为重复（同一目录第二次出现 / 同一文件第二个链接）被跳过的项数
        var skippedDuplicates = 0
        var cancelled = false
    }

    /// 一次合并扫描的差异：四类事件都得说得出名字，用户才敢开监控
    struct Delta: Equatable {
        var added: [String] = []
        /// 目录在线而文件没了：从库里摘掉（其他档案里的引用另由 F04 规矩留住）
        var removed: [String] = []
        /// 目录不在线：留住并标失效
        var invalid: [String] = []
        /// 之前失效的目录回来了
        var restored: [String] = []
        /// 还在但内容改了（改动时间变了）：元数据要重读
        var modified: [String] = []

        var isEmpty: Bool {
            added.isEmpty && removed.isEmpty && invalid.isEmpty
                && restored.isEmpty && modified.isEmpty
        }
        var changedKeys: Set<String> { Set(added + modified + restored) }
    }

    // MARK: - 现场

    /// 用户添加的目录（按添加顺序，存档里就是这个数组）
    private(set) var folders: [String] = []
    /// 库里的条目引用，含失效的（顺序 = 目录顺序 + 自然序，稳定可比）
    private(set) var keys: [String] = []
    /// 当前不在线的目录：这一档下的条目只标失效，不摘掉
    private(set) var offlineFolders: Set<String> = []
    /// 每一趟扫描的账（菜单与自检都读它，不另算一遍）
    private(set) var lastStats = ScanStats()
    /// 上次见到某个**文件**时的改动时间：按文件记账，再翻译成依赖它的所有引用
    /// （一份 cue 改了，它展开的每一轨都算修改）。只在本次运行里比，重启后第一趟没什么可比的
    private var pathStamps: [String: Date] = [:]

    private(set) var isScanning = false
    /// 扫描中给界面的一句话（「扫描中：已看 1200 个文件」），扫完清空
    private(set) var scanNote = ""
    private var cancelRequested = false
    private let stateLock = NSLock()
    private let scanQueue = DispatchQueue(label: "com.ttplayer.library.scan", qos: .utility)
    /// 监控事件攒到这里，等安静一会儿再合并扫描（一次批量拷贝不该扫十趟）
    private var pendingMerge: Set<String> = []
    private var mergeTimer: Timer?
    private var streams: [String: FSEventStreamRef] = [:]
    private let watchQueue = DispatchQueue(label: "com.ttplayer.library.watch")

    /// 扫描扩展名白名单：与拖目录完全同一份（含 cue / 歌单 / 归档）
    static var scanExtensions: Set<String> { LibraryStore.directoryExtensions }

    // MARK: - 存档往返

    /// 从 state.json 还原。只认目录路径与条目键，改动时间戳不跨进程（重启后重新比）
    func restore(folders: [String], keys: [String]) {
        self.folders = folders
        self.keys = keys
        offlineFolders = Set(folders.filter { !MediaLibrary.isDirectoryOnline($0) })
        pathStamps = [:]
    }

    // MARK: - 目录管理

    /// 添加一个音乐目录。返回 nil = 成功，否则一句没加成的原因（界面直接拿去说）
    @discardableResult
    func addFolder(_ rawPath: String) -> String? {
        let path = (rawPath as NSString).standardizingPath
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else {
            return "这个目录现在不在：\(path)"
        }
        guard isDir.boolValue else { return "选中的不是目录：\(path)" }
        if let same = folders.first(where: { MediaLibrary.sameDirectory($0, path) }) {
            return "已经在库了（与「\(same)」是同一个目录，重复添加不会多出货）"
        }
        // 一个目录已经装在另一个里面：再单独加一遍只会让同一批文件被扫两次
        if let upper = folders.first(where: { MediaLibrary.isDirectory($0, parentOf: path) }) {
            return "「\(upper)」已经把它整个覆盖到了，再单独添加只会重复扫一遍"
        }
        folders.append(path)
        offlineFolders.remove(path)
        Diagnostics.log("媒体库添加目录 \(path)")
        return nil
    }

    /// 从库里去掉一个目录。只摘这个目录扫出来的条目引用：
    /// 歌单、收藏、历史、待播队列、磁盘上的文件一概不动
    func removeFolder(_ path: String) -> (dropped: Int, note: String) {
        guard folders.contains(path) else { return (0, "库里没有这个目录") }
        folders.removeAll { $0 == path }
        offlineFolders.remove(path)
        let kept = keys.filter { !MediaLibrary.key($0, liesUnder: path) }
        let dropped = keys.count - kept.count
        keys = kept
        let prefix = path.hasSuffix("/") ? path : path + "/"
        pathStamps = pathStamps.filter { !$0.key.hasPrefix(prefix) }
        stopWatchingFolder(path)
        Diagnostics.log("媒体库移除目录 \(path)（摘掉 \(dropped) 条引用）："
            + "歌单、收藏、历史与待播队列未受影响，磁盘上的文件不动")
        return (dropped, "已移除「\((path as NSString).lastPathComponent)」，库里少了 \(dropped) 条引用")
    }

    // MARK: - 有效性

    /// 这一条现在能不能用：目录在不在线由扫描那一关说（离线只标失效不摘掉），
    /// 这里只看东西现在能不能打开
    func isInvalid(_ key: String) -> Bool { !LibraryStore.entryExists(key) }

    var missingCount: Int { keys.filter { isInvalid($0) }.count }

    /// 目录在不在线（外置盘拔走时这条先说=false，条目就一律只标失效不摘掉）
    static func isDirectoryOnline(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    // MARK: - 扫描

    /// 全量重扫（首次扫描与手动「重新扫描」都走这里）。异步：主线程只收进度与结果
    func scanAll(initial: Bool) {
        guard !folders.isEmpty else {
            scanNote = ""
            Diagnostics.log("媒体库扫描：还没添加任何目录")
            return
        }
        startScan(over: folders, label: initial ? "首次扫描" : "重新扫描")
    }

    /// 只扫某几个目录（监控事件用）：合并进现有库，不动别的目录的条目
    func scan(folders targets: [String]) {
        guard !targets.isEmpty else { return }
        startScan(over: targets, label: "目录变更")
    }

    /// 请求取消当前扫描：已经合并的部分不回滚（用户要的是「别再占着磁盘」，不是「当无事发生」）
    func cancelScan() {
        guard isScanning else { return }
        stateLock.lock()
        cancelRequested = true
        stateLock.unlock()
        Diagnostics.log("媒体库扫描：用户取消")
    }

    private var shouldCancel: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return cancelRequested
    }

    private func startScan(over targets: [String], label: String) {
        stateLock.lock()
        if isScanning {
            // 上一趟还没走完（批量拷贝最容易撞上）：把这一批并进去，不另起一趟
            stateLock.unlock()
            pendingMerge.formUnion(targets)
            Diagnostics.log("媒体库扫描（\(label)）：上一趟在跑，这一批并到尾巴上")
            return
        }
        isScanning = true
        cancelRequested = false
        stateLock.unlock()
        scanNote = "扫描中（\(label)）：0 个文件"
        NotificationCenter.default.post(name: .ttLibraryChanged, object: nil,
                                        userInfo: ["note": scanNote])
        let snapshot = targets
        scanQueue.async { [weak self] in
            guard let self else { return }
            let found = self.collectFolders(snapshot, report: { done in
                // 后台只递一个数上来，文字与通知都在主线程拼（界面读 scanNote 不用加锁）
                DispatchQueue.main.async {
                    guard self.isScanning else { return }
                    self.scanNote = "扫描中（\(label)）：已看 \(done) 个文件"
                    NotificationCenter.default.post(name: .ttLibraryChanged, object: nil,
                                                    userInfo: ["note": self.scanNote])
                }
            })
            DispatchQueue.main.async {
                self.finishScan(found, label: label, folders: snapshot)
            }
        }
    }

    /// 一趟扫描的收获（按目录分组，才分得清「哪个目录里的东西没了」）
    private struct Harvest {
        var byFolder: [String: [String]] = [:]
        var stats = ScanStats()
        /// 文件路径 → 改动时间：「修改」按文件记账，再翻译成依赖它的每一条引用
        var mtimes: [String: Date] = [:]
        var offline: Set<String> = []
        /// 这一趟**看完一整片**的目录（扫完的或确认不在线的）。
        /// 被取消的那一片不算看完：半截清单不能当全清单用
        var covered: Set<String> = []
    }

    /// 后台阶段：只读盘、只算键，不碰任何共享状态。
    /// report 最多 0.2 s 递一次（已看文件数）：每个文件都往主线程递消息的话，
    /// 扫描自己就把主线程挤满了，进度条反而看不见了
    private func collectFolders(_ targets: [String], report: (Int) -> Void = { _ in }) -> Harvest {
        var h = Harvest()
        let start = Date()
        let ext = Self.scanExtensions
        var lastReport = start
        for dir in targets {
            if shouldCancel { h.stats.cancelled = true; break }
            guard Self.isDirectoryOnline(dir) else {
                h.offline.insert(dir)
                h.covered.insert(dir)
                continue
            }
            var paths: [String] = []
            var visitedDirs = Set<String>()
            var visitedFiles = Set<String>()
            let cancelled = Self.walk(dir: dir, into: &paths, extensions: ext,
                                      visitedDirs: &visitedDirs, visitedFiles: &visitedFiles,
                                      depth: 0, stats: &h.stats,
                                      shouldCancel: { [weak self] in self?.shouldCancel ?? false },
                                      progress: { done in
                                          let now = Date()
                                          guard now.timeIntervalSince(lastReport) >= 0.2 else { return }
                                          lastReport = now
                                          report(done)
                                      })
            if cancelled { h.stats.cancelled = true; break }
            for p in paths { h.mtimes[p] = Self.mtime(of: p) }
            // 键由导入规则算出（cue 会展开成一串分轨键），不是简单把路径拄一遍
            h.byFolder[dir] = Self.keys(from: paths)
            h.covered.insert(dir)
        }
        h.stats.seconds = Date().timeIntervalSince(start)
        h.stats.entries = h.byFolder.values.reduce(0) { $0 + $1.count }
        return h
    }

    /// 主线程阶段：合并进库、算差异、发通知
    private func finishScan(_ harvest: Harvest, label: String, folders scanned: [String]) {
        // 后台那一趟跑着的这段时间里用户可能已经把某一片移出了库：过期的收获不能并回来，
        // 否则 `removeFolder` 之后那些条目会在下一趟合并里复活（连改动记账一起补回去）
        let harvest = pruning(harvest, stale: scanned.filter { !folders.contains($0) })
        let delta = merge(harvest, scanned: scanned)
        lastStats = harvest.stats
        isScanning = false
        scanNote = ""
        stateLock.lock()
        let extra = pendingMerge
        pendingMerge = []
        stateLock.unlock()
        Diagnostics.log(String(format: "媒体库扫描（%@%@）：看了 %d 个文件，库里 %d 条，%.2f s",
                               label, harvest.stats.cancelled ? "，已取消" : "",
                               harvest.stats.filesScanned, keys.count, harvest.stats.seconds))
        // 取消那一趟不能说「扫描完成」：那几条差量只是走到一半的账
        let head = harvest.stats.cancelled ? "已停止扫描：" : "扫描完成："
        NotificationCenter.default.post(name: .ttLibraryChanged, object: nil,
                                        userInfo: ["note": "\(head)新增 \(delta.added.count) 条，"
                                            + "摘掉 \(delta.removed.count) 条，"
                                            + "失效 \(missingCount) 条"])
        if !extra.isEmpty { startScan(over: Array(extra), label: "目录变更") }
    }

    /// 把「已经不在库里的目录」从那趟收获里摘干净：条目、改动记账、在线状态、
    /// 「看完一整片」的标记一概不留，`merge` 因此既不会把条目加回来，也不会去清它的记账。
    /// `scanNow` 不走这里：它同步跑完，中间腾不出手去移除目录，自检还会拿它扫未注册的目录
    private func pruning(_ h: Harvest, stale: [String]) -> Harvest {
        guard !stale.isEmpty else { return h }
        var out = h
        for dir in stale {
            out.byFolder[dir] = nil
            out.covered.remove(dir)
            out.offline.remove(dir)
            let prefix = dir.hasSuffix("/") ? dir : dir + "/"
            out.mtimes = out.mtimes.filter { !$0.key.hasPrefix(prefix) }
        }
        out.stats.entries = out.byFolder.values.reduce(0) { $0 + $1.count }
        return out
    }

    /// 把一趟扫描的结果并进库。四类事件分开算，用户才问得出「到底哪一类变了」
    /// （只给内部与 scanNow 用：外面拿到的是 Delta，不需要自己造 Harvest）
    @discardableResult
    private func merge(_ harvest: Harvest, scanned: [String]) -> Delta {
        var d = Delta()
        var held = Set(keys)
        // 一条引用落在哪个文件上就只能问一次（一万行库 × 几千个文件的字典不能算两遍）
        var byPath: [String: [String]] = [:]
        for k in keys { byPath[Self.path(ofKey: k), default: []].append(k) }
        for dir in scanned {
            // 没看完的那一片（取消了、或扫描一开始就已经在跑）一概不动它的引用：
            // 拿半截清单当全清单会把还在盘上的条目报成「没了」，下一趟又当新增加回来
            guard harvest.covered.contains(dir) else { continue }
            let found = harvest.byFolder[dir] ?? []
            let foundSet = Set(found)
            for k in found where !held.contains(k) && held.insert(k).inserted { d.added.append(k) }
            let before = keys.filter { Self.key($0, liesUnder: dir) }
            for k in before where !foundSet.contains(k) {
                if harvest.offline.contains(dir) {
                    d.invalid.append(k)
                } else {
                    d.removed.append(k)
                }
            }
            if harvest.offline.contains(dir) {
                offlineFolders.insert(dir)
            } else if offlineFolders.contains(dir) {
                // 盘回来了：库里那些重新扫到的就是恢复的
                offlineFolders.remove(dir)
                d.restored.append(contentsOf: before.filter { foundSet.contains($0) })
            }
        }
        // 修改：先拿旧的记账比，再更新记账。两张盘上同一个位置换了内容，
        // 不重新猜身份也不删引用（元数据重读就够）
        for (path, mtime) in harvest.mtimes {
            if let old = pathStamps[path], old != mtime { d.modified.append(contentsOf: byPath[path] ?? []) }
        }
        let gone = Set(d.removed)
        if !d.added.isEmpty || !gone.isEmpty {
            keys = Self.sortedKeys(keys.filter { !gone.contains($0) } + d.added)
        }
        // 只动这次看完的那几片：部分重扫与被取消的那一片都不该把别的记账清掉
        for dir in scanned where harvest.covered.contains(dir) {
            let prefix = dir.hasSuffix("/") ? dir : dir + "/"
            pathStamps = pathStamps.filter { !$0.key.hasPrefix(prefix) }
        }
        for (path, mtime) in harvest.mtimes { pathStamps[path] = mtime }
        if !d.changedKeys.isEmpty || !d.removed.isEmpty || !d.invalid.isEmpty {
            // 失效那几条也要播：整片盘拔走时 added / removed 都是空，只有 invalid 变了，
            // 不播这一句库页就永远停在拔盘之前那句「一切都好」
            NotificationCenter.default.post(name: .ttLibraryEntriesChanged, object: nil,
                                           userInfo: ["changed": Array(d.changedKeys.union(d.invalid)),
                                                      "removed": d.removed])
        }
        return d
    }

    /// 同步跑一趟（自检与「重新扫描某目录」的快捷路径）：直接走完后台 + 合并两段
    @discardableResult
    func scanNow(folders targets: [String]) -> Delta {
        let h = collectFolders(targets)
        let d = merge(h, scanned: targets)
        lastStats = h.stats
        return d
    }

    /// 一组路径 → 一组条目键：交给既有导入规则（cue 分轨、m3u 展开、归档拆条目都在这一步）
    private static func keys(from paths: [String]) -> [String] {
        var importer = LibraryStore.Importer()
        var out: [String] = []
        let sorted = paths.sorted {
            ($0 as NSString).lastPathComponent.localizedStandardCompare(
                ($1 as NSString).lastPathComponent) == .orderedAscending
        }
        // 每 400 个一批：一批收完就把 Track 对象抖掉，只留键（一万行的库不该把内存顶到天上去）
        var i = 0
        while i < sorted.count {
            let chunk = Array(sorted[i..<min(i + 400, sorted.count)])
            for path in chunk {
                importer.absorbScanned(URL(fileURLWithPath: path))
            }
            out.append(contentsOf: importer.result.tracks.map { $0.identityKey })
            importer.result = LibraryStore.ImportResult()
            i += 400
        }
        return out
    }

    /// 整表的稳定次序：按引用写法自然序。同一张盘里 cue 键（`x.cue#track=2`）要紧跟它的镜像，
    /// 所以按整串键排而不是按文件路径排；重扫前后同一个位置都在同一行
    private static func sortedKeys(_ keys: [String]) -> [String] {
        keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    // MARK: - 递归收集（隐藏文件、重复目录、符号链接循环都在这一关挡掉）

    /// 深度上限：正常的唱片目录到不了这一层，能到的一定是链接环
    private static let maxDepth = 32

    /// 返回 true = 被取消。progress 拿到「已看了多少个文件」（由调用方节流）
    @discardableResult
    static func walk(dir: String, into out: inout [String], extensions: Set<String>,
                     visitedDirs: inout Set<String>, visitedFiles: inout Set<String>,
                     depth: Int, stats: inout ScanStats, shouldCancel: () -> Bool,
                     progress: (Int) -> Void = { _ in }) -> Bool {
        if depth > maxDepth {
            stats.skippedDuplicates += 1
            Diagnostics.error("媒体库扫描：目录层级超过 \(maxDepth) 层，跳过 \(dir)（符号链接循环？）")
            return false
        }
        if let id = identity(ofDirectory: dir) {
            guard visitedDirs.insert(id).inserted else {
                stats.skippedDuplicates += 1
                return false
            }
        }
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else {
            // 读不了 = 没权限或磁盘断了。断盘由调用处的在线检查兜，这里只记账不猜
            Diagnostics.error("媒体库扫描：读不了目录 \(dir)")
            return false
        }
        for name in names.sorted() {
            if shouldCancel() { return true }
            // 隐藏文件（.DS_Store、._xxx、.git 里的东西）一概不进库
            if name.hasPrefix(".") || name.hasPrefix("._") { continue }
            let full = (dir as NSString).appendingPathComponent(name)
            var st = stat()
            guard lstat(full, &st) == 0 else { continue }
            if (st.st_mode & S_IFMT) == S_IFLNK {
                // 链接：指文件就当普通文件收（同一份文件的第二个链接会被 visitedFiles 挡掉），
                // 指目录就顺着走一次，走之前先查「这个目录是不是已经进过」——循环就在这一刻断掉
                var target = stat()
                guard stat(full, &target) == 0 else { continue }
                if (target.st_mode & S_IFMT) == S_IFDIR {
                    if shouldCancel() { return true }
                    // progress 也要递进去：否则链接目录里的文件不报扫描进度
                    _ = walk(dir: full, into: &out, extensions: extensions, visitedDirs: &visitedDirs,
                             visitedFiles: &visitedFiles, depth: depth + 1, stats: &stats,
                             shouldCancel: shouldCancel, progress: progress)
                    continue
                }
                if !extensions.contains((name as NSString).pathExtension.lowercased()) { continue }
                stats.filesScanned += 1
                progress(stats.filesScanned)
                if !visitedFiles.insert("\(target.st_dev)-\(target.st_ino)").inserted {
                    stats.skippedDuplicates += 1
                    continue
                }
                out.append(full)
                continue
            }
            if (st.st_mode & S_IFMT) == S_IFDIR {
                if shouldCancel() { return true }
                if walk(dir: full, into: &out, extensions: extensions, visitedDirs: &visitedDirs,
                        visitedFiles: &visitedFiles, depth: depth + 1, stats: &stats,
                        shouldCancel: shouldCancel, progress: progress) { return true }
                continue
            }
            guard extensions.contains((name as NSString).pathExtension.lowercased()) else { continue }
            stats.filesScanned += 1
            progress(stats.filesScanned)
            if !visitedFiles.insert("\(st.st_dev)-\(st.st_ino)").inserted {
                stats.skippedDuplicates += 1
                continue
            }
            out.append(full)
        }
        return false
    }

    // MARK: - 目录监控

    /// 给每个目录挂一条 FSEvents。事件不直接改成什么样，只当「这一片变了，去合并扫描一次」用：
    /// 逐事件增删要猜的事太多（改名、覆盖、批量拷贝半途），整目录重扫反而更准也更便宜
    func startWatching() {
        for dir in folders where streams[dir] == nil { startWatchingFolder(dir) }
    }

    func stopWatching() {
        for dir in Array(streams.keys) { stopWatchingFolder(dir) }
    }

    private func startWatchingFolder(_ dir: String) {
        guard streams[dir] == nil, Self.isDirectoryOnline(dir) else { return }
        var ctx = FSEventStreamContext(version: 0,
                                       info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let paths = [dir] as CFArray
        guard let stream = FSEventStreamCreate(kCFAllocatorDefault, { _, info, count, eventPaths, _, _ in
            guard let info, count > 0 else { return }
            let me = Unmanaged<MediaLibrary>.fromOpaque(info).takeUnretainedValue()
            let names = eventPaths.bindMemory(to: UnsafePointer<CChar>.self, capacity: Int(count))
            // 回调在专用队列：只把「哪个目录该重扫」递回主线程，不在这儿读盘
            let first = String(cString: names[0])
            me.queueFolderChange(first)
        }, &ctx, paths, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5,
           FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents)) else { return }
        FSEventStreamSetDispatchQueue(stream, watchQueue)
        FSEventStreamStart(stream)
        streams[dir] = stream
        Diagnostics.log("媒体库监控挂上：\(dir)")
    }

    private func stopWatchingFolder(_ dir: String) {
        guard let stream = streams.removeValue(forKey: dir) else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        Diagnostics.log("媒体库监控摘下：\(dir)")
    }

    /// 事件来了：先在主线程攒着，安静一秒多才动手（一次拷 500 首歌不该扫 500 趟）
    private func queueFolderChange(_ path: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // 事件给的是被改的那一项（可能是目录里的某个文件）：往上找到它属于哪个库目录
            guard let dir = self.folders.first(where: { Self.folder($0, holdsEventPath: path) })
            else { return }
            self.pendingMerge.insert(dir)
            self.mergeTimer?.invalidate()
            self.mergeTimer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: false) { [weak self] _ in
                guard let self else { return }
                let due = Array(self.pendingMerge)
                self.pendingMerge = []
                self.scan(folders: due)
            }
        }
    }

    /// 忘掉整个库（自检收摊用）：摘监控、清目录与引用与记账。
    /// 磁盘上的文件一个字都不动，也不碰歌单与队列
    func clearAll() {
        stopWatching()
        folders = []
        keys = []
        offlineFolders = []
        pathStamps = [:]
        pendingMerge = []
        mergeTimer?.invalidate()
        mergeTimer = nil
        lastStats = ScanStats()
        scanNote = ""
        isScanning = false
        cancelRequested = false
    }

    // MARK: - 重新定位（F08 的后半：文件搬走了，引用要跟过去）

    /// 一条引用在新目录下的写法。CUE 与归档**只换容器路径、保留条目身份**：
    /// `x.cue#track=3` 换目录后还是第 3 轨，归档条目的 `#archive-entry=` 也原样跟着
    static func rewrite(key: String, prefix old: String, to new: String) -> String? {
        let oldPrefix = old.hasSuffix("/") ? old : old + "/"
        let newPrefix = new.hasSuffix("/") ? new : new + "/"
        func swap(_ path: String) -> String? {
            guard path.hasPrefix(oldPrefix) else { return nil }
            return newPrefix + String(path.dropFirst(oldPrefix.count))
        }
        if let marker = key.range(of: LibraryStore.cueArchiveMarker) {
            // 普通文件键不含 `#track=`，这一支只管 CUE：轨号一个字都不动
            guard let moved = swap(String(key[..<marker.lowerBound])) else { return nil }
            return moved + String(key[marker.lowerBound...])
        }
        if key.hasPrefix("file://"), key.contains(Archive.entryFragmentMarker),
           let hash = key.firstIndex(of: "#") {
            // 归档条目：`file:///…zip#archive-entry=…`，只有外层归档那段是路径
            let container = String(key[..<hash])
            guard let url = URL(string: container), let moved = swap(url.path) else { return nil }
            return URL(fileURLWithPath: moved).absoluteString + String(key[hash...])
        }
        return swap(key)
    }

    /// 一条引用换到新的容器路径（换目录、改名都行），条目身份保留。
    /// 认不出这一类写法时返回 nil：宁可不改，也不要造出一条谁都解不开的键 ——
    /// 拿镜像 wav 去顶 CUE 轨、拿一首单曲去顶归档条目，都是这一关挡下来的
    static func relabel(key: String, to newPath: String) -> String? {
        if RadioURL.explicit(key) != nil { return nil }        // 电台没有盘上文件可言
        if let marker = key.range(of: LibraryStore.cueArchiveMarker) {
            guard (newPath as NSString).pathExtension.lowercased() == LibraryStore.cueExtension else {
                return nil
            }
            return newPath + String(key[marker.lowerBound...])
        }
        if key.hasPrefix("file://"), key.contains(Archive.entryFragmentMarker),
           let hash = key.firstIndex(of: "#") {
            guard AudioFormats.isArchive(URL(fileURLWithPath: newPath)) else { return nil }
            return URL(fileURLWithPath: newPath).absoluteString + String(key[hash...])
        }
        return newPath
    }

    /// 一批键里落在 old 下的都换成 new 下的写法（媒体库自己那一份）
    func planPrefixReplacement(old: String, new: String) -> [String: String] {
        planPrefixReplacement(old: old, new: new, extraKeys: [])
    }

    /// 同上，但把界面上正在看的键（歌单、收藏、队列…）一起算进来：
    /// 前缀替换必须一把覆盖所有档案，分两次改就会出现「歌单跟了、收藏没跟」
    func planPrefixReplacement(old: String, new: String, extraKeys: [String]) -> [String: String] {
        var map: [String: String] = [:]
        for key in Set(keys + extraKeys) {
            if let rewritten = Self.rewrite(key: key, prefix: old, to: new), rewritten != key {
                map[key] = rewritten
            }
        }
        return map
    }

    /// 换完前缀后有两个来源撞到同一条 → 歧义。绝不自己挑一个（需求点名）
    static func collisions(in map: [String: String]) -> [String: [String]] {
        var byTarget: [String: [String]] = [:]
        for (from, to) in map { byTarget[to, default: []].append(from) }
        return byTarget.filter { $0.value.count > 1 }
    }

    /// 目标位置已经有东西（同一首两次入表）也算歧义，得让用户先决定
    static func targetsAlreadyInLibrary(_ map: [String: String], keys: [String]) -> [String] {
        let held = Set(keys)
        return map.values.filter { held.contains($0) && !map.keys.contains($0) }.sorted()
    }

    /// 这一批替换会不会撞车：两条来源换成同一条，或者目标位置本来就已经被某份档案引用着。
    /// 任一种都不动东西 —— 需求点名「映射歧义时让用户选择」
    static func hasCollision(in map: [String: String], held: [String]) -> Bool {
        if !collisions(in: map).isEmpty { return true }
        return !targetsAlreadyInLibrary(map, keys: held).isEmpty
    }

    /// 在库里的目录中找同名文件，作为「重新定位」的候选。找到几个就给几个，
    /// 一个以上绝不当「就是它」——同名不同内容的文件在抓轨圈太常见了
    func candidates(sameNameAs key: String) -> [String] {
        let name = (MediaLibrary.path(ofKey: key) as NSString).lastPathComponent
        var hits: [String] = []
        for dir in folders where Self.isDirectoryOnline(dir) {
            var out: [String] = []
            var visitedDirs = Set<String>()
            var visitedFiles = Set<String>()
            var stats = ScanStats()
            _ = Self.walk(dir: dir, into: &out, extensions: Self.scanExtensions,
                          visitedDirs: &visitedDirs, visitedFiles: &visitedFiles,
                          depth: 0, stats: &stats, shouldCancel: { false })
            for path in out where (path as NSString).lastPathComponent == name {
                hits.append(path)
            }
        }
        return hits.sorted()
    }

    /// 把库里指向旧位置的那条换成新位置（只动库这一份，其他档案由控制器统一改）
    @discardableResult
    func replaceKey(_ old: String, with new: String) -> Bool {
        guard let i = keys.firstIndex(of: old) else { return false }
        keys[i] = new
        // 换了位置不等于内容变了：把那个文件的改动时间一起挪过去，
        // 不然下一趟扫描会把这条新引用报成「修改」
        let oldPath = Self.path(ofKey: old), newPath = Self.path(ofKey: new)
        if oldPath != newPath {
            if pathStamps[newPath] == nil, let mtime = pathStamps[oldPath] {
                pathStamps[newPath] = mtime
            }
            // 一份 cue / 归档里有好几条引用时，只剩这一条搬走的不能把记账抽走
            if !keys.contains(where: { Self.path(ofKey: $0) == oldPath }) {
                pathStamps[oldPath] = nil
            }
        }
        return true
    }

    // MARK: - 路径小工具

    /// 引用写法 → 它真正依赖的那个文件路径（CUE 轨是分轨表，归档条目是外层归档）
    static func path(ofKey key: String) -> String {
        if let marker = key.range(of: LibraryStore.cueArchiveMarker) {
            return String(key[..<marker.lowerBound])
        }
        if let url = URL(string: key), key.hasPrefix("file://"), Archive.parseEntryURL(url) != nil {
            return url.path
        }
        return key
    }

    /// 这条引用属不属于这个目录
    static func key(_ key: String, liesUnder dir: String) -> Bool {
        isDirectory(dir, parentOf: path(ofKey: key))
    }

    static func isDirectory(_ dir: String, parentOf path: String) -> Bool {
        let prefix = dir.hasSuffix("/") ? dir : dir + "/"
        return path.hasPrefix(prefix)
    }

    /// 这个库目录管不管得到事件里那条路径。不能只比字符串写法：FSEvents 报回来的是它自己
    /// 解析过的形式（`/tmp` 变成 `/private/tmp`、TMPDIR 变成 `/private/var/…`），而 `/private/var`
    /// 这一类既不会被 `standardizingPath` 也不会被 `resolvingSymlinksInPath` 折回去，
    /// 只比字符串会把外置盘与临时目录里的改动整批当不相干丢掉。写法对不上时逐层上溯比 inode：
    /// 那才是盘上的事实
    static func folder(_ dir: String, holdsEventPath path: String) -> Bool {
        if isDirectory(dir, parentOf: path) || dir == path { return true }
        guard let want = identity(ofDirectory: dir) else { return false }
        var cur = path
        // 最多上溯 16 层：一张唱片到不了这一层，能到的都是写法不同源
        for _ in 0..<16 {
            if cur.isEmpty || cur == "/" { break }
            if identity(ofDirectory: cur) == want { return true }
            cur = (cur as NSString).deletingLastPathComponent
        }
        return false
    }

    /// 同一个目录的两种写法（/tmp 与 /private/tmp、经过符号链接的路径）算一个
    static func sameDirectory(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        guard let ia = identity(ofDirectory: a), let ib = identity(ofDirectory: b) else { return false }
        return ia == ib
    }

    /// (卷号, inode)：目录身份的唯一可靠来源
    private static func identity(ofDirectory path: String) -> String? {
        var st = stat()
        guard stat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { return nil }
        return "\(st.st_dev)-\(st.st_ino)"
    }

    private static func mtime(of path: String) -> Date {
        (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? Date()
    }
}
