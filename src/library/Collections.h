#pragma once

// 集合层（F04/F05）：把「注册过的曲目 + 收藏 + 自建歌单」装配成左栏那一列可切换的页，
// 并驱动 GlobalSearch。控制器只管「当前在看的那一页」，页的取舍、键→Track 还原、跨页搜索
// 都集中在这里——组页 + GlobalSearch 判定的分工。
//
// 约定 viewId：@all=媒体库/当前，@fav=收藏，其余=某张自建歌单的 id。

#include "GlobalSearch.h"
#include "LibraryStore.h"
#include "models/RadioStations.h"
#include "models/Track.h"
#include "models/UserPlaylist.h"

#include <QHash>
#include <QList>
#include <QPair>
#include <QSet>
#include <QString>
#include <QStringList>

class Collections {
public:
    static inline const QString kAllViewId = QStringLiteral("@all"); // [默认] 工作列表
    static inline const QString kFavViewId = QStringLiteral("@fav"); // 我的收藏
    // 派生固定页（内容由投影或档案算出，歌单 UUID 永不以 @ 开头 → 不会撞车）
    static inline const QString kLibraryViewId = QStringLiteral("@library"); // 媒体库（扫描子集）
    static inline const QString kRadioViewId = QStringLiteral("@radio"); // 网络电台（@all 里 isRadio 投影）
    static inline const QString kRecentRadioViewId = QStringLiteral("@recentRadio"); // 最近听的台
    static inline const QString kRecentViewId = QStringLiteral("@recent");           // 最近播放
    // 电台分类页（R11/F13）：都是 @all 里电台地址按 RadioStations 归属的投影，与 @radio 同源。
    // viewId = "radioCat:" + 分类 id；未分类 id = RadioStations::uncategorizedID（默认入口、删不掉）。
    static inline const QString kRadioCatPrefix = QStringLiteral("radioCat:");
    static bool isRadioCatView(const QString &viewId) { return viewId.startsWith(kRadioCatPrefix); }
    static QString radioCatViewId(const QString &catId) { return kRadioCatPrefix + catId; }
    static QString radioCatIdOf(const QString &viewId) { return viewId.mid(kRadioCatPrefix.size()); }

    static constexpr int kRecentLimit = 50;      // 最近播放留多少首
    static constexpr int kRecentRadioLimit = 20; // 最近听的台留多少个

    // MARK: 注册表（媒体库/当前页）
    /// 登记曲目（按 identityKey 建索引，重复键覆盖为最新对象），并作为「@all」页内容
    void setAllTracks(const QList<Track> &tracks);
    const QList<Track> &allTracks() const { return m_all; }
    /// 把额外曲目补进注册表（不改变 @all 次序里已有的，只在缺时追加）
    void registerTracks(const QList<Track> &tracks, bool addToDefault = true);
    void replaceLibrary(const QList<Track> &tracks);
    bool replaceKey(const QString &oldKey, const Track &replacement);
    void editTrack(const QString &key, const QString &title, const QString &artist, const QString &album);
    /// 从指定视图移走一行（按稳定身份）：@all 删注册表、@fav 取消收藏、
    /// 自建歌单删键。只影响这一页，不动其它页/队列/磁盘。返回是否真删了
    void removeSearchHits(const QSet<QString> &keys);
    bool removeTrackFromView(const QString &viewId, const QString &key);
    /// 把某页重排为新键序（拖拽）：@all 改 m_all、@fav 改 m_fav、自建歌单走
    /// playlists().reorder。派生页（@library/@radio/@recent/@recentRadio）无存储序可改，返回 false。
    /// order 必须是当前页键集的一个全排列，否则拒绝（不丢条目）。
    bool reorderView(const QString &viewId, const QStringList &order);
    /// 纯移动算法（拖拽落点→新序）：把 displayed 中 selected 行作为整块搬到 target 行前，
    /// 其余保序；selected 为空或越界则原样返回。供 UI 与探针共用，不依赖任何状态。
    static QStringList applyMove(const QStringList &displayed, const QSet<int> &selected, int target);
    /// 键 → Track：优先拿注册表里的完整对象（带 CUE/归档/元数据），
    /// 不在表里的按键形态尽力还原（电台/归档条目/普通路径），还原不了的返回 null Track
    Track trackForKey(const QString &key) const;

