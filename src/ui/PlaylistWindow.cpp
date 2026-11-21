#include "PlaylistWindow.h"
#include "PlaylistView.h"
#include "SkinParts.h"
#include "SkinWidgets.h"
#include "Painter.h"
#include "Theme.h"
#include "library/GlobalSearch.h"
#include "library/Importer.h"
#include "media/PlaylistM3U.h"
#include "models/TrackFilter.h"

#include <QHBoxLayout>
#include <QVBoxLayout>
#include <QLineEdit>
#include <QLabel>
#include <QTimer>
#include <QInputDialog>
#include <QFileDialog>
#include <QMessageBox>
#include <QFileInfo>
#include <QDir>
#include <QMenu>
#include <QAction>
#include <QPainter>
#include <QDropEvent>
#include <QFutureWatcher>
#include <QUrl>
#include <QtConcurrent>
#include <algorithm>
#include <cmath>
#include <QShortcut>

namespace {

constexpr int kSearchDebounceMs = 120;

} // namespace

PlaylistWindow::PlaylistWindow(PlayerController *controller, Collections *collections, QWidget *parent)
    : SkinWindow(QStringLiteral("播放列表"), true, parent), m_controller(controller), m_collections(collections) {
    resize(460, 380 + 30); // 与主窗/均衡器同一紧凑默认宽（+30 为标题条高度）

    auto *root = new QHBoxLayout(body());
    root->setContentsMargins(6, 6, 6, 6);
    root->setSpacing(6);

    // —— 左栏：多页浏览器（收藏 + 各自建歌单 + 全部），统一毛玻璃自绘 SkinListView ——
    m_groups = new SkinListView(this);
    m_groups->setFixedWidth(112);
    m_groups->setRowHeight(22);
    root->addWidget(m_groups);

    // —— 右栏：标题行 + 歌曲表 ——
    auto *right = new QVBoxLayout();
    right->setSpacing(4);

    // 标题行：「歌曲列表」+ 固定放大镜 + 可展开搜索框（放大镜右侧）+ 计数
    auto *topRow = new QHBoxLayout();
    topRow->setSpacing(8); // 放大镜紧贴标题，间隙 ≤ 12pt（布局规范）
    m_caption = new QLabel(QStringLiteral("歌曲列表"), this);
    m_caption->setFont(Fonts::panelTitle);
    m_caption->setStyleSheet(QStringLiteral("color:%1;background:transparent;").arg(Theme::titleText.name()));
    m_searchToggle = new TTButton(this);
    m_searchToggle->setGlyph(Skin::Glyph::Search);
    m_searchToggle->setFace(TTButton::Face::Glass);
    m_searchToggle->setPreferredSize({22, 18});
    m_searchToggle->setToolTip(QStringLiteral("搜索（关键字搜整个播放器）"));
    m_search = new SkinLineEdit(this);
    m_search->setPlaceholderText(QStringLiteral("搜索歌曲 / 艺术家 / 专辑 / 文件名"));
    m_search->setClearButtonEnabled(true);
    m_search->setFixedHeight(26);
    m_search->setVisible(false); // 收起时标题行只剩这颗键，放大镜位置固定
    m_info = new QLabel(QStringLiteral("共 0 首"), this);
    m_info->setFont(Fonts::small);
    m_info->setAlignment(Qt::AlignRight | Qt::AlignVCenter);
    m_info->setStyleSheet(QStringLiteral("color:%1;background:transparent;").arg(Theme::inkOnGlassSoft.name()));
    topRow->addWidget(m_caption);
    topRow->addWidget(m_searchToggle);
    auto *formats = new TTButton(this);
    formats->setTextLabel(QStringLiteral("格式"));
    formats->setPreferredSize({38, 20});
    formats->hide();
    m_searchToggle->setToolTip(QStringLiteral("搜索；右键筛选格式"));
    m_searchToggle->setContextMenuPolicy(Qt::CustomContextMenu);
    connect(m_searchToggle, &QWidget::customContextMenuRequested, this,
            [formats](const QPoint &) { formats->click(); });
    connect(formats, &TTButton::clicked, this, [this, formats] {
        QMenu menu(this);
        for (const QString &format : TrackFilter::formatOptions(m_collections->allTracks())) {
            QAction *action = menu.addAction(format);
            action->setCheckable(true);
            action->setChecked(m_formats.contains(format));
            connect(action, &QAction::triggered, this, [this, format] {
                if (!m_formats.remove(format)) m_formats.insert(format);
                applySearch();
            });
        }
        menu.addSeparator();
        connect(menu.addAction(QStringLiteral("全部格式")), &QAction::triggered, this, [this] {
            m_formats.clear();
            applySearch();
        });
        menu.exec(formats->mapToGlobal(QPoint(0, formats->height())));
    });
    topRow->addWidget(m_search, 1); // 展开时向右长，收起时不占位
    topRow->addStretch();
    topRow->addWidget(m_info);
    right->addLayout(topRow);

    // 入口统一走列表右键：行上给播放/收藏/曲目/电台动作，行上与空白处都给页级的
    // 添加/列表/歌单三个子菜单；不再保留标题下那排按钮。

    m_view = new PlaylistView(controller, this);
    m_view->setCollections(collections); // 右键需要拼「加入歌单」子菜单
    right->addWidget(m_view, 1);
    connect(m_view, &PlaylistView::propertiesRequested, this, &PlaylistWindow::propertiesRequested);
    connect(m_view, &PlaylistView::convertRequested, this, &PlaylistWindow::convertRequested);
    connect(m_view, &PlaylistView::editRequested, this, &PlaylistWindow::editRequested);
    connect(m_view, &PlaylistView::relocateRequested, this, &PlaylistWindow::relocateRequested);
    connect(m_view, &PlaylistView::radioAddressRequested, this, &PlaylistWindow::radioAddressRequested);
    connect(m_view, &PlaylistView::radioRetryRequested, this, [this](const Track &track) {
        if (m_controller->currentTrack().isNull() ||
            m_controller->currentTrack().identityKey() != track.identityKey()) {
            const auto tracks = m_controller->tracks();
            for (int i = 0; i < tracks.size(); ++i)
                if (tracks[i].identityKey() == track.identityKey()) {
                    m_controller->playRowAt(i);
                    return;
                }
        }
        m_controller->retryRadio();
    });
    auto *escape = new QShortcut(QKeySequence(Qt::Key_Escape), this);
    connect(escape, &QShortcut::activated, this, &PlaylistWindow::clearSearch);
    root->addLayout(right, 1);

    // —— 防抖搜索 ——
    m_debounce = new QTimer(this);
    m_debounce->setSingleShot(true);
    m_debounce->setInterval(kSearchDebounceMs);
    connect(m_debounce, &QTimer::timeout, this, &PlaylistWindow::applySearch);
    connect(m_search, &SkinLineEdit::textChanged, this, [this] { m_debounce->start(); });

    // 放大镜：展开 / 收起搜索框（收起即退出搜索、还原当前页）
    connect(m_searchToggle, &TTButton::clicked, this, [this] {
        if (!m_searchOpen) {
            m_searchOpen = true;
            m_search->setVisible(true);
            m_search->setFocus();
        } else {
            clearSearch();
        }
        m_searchToggle->setLit(m_searchOpen);
    });
    // Esc 直接退出搜索（不只是丢焦点，否则回到列表看见的是空表）
    connect(m_search, &SkinLineEdit::returnPressed, this, [this] {
        m_debounce->stop();
        applySearch();
    });

    // 左栏切页：当前行变了→取该行携带的 viewId 切页。
    connect(m_groups, &SkinListView::currentRowChanged, this, [this](int row) {
        if (row < 0) return;
        showPage(m_groups->rowData(row).toString());
    });

    // 歌单操作（新建/重命名/删除/导入/导出）已收进「列表」下拉，见 buildListMenu()。

    // R13 左栏电台页/分类页右键：新建分类（两类都给）、重命名/删除（只给真分类，未分类改不了也删不掉）。
    m_groups->setContextMenuPolicy(Qt::CustomContextMenu);
    connect(m_groups, &QWidget::customContextMenuRequested, this, [this](const QPoint &pos) {
        const int r = m_groups->rowAt(pos);
        const QString viewId = r >= 0 ? m_groups->rowData(r).toString() : QString();
        const bool isRadio = (viewId == Collections::kRadioViewId);
        const bool isCat = Collections::isRadioCatView(viewId);
        if (!isRadio && !isCat) return; // 分类入口只在电台页上给，别处不给（会让人以为能往任意页建）
        const QString catId = isCat ? Collections::radioCatIdOf(viewId) : QString();
        const bool realCat = isCat && catId != RadioStations::uncategorizedID;
        QMenu menu(this);
        QAction *newCat = menu.addAction(QStringLiteral("新建电台分类…"));
        QAction *renameCat = nullptr, *delCat = nullptr;
        if (realCat) {
            const QString name = m_collections->radios().nameOf(catId);
            renameCat = menu.addAction(QStringLiteral("重命名分类「%1」…").arg(name));
            delCat = menu.addAction(QStringLiteral("删除分类「%1」…").arg(name));
        }
        QAction *chosen = menu.exec(m_groups->mapToGlobal(pos));
        if (!chosen) return;
        if (chosen == newCat) {
            bool ok = false;
            const QString name = QInputDialog::getText(this, QStringLiteral("新建电台分类"), QStringLiteral("分类名称"),
                                                       QLineEdit::Normal, QString(), &ok);
            if (!ok) return;
            QString madeId, note;
            if (!m_collections->radios().createCategory(name, &madeId, &note)) return;
            if (!note.isEmpty()) QMessageBox::information(this, QStringLiteral("新建电台分类"), note);
            showPage(Collections::radioCatViewId(madeId)); // 建完就看这一页
            refreshGroups();
            emit collectionsChanged();
        } else if (renameCat && chosen == renameCat) {
            bool ok = false;
            const QString name = QInputDialog::getText(this, QStringLiteral("重命名分类"), QStringLiteral("新名称"),
                                                       QLineEdit::Normal, m_collections->radios().nameOf(catId), &ok);
            if (!ok) return;
            const QString err = m_collections->radios().renameCategory(catId, name);
            if (!err.isEmpty()) {
                QMessageBox::warning(this, QStringLiteral("重命名分类"), err);
                return;
            }
            if (m_collections->viewId() == viewId) showPage(viewId);
            refreshGroups();
            emit collectionsChanged();
        } else if (delCat && chosen == delCat) {
            const int n = m_collections->radioCountIn(catId);
            const auto ret =
                QMessageBox::question(this, QStringLiteral("删除分类"),
                                      QStringLiteral("确定删除分类「%1」？%2 个台会回到未分类（地址与台名都不动）。")
                                          .arg(m_collections->radios().nameOf(catId))
                                          .arg(n));
            if (ret != QMessageBox::Yes) return;
            int moved = 0;
            if (!m_collections->radios().deleteCategory(catId, &moved)) return;
            if (m_collections->viewId() == viewId) // 正在看这一页→先落到未分类，不能停在一张已删的页上
                showPage(Collections::radioCatViewId(RadioStations::uncategorizedID));
            refreshGroups();
            emit collectionsChanged();
        }
    });

    // 控制器换页 / 元数据晚到 → 只刷计数（列表内容 Collections 已在切页时喂好）
    connect(m_controller, &PlayerController::listChanged, this, &PlaylistWindow::updateInfo);

    // 右键页级入口：添加 / 列表（定位/排序/模式/队列/清空） / 歌单（定义级动作）
    connect(m_view, &PlaylistView::addFilesRequested, this, &PlaylistWindow::addRequested);
    connect(m_view, &PlaylistView::addFolderRequested, this, &PlaylistWindow::addFolderRequested);
    connect(m_view, &PlaylistView::addRadioRequested, this, &PlaylistWindow::radioRequested);
    connect(m_view, &PlaylistView::queueRequested, this, &PlaylistWindow::queueRequested);
    connect(m_view, &PlaylistView::sortRequested, this, [this](int key) { sortView(key); });
    // 右键「歌单」子菜单：视图建菜单，内容由本窗按当前页现填
    connect(m_view, &PlaylistView::playlistMenuRequested, this, &PlaylistWindow::buildListMenu);
    // 右键「列表 / 清空当前列表」（视图已按当前页藏掉不能清的情形，这里再守一道）
    connect(m_view, &PlaylistView::clearListRequested, this, [this] {
        if (m_beforeSearch || m_collections->viewId() == Collections::kLibraryViewId) return;
        QList<int> rows;
        for (int i = 0; i < m_controller->tracks().size(); ++i)
            rows << i;
        removeRows(rows);
    });

    // 右键「从列表移除」（可多选）
    connect(m_view, &PlaylistView::removeRequested, this, &PlaylistWindow::removeRows);

    // 拖拽重排当前页
    connect(m_view, &PlaylistView::reorderRequested, this, &PlaylistWindow::reorderCurrentView);

    // 右键播放类：直接走控制器的队列 API（不打断当前曲），多选按选区升序整段入队
    connect(m_view, &PlaylistView::enqueueNextRequested, this, [this](const QList<int> &rows) {
        const QList<Track> cur = m_controller->tracks();
        QList<Track> picked;
        for (const int row : rows)
            if (row >= 0 && row < cur.size()) picked.append(cur[row]);
        if (!picked.isEmpty()) m_controller->enqueueNext(picked);
    });
    connect(m_view, &PlaylistView::enqueueLaterRequested, this, [this](const QList<int> &rows) {
        const QList<Track> cur = m_controller->tracks();
        QList<Track> picked;
        for (const int row : rows)
            if (row >= 0 && row < cur.size()) picked.append(cur[row]);
        if (!picked.isEmpty()) m_controller->enqueueLater(picked);
    });

    // 右键集合类：加入指定页（@fav 或自建歌单），已在页内不重复加（addKeys/toggle 自带去重）
    connect(m_view, &PlaylistView::addToListRequested, this, [this](const QList<int> &rows, const QString &listId) {
        const QList<Track> cur = m_controller->tracks();
        QStringList keys;
        for (const int row : rows)
            if (row >= 0 && row < cur.size()) keys.append(cur[row].identityKey());
        if (keys.isEmpty()) return;
        if (listId == Collections::kFavViewId) {
            for (const QString &k : std::as_const(keys))
                if (!m_collections->isFavorite(k)) m_collections->toggleFavorite(k);
        } else {
            m_collections->playlists().addKeys(keys, listId);
        }
        if (m_collections->viewId() == listId && !m_searchOpen) showPage(listId);
        emit collectionsChanged();
    });
    connect(m_view, &PlaylistView::toggleFavoriteRequested, this, [this](const QList<int> &rows) {
        const QList<Track> cur = m_controller->tracks();
        bool any = false;
        for (const int row : rows)
            if (row >= 0 && row < cur.size()) {
                m_collections->toggleFavorite(cur[row].identityKey());
                any = true;
            }
        if (!any) return;
        if (m_collections->viewId() == Collections::kFavViewId && !m_searchOpen) showPage(Collections::kFavViewId);
        emit collectionsChanged();
    });

    // R13 右键电台行「重命名台名…」：台名记在地址上，空名 = 取消自定义（回落内置名/地址）。
    connect(m_view, &PlaylistView::radioAliasRequested, this, [this](const QList<int> &rows) {
        const QList<Track> cur = m_controller->tracks();
        Track target;
        for (const int row : rows)
            if (row >= 0 && row < cur.size() && cur[row].isRadio()) {
                target = cur[row];
                break;
            }
        if (target.isNull()) return;
        bool ok = false;
        const QString curName = m_collections->radios().displayName(target.url());
        const QString name =
            QInputDialog::getText(this, QStringLiteral("重命名电台"), QStringLiteral("台名（留空=取消自定义）"),
                                  QLineEdit::Normal, curName, &ok);
        if (!ok) return;
        m_collections->radios().setAlias(target.identityKey(), name);
        m_collections->refreshRadioTitles();
        if (!m_searchOpen) showPage(m_collections->viewId());
        emit collectionsChanged();
    });
    // R13 右键电台行「移入分类」：只改归属，地址与台名不动；catId=未分类 id 则摘归属。
    connect(m_view, &PlaylistView::radioMoveCategoryRequested, this,
            [this](const QList<int> &rows, const QString &catId) {
                const QList<Track> cur = m_controller->tracks();
                QStringList keys;
                for (const int row : rows)
                    if (row >= 0 && row < cur.size() && cur[row].isRadio()) keys.append(cur[row].identityKey());
                if (keys.isEmpty()) return;
                QString problem;
                m_collections->radios().moveRadios(keys, catId, &problem);
                if (!problem.isEmpty()) {
                    QMessageBox::warning(this, QStringLiteral("移入分类"), problem);
                    return;
                }
                m_collections->refreshRadioTitles();
                const QString view = m_collections->viewId();
                if (!m_searchOpen && (view == Collections::kRadioViewId || Collections::isRadioCatView(view)))
                    showPage(view); // 当前正看电台/分类页：重投影
                refreshGroups();    // 分类行的台数变了
                emit collectionsChanged();
            });

    refreshGroups();
    updateInfo();
}

