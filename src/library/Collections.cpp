#include "Collections.h"

#include "media/CueSheet.h"
#include "media/Archive.h"

#include <QFileInfo>
#include <QSet>
#include <QUrl>
#include <QRegularExpression>

namespace {
// 电台条目的显示名统一走 RadioStations::displayName（自定义名 > 内置名 > 地址）；
// 非电台条目不动。
void nameRadio(Track &t, const RadioStations &radio) {
    if (t.isRadio()) t.setTitle(radio.displayName(t.url()));
}
} // namespace

void Collections::setAllTracks(const QList<Track> &tracks) {
    m_all = tracks;
    if (!m_defaultRestored) {
        m_defaultKeys.clear();
        for (const Track &track : tracks)
            if (!m_defaultKeys.contains(track.identityKey())) m_defaultKeys << track.identityKey();
    }
    m_byKey.clear();
    m_byKey.reserve(tracks.size());
    for (Track &t : m_all) {
        applyEdit(t);
        nameRadio(t, m_radio);
        m_byKey.insert(t.identityKey(), t);
    }
    invalidateIndex();
}

void Collections::registerTracks(const QList<Track> &tracks, bool addToDefault) {
    for (Track t : tracks) {
        applyEdit(t);
        nameRadio(t, m_radio);
        const QString key = t.identityKey();
        if (addToDefault && !m_defaultKeys.contains(key)) m_defaultKeys << key;
        if (m_byKey.contains(key)) {
            m_byKey[key] = t; // 覆盖为最新对象，@all 次序不动
            for (Track &m : m_all)
                if (m.identityKey() == key) {
                    m = t;
                    break;
                }
        } else {
            m_byKey.insert(key, t);
            m_all.append(t);
        }
    }
    invalidateIndex();
}

void Collections::removeSearchHits(const QSet<QString> &keys) {
    for (const QString &key : keys) {
        m_fav.removeAll(key);
        m_recent.removeAll(key);
        m_recentRadio.removeAll(key);
        for (const QString &id : m_lists.ids())
            m_lists.removeKeys({key}, id);
        removeTrackFromView(kAllViewId, key);
    }
    invalidateIndex();
}

bool Collections::removeTrackFromView(const QString &viewId, const QString &key) {
    if (key.isEmpty()) return false;
    if (viewId == kAllViewId) {
        const bool changed = m_defaultKeys.removeAll(key) > 0;
        if (changed && !m_libraryKeys.contains(key)) {
            m_byKey.remove(key);
            for (qsizetype i = m_all.size(); i-- > 0;)
                if (m_all[i].identityKey() == key) m_all.removeAt(i);
        }
        if (changed) invalidateIndex();
        return changed;
    }
    // @all 与 @radio / 各分类页（都投影自 @all 里电台那几条）删一行都是真删底层条目
    if (viewId == kAllViewId || viewId == kRadioViewId || isRadioCatView(viewId)) {
        m_defaultKeys.removeAll(key);
        bool changed = false;
        for (int i = 0; i < m_all.size(); ++i)
            if (m_all[i].identityKey() == key) {
                m_all.removeAt(i);
                changed = true;
                break;
            }
        m_byKey.remove(key);
        if (changed) invalidateIndex();
        return changed;
    }
    if (viewId == kFavViewId) {
        const int i = m_fav.indexOf(key);
        if (i < 0) return false;
        m_fav.removeAt(i);
        invalidateIndex();
        return true;
    }
    if (viewId == kRecentViewId) {
        const int i = m_recent.indexOf(key);
        if (i < 0) return false;
        m_recent.removeAt(i);
        invalidateIndex();
        return true;
    }
    if (viewId == kRecentRadioViewId) {
        const int i = m_recentRadio.indexOf(key);
        if (i < 0) return false;
        m_recentRadio.removeAt(i);
        invalidateIndex();
        return true;
    }
    // 媒体库页是「看得见才修得了」的只读投影：删行请先去菜单移除目录（调用处已拦）
    if (viewId == kLibraryViewId) return false;
    const int n = m_lists.removeKeys(QSet<QString>{key}, viewId);
    if (n > 0) invalidateIndex();
    return n > 0;
}

