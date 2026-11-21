#include "PlaylistView.h"
#include <QDesktopServices>
#include <QFileInfo>
#include "Theme.h"
#include "Painter.h"
#include "library/Collections.h"
#include "models/UserPlaylist.h"

#include <QPainter>
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
    connect(verticalScrollBar(), &QScrollBar::valueChanged, this, [this] { viewport()->update(); });
    connect(this, &PlaylistView::activateRow, controller, &PlayerController::playRowAt);

    reload();
}

void PlaylistView::reload() {
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
    m_anchor = m_selectedRow;
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
        QRectF nameRect(12, top, durX - 12 - 4, kRowH);
        p.drawText(nameRect, Qt::AlignVCenter | Qt::AlignLeft | Qt::TextShowMnemonic,
                   p.fontMetrics().elidedText(name, Qt::ElideMiddle, int(nameRect.width())));

        // 时长列：右对齐、等宽数字；电台「直播」，未知「...」
        QString durText;
        if (t.isRadio())
            durText = QStringLiteral("直播");
        else if (t.duration() > 0)
            durText = clock(t.duration());
        else
            durText = QStringLiteral("...");
        QFont durFont = Fonts::small;
        durFont.setStyleStrategy(QFont::PreferMatch);
        p.setFont(durFont);
        p.setPen(isCurrent ? Theme::inkOnGlassAccent : Theme::inkOnGlassSoft);
        p.drawText(QRectF(durX + 4, top, kDurW - 8, kRowH), Qt::AlignVCenter | Qt::AlignRight, durText);
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
    if (hr != m_hoverRow) {
        m_hoverRow = hr;
        viewport()->update();
    }
    QAbstractScrollArea::mouseMoveEvent(event);
}

void PlaylistView::leaveEvent(QEvent *event) {
    if (m_hoverRow != -1) {
        m_hoverRow = -1;
        viewport()->update();
    }
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
    if (row >= 0) emit activateRow(row);
    QAbstractScrollArea::mouseDoubleClickEvent(event);
}

void PlaylistView::wheelEvent(QWheelEvent *event) {
    const int step = kRowH * 3;
    const int delta = event->angleDelta().y() > 0 ? -step : step;
    verticalScrollBar()->setValue(verticalScrollBar()->value() + delta);
}

// 右键菜单：选中行上给队列 / 收藏 / 曲目 / 电台 / 移除，页级入口（添加 / 列表 / 歌单）
// 行上与空白处都给。当前页或当前行做不到的动作直接不生成（不给灰项），判定只看
// 集合层与视图自己的状态。本视图只弹菜单与发信号，真正动队列 / 集合 / 落盘由上层
// （PlaylistWindow）做。
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
    QMenu menu(this);
    buildContextMenu(menu, onRow ? row : -1);
    menu.exec(event->globalPos());
}

