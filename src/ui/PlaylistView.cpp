#include "PlaylistView.h"
#include <QDesktopServices>
#include <QFileInfo>
#include "Theme.h"
#include "Painter.h"
#include "SkinParts.h"
#include "SkinWidgets.h"
#include "library/Collections.h"
#include "models/UserPlaylist.h"

#include <QPainter>
#include <QFontMetricsF>
#include <QMouseEvent>
#include <QKeyEvent>
#include <QWheelEvent>
#include <QScrollBar>
#include <QStyle>
#include <QMenu>
#include <QContextMenuEvent>
#include <QApplication>

#include <algorithm>
#include <cmath>

namespace {

// mm:ss（电台/未知时长不走这里）
QString clock(double sec) {
    const int s = int(std::lround(sec));
    return QStringLiteral("%1:%2").arg(s / 60).arg(s % 60, 2, 10, QLatin1Char('0'));
}

QString durationText(const Track &track) {
    if (track.isRadio()) return QStringLiteral("直播");
    return track.duration() > 0 ? clock(track.duration()) : QStringLiteral("...");
}

QFont durationFont(const Track &track) {
    QFont font = track.isRadio() ? Fonts::small : Fonts::numericSmall;
    font.setStyleStrategy(QFont::PreferMatch);
    return font;
}

// 能否转格式：只收本机文件。电台没实体、CUE 分轨转出来会变成整张镜像、
// 归档条目是压缩包内的一截（转换只认普通路径）。
bool convertible(const Track &t) {
    if (t.isNull() || t.isRadio() || t.isCueSegment()) return false;
    const QUrl &url = t.url();
    if (!url.isLocalFile() || !url.fragment().isEmpty()) return false;
    return QFileInfo::exists(url.toLocalFile());
}

} // namespace

PlaylistView::PlaylistView(PlayerController *controller, QWidget *parent)
    : QAbstractScrollArea(parent), m_controller(controller) {
    viewport()->setAutoFillBackground(false);
    setFrameShape(QFrame::NoFrame);
    setFocusPolicy(Qt::StrongFocus);
    setHorizontalScrollBarPolicy(Qt::ScrollBarAlwaysOff);
    viewport()->setMouseTracking(true); // 统一毛玻璃：未按键也收 move，hover 行才能轻亮

    // 只替换歌曲列表的滚动条：轨道透底，滑块使用现有灰色并跟随玻璃 alpha。
    // 保留 Fusion 的宽度，不改变列表可用宽度；滚动与命中仍由 QScrollBar 处理。
    auto *bar = verticalScrollBar();
    const int barWidth = bar->sizeHint().width();
    const int minHandle = bar->style()->pixelMetric(QStyle::PM_ScrollBarSliderMin, nullptr, bar);
    const auto updateScrollStyle = [this, bar, barWidth, minHandle] {
        QColor handle = Theme::inkOnGlassSoft;
        handle.setAlphaF(GlassStyle::enabled() ? GlassStyle::glassAlpha() : 1.0f);
        bar->setStyleSheet(
            QStringLiteral(
                "QScrollBar:vertical{background:transparent;width:%1px;margin:0;border:none;}"
                "QScrollBar::handle:vertical{background:rgba(%2,%3,%4,%5);border-radius:3px;min-height:%6px;}"
                "QScrollBar::add-line:vertical,QScrollBar::sub-line:vertical{height:0;background:transparent;}"
                "QScrollBar::add-page:vertical,QScrollBar::sub-page:vertical{background:transparent;}")
                .arg(barWidth)
                .arg(handle.red())
                .arg(handle.green())
                .arg(handle.blue())
                .arg(handle.alpha())
                .arg(minHandle));
        bar->setAutoFillBackground(false);
        viewport()->update();
    };
    connect(&GlassNotifier::instance(), &GlassNotifier::changed, this, updateScrollStyle);
    updateScrollStyle();

    connect(controller, &PlayerController::listChanged, this, &PlaylistView::reload);
    connect(controller, &PlayerController::trackChanged, this, &PlaylistView::reload);
    connect(verticalScrollBar(), &QScrollBar::valueChanged, this, [this] {
        if (m_favoritePress) m_favoriteCancelled = true;
        viewport()->update();
    });
    connect(this, &PlaylistView::activateRow, controller, &PlayerController::playRowAt);

    reload();
}