// 纯移动算法：把 selected 行作为整块（按原相对序）插到 target 行前，其余保序。
QStringList Collections::applyMove(const QStringList &displayed, const QSet<int> &selected, int target) {
    if (selected.isEmpty() || displayed.isEmpty()) return displayed;
    if (target < 0 || target > displayed.size()) return displayed;
    QStringList moved, remaining;
    for (int i = 0; i < displayed.size(); ++i) {
        if (selected.contains(i))
            moved.append(displayed[i]);
        else
            remaining.append(displayed[i]);
    }
    if (moved.isEmpty()) return displayed;
    int insertAt = 0; // 在 remaining 坐标下的插入点：target 前有多少非选中行
    for (int i = 0; i < target; ++i)
        if (!selected.contains(i)) ++insertAt;
    insertAt = qBound(0, insertAt, remaining.size());
    QStringList result;
    for (int i = 0; i < remaining.size(); ++i) {
        if (i == insertAt) result.append(moved);
        result.append(remaining[i]);
    }
    if (insertAt == remaining.size()) result.append(moved);
    return result;
}

// 拖拽重排落盘：先拿当前页的键序，验 order 是全排列后按页类型写回。
bool Collections::reorderView(const QString &viewId, const QStringList &order) {
    QStringList cur;
    if (viewId == kAllViewId)
        cur = m_defaultKeys;
    else if (viewId == kFavViewId) {
        cur = m_fav;
    } else if (viewId == kLibraryViewId || viewId == kRadioViewId || viewId == kRecentViewId ||
               viewId == kRecentRadioViewId || isRadioCatView(viewId))
        return false; // 派生页无存储序可改
    else
        cur = m_lists.keysOf(viewId); // 自建歌单
    if (order.size() != cur.size()) return false;
    const QSet<QString> curSet(cur.cbegin(), cur.cend());
    const QSet<QString> ordSet(order.cbegin(), order.cend());
    if (ordSet != curSet || ordSet.size() != order.size()) return false; // 必须恰为全排列，不丢不多
    if (viewId == kAllViewId) {
        QList<Track> reordered;
        reordered.reserve(order.size());
        for (const QString &k : order)
            reordered.append(m_byKey.value(k));
        m_defaultKeys = order;
        invalidateIndex();
        return true;
    }
    if (viewId == kFavViewId) {
        m_fav = order;
        invalidateIndex();
        return true;
    }
    const bool ok = m_lists.reorder(viewId, order);
    if (ok) invalidateIndex();
    return ok;
}

Track Collections::trackForKey(const QString &key) const {
    auto it = m_byKey.find(key);
    if (it != m_byKey.end()) return it.value();
    Track t = resolveToken(key);
    if (!t.isNull()) {
        const auto canonical = m_byKey.constFind(t.identityKey());
        if (canonical != m_byKey.cend()) return canonical.value();
    }
    applyEdit(t);
    // 不在 @all 的电台（如只在「最近听的台」/收藏里）resolveToken 只能给地址兜底名，
    // 这里补过一道 RadioStations：自定义名 > 内置名 > 地址，与 @all/@radio 口径一致。
    nameRadio(t, m_radio);
    return t;
}