void PlaylistWindow::removeRows(const QList<int> &rows) {
    const QList<Track> cur = m_controller->tracks(); // 移除前的快照，按 key 删不受行号影响
    const QString view = m_collections->viewId();
    // 媒体库页是扫描的只读投影：删不动，先说清楚该去哪里收
    if (!m_beforeSearch && view == Collections::kLibraryViewId) {
        QMessageBox::information(
            this, QStringLiteral("媒体库"),
            QStringLiteral("媒体库是扫描出来的只读投影：想少收几首请在菜单「媒体库」里移除对应目录。"));
        return;
    }
    if (m_beforeSearch) {
        QSet<QString> keys;
        QList<Track> hits;
        for (int row : rows)
            if (row >= 0 && row < cur.size() && !keys.contains(cur[row].identityKey())) {
                keys.insert(cur[row].identityKey());
                hits << cur[row];
            }
        if (keys.isEmpty()) return;
        m_collections->removeSearchHits(keys);
        m_controller->dropTracks(keys);
        for (const Track &track : hits)
            emit trackRemoved(track);
        applySearch();
        emit collectionsChanged();
        return;
    }
    QList<Track> removed;
    QSet<QString> seen;
    for (const int row : rows) {
        if (row < 0 || row >= cur.size()) continue;
        const Track &t = cur[row];
        if (seen.contains(t.identityKey())) continue;
        seen.insert(t.identityKey());
        if (m_collections->removeTrackFromView(view, t.identityKey())) removed.append(t);
    }
    if (removed.isEmpty()) return;
    showPage(view); // 退出搜索态 + 重喂该页（行号随之失效，不拿旧 row 再动）
    if (view == Collections::kAllViewId || view == Collections::kRadioViewId || Collections::isRadioCatView(view)) {
        QSet<QString> keys;
        for (const Track &track : std::as_const(removed)) {
            keys.insert(track.identityKey());
            emit trackRemoved(track);
        }
        m_controller->dropTracks(keys);
    }
    // Only real deletions decline presets; cancelling a favorite or history entry does not.    // 外层记内置电台黑名单（必须在 collectionsChanged 之前）
    emit collectionsChanged(); // 外层 invalidateIndex + saveState
}

