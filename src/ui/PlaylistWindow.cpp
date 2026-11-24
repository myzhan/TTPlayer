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
    : SkinWindow(QStringLiteral("播放列表"), TitleButtons::None, parent), m_controller(controller),
      m_collections(collections) {
    resize(460, 380 + 30); // 与主窗/均衡器同一紧凑默认宽（+30 为标题条高度）

    auto *root = new QHBoxLayout(body());
    root->setContentsMargins(6, 6, 6, 6);
    root->setSpacing(6);

    // —— 左栏：多页浏览器（收藏 + 各自建列表 + 全部），统一毛玻璃自绘 SkinListView ——
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
        SkinMenu menu(this);
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

    // 左栏管理列表，右栏仅提供文件与电台操作。

    m_view = new PlaylistView(controller, this);
    m_view->setCollections(collections); // 行内收藏与电台分类共用集合层。
    right->addWidget(m_view, 1);
    connect(m_view, &PlaylistView::propertiesRequested, this, &PlaylistWindow::propertiesRequested);
    connect(m_view, &PlaylistView::convertRequested, this, &PlaylistWindow::convertRequested);
    connect(m_view, &PlaylistView::editRequested, this, &PlaylistWindow::editRequested);
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

    // 右键只绑定目标身份，不切换浏览页或丢掉右侧歌曲选区。
    m_groups->setContextMenuPolicy(Qt::CustomContextMenu);
    connect(m_groups, &QWidget::customContextMenuRequested, this, [this](const QPoint &pos) {
        const int row = m_groups->rowAt(pos);
        const QString viewId = row >= 0 ? m_groups->rowData(row).toString() : QString();
        SkinMenu menu(this);
        buildSidebarMenu(menu, viewId);
        menu.exec(m_groups->mapToGlobal(pos));
    });

    // 控制器换页 / 元数据晚到 → 只刷计数（列表内容 Collections 已在切页时喂好）
    connect(m_controller, &PlayerController::listChanged, this, &PlaylistWindow::updateInfo);

    // Delete 快捷键仍按当前页语义移除选区。
    connect(m_view, &PlaylistView::removeRequested, this, &PlaylistWindow::removeRows);

    // 拖拽重排当前页
    connect(m_view, &PlaylistView::reorderRequested, this, &PlaylistWindow::reorderCurrentView);

    connect(m_view, &PlaylistView::toggleFavoriteRequested, this, [this](const QString &key) {
        if (key.isEmpty()) return;
        m_collections->toggleFavorite(key);
        refreshFavorites();
        emit collectionsChanged();
    });

    // R13 电台台名与地址在行右键「编辑…」里一并提交（上层写 alias 与 URL 两条保存通道）。
    // 右键电台行「移入分类」：只改归属，地址与台名不动；catId=未分类 id 则摘归属。
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
    const QList<Track> cur = m_controller->tracks();
    QList<Track> picked;
    for (const int row : rows)
        if (row >= 0 && row < cur.size()) picked << cur[row];
    removeTracks(m_collections->viewId(), picked, m_beforeSearch.has_value());
}

