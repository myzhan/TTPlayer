#include "QueueWindow.h"
#include "SkinParts.h"
#include "Theme.h"

#include <QVBoxLayout>
#include <QHBoxLayout>
#include <QLabel>
#include <QDropEvent>
#include <QUuid>
#include <QSet>

namespace {

// 「艺术家 - 标题」，缺项回落文件名（对齐 Swift QueuePanelController.displayName）
QString displayName(const Track &t) {
    if (t.artist().isEmpty()) return t.title().isEmpty() ? t.fileName() : t.title();
    return t.artist() + QStringLiteral(" - ") + (t.title().isEmpty() ? t.fileName() : t.title());
}

// 时长列文字：电台「直播」，未知「...」，否则 mm:ss
QString durText(const Track &t) {
    if (t.isRadio()) return QStringLiteral("直播");
    if (t.duration() <= 0) return QStringLiteral("...");
    const int s = int(t.duration() + 0.5);
    return QStringLiteral("%1:%2").arg(s / 60).arg(s % 60, 2, 10, QLatin1Char('0'));
}

} // namespace

void QueueList::dropEvent(QDropEvent *event) {
    QListWidget::dropEvent(event);
    emit reordered();
}

QueueWindow::QueueWindow(PlayerController *controller, QWidget *parent)
    : SkinWindow(QStringLiteral("待播队列"), true, parent), m_controller(controller) {
    resize(420, 320 + 30);   // 高度补上自绘标题条（~30）
    setMinimumSize(300, 180);

    auto *root = new QVBoxLayout(body());
    root->setContentsMargins(10, 8, 10, 8);
    root->setSpacing(6);

    // 顶部：正在播放 + 计数 + 移除 / 清空
    auto *top = new QHBoxLayout();
    top->setSpacing(8);
    m_current = new QLabel(QStringLiteral("正在播放：无"), this);
    m_current->setFont(Fonts::small);
    m_current->setStyleSheet(QStringLiteral("color:%1;background:transparent;")
                                 .arg(Theme::inkOnGlassAccent.name()));
    m_info = new QLabel(QStringLiteral("待播 0 首"), this);
    m_info->setStyleSheet(QStringLiteral("color:%1;background:transparent;")
                              .arg(Theme::inkOnGlassSoft.name()));
    m_remove = new TTButton(this);
    m_remove->setTextLabel(QStringLiteral("移除"));
    m_remove->setFace(TTButton::Face::Glass);
    m_remove->setPreferredSize({44, 20});
    m_remove->setToolTip(QStringLiteral("移除选中的待播条目（正在播的不受影响）"));
    m_clear = new TTButton(this);
    m_clear->setTextLabel(QStringLiteral("清空待播"));
    m_clear->setFace(TTButton::Face::Glass);
    m_clear->setPreferredSize({64, 20});
    m_clear->setToolTip(QStringLiteral("清空待播：当前曲继续播完就收手"));
    top->addWidget(m_current, 1);
    top->addWidget(m_info);
    top->addWidget(m_remove);
    top->addWidget(m_clear);
    root->addLayout(top);

    m_list = new QueueList(this);
    m_list->setFrameShape(QFrame::NoFrame);
    m_list->setSelectionMode(QAbstractItemView::ExtendedSelection);
    m_list->setDragDropMode(QAbstractItemView::InternalMove);
    m_list->setDefaultDropAction(Qt::MoveAction);
    m_list->setStyleSheet(QStringLiteral(
        "QListWidget{background:transparent;color:%1;border:none;outline:0;}"
        "QListWidget::item{height:22px;padding-left:6px;border-radius:3px;}"
        "QListWidget::item:selected{background:rgba(27,94,158,60);color:%2;}"
        "QListWidget::item:hover{background:rgba(111,155,198,66);}"
        "QScrollBar:vertical{background:transparent;width:8px;margin:0;}"
        "QScrollBar::handle:vertical{background:rgba(81,102,127,120);border-radius:3px;min-height:20px;}"
        "QScrollBar::add-line:vertical,QScrollBar::sub-line:vertical{height:0;}"
        "QScrollBar::add-page:vertical,QScrollBar::sub-page:vertical{background:transparent;}")
        .arg(Theme::inkOnGlass.name(), Theme::inkOnGlassAccent.name()));
    root->addWidget(m_list, 1);

    connect(m_remove, &TTButton::clicked, this, [this] {
        QSet<QUuid> ids;
        for (QListWidgetItem *it : m_list->selectedItems())
            ids.insert(QUuid::fromString(it->data(Qt::UserRole).toString()));
        if (!ids.isEmpty()) m_controller->removeQueued(ids);
    });
    connect(m_clear, &TTButton::clicked, this, [this] { m_controller->clearPendingQueue(); });
    connect(m_list, &QListWidget::itemDoubleClicked, this, [this](QListWidgetItem *it) {
        if (it) m_controller->playQueued(QUuid::fromString(it->data(Qt::UserRole).toString()));
    });
    connect(m_list, &QueueList::reordered, this, [this] {
        if (!m_reloading) commitOrder();
    });

    connect(m_controller, &PlayerController::queueChanged, this, &QueueWindow::reload);
    connect(m_controller, &PlayerController::trackChanged, this, &QueueWindow::reload);

    reload();
}

void QueueWindow::reload() {
    m_reloading = true;
    const Track cur = m_controller->currentTrack();
    m_current->setText(cur.isNull() ? QStringLiteral("正在播放：无")
                                    : QStringLiteral("正在播放：%1").arg(displayName(cur)));

    const QList<QueueItem> pending = m_controller->queue().pending();
    m_list->clear();
    for (int i = 0; i < pending.size(); ++i) {
        const Track &t = pending[i].track;
        auto *it = new QListWidgetItem(
            QStringLiteral("%1. %2    %3").arg(i + 1).arg(displayName(t), durText(t)), m_list);
        it->setData(Qt::UserRole, pending[i].id.toString());
    }
    m_info->setText(QStringLiteral("待播 %1 首").arg(pending.size()));
    m_reloading = false;
}

// 把表里当前次序写回队列：只有真变了才提交，避免与 reload 来回打架。
void QueueWindow::commitOrder() {
    QList<QUuid> order;
    order.reserve(m_list->count());
    for (int i = 0; i < m_list->count(); ++i)
        order.append(QUuid::fromString(m_list->item(i)->data(Qt::UserRole).toString()));

    QList<QUuid> now;
    for (const QueueItem &it : m_controller->queue().pending()) now.append(it.id);
    if (order == now) return;

    if (!m_controller->reorderQueued(order))
        reload();   // 提交被拒（次序对不上）：以队列为准重建，别让用户看脏表
}