void PlaylistWindow::reorderCurrentView(int target) {
    const QList<Track> cur = m_controller->tracks();
    if (cur.isEmpty()) return;
    QStringList displayed;
    displayed.reserve(cur.size());
    for (const Track &t : cur)
        displayed.append(t.identityKey());
    const QList<int> rows = m_view->selectedRows();
    const QSet<int> selected(rows.cbegin(), rows.cend());
    const QStringList order = Collections::applyMove(displayed, selected, target);
    const QString view = m_collections->viewId();
    if (order == displayed) return;               // 没真移动
    if (!m_collections->reorderView(view, order)) // 派生页只读：重排不了，静默不列
        return;
    showPage(view);
    emit collectionsChanged();
}

QString PlaylistWindow::selectedViewId() const {
    const int r = m_groups->currentRow();
    if (r >= 0) return m_groups->rowData(r).toString();
    return Collections::kAllViewId;
}

void PlaylistWindow::refreshGroups() {
    const QString want = m_collections->viewId();
    QSignalBlocker block(m_groups); // 重建选择期间不触发切页回调
    m_groups->clear();
    int wantRow = -1, fallbackRow = -1, row = 0;
    for (const auto &p : m_collections->viewList()) {
        m_groups->addItem(p.second, p.first); // 行携带 viewId（UserRole 语义）
        if (p.first == want) wantRow = row;
        if (p.first == Collections::kAllViewId) fallbackRow = row;
        ++row;
    }
    m_groups->setCurrentRow(wantRow >= 0 ? wantRow : fallbackRow);
    // 同步当前页的空提示（启动/重扫可能没走过 showPage）
    m_view->setEmptyHint(Collections::emptyHintFor(m_collections->viewId()));
}