// 唯一入口解析器：四种形态各自重建带完整身份的 Track（不探解码，只恢复 URL/cue 字段/台名）。
Track Collections::resolveToken(const QString &key) {
    if (key.isEmpty()) return Track();

    // CUE 分轨：`<sheet 本地路径>#track=N`
    const int h = key.indexOf(QLatin1Char('#'));
    if (h >= 0 && QStringView(key).mid(h + 1).startsWith(QLatin1String("track="))) {
        const QString sheetPart = key.left(h);
        const QUrl sheetUrl = QUrl::fromUserInput(sheetPart);
        const QString sheetPath = sheetUrl.isLocalFile() ? sheetUrl.toLocalFile() : sheetPart;
        bool okNum = false;
        const int num = key.mid(h + QStringLiteral("track=").size() + 1).toInt(&okNum);
        if (okNum) {
            const QList<Track> segs = CueSheet::toTracks(CueSheet::parseFile(sheetPath));
            for (const Track &t : segs)
                if (t.isCueSegment() && t.cueNumber() == num) return t; // 带真实起止/标题
        }
        // sheet 丢失 / 轨号解析不出：尽力退成镜像整轨，带失败原因（不假装恢复成功）
        Track mirror = Track::fromCueSegment(sheetUrl, num, sheetUrl, 0, -1);
        mirror.setDecodeProblem(QStringLiteral("分轨表不可用，无法恢复第 %1 段").arg(num));
        return mirror;
    }

    static const QRegularExpression drive(QStringLiteral("^[A-Za-z]:[/\\\\]"));
    if (drive.match(key).hasMatch() || key.startsWith(QLatin1String("\\\\"))) return Track(QUrl::fromLocalFile(key));
    const QUrl u(key);
    const QString scheme = u.scheme().toLower();
    if (scheme == QLatin1String("http") || scheme == QLatin1String("https")) return Track::fromRadio(u);
    if (u.hasFragment()) { // 归档条目 file://…#archive-entry=…
        QString archivePath, entryName;
        if (Archive::parseEntryUrl(u, archivePath, entryName)) {
            Track t(u);
            t.setTitle(QFileInfo(entryName).completeBaseName()); // 真实标签探测时覆盖
            return t;
        }
        return Track(u);
    }
    if (scheme == QLatin1String("file")) return Track(u);
    if (key.startsWith(QLatin1Char('/'))) return Track(QUrl::fromLocalFile(key));
    return Track(u);
}

bool Collections::isFavorite(const QString &key) const {
    return m_fav.contains(key);
}

void Collections::replaceLibrary(const QList<Track> &tracks) {
    QSet<QString> fresh;
    for (const Track &track : tracks)
        fresh.insert(track.identityKey());
    const QSet<QString> stale = m_libraryKeys - fresh;
    m_libraryKeys = fresh;
    for (const QString &key : stale) {
        if (m_defaultKeys.contains(key)) continue;
        m_byKey.remove(key);
        for (qsizetype i = m_all.size(); i-- > 0;)
            if (m_all[i].identityKey() == key) m_all.removeAt(i);
    }
    registerTracks(tracks, false);
    invalidateIndex();
}

bool Collections::replaceKey(const QString &oldKey, const Track &replacement) {
    if (replacement.isNull() || oldKey.isEmpty()) return false;
    const QString key = replacement.identityKey();
    if (key != oldKey && m_byKey.contains(key)) return false;
    if (oldKey != key && m_edits.contains(oldKey)) m_edits.insert(key, m_edits.take(oldKey));
    registerTracks({replacement}, false);
    auto rewrite = [&](QStringList &keys) {
        for (QString &value : keys)
            if (value == oldKey) value = key;
        keys.removeDuplicates();
    };
    rewrite(m_defaultKeys);
    rewrite(m_fav);
    rewrite(m_recent);
    rewrite(m_recentRadio);
    m_lists.replaceKeys({{oldKey, key}});
    m_radio.replaceKeys({{oldKey, key}});
    if (m_libraryKeys.remove(oldKey)) m_libraryKeys.insert(key);
    if (oldKey != key) {
        m_byKey.remove(oldKey);
        for (qsizetype i = m_all.size(); i-- > 0;)
            if (m_all[i].identityKey() == oldKey) m_all.removeAt(i);
    }
    refreshRadioTitles();
    invalidateIndex();
    return true;
}

