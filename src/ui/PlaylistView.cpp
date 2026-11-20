#include "PlaylistView.h"
#include <QDesktopServices>
#include <QFileInfo>
#include "Theme.h"
#include "Painter.h"
#include "core/Collections.h"
#include "models/UserPlaylist.h"

#include <QPainter>
#include <QMouseEvent>
#include <QKeyEvent>
#include <QWheelEvent>
#include <QScrollBar>
#include <QMenu>
#include <QContextMenuEvent>
#include <QApplication>

#include <algorithm>

namespace {

// mm:ss（电台/未知时长不走这里）
QString clock(double sec) {
    const int s = int(sec + 0.5);
    return QStringLiteral("%1:%2").arg(s / 60).arg(s % 60, 2, 10, QLatin1Char('0'));
}

} // namespace

PlaylistView::PlaylistView(PlayerController *controller, QWidget *parent)
    : QAbstractScrollArea(parent), m_controller(controller) {
    viewport()->setAutoFillBackground(false);
    setFrameShape(QFrame::NoFrame);
    setFocusPolicy(Qt::StrongFocus);
    setHorizontalScrollBarPolicy(Qt::ScrollBarAlwaysOff);
    viewport()->setMouseTracking(true);   // 统一毛玻璃：未按键也收 move，hover 行才能轻亮

    connect(controller, &PlayerController::listChanged, this, &PlaylistView::reload);
    connect(controller, &PlayerController::trackChanged, this, &PlaylistView::reload);
    connect(verticalScrollBar(), &QScrollBar::valueChanged, this, [this] { viewport()->update(); });
    connect(this, &PlaylistView::activateRow, controller, &PlayerController::playRowAt);

    reload();
}

void PlaylistView::reload() {
    const Scene previous=scene();
    m_tracks = m_controller->tracks();
    const Track cur = m_controller->currentTrack();
    const QString key = cur.isNull() ? QString() : cur.identityKey();
    m_currentRow = -1;
    if (!key.isEmpty()) {
        for (int i = 0; i < m_tracks.size(); ++i)
            if (m_tracks[i].identityKey() == key) { m_currentRow = i; break; }
    }
    if (m_selectedRow >= m_tracks.size()) m_selectedRow = m_tracks.size() - 1;
    // 选区夹回新长度（删行/重扫后旧行号失效，丢弃越界的选中项）
    if (!m_selection.isEmpty()) {
        QSet<int> keep;
        for (const int r : std::as_const(m_selection))
            if (r >= 0 && r < m_tracks.size()) keep.insert(r);
        m_selection = keep;
    }
    if (m_anchor >= m_tracks.size()) m_anchor = -1;
    updateScrollRange();
    viewport()->update();
    restoreScene(previous);
}

PlaylistView::Scene PlaylistView::scene() const {
    Scene result;result.scroll=verticalScrollBar()->value();
    for(int row:selectedRows())if(row>=0&&row<m_tracks.size())result.selected<<m_tracks[row].identityKey();
    return result;
}
void PlaylistView::restoreScene(const Scene &scene) {
    m_selection.clear();m_selectedRow=-1;m_anchor=-1;
    for(int row=0;row<m_tracks.size();++row)if(scene.selected.contains(m_tracks[row].identityKey())) {
        m_selection.insert(row);m_selectedRow=row;
    }
    m_anchor=m_selectedRow;verticalScrollBar()->setValue(scene.scroll);viewport()->update();
}

void PlaylistView::updateScrollRange() {
    const int total = m_tracks.size() * kRowH;
    const int page = viewport()->height();
    verticalScrollBar()->setRange(0, qMax(0, total - page));
    verticalScrollBar()->setPageStep(qMax(1, page / kRowH));
    verticalScrollBar()->setSingleStep(kRowH);
}

int PlaylistView::visibleRows() const {
    return viewport()->height() / kRowH + 1;
}

void PlaylistView::resizeEvent(QResizeEvent *) {
    updateScrollRange();
}

int PlaylistView::rowAtPos(const QPoint &p) const {
    const int y = p.y() + verticalScrollBar()->value();
    const int row = y / kRowH;
    if (row < 0 || row >= m_tracks.size()) return -1;
    return row;
}