void PlaylistView::reload() {
    if (m_favoritePress) m_favoriteCancelled = true;
    const Scene previous = scene();
    m_tracks = m_controller->tracks();
    const Track cur = m_controller->currentTrack();
    const QString key = cur.isNull() ? QString() : cur.identityKey();
    m_currentRow = -1;
    if (!key.isEmpty()) {
        for (int i = 0; i < m_tracks.size(); ++i)
            if (m_tracks[i].identityKey() == key) {
                m_currentRow = i;
                break;
            }
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
    Scene result;
    result.scroll = verticalScrollBar()->value();
    for (int row : selectedRows())
        if (row >= 0 && row < m_tracks.size()) result.selected << m_tracks[row].identityKey();
    if (m_selectedRow >= 0 && m_selectedRow < m_tracks.size()) result.primary = m_tracks[m_selectedRow].identityKey();
    if (m_anchor >= 0 && m_anchor < m_tracks.size()) result.anchor = m_tracks[m_anchor].identityKey();
    return result;
}
void PlaylistView::restoreScene(const Scene &scene) {
    m_selection.clear();
    m_selectedRow = -1;
    m_anchor = -1;
    for (int row = 0; row < m_tracks.size(); ++row)
        if (scene.selected.contains(m_tracks[row].identityKey())) {
            m_selection.insert(row);
            m_selectedRow = row;
        }
    for (int row = 0; row < m_tracks.size(); ++row) {
        const QString key = m_tracks[row].identityKey();
        if (key == scene.primary) m_selectedRow = row;
        if (key == scene.anchor) m_anchor = row;
    }
    verticalScrollBar()->setValue(scene.scroll);
    viewport()->update();
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

qreal PlaylistView::durationTextLeft(int row) const {
    if (row < 0 || row >= m_tracks.size()) return viewport()->width() - 4;
    const Track &track = m_tracks[row];
    const QFontMetricsF metrics(durationFont(track), viewport());
    return viewport()->width() - 4 - metrics.horizontalAdvance(durationText(track));
}

QRectF PlaylistView::favoriteGlyphRect(int row) const {
    return QRectF(durationTextLeft(row) - kFavoriteGap - kFavoriteGlyphSize,
                  row * kRowH - verticalScrollBar()->value() + (kRowH - kFavoriteGlyphSize) / 2.0, kFavoriteGlyphSize,
                  kFavoriteGlyphSize);
}

QRect PlaylistView::favoriteRect(int row) const {
    // 点击区向左扩展，右侧不覆盖时长；图标贴实际文字而非固定列的左边界。
    const int right = int(std::ceil(favoriteGlyphRect(row).right()));
    return QRect(right - kFavoriteW, row * kRowH - verticalScrollBar()->value(), kFavoriteW, kRowH);
}

bool PlaylistView::favoriteHit(const QPoint &pos, int row) const {
    return m_collections && row >= 0 && row < m_tracks.size() && viewport()->rect().contains(pos) &&
           favoriteRect(row).contains(pos);
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
        if (!isSelected && row != m_hoverRow && !isCurrent && (row & 1)) p.fillRect(line, QColor(255, 255, 255, 10));

        // hover 行轻亮（静止不画，鼠标悬停才叠一层柔白）：非选中/非当前才叠。
        if (row == m_hoverRow && !isSelected && !isCurrent) p.fillRect(line, QColor(255, 255, 255, 26));

        // 选中行：accent 橙黄轻条（深底上亮字 + 橙条可读）。
        if (isSelected && !isCurrent) {
            QColor sel = Theme::inkOnGlassAccent;
            sel.setAlphaF(0.20f);
            p.fillRect(line, sel);
        }

        // 名称列：「序号. 艺术家 - 标题」
        const QString head = t.artist().isEmpty() ? t.title() : QStringLiteral("%1 - %2").arg(t.artist(), t.title());
        QString name = QStringLiteral("%1. %2").arg(row + 1).arg(head);
        if (!t.decodeProblem().isEmpty()) name += QStringLiteral("  [无法播放：%1]").arg(t.decodeProblem());
        if (m_searching && m_collections)
            name += QStringLiteral("  [%1]").arg(m_collections->pagesOf(t.identityKey()).join(QStringLiteral(" · ")));
        if (isCurrent) name.prepend(QStringLiteral("▶ "));

        QFont nameFont = isCurrent ? Fonts::title : Fonts::small;
        p.setFont(nameFont);
        p.setPen(isCurrent ? Theme::inkOnGlassAccent : Theme::inkOnGlass);
        const int nameRight = m_collections ? qMin(durX - kFavoriteW, favoriteRect(row).left()) : durX;
        QRectF nameRect(12, top, qMax(0, nameRight - 12 - 4), kRowH);
        p.drawText(nameRect, Qt::AlignVCenter | Qt::AlignLeft | Qt::TextShowMnemonic,
                   p.fontMetrics().elidedText(name, Qt::ElideMiddle, int(nameRect.width())));

        if (m_collections) {
            const bool favorite = m_collections->isFavorite(t.identityKey());
            Skin::drawGlyph(&p, favorite ? Skin::Glyph::HeartFilled : Skin::Glyph::HeartOutline, favoriteGlyphRect(row),
                            favorite ? Theme::inkOnGlassAccent : Theme::inkOnGlassSoft, 1.0);
        }

        // 时长列：右对齐、等宽数字；电台「直播」，未知「...」
        p.setFont(durationFont(t));
        p.setPen(isCurrent ? Theme::inkOnGlassAccent : Theme::inkOnGlassSoft);
        p.drawText(QRectF(durX + 4, top, kDurW - 8, kRowH), Qt::AlignVCenter | Qt::AlignRight, durationText(t));
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
        m_ignoreFavoriteRelease = false;
        m_favoriteClickRect = {};
        if (favoriteHit(event->pos(), row)) {
            m_favoriteClickRect = favoriteRect(row);
            m_favoritePress = true;
            m_favoriteCancelled = false;
            m_favoriteKey = m_tracks[row].identityKey();
            m_pressPos = event->pos();
            m_pressing = m_dragging = false;
            m_dragTarget = -1;
            event->accept();
            return;
        }
        selectAt(row, event->modifiers());
        // 按下在有效行上→记为潜在拖拽起点（选中行不在选区内时 selectAt 已收到单行）
        if (row >= 0) {
            m_pressing = true;
            m_pressPos = event->pos();
            m_dragging = false;
            m_dragTarget = -1;
        }
    }
    QAbstractScrollArea::mousePressEvent(event);
}

void PlaylistView::mouseMoveEvent(QMouseEvent *event) {
    if (m_favoritePress) {
        if ((event->pos() - m_pressPos).manhattanLength() >= QApplication::startDragDistance())
            m_favoriteCancelled = true;
        event->accept();
        return;
    }
    if (m_pressing && (event->buttons() & Qt::LeftButton)) {
        if (!m_dragging && (event->pos() - m_pressPos).manhattanLength() >= QApplication::startDragDistance())
            m_dragging = true;
        if (m_dragging) {
            m_dragTarget = rowAtPos(event->pos());
            viewport()->update();
        }
        return;
    }
    // 非拖拽：维护 hover 行（只在变化时重绘）。
    const int hr = rowAtPos(event->pos());
    const bool heart = favoriteHit(event->pos(), hr);
    viewport()->setCursor(heart ? Qt::PointingHandCursor : Qt::ArrowCursor);
    viewport()->setToolTip(heart ? (m_collections->isFavorite(m_tracks[hr].identityKey()) ? QStringLiteral("取消收藏")
                                                                                          : QStringLiteral("加入收藏"))
                                 : QString());
    if (hr != m_hoverRow) {
        m_hoverRow = hr;
        viewport()->update();
    }
    QAbstractScrollArea::mouseMoveEvent(event);
}

void PlaylistView::leaveEvent(QEvent *event) {
    viewport()->unsetCursor();
    viewport()->setToolTip({});
    if (m_hoverRow != -1) {
        m_hoverRow = -1;
        viewport()->update();
    }
    QAbstractScrollArea::leaveEvent(event);
}

void PlaylistView::mouseReleaseEvent(QMouseEvent *event) {
    if (event->button() == Qt::LeftButton) {
        if (m_ignoreFavoriteRelease) {
            m_ignoreFavoriteRelease = false;
            event->accept();
            return;
        }
        if (m_favoritePress) {
            const int row = rowAtPos(event->pos());
            const bool toggle =
                !m_favoriteCancelled && favoriteHit(event->pos(), row) && m_tracks[row].identityKey() == m_favoriteKey;
            const QString key = m_favoriteKey;
            m_favoritePress = false;
            m_favoriteKey.clear();
            if (toggle) emit toggleFavoriteRequested(key);
            const int hoverRow = rowAtPos(event->pos());
            const bool heart = favoriteHit(event->pos(), hoverRow);
            viewport()->setToolTip(heart ? (m_collections->isFavorite(m_tracks[hoverRow].identityKey())
                                                ? QStringLiteral("取消收藏")
                                                : QStringLiteral("加入收藏"))
                                         : QString());
            viewport()->update();
            event->accept();
            return;
        }
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
        if (m_selection.contains(row))
            m_selection.remove(row);
        else {
            m_selection.insert(row);
            m_anchor = row;
        }
        m_selectedRow = row;
    } else if (mods & Qt::ShiftModifier) {
        // Shift：从锚点到当前行的连续区间（覆盖式，与经典列表一致）
        const int a = m_anchor < 0 ? row : m_anchor;
        m_selection.clear();
        for (int i = qMin(a, row); i <= qMax(a, row); ++i)
            m_selection.insert(i);
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
    for (int i = 0; i < m_tracks.size(); ++i)
        m_selection.insert(i);
    if (!m_tracks.isEmpty()) {
        m_selectedRow = m_tracks.size() - 1;
        m_anchor = m_selectedRow;
    }
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
    const bool heart = m_collections && viewport()->rect().contains(event->pos()) &&
                       (favoriteHit(event->pos(), row) || m_favoriteClickRect.contains(event->pos()));
    if (heart) {
        m_ignoreFavoriteRelease = true;
        m_favoritePress = m_pressing = m_dragging = false;
        event->accept();
        return;
    }
    if (row >= 0) emit activateRow(row);
    QAbstractScrollArea::mouseDoubleClickEvent(event);
}

void PlaylistView::wheelEvent(QWheelEvent *event) {
    const int step = kRowH * 3;
    const int delta = event->angleDelta().y() > 0 ? -step : step;
    verticalScrollBar()->setValue(verticalScrollBar()->value() + delta);
}

// 歌曲区域右键只提供文件、属性、转换与电台操作；列表操作统一在左栏。
void PlaylistView::contextMenuEvent(QContextMenuEvent *event) {
    const int row = rowAtPos(event->pos());
    const bool onRow = row >= 0 && row < m_tracks.size();
    if (onRow) {
        m_selectedRow = row;
        // 右键的行不在现有选区里→把选区收到这一行（在选区内则保留整段批量）
        if (!m_selection.contains(row)) {
            m_selection.clear();
            m_selection.insert(row);
            m_anchor = row;
        }
        viewport()->update();
    }
    SkinMenu menu(this);
    buildContextMenu(menu, onRow ? row : -1);
    if (!menu.isEmpty()) menu.exec(event->globalPos());
}

// 菜单树构造：动作一律用 triggered 连接，exec 只负责显示。探针可直接调用本函数核对分组
// 与隐藏规则（exec 会阻塞，测试不能走它）。
void PlaylistView::buildContextMenu(QMenu &menu, int row) {
    const bool onRow = row >= 0 && row < m_tracks.size();
    const QList<int> rows = onRow ? selectedRows() : QList<int>();
    QList<Track> picked;
    picked.reserve(rows.size());
    for (int r : rows)
        picked << m_tracks[r];

    if (onRow) {
        const Track t = m_tracks[row];

        // —— 显示信息 / 文件 ——
        // 只编辑右键指向的电台；本地、CUE 与归档曲目的显示信息沿用原始元数据。
        if (t.isRadio())
            connect(menu.addAction(QStringLiteral("编辑显示信息…")), &QAction::triggered, this,
                    [this, t] { emit editRequested(t); });
        QMenu *file = SkinMenu::addSubmenu(menu, QStringLiteral("文件"));
        // 电台只提供属性；磁盘操作只对本地实体有意义。
        if (!t.isRadio()) {
            connect(file->addAction(QStringLiteral("在文件管理器中打开目录")), &QAction::triggered, this, [t] {
                QDesktopServices::openUrl(QUrl::fromLocalFile(QFileInfo(t.url().toLocalFile()).absolutePath()));
            });
            connect(file->addAction(QStringLiteral("重新定位文件…")), &QAction::triggered, this,
                    [this, t] { emit relocateRequested(t); });
            // 多选里只要有一条不能转（电台 / CUE 分轨 / 归档条目 / 文件不在）就整项不给，
            // 不偷偷只转一部分。
            bool allConvertible = !picked.isEmpty();
            for (const Track &track : std::as_const(picked))
                allConvertible = allConvertible && convertible(track);
            if (allConvertible)
                connect(file->addAction(QStringLiteral("转换为其他格式…")), &QAction::triggered, this,
                        [this, picked] { emit convertRequested(picked); });
            file->addSeparator();
        }
        connect(file->addAction(QStringLiteral("属性")), &QAction::triggered, this,
                [this, t] { emit propertiesRequested(t); });

        // —— 电台：台名/归属都记在地址上（R13） ——
        if (t.isRadio()) {
            menu.addSeparator();
            QMenu *radio = SkinMenu::addSubmenu(menu, QStringLiteral("电台"));
            connect(radio->addAction(QStringLiteral("修改电台地址…")), &QAction::triggered, this,
                    [this, t] { emit radioAddressRequested(t); });
            connect(radio->addAction(QStringLiteral("重试这个电台")), &QAction::triggered, this,
                    [this, t] { emit radioRetryRequested(t); });
            if (m_collections) {
                radio->addSeparator();
                connect(radio->addAction(QStringLiteral("重命名台名…")), &QAction::triggered, this,
                        [this, rows] { emit radioAliasRequested(rows); });
                QMenu *cats = SkinMenu::addSubmenu(*radio, QStringLiteral("移入分类"));
                const RadioStations &rs = m_collections->radios();
                const QString cur = rs.categoryIDOf(t.identityKey());
                QAction *uncat = cats->addAction(QStringLiteral("未分类"));
                uncat->setCheckable(true);
                uncat->setChecked(cur.isEmpty());
                connect(uncat, &QAction::triggered, this,
                        [this, rows] { emit radioMoveCategoryRequested(rows, RadioStations::uncategorizedID); });
                for (const RadioCategory &c : rs.categories()) {
                    QAction *act = cats->addAction(c.name);
                    act->setCheckable(true);
                    act->setChecked(cur == c.id);
                    const QString catId = c.id;
                    connect(act, &QAction::triggered, this,
                            [this, rows, catId] { emit radioMoveCategoryRequested(rows, catId); });
                }
            }
        }
    }
}

void PlaylistView::scrollToCurrent() {
    if (m_currentRow < 0) return;
    const int page = viewport()->height();
    const int rowTop = m_currentRow * kRowH;
    int value = verticalScrollBar()->value();
    if (rowTop < value)
        value = rowTop;
    else if (rowTop + kRowH > value + page)
        value = rowTop + kRowH - page;
    verticalScrollBar()->setValue(value);
}