bool Collections::toggleFavorite(const QString &key) {
    const int i = m_fav.indexOf(key);
    if (i >= 0) {
        m_fav.removeAt(i);
        invalidateIndex();
        return false;
    }
    m_fav.append(key);
    invalidateIndex();
    return true;
}

void Collections::applyEdit(Track &track) const {
    if (track.isNull()) return;
    const auto edit = m_edits.value(track.identityKey()).toObject();
    if (edit.contains("title")) track.setTitle(edit.value("title").toString());
    if (edit.contains("artist")) track.setArtist(edit.value("artist").toString());
    if (edit.contains("album")) track.setAlbum(edit.value("album").toString());
}
void Collections::editTrack(const QString &key, const QString &title, const QString &artist, const QString &album) {
    m_edits.insert(key, QJsonObject{{"title", title}, {"artist", artist}, {"album", album}});
    Track track = trackForKey(key);
    applyEdit(track);
    invalidateIndex();
}

// 「最近的挤到最前，多余的从尾巴剪掉」——两份历史档案同一条规矩
static void touchKey(const QString &key, QStringList &list, int limit) {
    if (key.isEmpty()) return;
    list.removeAll(key);
    list.prepend(key);
    while (list.size() > limit)
        list.removeLast();
}

void Collections::recordPlay(const QString &key) {
    if (key.isEmpty()) return;
    touchKey(key, m_recent, kRecentLimit);
    invalidateIndex();
}

void Collections::recordRadioPlay(const QString &key) {
    if (key.isEmpty()) return;
    touchKey(key, m_recentRadio, kRecentRadioLimit);
    invalidateIndex();
}

// 台名/分类变了：把 @all 里电台条目的标题按 displayName 重刷（自定义 > 内置 > 地址）
void Collections::refreshRadioTitles() {
    for (Track &t : m_all)
        nameRadio(t, m_radio);
    // m_byKey 与 m_all 共享同一 Track 对象（隐式共享），刷新后键不变（电台 identityKey = 地址）
    invalidateIndex();
}

int Collections::radioCountIn(const QString &catId) const {
    return tracksOf(radioCatViewId(catId)).size();
}

int Collections::updateRadioAddress(const QString &oldKey, const QString &newKey) {
    if (oldKey.isEmpty() || newKey.isEmpty() || oldKey == newKey) return 0;
    const int n = m_radio.replaceKeys({{oldKey, newKey}}); // 台名 + 归属
    invalidateIndex();
    return n;
}

QList<Track> Collections::tracksOf(const QString &viewId) const {
    if (viewId == kAllViewId) {
        QList<Track> result;
        for (const QString &key : m_defaultKeys)
            result << trackForKey(key);
        return result;
    }
    if (viewId == kRadioViewId) {
        QList<Track> out;
        for (const Track &t : m_all)
            if (t.isRadio()) out.append(t);
        return out;
    }
    if (isRadioCatView(viewId)) {
        // 分类页 = @all 里电台地址按归属分组投影（与 @radio 同一批对象）
        const QString id = radioCatIdOf(viewId);
        const bool uncat = (id == RadioStations::uncategorizedID);
        QList<Track> out;
        for (const Track &t : m_all) {
            if (!t.isRadio()) continue;
            const QString cid = m_radio.categoryIDOf(t.identityKey());
            if (uncat ? cid.isEmpty() : cid == id) out.append(t);
        }
        return out;
    }
    if (viewId == kLibraryViewId) {
        QList<Track> out;
        // 按 @all 次序取扫描子集，别用 QSet 迭代的不确定序
        for (const Track &t : m_all)
            if (m_libraryKeys.contains(t.identityKey())) out.append(t);
        return out;
    }
    if (viewId == kRecentViewId) {
        QList<Track> out;
        out.reserve(m_recent.size());
        for (const QString &k : m_recent)
            out.append(trackForKey(k));
        return out;
    }
    if (viewId == kRecentRadioViewId) {
        QList<Track> out;
        out.reserve(m_recentRadio.size());
        for (const QString &k : m_recentRadio)
            out.append(trackForKey(k));
        return out;
    }
    if (viewId == kFavViewId) {
        QList<Track> out;
        out.reserve(m_fav.size());
        for (const QString &k : m_fav)
            out.append(trackForKey(k));
        return out;
    }
    QList<Track> out;
    const QStringList keys = m_lists.keysOf(viewId);
    out.reserve(keys.size());
    for (const QString &k : keys)
        out.append(trackForKey(k));
    return out;
}

