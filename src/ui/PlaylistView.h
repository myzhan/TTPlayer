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

    /// 空页时表中央的提示（来自 Collections::emptyHintFor）；空串=不画
    void setEmptyHint(const QString &hint) {
        m_emptyHint = hint;
        viewport()->update();
    }

signals:
    void propertiesRequested(const Track &track);
    void relocateRequested(const Track &track);
    void editRequested(const Track &track);
    void radioAddressRequested(const Track &track);
    void radioRetryRequested(const Track &track);
    void activateRow(int row);                          // 双击
    void removeRequested(const QList<int> &rows);       // 右键「从列表移除」（可多选）
    void enqueueNextRequested(const QList<int> &rows);  // 右键「下一首播放」
    void enqueueLaterRequested(const QList<int> &rows); // 右键「稍后播放」
    // 工具条已收进右键：添加 / 排序 / 模式 / 队列 / 歌单管理由上层执行或弹子菜单
    void addFilesRequested();
    void addFolderRequested();
    void addRadioRequested();
    void queueRequested();
    void sortRequested(int key);                         // 0-3 升序、4-7 降序、-1 还原
    void playlistMenuRequested(const QPoint &globalPos); // 「歌单管理…」在鼠标位置弹菜单
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
    void contextMenuEvent(QContextMenuEvent *) override; // 右键：从列表移除

private:
    bool m_searching = false;
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