// 菜单树构造：动作一律用 triggered 连接，exec 只负责显示。探针可直接调用本函数核对分组
// 与隐藏规则（exec 会阻塞，测试不能走它）。
void PlaylistView::buildContextMenu(QMenu &menu, int row) {
    const bool onRow = row >= 0 && row < m_tracks.size();
    const QList<int> rows = onRow ? selectedRows() : QList<int>();
    const QString pageId = m_collections ? m_collections->viewId() : Collections::kAllViewId;
    // 只有自建歌单页有「定义」可改；媒体库是扫描出来的只读投影；筛选态下列表不是整页原貌，
    // 整页动作先不给。
    const bool customPage = m_collections && m_collections->playlists().contains(pageId);
    const bool libraryPage = pageId == Collections::kLibraryViewId;
    const bool sortablePage = customPage || pageId == Collections::kAllViewId || pageId == Collections::kFavViewId;
    QList<Track> picked;
    picked.reserve(rows.size());
    for (int r : rows)
        picked << m_tracks[r];

    if (onRow) {
        const Track t = m_tracks[row];

        // —— 播放 ——
        connect(menu.addAction(QStringLiteral("下一首播放")), &QAction::triggered, this,
                [this, rows] { emit enqueueNextRequested(rows); });
        connect(menu.addAction(QStringLiteral("稍后播放")), &QAction::triggered, this,
                [this, rows] { emit enqueueLaterRequested(rows); });

        // —— 收藏 / 歌单：整段选区都已在该歌单里的不再列，免得点了没反应 ——
        if (m_collections) {
            menu.addSeparator();
            const bool isFav = m_collections->isFavorite(t.identityKey());
            connect(menu.addAction(isFav ? QStringLiteral("取消收藏") : QStringLiteral("加入收藏")),
                    &QAction::triggered, this, [this, rows] { emit toggleFavoriteRequested(rows); });
            QMenu *lists = nullptr;
            for (const UserPlaylist &pl : m_collections->playlists().items()) {
                const QStringList keys = m_collections->playlists().keysOf(pl.id);
                const QSet<QString> inList(keys.cbegin(), keys.cend());
                const bool alreadyThere = std::all_of(picked.cbegin(), picked.cend(), [&inList](const Track &track) {
                    return inList.contains(track.identityKey());
                });
                if (alreadyThere) continue;
                if (!lists) lists = menu.addMenu(QStringLiteral("加入歌单"));
                const QString listId = pl.id;
                connect(lists->addAction(pl.name), &QAction::triggered, this,
                        [this, rows, listId] { emit addToListRequested(rows, listId); });
            }
        }

        // —— 曲目信息 ——
        menu.addSeparator();
        connect(menu.addAction(QStringLiteral("属性")), &QAction::triggered, this,
                [this, t] { emit propertiesRequested(t); });
        // 电台的显示名由台名（别名/内置名）盖掉字段编辑，改名走「电台 / 重命名台名…」
        if (!t.isRadio())
            connect(menu.addAction(QStringLiteral("编辑显示信息…")), &QAction::triggered, this,
                    [this, t] { emit editRequested(t); });
        // 文件类只对磁盘上的实体有意义：电台没有本地路径，探不到的文件不提供转格式
        if (!t.isRadio()) {
            QMenu *file = menu.addMenu(QStringLiteral("文件"));
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
        }

        // —— 电台：台名/归属都记在地址上（R13） ——
        if (t.isRadio()) {
            menu.addSeparator();
            QMenu *radio = menu.addMenu(QStringLiteral("电台"));
            connect(radio->addAction(QStringLiteral("修改电台地址…")), &QAction::triggered, this,
                    [this, t] { emit radioAddressRequested(t); });
            connect(radio->addAction(QStringLiteral("重试这个电台")), &QAction::triggered, this,
                    [this, t] { emit radioRetryRequested(t); });
            if (m_collections) {
                radio->addSeparator();
                connect(radio->addAction(QStringLiteral("重命名台名…")), &QAction::triggered, this,
                        [this, rows] { emit radioAliasRequested(rows); });
                QMenu *cats = radio->addMenu(QStringLiteral("移入分类"));
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

        // —— 从列表移除：媒体库是只读投影（筛选态下删的是命中页，仍可删） ——
        if (m_collections && (m_filterActive || !libraryPage)) {
            menu.addSeparator();
            connect(menu.addAction(QStringLiteral("从列表移除")), &QAction::triggered, this,
                    [this, rows] { emit removeRequested(rows); });
        }
    }

    // —— 页级动作：添加 / 列表 / 歌单 ——
    if (onRow) menu.addSeparator();

    QMenu *add = menu.addMenu(QStringLiteral("添加"));
    connect(add->addAction(QStringLiteral("添加文件…")), &QAction::triggered, this,
            [this] { emit addFilesRequested(); });
    connect(add->addAction(QStringLiteral("添加文件夹…")), &QAction::triggered, this,
            [this] { emit addFolderRequested(); });
    connect(add->addAction(QStringLiteral("添加网络电台…")), &QAction::triggered, this,
            [this] { emit addRadioRequested(); });

    QMenu *listMenu = menu.addMenu(QStringLiteral("列表"));
    // 没在播 / 不在本页时「定位当前曲」无处可去
    if (m_currentRow >= 0)
        connect(listMenu->addAction(QStringLiteral("定位当前曲")), &QAction::triggered, this,
                &PlaylistView::scrollToCurrent);
    // 排序写的是这一页的存储序：派生页（媒体库/电台/最近）没有序可写，筛选态也不能写
    if (sortablePage && !m_filterActive && !m_tracks.isEmpty()) {
        QMenu *sort = listMenu->addMenu(QStringLiteral("排序"));
        const struct SortRow {
            const char *name;
            int key;
        } sortRows[] = {
            {"按标题", 0},     {"按艺术家", 1},     {"按专辑", 2},     {"按时长", 3},
            {"按标题降序", 4}, {"按艺术家降序", 5}, {"按专辑降序", 6}, {"按时长降序", 7},
        };
        for (const SortRow &r : sortRows) {
            const int key = r.key;
            connect(sort->addAction(QString::fromUtf8(r.name)), &QAction::triggered, this,
                    [this, key] { emit sortRequested(key); });
            if (key == 3) sort->addSeparator();
        }
        connect(sort->addAction(QStringLiteral("还原原序")), &QAction::triggered, this,
                [this] { emit sortRequested(-1); });
    }
    QMenu *mode = listMenu->addMenu(QStringLiteral("播放模式"));
    const struct ModeRow {
        const char *name;
        PlayMode mode;
    } modeRows[] = {
        {"顺序播放", PlayMode::Order},
        {"列表循环", PlayMode::ListLoop},
        {"单曲循环", PlayMode::SingleLoop},
        {"随机播放", PlayMode::Random},
    };
    for (const ModeRow &r : modeRows) {
        QAction *act = mode->addAction(QString::fromUtf8(r.name));
        act->setCheckable(true);
        act->setChecked(r.mode == m_controller->mode());
        const PlayMode pickedMode = r.mode;
        connect(act, &QAction::triggered, this, [this, pickedMode] { m_controller->setMode(pickedMode); });
    }
    connect(listMenu->addAction(QStringLiteral("待播队列")), &QAction::triggered, this,
            [this] { emit queueRequested(); });
    // 空页没什么可清，媒体库只读，筛选态下清空会把命中之外的也带走
    if (m_collections && !m_filterActive && !libraryPage && !m_tracks.isEmpty())
        connect(listMenu->addAction(QStringLiteral("清空当前列表")), &QAction::triggered, this,
                [this] { emit clearListRequested(); });

    // 「歌单」：新建 / 导入 / 导出 / 重命名 / 删除这些定义级动作由上层按当前页现填，
    // 它才知道这一页真能做哪些；整块为空就把子菜单摘掉。
    QMenu *playlistMenu = menu.addMenu(QStringLiteral("歌单"));
    emit playlistMenuRequested(playlistMenu);
    if (playlistMenu->isEmpty()) menu.removeAction(playlistMenu->menuAction());
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