void PlaylistView::paintEvent(QPaintEvent *) {
    QPainter p(viewport());
    p.setRenderHint(QPainter::Antialiasing, false);
    const QRect vp = viewport()->rect();
    // 统一毛玻璃：列表不再铺深蓝实心底，改与壳同调的浅玻璃（单一 alpha）。
    {
        float a = GlassStyle::glassAlpha();
        if (!GlassStyle::enabled()) a = 1.0f;
        Painter::drawBody(&p, QRectF(vp), Theme::windowTop, Theme::windowBottom, a, 0, QColor(), false);
    }

    // 空页提示（F06 派生页）：表中央一句引导，[默认] 无提示保持原版留白
    if (m_tracks.isEmpty() && !m_emptyHint.isEmpty()) {
        p.setPen(Theme::inkOnGlassSoft);
        p.setFont(Fonts::small);
        p.drawText(vp.adjusted(16, 0, -16, 0), Qt::AlignCenter | Qt::TextWordWrap, m_emptyHint);
        return;
    }

    const int offset = verticalScrollBar()->value();
    const int first = offset / kRowH;
    const int durX = vp.width() - kDurW;

    for (int row = first; row < m_tracks.size() && (row * kRowH - offset) <= vp.bottom(); ++row) {
        const int top = row * kRowH - offset;
        const QRectF line(0, top, vp.width(), kRowH);
        const Track &t = m_tracks[row];
        const bool isCurrent = row == m_currentRow;
        const bool isSelected = m_selection.contains(row);

        // 交替行：深底上极淡亮色带（不撞选中/hover）。
        if (!isSelected && row != m_hoverRow && !isCurrent && (row & 1))
            p.fillRect(line, QColor(255, 255, 255, 10));

        // hover 行轻亮（静止不画，鼠标悬停才叠一层柔白）：非选中/非当前才叠。
        if (row == m_hoverRow && !isSelected && !isCurrent)
            p.fillRect(line, QColor(255, 255, 255, 26));

        // 选中行：accent 橙黄轻条（深底上亮字 + 橙条可读）。
        if (isSelected && !isCurrent) {
            QColor sel = Theme::inkOnGlassAccent;
            sel.setAlphaF(0.20f);
            p.fillRect(line, sel);
        }

        // 名称列：「序号. 艺术家 - 标题」
        const QString head = t.artist().isEmpty() ? t.title()
                                                 : QStringLiteral("%1 - %2").arg(t.artist(), t.title());
        QString name = QStringLiteral("%1. %2").arg(row + 1).arg(head);
        if(!t.decodeProblem().isEmpty())name+=QStringLiteral("  [无法播放：%1]").arg(t.decodeProblem());
        if(m_searching&&m_collections)name+=QStringLiteral("  [%1]").arg(m_collections->pagesOf(t.identityKey()).join(QStringLiteral(" · ")));
        if (isCurrent) name.prepend(QStringLiteral("▶ "));

        QFont nameFont = isCurrent ? Fonts::title : Fonts::small;
        p.setFont(nameFont);
        p.setPen(isCurrent ? Theme::inkOnGlassAccent : Theme::inkOnGlass);
        QRectF nameRect(12, top, durX - 12 - 4, kRowH);
        p.drawText(nameRect, Qt::AlignVCenter | Qt::AlignLeft | Qt::TextShowMnemonic,
                   p.fontMetrics().elidedText(name, Qt::ElideMiddle, int(nameRect.width())));

        // 时长列：右对齐、等宽数字；电台「直播」，未知「...」
        QString durText;
        if (t.isRadio()) durText = QStringLiteral("直播");
        else if (t.duration() > 0) durText = clock(t.duration());
        else durText = QStringLiteral("...");
        QFont durFont = Fonts::small;
        durFont.setStyleStrategy(QFont::PreferMatch);
        p.setFont(durFont);
        p.setPen(isCurrent ? Theme::inkOnGlassAccent : Theme::inkOnGlassSoft);
        p.drawText(QRectF(durX + 4, top, kDurW - 8, kRowH),
                   Qt::AlignVCenter | Qt::AlignRight, durText);
    }

    // 拖拽插入指示：目标行顶部一条 2px accent 线
    if (m_dragging && m_dragTarget >= 0 && m_dragTarget <= m_tracks.size()) {
        const int y = m_dragTarget * kRowH - offset;
        p.fillRect(QRectF(0, y - 1, vp.width(), 2), Theme::inkOnGlassAccent);
    }
}

QList<int> PlaylistView::selectedRows() const {
    QList<int> rows = m_selection.values();
    std::sort(rows.begin(), rows.end());
    return rows;
}

void PlaylistView::mousePressEvent(QMouseEvent *event) {
    if (event->button() == Qt::LeftButton) {
        const int row = rowAtPos(event->pos());
        selectAt(row, event->modifiers());
        // 按下在有效行上→记为潜在拖拽起点（选中行不在选区内时 selectAt 已收到单行）
        if (row >= 0) { m_pressing = true; m_pressPos = event->pos(); m_dragging = false; m_dragTarget = -1; }
    }
    QAbstractScrollArea::mousePressEvent(event);
}