void PlaylistWindow::showPage(const QString &viewId) {
    m_beforeSearch.reset();
    m_formats.clear();
    m_debounce->stop();
    m_view->setSearching(false);
    m_view->setFilterActive(false);
    m_collections->setViewId(viewId);
    syncGroupSelection(viewId); // 程序化切页（新建/删除/导入）也要把左栏高亮对齐，不递归触发切页
    // 切页 = 退出搜索态（命中表不能跟着换页残留，pitfall #13）
    if (m_searchOpen || !m_search->text().isEmpty()) {
        QSignalBlocker b(m_search);
        m_search->clear();
        m_searchOpen = false;
        m_search->setVisible(false);
        m_searchToggle->setLit(false);
    }
    m_controller->setTracks(m_collections->currentTracks());
    m_view->setEmptyHint(Collections::emptyHintFor(viewId));
    updateInfo();
}

// 把左栏当前行对齐到 viewId（QSignalBlocker 防递归回 currentRowChanged→showPage）。
void PlaylistWindow::syncGroupSelection(const QString &viewId) {
    QSignalBlocker block(m_groups);
    for (int i = 0; i < m_groups->count(); ++i) {
        if (m_groups->rowData(i).toString() == viewId) {
            m_groups->setCurrentRow(i);
            return;
        }
    }
}