QList<Track> Collections::currentTracks() const {
    return tracksOf(m_view);
}

QList<QPair<QString, QString>> Collections::viewList() const {
    QList<QPair<QString, QString>> out;
    // 固定页永远按这个次序排在最前（对齐参考图 playlist.png），自建歌单跟在后面
    out.append({kAllViewId, QStringLiteral("[默认]")});
    out.append({kLibraryViewId, QStringLiteral("媒体库")});
    out.append({kRadioViewId, QStringLiteral("网络电台")});
    out.append({kRecentRadioViewId, QStringLiteral("最近听的台")});
    out.append({kRecentViewId, QStringLiteral("最近播放")});
    out.append({kFavViewId, QStringLiteral("我的收藏")});
    // 未分类电台是默认入口、永远在（不由用户创建，这里补在前面），其后跟各分类（创建序）
    out.append({radioCatViewId(RadioStations::uncategorizedID), QStringLiteral("未分类电台")});
    for (const RadioCategory &c : m_radio.categories())
        out.append({radioCatViewId(c.id), c.name});
    for (const UserPlaylist &p : m_lists.items())
        out.append({p.id, p.name});
    return out;
}

QString Collections::emptyHintFor(const QString &viewId) {
    if (viewId == kAllViewId) return QString(); // [默认] 保持原版，空着什么都不画
    if (viewId == kLibraryViewId) return QStringLiteral("菜单「媒体库」→ 添加音乐目录，扫到的歌就在这一页");
    if (viewId == kRadioViewId) return QStringLiteral("工具条「电台」键添加地址，或拖入带 http 行的 m3u");
    if (viewId == kRecentRadioViewId) return QStringLiteral("还没有听过的台");
    if (viewId == kRecentViewId) return QStringLiteral("还没有播放记录");
    if (viewId == kFavViewId) return QStringLiteral("右键曲目 → 加入收藏，或按 ⌘D");
    if (isRadioCatView(viewId)) return QStringLiteral("在电台页右键台 → 移入分类，归到这一类的台就在这一页");
    return QStringLiteral("右键曲目 → 加入歌单，或右键这里导入 m3u"); // 自建歌单
}

QList<SearchPage> Collections::buildPages() const {
    QList<SearchPage> pages;
    pages.append({QStringLiteral("[默认]"), tracksOf(kAllViewId)});
    pages.append({QStringLiteral("媒体库"), tracksOf(kLibraryViewId)});
    pages.append({QStringLiteral("网络电台"), tracksOf(kRadioViewId)});
    pages.append({QStringLiteral("最近听的台"), tracksOf(kRecentRadioViewId)});
    pages.append({QStringLiteral("最近播放"), tracksOf(kRecentViewId)});
    pages.append({QStringLiteral("我的收藏"), tracksOf(kFavViewId)});
    pages.append({QStringLiteral("未分类电台"), tracksOf(radioCatViewId(RadioStations::uncategorizedID))});
    for (const RadioCategory &c : m_radio.categories())
        pages.append({c.name, tracksOf(radioCatViewId(c.id))});
    for (const UserPlaylist &p : m_lists.items())
        pages.append({p.name, tracksOf(p.id)});
    return pages;
}

void Collections::rebuildIndex() {
    m_search.build(buildPages());
}

SearchResult Collections::search(const TrackFilter &filter) const {
    if (m_search.isStale()) m_search.build(buildPages()); // m_search 为 mutable
    return m_search.matches(filter);
}