void PlaylistView::mouseMoveEvent(QMouseEvent *event) {
    if (m_pressing && (event->buttons() & Qt::LeftButton)) {
        if (!m_dragging
            && (event->pos() - m_pressPos).manhattanLength() >= QApplication::startDragDistance())
            m_dragging = true;
        if (m_dragging) { m_dragTarget = rowAtPos(event->pos()); viewport()->update(); }
        return;
    }
    // 非拖拽：维护 hover 行（只在变化时重绘）。
    const int hr = rowAtPos(event->pos());
    if (hr != m_hoverRow) { m_hoverRow = hr; viewport()->update(); }
    QAbstractScrollArea::mouseMoveEvent(event);
}

void PlaylistView::leaveEvent(QEvent *event) {
    if (m_hoverRow != -1) { m_hoverRow = -1; viewport()->update(); }
    QAbstractScrollArea::leaveEvent(event);
}

void PlaylistView::mouseReleaseEvent(QMouseEvent *event) {
    if (event->button() == Qt::LeftButton) {
        if (m_dragging) {
            const int target = rowAtPos(event->pos());
            if (target >= 0) emit reorderRequested(target);
        }
        m_pressing = false;
        m_dragging = false;
        m_dragTarget = -1;
        viewport()->update();
    }
    QAbstractScrollArea::mouseReleaseEvent(event);
}

// 选区更新的单一入口（鼠标与探针共用）：row<0 时不带修饰键则清空。
void PlaylistView::selectAt(int row, Qt::KeyboardModifiers mods) {
    if (row < 0) {
        if (!(mods & (Qt::ControlModifier | Qt::ShiftModifier))) {
            m_selection.clear();
            m_selectedRow = -1;
            m_anchor = -1;
        }
    } else if (mods & Qt::ControlModifier) {
        // Ctrl：切换单行（增/减），锚点移到这一行
        if (m_selection.contains(row)) m_selection.remove(row);
        else { m_selection.insert(row); m_anchor = row; }
        m_selectedRow = row;
    } else if (mods & Qt::ShiftModifier) {
        // Shift：从锚点到当前行的连续区间（覆盖式，与经典列表一致）
        const int a = m_anchor < 0 ? row : m_anchor;
        m_selection.clear();
        for (int i = qMin(a, row); i <= qMax(a, row); ++i) m_selection.insert(i);
        m_selectedRow = row;
    } else {
        // 普通点击：重设为单行
        m_selection.clear();
        m_selection.insert(row);
        m_anchor = row;
        m_selectedRow = row;
    }
    viewport()->update();
}

void PlaylistView::selectAllRows() {
    m_selection.clear();
    for (int i = 0; i < m_tracks.size(); ++i) m_selection.insert(i);
    if (!m_tracks.isEmpty()) { m_selectedRow = m_tracks.size() - 1; m_anchor = m_selectedRow; }
    viewport()->update();
}

// Delete/退格：对整段选区发起「从列表移除」（上层按页语义分流）；Ctrl/Cmd+A 全选。
void PlaylistView::keyPressEvent(QKeyEvent *event) {
    if (event->matches(QKeySequence::Delete) || event->key() == Qt::Key_Backspace) {
        if (!m_selection.isEmpty()) emit removeRequested(selectedRows());
        return;
    }
    if (event->matches(QKeySequence::SelectAll)) {
        selectAllRows();
        return;
    }
    QAbstractScrollArea::keyPressEvent(event);
}

void PlaylistView::mouseDoubleClickEvent(QMouseEvent *event) {
    const int row = rowAtPos(event->pos());
    if (row >= 0) emit activateRow(row);
    QAbstractScrollArea::mouseDoubleClickEvent(event);
}

void PlaylistView::wheelEvent(QWheelEvent *event) {
    const int step = kRowH * 3;
    const int delta = event->angleDelta().y() > 0 ? -step : step;
    verticalScrollBar()->setValue(verticalScrollBar()->value() + delta);
}