void PlaylistWindow::applySearch() {
    const QString kw = m_search->text();
    const bool active = !kw.trimmed().isEmpty() || !m_formats.isEmpty();
    if (active && !m_beforeSearch) m_beforeSearch = m_view->scene();
    m_view->setSearching(!kw.trimmed().isEmpty());
    m_view->setFilterActive(active);
    if (!active) {
        m_controller->setTracks(m_collections->currentTracks());
        if (m_beforeSearch) {
            m_view->restoreScene(*m_beforeSearch);
            m_beforeSearch.reset();
        }
        m_view->setEmptyHint(Collections::emptyHintFor(m_collections->viewId()));
    } else {
        const SearchResult r = m_collections->search(TrackFilter(kw, m_formats));
        QList<Track> hits;
        hits.reserve(r.hits.size());
        for (const SearchHit &h : r.hits)
            hits.append(h.track);
        m_controller->setTracks(hits);
        m_view->setEmptyHint(QStringLiteral("没有搜到：换个关键字，或按 Esc 收起搜索"));
    }
    updateInfo();
}

void PlaylistWindow::focusSearch() {
    if (!m_searchOpen) {
        m_searchOpen = true;
        m_search->setVisible(true);
        m_searchToggle->setLit(true);
    }
    m_search->setFocus();
    m_search->selectAll();
}