QStringList Collections::pagesOf(const QString &key) const {
    return m_search.pagesOf(key);
}

void Collections::loadFrom(const LibraryStore::Loaded &s) {
    m_defaultRestored = s.hasDefaultKeys;
    m_defaultKeys = s.defaultKeys;
    m_libraryKeys = QSet<QString>(s.libraryKeys.cbegin(), s.libraryKeys.cend());
    m_lists.restore(s.userLists);
    m_edits = s.trackEdits;
    m_radio.restore(s.radioAliases, s.radioCategories, s.radioAssignments);
    // 收藏去重保序
    auto dedup = [](const QStringList &in) {
        QStringList out;
        QSet<QString> seen;
        for (const QString &k : in)
            if (!k.isEmpty() && !seen.contains(k)) {
                seen.insert(k);
                out.append(k);
            }
        return out;
    };
    m_fav = dedup(s.favoriteKeys);
    // 两份历史：同样去重保序（最近的在前）
    m_recent = dedup(s.recentKeys);
    m_recentRadio = dedup(s.recentRadioKeys);
    // 上次在看的页：解不开（旧档缺、或那张歌单已删）一律回 [默认]
    const QString v = s.viewListID;
    if (v == QLatin1String("library"))
        m_view = kLibraryViewId;
    else if (v == QLatin1String("radio"))
        m_view = kRadioViewId;
    else if (v == QLatin1String("recentRadio"))
        m_view = kRecentRadioViewId;
    else if (v == QLatin1String("recent"))
        m_view = kRecentViewId;
    else if (v == QLatin1String("favorites"))
        m_view = kFavViewId;
    else if (v.startsWith(QLatin1String("playlist:"))) {
        const QString id = v.mid(QStringLiteral("playlist:").size());
        m_view = m_lists.contains(id) ? id : kAllViewId;
    } else if (v.startsWith(kRadioCatPrefix)) {
        // 停在电台分类页：未分类那一格永不删；已删分类回 [默认]
        const QString cid = v.mid(kRadioCatPrefix.size());
        m_view = (cid == RadioStations::uncategorizedID || m_radio.contains(cid)) ? v : kAllViewId;
    } else if (!v.isEmpty() && m_lists.contains(v)) {
        m_view = v; // 兼容早期 Qt 直存裸 UUID 的写法
    } else {
        m_view = kAllViewId;
    }
    invalidateIndex();
}

void Collections::saveTo(LibraryStore::Loaded &s) const {
    s.hasDefaultKeys = true;
    s.defaultKeys = m_defaultKeys;
    s.libraryKeys = m_libraryKeys.values();
    s.userLists = m_lists.snapshot();
    s.trackEdits = m_edits;
    s.favoriteKeys = m_fav;
    s.recentKeys = m_recent;
    s.recentRadioKeys = m_recentRadio;
    s.radioAliases = m_radio.snapshotAliases();
    s.radioCategories = m_radio.snapshotCategories();
    s.radioAssignments = m_radio.snapshotAssigned();
    // 当前浏览组用旧档写法跨进程记住：固定页用名字，歌单页用 playlist:<id>
    // 兜底回 [默认] 页，先赋默认值避免 if 链首尾重复分支
    s.viewListID = QStringLiteral("main");
    if (m_view == kLibraryViewId)
        s.viewListID = QStringLiteral("library");
    else if (m_view == kRadioViewId)
        s.viewListID = QStringLiteral("radio");
    else if (m_view == kRecentRadioViewId)
        s.viewListID = QStringLiteral("recentRadio");
    else if (m_view == kRecentViewId)
        s.viewListID = QStringLiteral("recent");
    else if (m_view == kFavViewId)
        s.viewListID = QStringLiteral("favorites");
    else if (isRadioCatView(m_view))
        s.viewListID = m_view; // 已是 radioCat:<id>
    else if (m_lists.contains(m_view))
        s.viewListID = QStringLiteral("playlist:") + m_view;
}