// 右键选中那一行并弹菜单：播放类（下一首/稍后）与集合类（加入歌单/收藏/移除）。
// 本视图只负责弹菜单与发信号，真正动队列 / 集合 / 落盘由上层（PlaylistWindow）做。
void PlaylistView::contextMenuEvent(QContextMenuEvent *event) {
    const int row = rowAtPos(event->pos());
    if (row < 0 || row >= m_tracks.size()) {
        QAbstractScrollArea::contextMenuEvent(event);
        return;
    }
    m_selectedRow = row;
    // 右键的行不在现有选区里→把选区收到这一行（在选区内则保留整段批量）
    if (!m_selection.contains(row)) { m_selection.clear(); m_selection.insert(row); m_anchor = row; }
    viewport()->update();
    const QList<int> rows = selectedRows();

    QMenu menu(this);
    QAction *playNext = menu.addAction(QStringLiteral("下一首播放"));
    QAction *playLater = menu.addAction(QStringLiteral("稍后播放"));
    menu.addSeparator();

    const Track t = m_tracks[row];
    const bool isFav = m_collections && m_collections->isFavorite(t.identityKey());
    QAction *favToggle = menu.addAction(isFav ? QStringLiteral("取消收藏")
                                              : QStringLiteral("加入收藏"));
    // 「加入歌单」子菜单：收藏 + 各自建歌单（没有集合层就不列）
    QAction *pickedFav = nullptr;
    QList<QPair<QAction *, QString>> listActs;
    if (m_collections) {
        QMenu *sub = menu.addMenu(QStringLiteral("加入歌单"));
        pickedFav = sub->addAction(QStringLiteral("我的收藏"));
        for (const UserPlaylist &pl : m_collections->playlists().items())
            listActs.append({sub->addAction(pl.name), pl.id});
    }
    menu.addSeparator();
    QAction *remove = menu.addAction(QStringLiteral("从列表移除"));
    QAction *properties=menu.addAction(QStringLiteral("属性"));
    QAction *edit=menu.addAction(QStringLiteral("编辑显示信息…"));
    QAction *reveal=menu.addAction(QStringLiteral("在文件管理器中打开目录"));
    QAction *relocate=menu.addAction(QStringLiteral("重新定位文件…"));
    reveal->setEnabled(!t.isRadio());relocate->setEnabled(!t.isRadio());
    QAction *address=t.isRadio()?menu.addAction(QStringLiteral("修改电台地址…")):nullptr;
    QAction *retry=t.isRadio()?menu.addAction(QStringLiteral("重试这个电台")):nullptr;

    // 电台行：额外给「重命名台名…」与「移入分类」（R13）。台名/归属都记在地址上。
    QAction *aliasAct = nullptr;
    QList<QPair<QAction *, QString>> catActs;
    if (t.isRadio() && m_collections) {
        menu.addSeparator();
        aliasAct = menu.addAction(QStringLiteral("重命名台名…"));
        QMenu *catSub = menu.addMenu(QStringLiteral("移入分类"));
        const RadioStations &rs = m_collections->radios();
        const QString cur = rs.categoryIDOf(t.identityKey());
        QAction *uncat = catSub->addAction(QStringLiteral("未分类"));
        uncat->setCheckable(true);
        uncat->setChecked(cur.isEmpty());
        catActs.append({uncat, RadioStations::uncategorizedID});
        for (const RadioCategory &c : rs.categories()) {
            QAction *a = catSub->addAction(c.name);
            a->setCheckable(true);
            a->setChecked(cur == c.id);
            catActs.append({a, c.id});
        }
    }

    QAction *chosen = menu.exec(event->globalPos());
    if (!chosen) return;
    if(chosen==properties){emit propertiesRequested(t);return;}
    if(chosen==edit){emit editRequested(t);return;}
    if(chosen==reveal){QDesktopServices::openUrl(QUrl::fromLocalFile(QFileInfo(t.url().toLocalFile()).absolutePath()));return;}
    if(chosen==relocate){emit relocateRequested(t);return;}
    if(address&&chosen==address){emit radioAddressRequested(t);return;}
    if(retry&&chosen==retry){emit radioRetryRequested(t);return;}
    if (chosen == playNext) emit enqueueNextRequested(rows);
    else if (chosen == playLater) emit enqueueLaterRequested(rows);
    else if (chosen == favToggle) emit toggleFavoriteRequested(rows);
    else if (chosen == remove) emit removeRequested(rows);
    else if (aliasAct && chosen == aliasAct) emit radioAliasRequested(rows);
    else if (pickedFav && chosen == pickedFav)
        emit addToListRequested(rows, Collections::kFavViewId);
    else
        for (const auto &ca : catActs)
            if (chosen == ca.first) { emit radioMoveCategoryRequested(rows, ca.second); return; }
        for (const auto &pa : listActs)
            if (chosen == pa.first) { emit addToListRequested(rows, pa.second); break; }
}

void PlaylistView::scrollToCurrent() {
    if (m_currentRow < 0) return;
    const int page = viewport()->height();
    const int rowTop = m_currentRow * kRowH;
    int value = verticalScrollBar()->value();
    if (rowTop < value) value = rowTop;
    else if (rowTop + kRowH > value + page) value = rowTop + kRowH - page;
    verticalScrollBar()->setValue(value);
}