void PlaylistWindow::probeSearch(const QString &text) {
    focusSearch();
    m_debounce->stop();
    m_search->setText(text); // textChanged 会重启防抖，这里立即应用并停掉它
    m_debounce->stop();
    applySearch();
}

void PlaylistWindow::clearSearch() {
    m_debounce->stop();
    m_formats.clear();
    m_view->setSearching(false);
    m_view->setFilterActive(false);
    {
        QSignalBlocker b(m_search);
        m_search->clear();
    }
    m_searchOpen = false;
    m_search->setVisible(false);
    m_searchToggle->setLit(false);
    m_controller->setTracks(m_collections->currentTracks());
    if (m_beforeSearch) {
        m_view->restoreScene(*m_beforeSearch);
        m_beforeSearch.reset();
    }
    m_view->setEmptyHint(Collections::emptyHintFor(m_collections->viewId()));
    updateInfo();
}

void PlaylistWindow::updateInfo() {
    const bool searching = m_searchOpen && !m_search->text().trimmed().isEmpty();
    const QList<Track> tracks = m_controller->tracks();
    const int n = tracks.size();
    if (searching) {
        m_info->setText(QStringLiteral("命中 %1 首").arg(n));
        return;
    }
    // 参考图口径：共 N 首 · MM:SS（累加非电台时长，电台直播不计入）
    double total = 0;
    for (const Track &t : tracks)
        if (!t.isRadio() && t.duration() > 0) total += t.duration();
    const int s = int(std::lround(total));
    m_info->setText(QStringLiteral("共 %1 首 · %2:%3").arg(n).arg(s / 60).arg(s % 60, 2, 10, QLatin1Char('0')));
}

// 当前页排序写回成员次序；搜索态不排序，key>=4 代表降序。
void PlaylistWindow::sortView(int key) {
    if (m_beforeSearch) return;
    const bool descending = key >= 4;
    if (descending) key -= 4;
    if (key < 0) {
        showPage(m_collections->viewId());
        return;
    }
    QList<Track> tracks = m_controller->tracks();
    std::stable_sort(tracks.begin(), tracks.end(), [key](const Track &a, const Track &b) {
        switch (key) {
        case 0:
            return a.title().localeAwareCompare(b.title()) < 0;
        case 1:
            return a.artist().localeAwareCompare(b.artist()) < 0;
        case 2:
            return a.album().localeAwareCompare(b.album()) < 0;
        case 3:
            return a.duration() < b.duration();
        default:
            break;
        }
        return false;
    });
    if (descending) std::reverse(tracks.begin(), tracks.end());
    QStringList order;
    for (const Track &track : tracks)
        order << track.identityKey();
    if (m_collections->reorderView(m_collections->viewId(), order)) {
        m_controller->setTracks(tracks);
        emit collectionsChanged();
    }
    updateInfo();
}

