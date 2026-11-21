#pragma once

// 待播队列面板（F03）：上面一行写「正在播放」，
// 下面是待播条目表——拖动调整次序、多选「移除」、「清空待播」、双击某条直接播它。
// 面板只读 PlayQueue.pending()、写只经 PlayerController 的队列 API，绝不自己挪游标。

#include "playback/PlayerController.h"
#include "SkinWindow.h"

#include <QListWidget>
#include <QWidget>

class QLabel;
class TTButton;

// 待播表：拖动落点后通知外层提交新次序（QListWidget 内部移动不发 rowsMoved）
class QueueList : public QListWidget {
    Q_OBJECT
public:
    using QListWidget::QListWidget;
signals:
    void reordered();

protected:
    void dropEvent(QDropEvent *event) override;
};

class QueueWindow : public SkinWindow {
    Q_OBJECT
public:
    explicit QueueWindow(PlayerController *controller, QWidget *parent = nullptr);

    void reload(); // 从控制器队列重建「正在播放」行 + 待播表

private:
    void commitOrder(); // 把表里的次序写回队列（拖动重排后）

    PlayerController *m_controller;
    QLabel *m_current = nullptr;
    QLabel *m_info = nullptr;
    QueueList *m_list = nullptr;
    TTButton *m_remove = nullptr;
    TTButton *m_clear = nullptr;
    bool m_reloading = false; // 程序化重建期间不响应 reordered，防自激
};