// 菜单持有曲目身份快照，期间换页或重排不会把旧行号误用到另一首歌。
void PlaylistWindow::removeTracks(const QString &view, const QList<Track> &picked, bool searchHits) {
    // 媒体库页是扫描的只读投影：删不动，先说清楚该去哪里收
    if (!searchHits && view == Collections::kLibraryViewId) {
        QMessageBox::information(
            this, QStringLiteral("媒体库"),
            QStringLiteral("媒体库是扫描出来的只读投影：想少收几首请在菜单「媒体库」里移除对应目录。"));
        return;
    }
    if (searchHits) {
        QSet<QString> keys;
        QList<Track> hits;
        for (const Track &track : picked)
            if (!keys.contains(track.identityKey())) {
                keys.insert(track.identityKey());
                hits << track;
            }
        if (keys.isEmpty()) return;
        m_collections->removeSearchHits(keys);
        m_controller->dropTracks(keys);
        for (const Track &track : hits)
            emit trackRemoved(track);
        refreshFavorites();
        emit collectionsChanged();
        return;
    }
    QList<Track> removed;
    QSet<QString> seen;
    for (const Track &t : picked) {
        if (seen.contains(t.identityKey())) continue;
        seen.insert(t.identityKey());
        if (m_collections->removeTrackFromView(view, t.identityKey())) removed.append(t);
    }
    if (removed.isEmpty()) return;
    if (view == Collections::kAllViewId || view == Collections::kRadioViewId || Collections::isRadioCatView(view)) {
        QSet<QString> keys;
        for (const Track &track : std::as_const(removed)) {
            keys.insert(track.identityKey());
            emit trackRemoved(track);
        }
        m_controller->dropTracks(keys);
    }
    // 只有真实删除才记录电台黑名单；刷新当前浏览页，不强制切换到右键目标。
    refreshFavorites();
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

void PlaylistWindow::refreshFavorites() {
    const auto currentScene = m_view->scene();
    refreshGroups();
    if (m_beforeSearch) {
        m_debounce->stop();
        applySearch();
    } else {
        m_controller->setTracks(m_collections->currentTracks());
        updateInfo();
    }
    m_view->restoreScene(currentScene);
    m_view->viewport()->update();
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
    // 共 N 首 · HH:MM:SS：累加非电台时长，小时不按 24 小时截断。
    double total = 0;
    for (const Track &t : tracks)
        if (!t.isRadio() && t.duration() > 0) total += t.duration();
    const qint64 s = std::llround(total);
    m_info->setText(QStringLiteral("共 %1 首 · %2:%3:%4")
                        .arg(n)
                        .arg(s / 3600, 2, 10, QLatin1Char('0'))
                        .arg(s / 60 % 60, 2, 10, QLatin1Char('0'))
                        .arg(s % 60, 2, 10, QLatin1Char('0')));
}

// 按目标身份写回成员次序；不把当前页的筛选结果当作整页，key>=4 代表降序。
void PlaylistWindow::sortView(int key, const QString &viewId) {
    const QString id = viewId.isEmpty() ? m_collections->viewId() : viewId;
    if (id == m_collections->viewId() && m_view->filterActive()) return;
    const bool descending = key >= 4;
    if (descending) key -= 4;
    if (key < 0) {
        if (id == m_collections->viewId()) showPage(id);
        return;
    }
    QList<Track> tracks = m_collections->tracksOf(id);
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
    if (m_collections->reorderView(id, order)) {
        if (id == m_collections->viewId()) m_controller->setTracks(tracks);
        emit collectionsChanged();
    }
    updateInfo();
}

// 左栏菜单：页级动作绑定右键目标，曲目动作绑定右侧选区的稳定身份。
void PlaylistWindow::buildSidebarMenu(QMenu &menu, const QString &id) {
    const QString source = m_collections->viewId();
    const bool current = id == source;
    const bool filtered = current && m_view->filterActive();
    const bool custom = m_collections->playlists().contains(id);
    const bool library = id == Collections::kLibraryViewId;
    const QList<Track> target = m_collections->tracksOf(id);
    const QList<Track> displayed = m_controller->tracks();
    QList<Track> picked;
    QStringList keys;
    for (const int row : m_view->selectedRows()) {
        if (row < 0 || row >= displayed.size()) continue;
        picked << displayed[row];
        keys << displayed[row].identityKey();
    }
    if (!keys.isEmpty()) {
        QMenu *lists = nullptr;
        for (const UserPlaylist &pl : m_collections->playlists().items()) {
            const QStringList members = m_collections->playlists().keysOf(pl.id);
            const QSet<QString> inList(members.cbegin(), members.cend());
            if (std::all_of(keys.cbegin(), keys.cend(), [&inList](const QString &key) { return inList.contains(key); }))
                continue;
            if (!lists) lists = SkinMenu::addSubmenu(menu, QStringLiteral("加入列表"));
            connect(lists->addAction(pl.name), &QAction::triggered, this, [this, keys, listId = pl.id] {
                if (m_collections->playlists().addKeys(keys, listId) == 0) return;
                refreshFavorites();
                emit collectionsChanged();
            });
        }
        QList<Track> removable;
        QSet<QString> members;
        for (const Track &track : target)
            members.insert(track.identityKey());
        for (const Track &track : picked)
            if (filtered || members.contains(track.identityKey())) removable << track;
        if (!id.isEmpty() && (!library || filtered) && !removable.isEmpty())
            connect(menu.addAction(QStringLiteral("从列表移除")), &QAction::triggered, this,
                    [this, id, removable, filtered] { removeTracks(id, removable, filtered); });
    }
    if (!menu.isEmpty()) menu.addSeparator();
    // 添加▸ 按页类型给项：
    //   曲库 / 自定义列表 → 本地文件与文件夹
    //   电台 / 电台分类（含未分类）→ 网络电台
    //   全部 / 收藏 不显示添加▸（派生视图，要导入请回曲库）
    const bool radioPage = id == Collections::kRadioViewId || Collections::isRadioCatView(id);
    const bool localAdd = library || custom;
    QMenu *add = nullptr;
    if (radioPage || localAdd) add = SkinMenu::addSubmenu(menu, QStringLiteral("添加"));
    if (localAdd && add) {
        connect(add->addAction(QStringLiteral("添加文件…")), &QAction::triggered, this, [this, id, custom] {
            if (!custom) {
                emit addRequested();
                return;
            }
            const QStringList files = QFileDialog::getOpenFileNames(this, QStringLiteral("添加音频文件"),
                                                                    QDir::homePath(), Importer::fileDialogFilter());
            if (!files.isEmpty()) addPathsToCurrentPlaylist(files, id);
        });
        connect(add->addAction(QStringLiteral("添加文件夹…")), &QAction::triggered, this, [this, id, custom] {
            if (!custom) {
                emit addFolderRequested();
                return;
            }
            const QString dir = QFileDialog::getExistingDirectory(this, QStringLiteral("添加文件夹"), QDir::homePath());
            if (!dir.isEmpty()) addPathsToCurrentPlaylist({dir}, id);
        });
    }
    if (radioPage && add)
        connect(add->addAction(QStringLiteral("添加网络电台…")), &QAction::triggered, this,
                &PlaylistWindow::radioRequested);

    const Track currentTrack = m_controller->currentTrack();
    const QString playing = currentTrack.isNull() ? QString() : currentTrack.identityKey();
    if (!id.isEmpty() && std::any_of(target.cbegin(), target.cend(), [&playing](const Track &track) {
            return !playing.isEmpty() && track.identityKey() == playing;
        }))
        connect(menu.addAction(QStringLiteral("定位当前曲")), &QAction::triggered, this, [this, id] {
            if (m_collections->viewId() != id || m_view->filterActive()) showPage(id);
            m_view->scrollToCurrent();
        });
    const bool sortable = custom || id == Collections::kAllViewId || id == Collections::kFavViewId;
    if (sortable && !filtered && !target.isEmpty()) {
        QMenu *sort = SkinMenu::addSubmenu(menu, QStringLiteral("排序"));
        const QStringList names = {QStringLiteral("按标题"),     QStringLiteral("按艺术家"),
                                   QStringLiteral("按专辑"),     QStringLiteral("按时长"),
                                   QStringLiteral("按标题降序"), QStringLiteral("按艺术家降序"),
                                   QStringLiteral("按专辑降序"), QStringLiteral("按时长降序")};
        for (int key = 0; key < names.size(); ++key) {
            connect(sort->addAction(names[key]), &QAction::triggered, this, [this, id, key] { sortView(key, id); });
            if (key == 3) sort->addSeparator();
        }
        connect(sort->addAction(QStringLiteral("还原原序")), &QAction::triggered, this,
                [this, id] { sortView(-1, id); });
    }
    // 播放模式不在列表右键里——TransportBar 的 m_mode 循环键已唯一入口。
    if (!id.isEmpty() && !library && !filtered && !target.isEmpty())
        connect(menu.addAction(QStringLiteral("清空列表")), &QAction::triggered, this, [this, id] {
            if (id == m_collections->viewId() && m_view->filterActive()) return;
            removeTracks(id, m_collections->tracksOf(id));
        });
    buildListMenu(&menu, id);

    if (id != Collections::kRadioViewId && !Collections::isRadioCatView(id)) return;
    menu.addSeparator();
    connect(menu.addAction(QStringLiteral("新建电台分类…")), &QAction::triggered, this, [this] {
        bool ok = false;
        const QString name = QInputDialog::getText(this, QStringLiteral("新建电台分类"), QStringLiteral("分类名称"),
                                                   QLineEdit::Normal, QString(), &ok);
        if (!ok) return;
        QString madeId, note;
        if (!m_collections->radios().createCategory(name, &madeId, &note)) return;
        if (!note.isEmpty()) QMessageBox::information(this, QStringLiteral("新建电台分类"), note);
        refreshGroups();
        showPage(Collections::radioCatViewId(madeId));
        emit collectionsChanged();
    });
    const QString catId = Collections::isRadioCatView(id) ? Collections::radioCatIdOf(id) : QString();
    if (catId.isEmpty() || catId == RadioStations::uncategorizedID) return;
    const QString name = m_collections->radios().nameOf(catId);
    connect(menu.addAction(QStringLiteral("重命名分类「%1」…").arg(name)), &QAction::triggered, this, [this, catId] {
        bool ok = false;
        const QString renamed = QInputDialog::getText(this, QStringLiteral("重命名分类"), QStringLiteral("新名称"),
                                                      QLineEdit::Normal, m_collections->radios().nameOf(catId), &ok);
        if (!ok) return;
        const QString err = m_collections->radios().renameCategory(catId, renamed);
        if (!err.isEmpty()) {
            QMessageBox::warning(this, QStringLiteral("重命名分类"), err);
            return;
        }
        refreshGroups();
        emit collectionsChanged();
    });
    connect(menu.addAction(QStringLiteral("删除分类「%1」…").arg(name)), &QAction::triggered, this, [this, id, catId] {
        const auto ret =
            QMessageBox::question(this, QStringLiteral("删除分类"),
                                  QStringLiteral("确定删除分类「%1」？%2 个台会回到未分类（地址与台名都不动）。")
                                      .arg(m_collections->radios().nameOf(catId))
                                      .arg(m_collections->radioCountIn(catId)));
        if (ret != QMessageBox::Yes) return;
        int moved = 0;
        if (!m_collections->radios().deleteCategory(catId, &moved)) return;
        if (m_collections->viewId() == id) showPage(Collections::radioCatViewId(RadioStations::uncategorizedID));
        refreshGroups();
        emit collectionsChanged();
    });
}

// 左栏新建流程，创建成功后刷新并选中新列表。
void PlaylistWindow::createPlaylist() {
    bool ok = false;
    const QString name = QInputDialog::getText(this, QStringLiteral("新建列表"), QStringLiteral("列表名称"),
                                               QLineEdit::Normal, QString(), &ok);
    if (!ok) return;
    QString id, note;
    if (!m_collections->playlists().create(name, &id, &note)) {
        QMessageBox::warning(this, QStringLiteral("新建列表"),
                             note.isEmpty() ? QStringLiteral("列表名不能为空") : note);
        return;
    }
    refreshGroups();
    showPage(id);
    emit collectionsChanged();
}

// 左栏定义级动作绑定右键目标；固定页不能重命名或删除。
void PlaylistWindow::buildListMenu(QMenu *menu, const QString &id) {
    if (!menu) return;
    if (!menu->isEmpty()) menu->addSeparator();
    const bool custom = m_collections->playlists().contains(id);
    connect(menu->addAction(QStringLiteral("新建列表…")), &QAction::triggered, this, &PlaylistWindow::createPlaylist);
    connect(menu->addAction(QStringLiteral("导入 m3u…")), &QAction::triggered, this, [this] {
        const QString path = QFileDialog::getOpenFileName(this, QStringLiteral("导入列表"), QDir::homePath(),
                                                          QStringLiteral("播放列表 (*.m3u *.m3u8)"));
        if (path.isEmpty()) return;
        PlaylistM3U::Imported imp;
        if (!PlaylistM3U::importFile(path, imp)) {
            QMessageBox::warning(this, QStringLiteral("导入"), QStringLiteral("读不出这个列表文件"));
            return;
        }
        QString id, note;
        const QString baseName = QFileInfo(path).completeBaseName();
        if (!m_collections->playlists().create(baseName, &id, &note)) {
            QMessageBox::warning(this, QStringLiteral("导入"), note.isEmpty() ? QStringLiteral("无法创建列表") : note);
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
        connect(menu->addAction(QStringLiteral("导出为 m3u…")), &QAction::triggered, this, [this, id] {
            const QList<Track> tracks = m_collections->tracksOf(id);
            const QString name = m_collections->playlists().nameOf(id);
            const QString defName = QStringLiteral("%1.m3u8").arg(name.isEmpty() ? QStringLiteral("播放列表") : name);
            const QString path = QFileDialog::getSaveFileName(this, QStringLiteral("导出列表"),
                                                              QDir::homePath() + QLatin1Char('/') + defName,
                                                              QStringLiteral("播放列表 (*.m3u8)"));
            if (path.isEmpty()) return;
            if (!PlaylistM3U::exportTracks(tracks, path))
                QMessageBox::warning(this, QStringLiteral("导出"), QStringLiteral("写文件失败"));
        });
    }
    if (!custom) return;
    menu->addSeparator();
    connect(menu->addAction(QStringLiteral("重命名列表…")), &QAction::triggered, this, [this, id] {
        bool ok = false;
        const QString name = QInputDialog::getText(this, QStringLiteral("重命名列表"), QStringLiteral("新名称"),
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
    connect(menu->addAction(QStringLiteral("删除列表")), &QAction::triggered, this, [this, id] {
        const auto ret =
            QMessageBox::question(this, QStringLiteral("删除列表"),
                                  QStringLiteral("确定删除列表「%1」？（只删除此列表，不动文件和其他列表）")
                                      .arg(m_collections->playlists().nameOf(id)));
        if (ret != QMessageBox::Yes) return;
        m_collections->playlists().remove(id);
        if (m_collections->viewId() == id) showPage(Collections::kAllViewId);
        refreshGroups();
        emit collectionsChanged();
    });
}

// 把外部目录/音频加进当前自建列表：与主窗导入同一条 Importer 链路（目录递归、m3u/CUE
// 展开、归档条目都在里面），读完注册进媒体库再写进此列表。读取放后台，大目录不卡 UI。
void PlaylistWindow::addPathsToCurrentPlaylist(const QStringList &paths, const QString &viewId) {
    const QString id = viewId.isEmpty() ? selectedViewId() : viewId;
    if (!m_collections->playlists().contains(id)) {
        QMessageBox::information(this, QStringLiteral("加入列表"),
                                 QStringLiteral("请先在左栏选中一个自建列表，或用「新建列表…」创建"));
        return;
    }
    if (paths.isEmpty()) return;
    auto *watcher = new QFutureWatcher<Importer::Result>(this);
    connect(watcher, &QFutureWatcher<Importer::Result>::finished, this, [this, watcher, id] {
        const Importer::Result imported = watcher->result();
        watcher->deleteLater();
        if (imported.cancelled) return;
        if (imported.tracks.isEmpty()) {
            QMessageBox::information(this, QStringLiteral("加入列表"),
                                     imported.problems.isEmpty() ? QStringLiteral("没有找到可播放的音频")
                                                                 : imported.problems.first());
            return;
        }
        const int added = addTracksToPlaylist(imported.tracks, id);
        refreshGroups();
        if (m_collections->viewId() == id) showPage(id);
        emit collectionsChanged();
        QString note = added > 0 ? QStringLiteral("已加入 %1 首").arg(added) : QStringLiteral("这些曲目都已经在列表里");
        if (!imported.problems.isEmpty()) note += QStringLiteral("；%1 项无法导入").arg(imported.problems.size());
        QMessageBox::information(this, QStringLiteral("加入列表"), note);
    });
    watcher->setFuture(QtConcurrent::run([paths] { return Importer::read(paths, true, nullptr); }));
}

int PlaylistWindow::addTracksToPlaylist(const QList<Track> &tracks, const QString &playlistId) {
    if (tracks.isEmpty() || !m_collections->playlists().contains(playlistId)) return 0;
    m_collections->registerTracks(tracks); // 先注册，列表里的键才能还原成带元数据的曲目
    QStringList keys;
    for (const Track &track : tracks)
        keys << track.identityKey();
    return m_collections->playlists().addKeys(keys, playlistId);
}

void PlaylistWindow::dropEvent(QDropEvent *event) {
    // 自建列表页：拖进来的目录/音频直接进此列表；其它页保持「导入媒体库」的原行为。
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