    /// 唯一的 token→Track 解析器（R04）：普通文件 / file:// / 电台 http(s) / 归档
    /// `#archive-entry=` / CUE 分轨 `<sheet 本地路径>#track=N`（重读 sheet 恢复段起止与标题）。
    /// 导入 / 歌单 / 收藏 / 存档 / 重定位共用，不再各处字符串截断假装恢复。
    static Track resolveToken(const QString &key);

    // MARK: 收藏
    const QStringList &favorites() const { return m_fav; }
    bool isFavorite(const QString &key) const;
    /// 切换收藏，返回切换后是否为收藏
    bool toggleFavorite(const QString &key);

    // MARK: 媒体库页（扫描贡献的键，由 MainWindow 同步）
    void setLibraryKeys(const QSet<QString> &keys) { m_libraryKeys = keys; }
    const QSet<QString> &libraryKeys() const { return m_libraryKeys; }

    // MARK: 最近播放 / 最近听的台（F06）
    const QStringList &recentKeys() const { return m_recent; }
    const QStringList &recentRadioKeys() const { return m_recentRadio; }
    /// 开播记一笔：已在历史里先摘掉再插到最前，超上限从尾巴剪
    void recordPlay(const QString &key);
    /// 听过的台另记一份（仅电台）：台不像本地文件删了就找不回，地址本身就是内容
    void recordRadioPlay(const QString &key);

    // MARK: 歌单仓库
    UserPlaylists &playlists() { return m_lists; }
    const UserPlaylists &playlists() const { return m_lists; }

    // MARK: 电台档案（R13）：台名 / 分类 / 归属，@radio 与各分类页都是它的投影
    RadioStations &radios() { return m_radio; }
    const RadioStations &radios() const { return m_radio; }
    /// 台名/分类变了之后的统一收尾：把 @all 里电台条目的 title 按 displayName 重刷
    /// （自定义名 > 内置名 > 地址），并让搜索索引跟上。分类页只读投影，不需重刷。
    void refreshRadioTitles();
    /// 分类页实际列出的台数（归属表与列表里真有的台求交），菜单标题与删除确认说真数字
    int radioCountIn(const QString &catId) const;
    /// 改了电台地址（换身份）：把台名与归属从旧地址搬到新地址，刷新台名。返回搬动项数。
    int updateRadioAddress(const QString &oldKey, const QString &newKey);

    // MARK: 当前视图
    QString viewId() const { return m_view; }
    void setViewId(const QString &id) { m_view = id; }
    /// 当前视图对应的曲目（按 viewId 解析键→对象）
    QList<Track> currentTracks() const;
    /// 指定 viewId 的曲目
    QList<Track> tracksOf(const QString &viewId) const;

    // MARK: 左栏那一列（固定页 + 可变歌单页）
    QList<QPair<QString, QString>> viewList() const; // (viewId, 显示名)
    /// 这一页空着时表格中央那句提示；[默认] 保持原版什么都不画
    static QString emptyHintFor(const QString &viewId);

    // MARK: 全局搜索
    /// 内容变了（注册/收藏/歌单增删）后重建索引
    void invalidateIndex() { m_search.invalidate(); }
    void rebuildIndex();
    SearchResult search(const TrackFilter &filter) const;
    QStringList pagesOf(const QString &key) const;

    // MARK: 持久化
    void loadFrom(const LibraryStore::Loaded &s);
    void saveTo(LibraryStore::Loaded &s) const;

private:
    void applyEdit(Track &track) const;
    QJsonObject m_edits;
    QList<SearchPage> buildPages() const; // 收藏 + 各歌单 + 全部（索引与搜索共用）

    QList<Track> m_all;
    QStringList m_defaultKeys;
    bool m_defaultRestored = false;
    QHash<QString, Track> m_byKey;
    UserPlaylists m_lists;
    QStringList m_fav;
    QStringList m_recent;        // 最近播过的键，最近的在最前
    QStringList m_recentRadio;   // 最近听过的台地址，最近的在最前
    QSet<QString> m_libraryKeys; // 扫描贡献的键（媒体库页内容）
    RadioStations m_radio;       // 电台台名 / 分类 / 归属（R13）
    QString m_view = kAllViewId;
    mutable GlobalSearch m_search;
};
