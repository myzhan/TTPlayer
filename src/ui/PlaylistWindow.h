#pragma once

// 播放列表窗（F04/F05 完整版）：左栏多页浏览器（收藏 + 各自建歌单 + 全部）+
// 右栏「歌曲列表」——顶部标题行（标题 + 固定放大镜 + 可展开搜索框 + 计数）、
// 工具条对齐参考图（添加/电台/删除/列表▾/排序▾/编辑/模式▾/队列）、下面是全自绘 PlaylistView。
//
// 分工（对齐 Swift PlaylistPanelController）：集合层 Collections 是各页内容的真相，
// 搜索命中只是临时把控制器列表换成命中表（pitfall #13）——清空关键字即从
// Collections.currentTracks() 还原，不依赖控制器自己「记得」原列表。

#include "core/PlayerController.h"
#include "core/Collections.h"
#include "SkinWindow.h"
#include "PlaylistView.h"
#include <optional>

class SkinListView;
class SkinLineEdit;
class QLabel;
class QTimer;
class QMenu;
class TTButton;
class PlaylistView;

class PlaylistWindow : public SkinWindow {
    Q_OBJECT
public:
    explicit PlaylistWindow(PlayerController *controller, Collections *collections,
                            QWidget *parent = nullptr);

    /// 左栏那一列随歌单增删 / 媒体库换页刷新（ MainWindow 载入后与每次开窗前调用）
    void refreshGroups();

    /// 展开并聚焦搜索框（Cmd+F 走这里）
    void focusSearch();

signals:
    /// 收藏 / 歌单内容变了，外层据此重建索引 + 落盘
    void collectionsChanged();
    /// 从列表移走了一行（携带被移走的 Track）：外层据此记录内置电台黑名单
    void trackRemoved(const Track &track);
    /// 点了「队列」键：外层懒建 / 开关待播队列面板
    void queueRequested();
    /// 点了「添加」键：外层开文件 / 文件夹对话框
    void addRequested();
    /// 点了「电台」键：外层按地址添加网络电台
    void radioRequested();
    /// 点了「编辑」键：外层开当前曲目属性窗
    void propertiesRequested(const Track &track);
    void relocateRequested(const Track &track);
    void editRequested(const Track &track);
    void radioAddressRequested(const Track &track);

protected:
    void paintBody(QPainter *p, const QRectF &rect) override;

private:
    friend class RegressionTests;
    void showPage(const QString &viewId);   // 切页：退出搜索 + 控制器换成该页曲目
    void syncGroupSelection(const QString &viewId);   // 只把左栏高亮对齐，不递归触发切页
    void removeRows(const QList<int> &rows);   // 从当前页移走选中行（可多选，不动其它页 / 磁盘）
    void reorderCurrentView(int target);       // 拖拽：把选区整块移到 target 行前（仅存序页生效）
    void applySearch();                     // 关键字空=还原当前页；非空=换成命中表
    void clearSearch();                     // 收放大镜 + 清关键字 + 还原当前页
    QString selectedViewId() const;         // 左栏当前选中页的 viewId（无=全部页）
    void updateInfo();                      // 「共 N 首 · MM:SS」计数
    void sortView(int key);                 // 当前页显示排序：0=标题 1=艺术家 2=专辑 3=时长 -1=还原
    void deleteSelectedRow();               // 工具条「删除」：移除选中行（复用 removeRows）
    void buildListMenu();                   // 「列表」下拉：新建/导入/导出/重命名/删除歌单
    void buildSortMenu();                   // 「排序」下拉
    void buildModeMenu();                   // 「模式」下拉（随当前 mode 勾选）

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

    // 工具条下拉菜单（懒建，点击时在按钮下方 exec）
    QMenu *m_listMenu = nullptr;
    QMenu *m_sortMenu = nullptr;
    QMenu *m_modeMenu = nullptr;
    TTButton *m_listBtn = nullptr;
    TTButton *m_sortBtn = nullptr;
    TTButton *m_modeBtn = nullptr;
};
