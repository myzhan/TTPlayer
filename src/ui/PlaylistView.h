#pragma once

// 播放列表（全自绘，照经典皮肤）：不显示系统表头，两列 ——
// 「序号. 艺术家 - 标题」+「时长」，当前行前面画 ▶ 并用亮蓝高亮。
// 只管高亮与选中，不负责推进（PlayQueue 是唯一真相，三层约束）。

#include "core/PlayerController.h"
#include "models/Track.h"

#include <QAbstractScrollArea>
#include <QList>
#include <QSet>

class Collections;
class QMenu;

class PlaylistView : public QAbstractScrollArea {
    Q_OBJECT
public:
    explicit PlaylistView(PlayerController *controller, QWidget *parent = nullptr);

    /// 传入集合层才能拼出「加入歌单」子菜单（为空时右键只列播放类动作）
    void setCollections(Collections *c) { m_collections = c; }

    void scrollToCurrent(); // 把正在播的那行滚进视野

    /// 当前鼠标选中的主行（无=-1）：单选时即那一行，多选时是最后点的那行
    int selectedRow() const { return m_selectedRow; }

    /// 全部选中行（升序）：右键批量动作据此对整段选区生效
    QList<int> selectedRows() const;

    /// 按修饰键更新选区（真实鼠标点击入口）：无=重设单行、Ctrl=切换、Shift=锚点到 row 的连续区间
    void selectAt(int row, Qt::KeyboardModifiers mods);

    /// 全选（Ctrl/Cmd+A 与探针入口）
    void selectAllRows();
    struct Scene {
        QStringList selected;
        int scroll = 0;
    };
    Scene scene() const;
    void restoreScene(const Scene &scene);
    void setSearching(bool active) { m_searching = active; }
    /// 搜索或格式筛选生效中：此时显示的不是整页原貌，右键里的整页动作（排序 / 清空）先不给
    void setFilterActive(bool active) { m_filterActive = active; }

    /// 空页时表中央的提示（来自 Collections::emptyHintFor）；空串=不画
    void setEmptyHint(const QString &hint) {
        m_emptyHint = hint;
        viewport()->update();
    }

signals:
    void propertiesRequested(const Track &track);
    void convertRequested(const QList<Track> &tracks); // 右键「转换为其他格式…」（可多选）
    void relocateRequested(const Track &track);
    void editRequested(const Track &track);
    void radioAddressRequested(const Track &track);
    void radioRetryRequested(const Track &track);
    void activateRow(int row);                          // 双击
    void removeRequested(const QList<int> &rows);       // 右键「从列表移除」（可多选）
    void enqueueNextRequested(const QList<int> &rows);  // 右键「下一首播放」
    void enqueueLaterRequested(const QList<int> &rows); // 右键「稍后播放」
    // 工具条已收进右键：页级的添加 / 列表 / 歌单三个子菜单由上层执行或现填
    void addFilesRequested();
    void addFolderRequested();
    void addRadioRequested();
    void sortRequested(int key); // 0-3 升序、4-7 降序、-1 还原
    void queueRequested();       // 「列表 / 待播队列」
    void clearListRequested();   // 「列表 / 清空当前列表」
    /// 「歌单」子菜单：本视图只管建菜单，内容由上层按当前页现填（哪些动作这一页真能做只有它知道）
    void playlistMenuRequested(QMenu *submenu);
    void addToListRequested(const QList<int> &rows, const QString &listId); // @fav 或自建歌单 id
    void toggleFavoriteRequested(const QList<int> &rows);                   // 收藏 / 取消收藏
    void radioAliasRequested(const QList<int> &rows); // 右键电台行「重命名台名…」（上层弹框取名）
    void radioMoveCategoryRequested(const QList<int> &rows,
                                    const QString &catId); // 移入分类（catId=未分类 id 则摘归属）
    void reorderRequested(int targetRow);                  // 拖拽：把当前选区整块移到 targetRow 前

protected:
    void paintEvent(QPaintEvent *) override;
    void resizeEvent(QResizeEvent *) override;
    void mousePressEvent(QMouseEvent *) override;
    void mouseMoveEvent(QMouseEvent *) override;
    void mouseReleaseEvent(QMouseEvent *) override;
    void mouseDoubleClickEvent(QMouseEvent *) override;
    void leaveEvent(QEvent *) override;
    void wheelEvent(QWheelEvent *) override;
    void keyPressEvent(QKeyEvent *) override;            // Delete 移除选中 / Ctrl+A 全选
    void contextMenuEvent(QContextMenuEvent *) override; // 右键菜单（见 buildContextMenu）

private:
    friend class RegressionTests; // 探针直接调用 buildContextMenu 核对菜单树
    bool m_searching = false;
    bool m_filterActive = false;
    /// 按当前环境拼右键菜单：row=-1 表示空白处（只给页级动作）；动作一律走 triggered 连接
    void buildContextMenu(QMenu &menu, int row);
    void reload();
    void updateScrollRange();
    int rowAtPos(const QPoint &p) const;
    int visibleRows() const;

    PlayerController *m_controller;
    Collections *m_collections = nullptr; // 只为「加入歌单」子菜单，可为空
    QList<Track> m_tracks;
    QString m_emptyHint;    // 当前页空着时的中央提示
    int m_currentRow = -1;  // 正在播的行（identityKey 匹配）
    int m_selectedRow = -1; // 鼠标选中的主行（多选时是最后点的那行）
    QSet<int> m_selection;  // 多选选区（含 m_selectedRow）
    int m_anchor = -1;      // Shift 扩展选区的锚点
    int m_hoverRow = -1;    // 鼠标悬停行（统一毛玻璃：静止不画、仅 hover 行轻亮）

    // 拖拽内部移动（按下→超过拖动阈值→释放到目标行）
    bool m_pressing = false;
    bool m_dragging = false;
    QPoint m_pressPos;
    int m_dragTarget = -1;

    static constexpr int kRowH = 24;
    static constexpr int kDurW = 62;
};