// 「歌单」子菜单：每次右键现填。只列当前页真能做的定义级动作 —— 固定页没有重命名/删除，
// 空页没有可导出内容，非自建歌单页不能往本页加歌；点了才弹「不能…」的项不再出现。
void PlaylistWindow::buildListMenu(QMenu *menu) {
    if (!menu) return;
    menu->clear(); // 可用项跟着当前页走，不缓存上一次的判定
    const QString id = m_collections->viewId();
    const bool custom = m_collections->playlists().contains(id);
    connect(menu->addAction(QStringLiteral("新建歌单…")), &QAction::triggered, this, [this] {
        bool ok = false;
        const QString name = QInputDialog::getText(this, QStringLiteral("新建歌单"), QStringLiteral("歌单名称"),
                                                   QLineEdit::Normal, QString(), &ok);
        if (!ok) return;
        QString id, note;
        if (!m_collections->playlists().create(name, &id, &note)) {
            QMessageBox::warning(this, QStringLiteral("新建歌单"),
                                 note.isEmpty() ? QStringLiteral("歌单名不能为空") : note);
            return;
        }
        refreshGroups();
        showPage(id);
        emit collectionsChanged();
    });
    if (custom) {
        connect(menu->addAction(QStringLiteral("添加文件到当前歌单…")), &QAction::triggered, this, [this] {
            const QStringList files = QFileDialog::getOpenFileNames(
                this, QStringLiteral("添加音频文件"), QDir::homePath(),
                QStringLiteral(
                    "音频与压缩包 (*.mp3 *.flac *.wav *.m4a *.aac *.ogg *.opus *.ape *.wv *.tta *.dsf "
                    "*.dff *.cue *.zip *.7z *.rar *.tar *.gz *.tgz *.bz2 *.tbz *.xz *.txz *.zst);;"
                    "音频文件 (*.mp3 *.flac *.wav *.m4a *.aac *.ogg *.opus *.ape *.wv *.tta *.dsf *.dff "
                    "*.cue);;"
                    "压缩包 (*.zip *.7z *.rar *.tar *.gz *.tgz *.bz2 *.tbz *.xz *.txz *.zst);;所有文件 (*)"));
            addPathsToCurrentPlaylist(files);
        });
        connect(menu->addAction(QStringLiteral("添加文件夹到当前歌单…")), &QAction::triggered, this, [this] {
            const QString dir = QFileDialog::getExistingDirectory(this, QStringLiteral("添加文件夹"), QDir::homePath());
            if (!dir.isEmpty()) addPathsToCurrentPlaylist({dir});
        });
    }
    connect(menu->addAction(QStringLiteral("导入 m3u…")), &QAction::triggered, this, [this] {
        const QString path = QFileDialog::getOpenFileName(this, QStringLiteral("导入歌单"), QDir::homePath(),
                                                          QStringLiteral("播放列表 (*.m3u *.m3u8)"));
        if (path.isEmpty()) return;
        PlaylistM3U::Imported imp;
        if (!PlaylistM3U::importFile(path, imp)) {
            QMessageBox::warning(this, QStringLiteral("导入"), QStringLiteral("读不出这个歌单文件"));
            return;
        }
        QString id, note;
        const QString baseName = QFileInfo(path).completeBaseName();
        if (!m_collections->playlists().create(baseName, &id, &note)) {
            QMessageBox::warning(this, QStringLiteral("导入"), note.isEmpty() ? QStringLiteral("无法创建歌单") : note);
            return;
        }
        m_collections->playlists().addKeys(imp.keys, id);
        refreshGroups();
        showPage(id);
        emit collectionsChanged();
        if (!imp.missing.isEmpty())
            QMessageBox::information(
                this, QStringLiteral("导入"),
                QStringLiteral("已导入 %1 首，其中 %2 个当前不在盘上").arg(imp.keys.size()).arg(imp.missing.size()));
    });
    // 空页导出没有内容，直接不列（比点完弹「这一页是空的」少一步废话）
    if (!m_collections->tracksOf(id).isEmpty()) {
        connect(menu->addAction(QStringLiteral("导出当前页为 m3u…")), &QAction::triggered, this, [this, id] {
            const QList<Track> tracks = m_collections->tracksOf(id);
            const QString name = m_collections->playlists().nameOf(id);
            const QString defName = QStringLiteral("%1.m3u8").arg(name.isEmpty() ? QStringLiteral("播放列表") : name);
            const QString path = QFileDialog::getSaveFileName(this, QStringLiteral("导出歌单"),
                                                              QDir::homePath() + QLatin1Char('/') + defName,
                                                              QStringLiteral("播放列表 (*.m3u8)"));
            if (path.isEmpty()) return;
            if (!PlaylistM3U::exportTracks(tracks, path))
                QMessageBox::warning(this, QStringLiteral("导出"), QStringLiteral("写文件失败"));
        });
    }
    if (!custom) return;
    menu->addSeparator();
    connect(menu->addAction(QStringLiteral("重命名当前歌单…")), &QAction::triggered, this, [this, id] {
        bool ok = false;
        const QString name = QInputDialog::getText(this, QStringLiteral("重命名歌单"), QStringLiteral("新名称"),
                                                   QLineEdit::Normal, m_collections->playlists().nameOf(id), &ok);
        if (!ok) return;
        const QString err = m_collections->playlists().rename(id, name);
        if (!err.isEmpty()) {
            QMessageBox::warning(this, QStringLiteral("重命名"), err);
            return;
        }
        refreshGroups();
        emit collectionsChanged();
    });
    connect(menu->addAction(QStringLiteral("删除当前歌单")), &QAction::triggered, this, [this, id] {
        const auto ret =
            QMessageBox::question(this, QStringLiteral("删除歌单"),
                                  QStringLiteral("确定删除歌单「%1」？（只删这一张的定义，不动文件和别的歌单）")
                                      .arg(m_collections->playlists().nameOf(id)));
        if (ret != QMessageBox::Yes) return;
        m_collections->playlists().remove(id);
        refreshGroups();
        showPage(Collections::kAllViewId);
        emit collectionsChanged();
    });
}

