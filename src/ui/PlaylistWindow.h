#pragma once

// 播放列表窗（F04/F05 完整版）：左栏多页浏览器（收藏 + 各自建列表 + 全部）+
// 右栏「歌曲列表」——顶部标题行（标题 + 固定放大镜 + 可展开搜索框 + 计数），
// 下面是全自绘 PlaylistView；收藏用行内爱心，列表级操作（清空/排序/导出）在左栏右键，
// 歌曲右键管文件/电台资源本身 + 从列表移除（曲库非筛选态不给）。
//
// 分工：集合层 Collections 是各页内容的真相，
// 搜索命中只是临时把控制器列表换成命中表（pitfall #13）——清空关键字即从
// Collections.currentTracks() 还原，不依赖控制器自己「记得」原列表。

#include "playback/PlayerController.h"
#include "library/Collections.h"
#include "SkinWindow.h"
#include "PlaylistView.h"
#include <optional>

class SkinListView;
class SkinLineEdit;
class QLabel;
class QTimer;
class QMenu;
class QDropEvent;
class TTButton;
class PlaylistView;

class PlaylistWindow : public SkinWindow {
    Q_OBJECT
public:
    explicit PlaylistWindow(PlayerController *controller, Collections *collections, QWidget *parent = nullptr);

    /// 左栏那一列随列表增删 / 媒体库换页刷新（ MainWindow 载入后与每次开窗前调用）
    void refreshGroups();
    void refreshFavorites(); // 收藏改变后刷新当前页，保留搜索、选区和滚动现场。

    /// 展开并聚焦搜索框（Cmd+F 走这里）
    void focusSearch();

    // 无头截图探针：切页与按关键字搜索都走真实通路（左栏高亮、命中表、计数一起变）。
    void probeShowView(const QString &viewId) { showPage(viewId); }
    void probeSearch(const QString &text);

signals:
    /// 收藏 / 列表内容变了，外层据此重建索引 + 落盘
    void collectionsChanged();
    /// 从列表移走了一行（携带被移走的 Track）：外层据此记录内置电台黑名单
    void trackRemoved(const Track &track);
    /// 右键「添加文件…」：外层开文件对话框
    void addRequested();
    /// 右键「添加文件夹…」：外层选目录后整棵导入
    void addFolderRequested();
    /// 右键「添加网络电台…」：外层按地址添加网络电台
    void radioRequested();
    /// 右键「属性」：外层开曲目属性窗
    void propertiesRequested(const Track &track);
    /// 右键「转换为其他格式…」：外层开格式转换窗（可多选）
    void convertRequested(const QList<Track> &tracks);
    void editRequested(const Track &track);
    void radioAddressRequested(const Track &track);

protected:
    void paintBody(QPainter *p, const QRectF &rect) override;
    // 自建列表页拖入目录/音频时直接进此列表；其它页保持「导入媒体库」的原行为。
    void dropEvent(QDropEvent *event) override;

private:
    friend class RegressionTests;
    void showPage(const QString &viewId);           // 切页：退出搜索 + 控制器换成该页曲目
    void syncGroupSelection(const QString &viewId); // 只把左栏高亮对齐，不递归触发切页
    void removeRows(const QList<int> &rows);        // 快捷键从当前页移走选中行。
    void removeTracks(const QString &view, const QList<Track> &picked, bool searchHits = false);
    void reorderCurrentView(int target); // 拖拽：把选区整块移到 target 行前（仅存序页生效）
    void applySearch();                  // 关键字空=还原当前页；非空=换成命中表
    void clearSearch();                  // 收放大镜 + 清关键字 + 还原当前页
    QString selectedViewId() const;      // 左栏当前选中页的 viewId（无=全部页）
    void updateInfo();                   // 「共 N 首 · HH:MM:SS」计数
    void sortView(int key, const QString &viewId = {}); // 0-3 升序、4-7 降序、-1 还原。
    // 左栏菜单绑定目标 viewId 与右侧歌曲身份快照，不在打开菜单时切页。
    void buildSidebarMenu(QMenu &menu, const QString &viewId);
    void buildListMenu(QMenu *menu, const QString &viewId);
    void createPlaylist(); // 左栏新建弹窗、校验和切页流程。
    // 把外部目录/音频加进当前自建列表：后台走 Importer（目录递归、m3u/CUE 展开），
    // 读完注册进媒体库再写列表。非自建列表页给出提示。
    void addPathsToCurrentPlaylist(const QStringList &paths, const QString &viewId = {});
    // 注册 + 写入列表的同步核心（拖放/对话框/探针共用），返回真正新增的条数。
    int addTracksToPlaylist(const QList<Track> &tracks, const QString &playlistId);

    PlayerController *m_controller;
    Collections *m_collections;

    SkinListView *m_groups = nullptr;
    PlaylistView *m_view = nullptr;
    QLabel *m_caption = nullptr;
    TTButton *m_searchToggle = nullptr;
    SkinLineEdit *m_search = nullptr;
    QLabel *m_info = nullptr;
    QTimer *m_debounce = nullptr;
    bool m_searchOpen = false;
    std::optional<PlaylistView::Scene> m_beforeSearch;
    QSet<QString> m_formats;
};