// 把外部目录/音频加进当前自建歌单：与主窗导入同一条 Importer 链路（目录递归、m3u/CUE
// 展开、归档条目都在里面），读完注册进媒体库再写进这张歌单。读取放后台，大目录不卡 UI。
void PlaylistWindow::addPathsToCurrentPlaylist(const QStringList &paths) {
    const QString id = selectedViewId();
    if (!m_collections->playlists().contains(id)) {
        QMessageBox::information(this, QStringLiteral("加入歌单"),
                                 QStringLiteral("请先在左栏选中一张自建歌单，或用「新建歌单…」建一张"));
        return;
    }
    if (paths.isEmpty()) return;
    auto *watcher = new QFutureWatcher<Importer::Result>(this);
    connect(watcher, &QFutureWatcher<Importer::Result>::finished, this, [this, watcher, id] {
        const Importer::Result imported = watcher->result();
        watcher->deleteLater();
        if (imported.cancelled) return;
        if (imported.tracks.isEmpty()) {
            QMessageBox::information(this, QStringLiteral("加入歌单"),
                                     imported.problems.isEmpty() ? QStringLiteral("没有找到可播放的音频")
                                                                 : imported.problems.first());
            return;
        }
        const int added = addTracksToPlaylist(imported.tracks, id);
        refreshGroups();
        if (m_collections->viewId() == id) showPage(id);
        emit collectionsChanged();
        QString note = added > 0 ? QStringLiteral("已加入 %1 首").arg(added) : QStringLiteral("这些曲目都已经在歌单里");
        if (!imported.problems.isEmpty()) note += QStringLiteral("；%1 项无法导入").arg(imported.problems.size());
        QMessageBox::information(this, QStringLiteral("加入歌单"), note);
    });
    watcher->setFuture(QtConcurrent::run([paths] { return Importer::read(paths, true, nullptr); }));
}

int PlaylistWindow::addTracksToPlaylist(const QList<Track> &tracks, const QString &playlistId) {
    if (tracks.isEmpty() || !m_collections->playlists().contains(playlistId)) return 0;
    m_collections->registerTracks(tracks); // 先注册，歌单里的键才能还原成带元数据的曲目
    QStringList keys;
    for (const Track &track : tracks)
        keys << track.identityKey();
    return m_collections->playlists().addKeys(keys, playlistId);
}

void PlaylistWindow::dropEvent(QDropEvent *event) {
    // 自建歌单页：拖进来的目录/音频直接进这张歌单；其它页保持「导入媒体库」的原行为。
    const QString id = selectedViewId();
    if (event->mimeData()->hasUrls() && m_collections->playlists().contains(id)) {
        QStringList paths;
        for (const QUrl &url : event->mimeData()->urls())
            if (url.isLocalFile()) paths << url.toLocalFile();
        if (!paths.isEmpty()) {
            event->acceptProposedAction();
            addPathsToCurrentPlaylist(paths);
            return;
        }
    }
    SkinWindow::dropEvent(event);
}

void PlaylistWindow::paintBody(QPainter *p, const QRectF &rect) {
    // 统一毛玻璃：与主窗/均衡器同一层浅玻璃（不再铺深蓝 well），单一 alpha。
    const float wA = GlassStyle::enabled() ? GlassStyle::wellAlpha() : 1.0f;
    Painter::drawWell(p, rect.adjusted(0.5, 0.5, -0.5, -0.5), Theme::windowTop, Theme::windowBottom, wA, 5);
}
