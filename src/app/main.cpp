#include "Application.h"
#include "CrashHandler.h"
#include "InstanceGuard.h"

#include "audio/AudioEngine.h"
#include "library/Collections.h"
#include "library/GlobalSearch.h"
#include "library/LibraryStore.h"
#include "media/Archive.h"
#include "media/CueSheet.h"
#include "media/FFmpeg.h"
#include "media/Lyric.h"
#include "media/PlaylistM3U.h"
#include "models/RadioPresets.h"
#include "models/RadioStations.h"
#include "models/Track.h"
#include "models/TrackFilter.h"
#include "models/UserPlaylist.h"
#include "platform/MediaSession.h"
#include "playback/PlayerController.h"
#include "testing/RadioHarness.h"
#include "testing/Regression.h"
#include "ui/AppIcon.h"
#include "ui/ConvertWindow.h"
#include "ui/CoverWindow.h"
#include "ui/EqWindow.h"
#include "ui/LyricWindow.h"
#include "ui/MainWindow.h"
#include "ui/PlaylistView.h"
#include "ui/PlaylistWindow.h"
#include "ui/PropertyWindow.h"
#include "ui/SettingsWindow.h"
#include "ui/SkinDock.h"
#include "ui/Theme.h"
#include "ui/TrayController.h"

#include <QApplication>
#include <QSysInfo>
#include <QWidget>
#include <SDL3/SDL.h>
#include <QFileInfo>
#include <QFile>
#include <QSqlDatabase>
#include <QSqlQuery>
#include <QStringList>
#include <QDir>
#include <QUrl>
#include <QList>
#include <QTimer>
#include <QEventLoop>
#include <QTextStream>
#include <QTemporaryDir>
#include <QScreen>
#include <QPointer>
#include <QThread>
#ifdef TTPLAYER_HAVE_TEXTCODEC
#include <QTextCodec>
#endif
#include <cmath>
#include <cstdlib>
#include <stdexcept>
#include <vector>

// searchlist 数据层无头探针：验 TrackFilter / GlobalSearch / UserPlaylists / PlaylistM3U
// 四条纯逻辑（不碰设备/窗口），逐条打 PASS/FAIL，返回失败条数。
static void waitForLibraryRestore(MainWindow &window) {
    QElapsedTimer timer;
    timer.start();
    while (window.isRestoringLibrary() && timer.elapsed() < 10000) {
        QCoreApplication::processEvents();
        QThread::msleep(1);
    }
}

static int runSearchListProbe(QTextStream &out) {
    int fail = 0;
    const auto check = [&](const char *name, bool ok) {
        out << "SL_PROBE " << name << ' ' << (ok ? "PASS" : "FAIL") << '\n';
        if (!ok) ++fail;
    };

    auto mk = [](const QString &path, const QString &title, const QString &artist) {
        Track t(QUrl::fromLocalFile(path));
        t.setTitle(title);
        t.setArtist(artist);
        return t;
    };
    const Track a = mk("/lib/alpha.mp3", "Alpha", "singer");
    const Track b = mk("/lib/beta.flac", "Beta", "band");
    const Track c = mk("/lib/gamma.mp3", "Gamma", "solo");

    // TrackFilter：关键字大小写不敏感，跨 title/artist
    check("filter_keyword_ci", TrackFilter("ALPHA").matches(a));
    check("filter_artist", TrackFilter("band").matches(b));
    check("filter_miss", !TrackFilter("zzz").matches(a));
    check("filter_format", TrackFilter("a", QSet<QString>{QStringLiteral("MP3")}).matches(a) &&
                               !TrackFilter("a", QSet<QString>{QStringLiteral("MP3")}).matches(b));
    check("filter_options", TrackFilter::formatOptions({a, b, c}).contains(QStringLiteral("FLAC")));

    // GlobalSearch：跨页去重 + 页序记录
    GlobalSearch gs;
    gs.build({{"收藏", {a, b}}, {"深夜", {b, c}}});
    check("gs_dedup_count", gs.indexedCount() == 3 && !gs.isStale());
    check("gs_pages_of_b",
          gs.pagesOf(b.identityKey()) == QStringList({QStringLiteral("收藏"), QStringLiteral("深夜")}));
    const SearchResult r = gs.matches(TrackFilter("a")); // a/b/c 都含 'a'
    check("gs_match_all", r.total == 3 && r.hits.size() == 3);
    const SearchResult rf = gs.matches(TrackFilter("a", QSet<QString>{QStringLiteral("MP3")}));
    check("gs_format_subset",
          rf.total == 2 && rf.formats.contains(QStringLiteral("FLAC")) && rf.formats.contains(QStringLiteral("MP3")));
    check("gs_empty_keyword", gs.matches(TrackFilter("   ")).hits.isEmpty());

    // UserPlaylists：建/同名区分/组内去重/重排
    UserPlaylists pls;
    QString id1, id2, note;
    check("pl_create", pls.create("深夜", &id1));
    check("pl_dup_distinct", pls.create("  深夜  ", &id2, &note) && pls.nameOf(id2) == QStringLiteral("深夜 (2)"));
    check("pl_empty_name", !pls.create("   ", nullptr));
    const int added = pls.addKeys({a.identityKey(), a.identityKey(), b.identityKey()}, id1);
    check("pl_dedup", added == 2 && pls.keysOf(id1).size() == 2);
    check("pl_reorder",
          pls.reorder(id1, {b.identityKey(), a.identityKey()}) && pls.keysOf(id1).first() == b.identityKey());
    check("pl_reorder_bad", !pls.reorder(id1, {a.identityKey()}));

    // PlaylistM3U：导出→导入逐字符往返（假路径不在盘上会记 missing，但键保序保真）
    QTemporaryDir tmp;
    const QString m3u = tmp.path() + "/list.m3u8";
    check("m3u_export", PlaylistM3U::exportTracks({a, b}, m3u));
    PlaylistM3U::Imported imp;
    check("m3u_import", PlaylistM3U::importFile(m3u, imp));
    check("m3u_roundtrip", imp.keys == QStringList({a.identityKey(), b.identityKey()}));
    check("m3u_missing_flag", imp.missing.size() == 2); // 两条都不在盘上

    // R15a：主窗/歌单共用的 importer 契约——importFile 吐出的键经 resolveToken 还原后
    // 身份逐字保持（普通文件路径 / 电台地址两类不依赖磁盘即可验证）
    check("resolve_identity_file", Collections::resolveToken(a.identityKey()).identityKey() == a.identityKey());
    check("resolve_identity_radio", Collections::resolveToken(QStringLiteral("http://x/stream")).identityKey() ==
                                        QStringLiteral("http://x/stream"));

    // 持久化 round-trip：歌单/收藏/viewListID 写隔离档再读回（沿用旧档键名）
    QTemporaryDir st;
    qputenv("TTPLAYER_QT_STATE", (st.path() + "/state.json").toUtf8());
    LibraryStore::Loaded s;
    s.userLists = pls.snapshot();
    s.favoriteKeys = {a.identityKey(), b.identityKey()};
    s.viewListID = id1;
    LibraryStore::save(s);
    const LibraryStore::Loaded back = LibraryStore::load();
    check("persist_userlists", back.userLists.size() == 2 && back.userLists.at(0).id == id1 && back.viewListID == id1);
    check("persist_fav", back.favoriteKeys.size() == 2 && back.favoriteKeys.at(0) == a.identityKey());

    // Collections：注册/键还原/收藏/歌单页/跨页搜索/持久化
    Collections col;
    col.setAllTracks({a, b, c});
    check("col_all_count", col.allTracks().size() == 3);
    check("col_key_resolve", col.trackForKey(a.identityKey()).title() == QStringLiteral("Alpha"));
    check("col_key_radio", col.trackForKey(QStringLiteral("http://x/stream")).isRadio());
    check("col_fav_toggle", col.toggleFavorite(a.identityKey()) && col.isFavorite(a.identityKey()) &&
                                !col.toggleFavorite(a.identityKey()));
    col.toggleFavorite(b.identityKey());
    QString cid;
    col.playlists().create(QStringLiteral("深夜"), &cid);
    col.playlists().addKeys({a.identityKey(), c.identityKey()}, cid);
    check("col_playlist_tracks", col.tracksOf(cid).size() == 2);
    const auto vl = col.viewList();
    // 普通固定页 + 自建列表 + 电台入口，共 8 行；自建列表在电台之前。
    check("col_viewlist", vl.size() == 8 && vl.first().first == Collections::kAllViewId &&
                              vl.first().second == QStringLiteral("[默认]") && vl.at(4).first == cid &&
                              vl.at(4).second == QStringLiteral("深夜") &&
                              vl.last().first == Collections::radioCatViewId(RadioStations::uncategorizedID));
    const SearchResult sr = col.search(TrackFilter(QStringLiteral("beta")));
    check("col_search", sr.hits.size() == 1 && col.pagesOf(b.identityKey()).contains(QStringLiteral("[默认]")) &&
                            col.pagesOf(b.identityKey()).contains(QStringLiteral("我的收藏")));
    LibraryStore::Loaded cs;
    col.saveTo(cs);
    Collections col2;
    col2.loadFrom(cs);
    col2.setAllTracks({a, b, c});
    check("col_persist",
          col2.playlists().count() == 1 && col2.tracksOf(cid).size() == 2 && col2.isFavorite(b.identityKey()));

    out << "SL_PROBE done fail=" << fail << '\n';
    return fail;
}

// SkinDock 几何探针：三窗同宽 / 竖排 / 整组拖动跟随 / 拉宽联动。
// 纯窗口几何，不开 SDL；offscreen 平台下 frameGeometry==geometry。
static int runDockProbe(QTextStream &out) {
    int fail = 0;
    const auto check = [&](const char *name, bool ok) {
        out << "DOCK_PROBE " << name << ' ' << (ok ? "PASS" : "FAIL") << '\n';
        if (!ok) ++fail;
    };

    QWidget main, pl, eq;
    // 与真实 app 一致：面板都是无边框 SkinWindow，frameGeometry==geometry，
    // 避免 offscreen 给普通 QWidget 加的边框让 client/frame 坐标错位。
    main.setWindowFlags(Qt::FramelessWindowHint);
    pl.setWindowFlags(Qt::FramelessWindowHint);
    eq.setWindowFlags(Qt::FramelessWindowHint);
    main.resize(480, 200);
    pl.resize(600, 300); // 故意比主窗宽，验同宽会被拉齐
    eq.resize(480, 178);
    main.show();
    pl.show();
    eq.show();
    QCoreApplication::processEvents();

    SkinDock dock;
    dock.registerPanel(SkinDock::Main, &main);
    dock.registerPanel(SkinDock::Playlist, &pl);
    dock.registerPanel(SkinDock::Equalizer, &eq);
    QCoreApplication::processEvents();

    check("width_sync", pl.width() == main.width() && eq.width() == main.width());
    check("stack_below_main", pl.frameGeometry().top() >= main.frameGeometry().bottom());
    check("stack_below_pl", eq.frameGeometry().top() >= pl.frameGeometry().bottom());

    // 拖主窗 → 整组按同一位移跟随
    const QPoint before = pl.frameGeometry().topLeft();
    main.move(main.frameGeometry().topLeft() + QPoint(50, 30));
    QCoreApplication::processEvents();
    check("group_follow_drag", pl.frameGeometry().topLeft() - before == QPoint(50, 30));

    // 拉宽主窗 → 三窗同宽
    main.resize(560, main.height());
    QCoreApplication::processEvents();
    check("width_sync_resize", pl.width() == 560 && eq.width() == 560);

    // —— 磁吸模型：自由拖动 + 靠近才吸附 ——
    // 让 settle 定时器（90ms）跑完：用嵌套事件循环等一次拖动停止后的判定。
    const auto spin = [](int ms) {
        QEventLoop loop;
        QTimer::singleShot(ms, &loop, &QEventLoop::quit);
        loop.exec();
    };

    // 1) 把列表拖离停靠槽很远 → 停下后脱离浮动，且保留拖到的位置（不是一直吸附）
    const QPoint detachedPosition = pl.frameGeometry().topLeft() + QPoint(500, 400);
    pl.move(detachedPosition);
    QCoreApplication::processEvents();
    spin(150);
    check("detach_when_far", !dock.isPanelDocked(SkinDock::Playlist));
    check("float_keeps_position", pl.frameGeometry().topLeft() == detachedPosition);
    // 列表脱离后，仍吸附的均衡器应补位到主窗正下方
    check("reflow_after_detach", eq.frameGeometry().left() == main.frameGeometry().left() &&
                                     eq.frameGeometry().top() >= main.frameGeometry().bottom());

    // 2) 移动主窗 → 浮动列表原地不动（证明不跟随），吸附均衡器跟随
    const QPoint plFrozen = pl.frameGeometry().topLeft();
    const QPoint eqBefore = eq.frameGeometry().topLeft();
    main.move(main.frameGeometry().topLeft() + QPoint(20, 20));
    QCoreApplication::processEvents();
    check("float_stays_on_main_move", pl.frameGeometry().topLeft() == plFrozen);
    check("docked_follows_main_move", eq.frameGeometry().topLeft() - eqBefore == QPoint(20, 20));

    // 3) 把浮动列表拖回停靠槽附近（阈值 44 内）→ 停下后吸附：落回槽位 + 同宽
    const QPoint slot(main.frameGeometry().left(), main.frameGeometry().bottom() + SkinDock::kGap + 1);
    pl.move(slot + QPoint(10, 8));
    QCoreApplication::processEvents();
    spin(150);
    check("snap_when_near", dock.isPanelDocked(SkinDock::Playlist));
    check("snap_aligns_slot", pl.frameGeometry().topLeft() == slot);
    check("snap_sync_width", pl.width() == main.width());
    // 列表重新吸附后排在主窗与均衡器之间，均衡器再往下让位
    check("reflow_after_snap", eq.frameGeometry().top() >= pl.frameGeometry().bottom());

    // 4) 横向磁吸：把列表拖到主窗右侧、顶边对齐 → 吸附成 Right 侧列（左边缘贴主窗右侧留缝）
    {
        const QRect mf = main.frameGeometry();
        const QPoint rightSlot(mf.right() + 1 + SkinDock::kGap, mf.top());
        pl.move(rightSlot + QPoint(-6, 5)); // 阈值 44 内
        QCoreApplication::processEvents();
        spin(150);
        check("snap_right_side",
              dock.isPanelDocked(SkinDock::Playlist) && dock.panelSide(SkinDock::Playlist) == SkinDock::Right);
        const QRect af = pl.frameGeometry();
        check("snap_right_flush",
              af.left() == main.frameGeometry().right() + 1 + SkinDock::kGap && af.top() == main.frameGeometry().top());
    }

    // 5) 把均衡器拖到主窗左侧、顶边对齐 → 吸附成 Left 侧列（右边缘贴主窗左侧留缝）
    {
        const QRect mf = main.frameGeometry();
        const QPoint leftSlot(mf.left() - SkinDock::kGap - eq.width(), mf.top());
        eq.move(leftSlot + QPoint(8, -4));
        QCoreApplication::processEvents();
        spin(150);
        check("snap_left_side",
              dock.isPanelDocked(SkinDock::Equalizer) && dock.panelSide(SkinDock::Equalizer) == SkinDock::Left);
        const QRect af = eq.frameGeometry();
        check("snap_left_flush",
              af.right() == main.frameGeometry().left() - 1 - SkinDock::kGap && af.top() == main.frameGeometry().top());
    }

    {
        QWidget lyric;
        lyric.setWindowFlags(Qt::FramelessWindowHint);
        lyric.resize(main.width(), 120);
        dock.registerPanel(SkinDock::Lyric, &lyric);
        lyric.show();
        const QString savedFrames = dock.panelFramesString();
        QWidget restoredMain, restoredPl, restoredEq, restoredLyric;
        for (QWidget *w : {&restoredMain, &restoredPl, &restoredEq, &restoredLyric})
            w->setWindowFlags(Qt::FramelessWindowHint);
        restoredMain.resize(main.size());
        restoredMain.show();
        SkinDock restored;
        restored.setSavedPanels(savedFrames);
        restored.registerPanel(SkinDock::Main, &restoredMain);
        restored.restoreGeometry(dock.geometryString());
        restored.registerPanel(SkinDock::Playlist, &restoredPl);
        restored.registerPanel(SkinDock::Equalizer, &restoredEq);
        restored.registerPanel(SkinDock::Lyric, &restoredLyric);
        restoredPl.show();
        restoredEq.show();
        restoredLyric.show();
        check("fixed_panel_frames_roundtrip", restored.panelFramesString() == savedFrames);
        check("fixed_panel_labels_unchanged", savedFrames.startsWith("pl=") && savedFrames.contains(";eq=") &&
                                                  savedFrames.contains(";ly=") && !savedFrames.contains("aux"));
    }
    // 辅助成员不占固定槽，同类多实例按创建序排布；无框测试窗复用真实事件路径。
    {
        const QRect available = QGuiApplication::primaryScreen()->availableGeometry();
        QWidget anchor;
        anchor.setWindowFlags(Qt::FramelessWindowHint);
        anchor.resize(180, 100);
        anchor.move(available.topLeft() + QPoint(220, 120));
        anchor.show();
        SkinDock auxiliaryDock;
        auxiliaryDock.registerPanel(SkinDock::Main, &anchor);
        auto makeAux = [&] {
            auto *aux = new QWidget;
            aux->setWindowFlags(Qt::FramelessWindowHint);
            aux->resize(110, 100);
            auxiliaryDock.registerAuxiliary(aux);
            return aux;
        };
        auto *first = makeAux();
        check("aux_preplaced_before_show", !first->isVisible() && available.contains(first->frameGeometry()) &&
                                               !first->frameGeometry().intersects(anchor.frameGeometry()));
        first->show();
        auto *second = makeAux();
        second->show();
        spin(150);
        check("aux_initial_right_order", auxiliaryDock.windowSide(first) == SkinDock::Right &&
                                             auxiliaryDock.windowSide(second) == SkinDock::Right &&
                                             second->y() == first->frameGeometry().bottom() + SkinDock::kGap + 2);
        check("aux_initial_no_overlap", !second->frameGeometry().intersects(first->frameGeometry()) &&
                                            !second->frameGeometry().intersects(anchor.frameGeometry()));
        const QPoint firstBefore = first->pos(), secondBefore = second->pos();
        anchor.move(anchor.pos() + QPoint(12, 9));
        check("aux_follow_main",
              first->pos() - firstBefore == QPoint(12, 9) && second->pos() - secondBefore == QPoint(12, 9));
        first->resize(137, 130);
        check("aux_height_reflows", second->y() == first->frameGeometry().bottom() + SkinDock::kGap + 2);
        anchor.resize(200, anchor.height());
        check("aux_right_width_independent", first->width() == 137 && second->width() == 110);
        first->move(anchor.pos() + QPoint(400, 350));
        spin(150);
        check("aux_detach", !auxiliaryDock.isWindowDocked(first));
        const QPoint frozen = first->pos();
        anchor.move(anchor.pos() + QPoint(8, 7));
        check("aux_float_stays", first->pos() == frozen);
        first->move(QPoint(anchor.x(), anchor.frameGeometry().bottom() + SkinDock::kGap + 1));
        spin(150);
        check("aux_bottom_snap_keeps_width", auxiliaryDock.isWindowDocked(first) &&
                                                 auxiliaryDock.windowSide(first) == SkinDock::Bottom &&
                                                 first->width() == 137 && anchor.width() == 200);
        first->resize(143, first->height());
        check("aux_bottom_resize_not_shared", first->width() == 143 && anchor.width() == 200);
        first->move(QPoint(anchor.frameGeometry().right() + SkinDock::kGap + 1, anchor.y()));
        spin(150);
        const int secondWidth = second->width();
        first->hide();
        check("aux_hide_reflows", second->y() == anchor.y() && second->width() == secondWidth);
        first->show();
        spin(150);
        check("aux_show_reflows", second->y() == first->frameGeometry().bottom() + SkinDock::kGap + 2);
        const QString saved = auxiliaryDock.panelFramesString();
        check("aux_not_serialized", saved.isEmpty());
        first->move(first->pos() + QPoint(8, 4));
        delete first; // settle 仍在途，必须同步移除计时器和映射。
        spin(150);
        check("aux_destroy_reflows", second->y() == anchor.y());
        delete second;
        const int timerBaseline = auxiliaryDock.findChildren<QTimer *>().size();
        bool safe = true;
        for (int cycle = 0; cycle < 30; ++cycle) {
            QPointer<QWidget> transient = makeAux();
            transient->show();
            transient->move(transient->pos() + QPoint(9, 3));
            delete transient.data();
            safe &= transient.isNull() && auxiliaryDock.findChildren<QTimer *>().size() == timerBaseline;
            spin(100);
        }
        check("aux_destroy_with_settle_30", safe);
        {
            QWidget floatingPanel;
            floatingPanel.setWindowFlags(Qt::FramelessWindowHint);
            const QPoint blocked(anchor.frameGeometry().right() + SkinDock::kGap + 1, anchor.y());
            auxiliaryDock.setSavedPanels(QStringLiteral("pl=%1,%2,110,100,0,2").arg(blocked.x()).arg(blocked.y()));
            auxiliaryDock.registerPanel(SkinDock::Playlist, &floatingPanel);
            floatingPanel.show();
            auto *beside = makeAux();
            beside->show();
            check("aux_avoids_floating_panel", !beside->frameGeometry().intersects(floatingPanel.frameGeometry()) &&
                                                   !beside->frameGeometry().intersects(anchor.frameGeometry()) &&
                                                   auxiliaryDock.windowSide(beside) == SkinDock::Left);
            delete beside;
        }
        for (bool rightEdge : {true, false}) {
            anchor.resize(180, 100);
            anchor.move(rightEdge ? QPoint(available.right() - anchor.width() + 1, available.top() + 100)
                                  : available.topLeft() + QPoint(0, 100));
            auto *edge = makeAux();
            edge->show();
            check(rightEdge ? "aux_right_screen_uses_left" : "aux_left_screen_uses_right",
                  available.contains(edge->frameGeometry()) &&
                      !edge->frameGeometry().intersects(anchor.frameGeometry()) &&
                      auxiliaryDock.windowSide(edge) == (rightEdge ? SkinDock::Left : SkinDock::Right));
            delete edge;
        }
        anchor.move(available.center() - QPoint(90, 50));
        auto *fallback = new QWidget;
        fallback->setWindowFlags(Qt::FramelessWindowHint);
        fallback->resize(110, available.height());
        auxiliaryDock.registerAuxiliary(fallback);
        fallback->show();
        spin(150);
        check("aux_nonstandard_fallback_floats", available.contains(fallback->frameGeometry()) &&
                                                     !fallback->frameGeometry().intersects(anchor.frameGeometry()) &&
                                                     !auxiliaryDock.isWindowDocked(fallback));
        delete fallback;
        anchor.resize(available.size());
        anchor.move(available.topLeft());
        auto *crowded = makeAux();
        crowded->show();
        spin(150);
        check("aux_insufficient_space_title_visible", available.contains(crowded->frameGeometry()) &&
                                                          crowded->frameGeometry().intersects(anchor.frameGeometry()) &&
                                                          !auxiliaryDock.isWindowDocked(crowded));
        delete crowded;
    }
    out << "DOCK_PROBE done fail=" << fail << '\n';
    return fail;
}

// 设置对话框背后的新后端无头探针：歌词时间轴数学 / 新字段持久化往返 /
// 控制器状态机（睡眠 / 无缝 / 每曲歌词校准）/ 输出设备选择。
// 不靠真音频设备：current track 用 begin() 合成（不装载、不开流）。
static int runSettingsProbe(PlayerController &c, QTextStream &out) {
    int fail = 0;
    const auto check = [&](const char *name, bool ok) {
        out << "SET_PROBE " << name << ' ' << (ok ? "PASS" : "FAIL") << '\n';
        if (!ok) ++fail;
    };

    // —— Lyric：offset 解析时烘焙 + alignedTime(段起点 - 校准) ——
    const Lyric ly = Lyric::parse(QStringLiteral("[offset:+500]\n[00:10.00]一\n[00:20.00]二"));
    // 正 offset = 歌词提前：10.0 - 0.5 = 9.5。行内已烘焙，查行不再二次叠
    check("lyric_offset_baked", !ly.isEmpty() && std::abs(ly.lines()[0].time - 9.5) < 0.01 &&
                                    ly.lineIndexAt(9.5) == 0 && ly.lineIndexAt(9.4) == -1);
    Lyric l2 = ly; // alignedTime = segment + mirrorShift - delay
    l2.setMirrorShift(5.0);
    check("lyric_aligned", std::abs(l2.alignedTime(10.0, 2.0) - 13.0) < 1e-9);

    // —— 新字段持久化逐字节往返（隔档）——
    QTemporaryDir st;
    qputenv("TTPLAYER_QT_STATE", (st.path() + "/state.json").toUtf8());
    LibraryStore::Loaded s;
    s.gaplessPlay = false;
    s.sleepFade = false;
    s.outputDeviceUID = QStringLiteral("MyDevice");
    s.outputDeviceName = QStringLiteral("MyDevice");
    s.lyricShifts = {{QStringLiteral("k1"), 3.0}, {QStringLiteral("k2"), -1.5}};
    LibraryStore::save(s);
    const LibraryStore::Loaded back = LibraryStore::load();
    check("persist_gapless", !back.gaplessPlay);
    check("persist_sleepfade", !back.sleepFade);
    check("persist_device", back.outputDeviceUID == QStringLiteral("MyDevice"));
    check("persist_lyricshifts", back.lyricShifts.size() == 2 &&
                                     std::abs(back.lyricShifts.value(QStringLiteral("k1")) - 3.0) < 1e-9 &&
                                     std::abs(back.lyricShifts.value(QStringLiteral("k2")) + 1.5) < 1e-9);

    // —— 控制器状态机：合成一个非电台当前曲 ——
    auto mk = [](const QString &path, const QString &title) {
        Track t(QUrl::fromLocalFile(path));
        t.setTitle(title);
        return t;
    };
    const QList<Track> list{mk(QStringLiteral("/x/a.mp3"), QStringLiteral("A"))};
    c.setTracks(list);
    c.queue().begin(list, 0);
    check("cur_track", !c.currentTrack().isNull() && !c.currentTrack().isRadio());

    // 睡眠：按分钟倒计时
    c.setSleepMinutes(30);
    check("sleep_countdown", c.sleepArmed() && c.sleepPlan() == PlayerController::SleepPlan::Countdown &&
                                 c.sleepStatusText().startsWith(QStringLiteral("剩")));
    c.cancelSleepTimer();
    check("sleep_cancel", !c.sleepArmed());
    // 睡眠：播完当前曲
    c.setSleepAfterCurrentTrack();
    check("sleep_aftertrack", c.sleepArmed() && c.sleepPlan() == PlayerController::SleepPlan::AfterTrack);
    c.cancelSleepTimer();
    // 淡出开关
    c.setSleepFadeEnabled(false);
    check("sleep_fade_off", !c.sleepFadeEnabled());
    c.setSleepFadeEnabled(true);

    // 无缝开关
    c.setGaplessEnabled(false);
    check("gapless_off", !c.gaplessEnabled());
    c.setGaplessEnabled(true);
    check("gapless_on", c.gaplessEnabled());

    // 每曲歌词校准：setLyricShift 越界夹到 ±30（不依赖歌词已加载）
    c.setLyricShift(100);
    check("lyric_shift_clamp_hi", std::abs(c.lyricShift() - PlayerController::kLyricShiftLimit) < 1e-9 &&
                                      c.lyricShiftText().contains(QStringLiteral("延后")));
    c.setLyricShift(-100);
    check("lyric_shift_clamp_lo", std::abs(c.lyricShift() + PlayerController::kLyricShiftLimit) < 1e-9 &&
                                      c.lyricShiftText().contains(QStringLiteral("提前")));
    c.setLyricShift(0);
    check("lyric_shift_zero", std::abs(c.lyricShift()) < 1e-9 && c.lyricShiftText() == QStringLiteral("未校准"));

    // 输出设备：没开设备时 setOutputDevice 只存选择
    c.setOutputDevice(QStringLiteral("SomeDev"));
    check("device_set", c.outputDevice() == QStringLiteral("SomeDev"));
    c.setOutputDevice(QString());
    check("device_default", c.outputDevice().isEmpty());

    out << "SET_PROBE done fail=" << fail << '\n';
    return fail;
}

// 出厂电台默认入表探针（F11）：normalize / 台名 / 首次播种 / 幂等去重 / 黑名单不回来。
// 走真 MainWindow（seedPresetRadios 在其上），隔档不碰设备、不开窗。
static int runRadioSeedProbe(AudioEnginePtr engine, PlayerController &controller, QTextStream &out) {
    int fail = 0;
    const auto check = [&](const char *name, bool ok) {
        out << "RADIO_PROBE " << name << ' ' << (ok ? "PASS" : "FAIL") << '\n';
        if (!ok) ++fail;
    };

    const RadioPreset &preset = RadioPresets::all().first();
    const QString key = preset.identityKey();

    // —— 纯逻辑：normalize 补协议 / 内置台名按地址兜底 ——
    check("normalize_adds_scheme", RadioURL::normalize(QStringLiteral("example.com/stream")).toString() ==
                                       QStringLiteral("http://example.com/stream"));
    check("normalize_rejects_empty", RadioURL::normalize(QStringLiteral("   ")).isEmpty());
    check("nameFor_preset", RadioPresets::nameFor(preset.url()) == preset.name);
    check("nameFor_unknown", RadioPresets::nameFor(QUrl(QStringLiteral("http://nope/x"))).isEmpty());

    QTemporaryDir st;
    qputenv("TTPLAYER_QT_STATE", (st.path() + QStringLiteral("/state.json")).toUtf8());

    // —— 空档：首次播种 1 台、带预设名、幂等不重 ——
    {
        MainWindow w(&controller, engine);
        check("seed_first", w.seedPresetRadios() == 1);
        bool titled = false;
        for (const Track &t : controller.tracks())
            if (t.identityKey() == key) titled = t.isRadio() && t.title() == preset.name;
        check("seed_titled_radio", titled);
        check("seed_idempotent", w.seedPresetRadios() == 0);
        int cnt = 0;
        for (const Track &t : w.collections().allTracks())
            if (t.identityKey() == key) ++cnt;
        check("seed_no_dup", cnt == 1);
        // 从列表移走 → 集合层不再含该台
        w.collections().removeTrackFromView(Collections::kAllViewId, key);
        bool gone = true;
        for (const Track &t : w.collections().allTracks())
            if (t.identityKey() == key) gone = false;
        check("remove_from_all", gone);
    }

    // —— 黑名单：declinedRadioKeys 命中 → 不再塞回 ——
    {
        LibraryStore::Loaded s;
        s.declinedRadioKeys = {key};
        LibraryStore::save(s);
        MainWindow w2(&controller, engine); // loadState 读到黑名单
        check("seed_declined_skip", w2.seedPresetRadios() == 0);
        bool absent = true;
        for (const Track &t : w2.collections().allTracks())
            if (t.identityKey() == key) absent = false;
        check("declined_absent", absent);
    }

    out << "RADIO_PROBE done fail=" << fail << '\n';
    return fail;
}

// R13 电台分类探针：先验 RadioStations 纯模型（建/同名区分/未分类不可改不可删/移入/删分类落回
// 未分类但台名不动/改地址搬身份/displayName 优先级），再验 Collections 的分类页投影与
// 存档往回（隔档，不碰真实 state.json）。
static int runRadioCatProbe(AudioEnginePtr engine, PlayerController &controller, QTextStream &out) {
    int fail = 0;
    const auto check = [&](const char *name, bool ok) {
        out << "RADIOCAT_PROBE " << name << ' ' << (ok ? "PASS" : "FAIL") << '\n';
        if (!ok) ++fail;
    };
    QTemporaryDir st;
    qputenv("TTPLAYER_QT_STATE", (st.path() + QStringLiteral("/state.json")).toUtf8());

    const QString a = QStringLiteral("http://a.example/live");
    const QString b = QStringLiteral("http://b.example/live");
    const auto radio = [](const QString &u) { return Track::fromRadio(QUrl(u)); };

    // —— 纯模型 ——
    {
        RadioStations rs;
        QString id, note;
        check("create_ok",
              rs.createCategory(QStringLiteral("通勤"), &id, &note) && rs.nameOf(id) == QStringLiteral("通勤"));
        QString id2;
        check("distinct_name",
              rs.createCategory(QStringLiteral("通勤"), &id2, &note) && rs.nameOf(id2) == QStringLiteral("通勤 (2)"));
        QString tmp;
        check("blank_rejected", !rs.createCategory(QStringLiteral("   "), &tmp, &note));
        check(
            "uncat_rename_fail",
            rs.renameCategory(RadioStations::uncategorizedID, QStringLiteral("x")).contains(QStringLiteral("改不了")));
        int mv = -1;
        check("uncat_delete_fail", !rs.deleteCategory(RadioStations::uncategorizedID, &mv));
        check("name_of_uncat", rs.nameOf(RadioStations::uncategorizedID) == QStringLiteral("未分类电台"));
        QString problem;
        check("move_in_two", rs.moveRadios({a, b}, id, &problem) == 2 && rs.categoryIDOf(a) == id);
        rs.setAlias(a, QStringLiteral("城市之声"));
        check("alias_shows", rs.displayName(QUrl(a)) == QStringLiteral("城市之声") && rs.hasCustomName(QUrl(a)));
        int moved = -1;
        check("delete_keeps_alias_returns_uncat", rs.deleteCategory(id, &moved) && moved == 2 &&
                                                      rs.categoryIDOf(a).isEmpty() &&
                                                      rs.aliasFor(a) == QStringLiteral("城市之声"));
        QString id3;
        rs.createCategory(QStringLiteral("健身"), &id3, &note);
        rs.moveRadios({a}, id3, &problem);
        check("replacekeys_migrates", rs.replaceKeys({{a, QStringLiteral("http://c.example/live")}}) >= 1 &&
                                          rs.categoryIDOf(QStringLiteral("http://c.example/live")) == id3 &&
                                          rs.categoryIDOf(a).isEmpty());
        check("uncat_is_noop_when_absent",
              rs.moveRadios({QStringLiteral("http://none/")}, RadioStations::uncategorizedID, &problem) == 0);
    }

    // —— Collections 投影 + 存档往回（真集合层 API）——
    {
        MainWindow w(&controller, engine);
        Collections &c = w.collections();
        c.setAllTracks({radio(a), radio(b), Track(QUrl::fromLocalFile(QStringLiteral("/lib/song.mp3")))});
        QString cid, note;
        c.radios().createCategory(QStringLiteral("通勤"), &cid, &note);
        QString problem;
        c.radios().moveRadios({a}, cid, &problem);
        const QList<Track> inCat = c.tracksOf(Collections::radioCatViewId(cid));
        check("cat_view_projects_one_radio", inCat.size() == 1 && inCat[0].identityKey() == a);
        const QList<Track> uncat = c.tracksOf(Collections::radioCatViewId(RadioStations::uncategorizedID));
        check("uncat_view_has_rest", uncat.size() == 1 && uncat[0].identityKey() == b);
        check("count_matches_view", c.radioCountIn(cid) == 1);
        bool seesUncat = false;
        for (const auto &p : c.viewList())
            if (p.second == QStringLiteral("未分类电台")) seesUncat = true;
        check("viewlist_has_uncat", seesUncat);
        c.radios().setAlias(a, QStringLiteral("城市之声"));
        c.refreshRadioTitles();
        bool titled = false;
        for (const Track &t : c.allTracks())
            if (t.identityKey() == a && t.title() == QStringLiteral("城市之声")) titled = true;
        check("refresh_titles", titled);
        // 派生页重排必须被拒
        check("cat_view_reorder_rejected", !c.reorderView(Collections::radioCatViewId(cid), {a}));

        LibraryStore::Loaded s;
        c.setViewId(Collections::radioCatViewId(cid));
        c.saveTo(s);
        LibraryStore::save(s);
        Collections c2;
        c2.loadFrom(LibraryStore::load());
        check("persist_category_roundtrip", c2.radios().nameOf(cid) == QStringLiteral("通勤"));
        check("persist_assignment", c2.radios().categoryIDOf(a) == cid);
        check("persist_alias_roundtrip", c2.radios().displayName(QUrl(a)) == QStringLiteral("城市之声"));
        check("persist_view_roundtrip", c2.viewId() == Collections::radioCatViewId(cid));
        // 停在已删分类→回 [默认]
        Collections c3;
        LibraryStore::Loaded d;
        d.viewListID = Collections::radioCatViewId(QStringLiteral("已经不存在的ID"));
        c3.loadFrom(d);
        check("dangling_category_to_default", c3.viewId() == Collections::kAllViewId);
        // 电台只在「最近听的台」（不在 @all）：trackForKey 补过 RadioStations，解析台名而非地址
        Collections c4;
        c4.radios().setAlias(a, QStringLiteral("深夜电台"));
        c4.recordRadioPlay(a); // 进 recentRadioKeys，@all 里没有它
        const QList<Track> recentRad = c4.tracksOf(Collections::kRecentRadioViewId);
        check("recentradio_resolves_name", recentRad.size() == 1 &&
                                               recentRad[0].title() == QStringLiteral("深夜电台") &&
                                               recentRad[0].identityKey() == a);
    }
    out << "RADIOCAT_PROBE done fail=" << fail << '\n';
    return fail;
}

// R19 后台驻留探针（构造 MainWindow，bypass 托盘门走真整组隐藏路径）：
// 验隐藏/恢复往返、isGroupHidden 状态、toggle 双向。
static int runGroupVisProbe(AudioEnginePtr engine, PlayerController &controller, QTextStream &out) {
    int fail = 0;
    const auto check = [&](const char *name, bool ok) {
        out << "GROUPVIS_PROBE " << name << ' ' << (ok ? "PASS" : "FAIL") << '\n';
        if (!ok) ++fail;
    };
    MainWindow w(&controller, engine);
    w.setGroupHideBypassTray(true); // offscreen 无托盘也走整组隐藏，不退化最小化
    w.show();
    QApplication::processEvents();
    check("visible_before", w.isVisible() && !w.isGroupHidden());
    w.hideGroupToBackground();
    check("hidden_after", w.isGroupHidden() && !w.isVisible());
    w.restoreGroupFromBackground();
    check("restored", !w.isGroupHidden() && w.isVisible());
    w.toggleGroupVisibility();
    check("toggle_hides", w.isGroupHidden());
    w.toggleGroupVisibility();
    check("toggle_shows", !w.isGroupHidden() && w.isVisible());
    const int baseline = w.probeGroupVisible();
    bool safe = true;
    for (int cycle = 0; cycle < 30; ++cycle) {
        w.openSettings();
        w.openProperties(Track(QUrl::fromLocalFile("/group/probe.mp3")));
        QPointer<SettingsWindow> settings = w.findChild<SettingsWindow *>();
        QPointer<PropertyWindow> property = w.findChild<PropertyWindow *>();
        safe &= w.probeGroupVisible() == baseline + 2;
        w.hideGroupToBackground();
        safe &= w.probeGroupVisible() == 0;
        if (property) property->close();
        QCoreApplication::sendPostedEvents(nullptr, QEvent::DeferredDelete);
        safe &= property.isNull();
        w.restoreGroupFromBackground();
        safe &= w.probeGroupVisible() == baseline + 1 && settings && settings->isVisible();
        if (settings) settings->close();
        QCoreApplication::sendPostedEvents(nullptr, QEvent::DeferredDelete);
        safe &= settings.isNull() && w.probeGroupVisible() == baseline;
    }
    check("aux_hidden_destroy_restore_30", safe);
    return fail;
}

// R15b 多选选区探针：经真实入口 PlaylistView::selectAt / selectAllRows 驱动选区，
// 验普通/Ctrl/Shift 语义、全选、点空白清空、以及行集变少后 reload 把选区夹回新长度。
static int runMultiSelectProbe(PlayerController &controller, QTextStream &out) {
    int fail = 0;
    const auto check = [&](const char *name, bool ok) {
        out << "MULTI_PROBE " << name << ' ' << (ok ? "PASS" : "FAIL") << '\n';
        if (!ok) ++fail;
    };
    auto mk = [](int i) {
        Track t(QUrl::fromLocalFile(QStringLiteral("/lib/t%1.mp3").arg(i)));
        t.setTitle(QStringLiteral("T%1").arg(i));
        return t;
    };
    const QList<Track> six = {mk(0), mk(1), mk(2), mk(3), mk(4), mk(5)};
    controller.setTracks(six);
    PlaylistView view(&controller); // 构造即 reload，读到刚设的 6 行

    view.selectAt(1, Qt::NoModifier);
    check("plain_single", view.selectedRows() == QList<int>({1}));
    view.selectAt(3, Qt::ControlModifier);
    check("ctrl_add", view.selectedRows() == QList<int>({1, 3}));
    view.selectAt(1, Qt::ControlModifier);
    check("ctrl_remove", view.selectedRows() == QList<int>({3}));
    view.selectAt(5, Qt::ShiftModifier); // 锚点仍为 3（Ctrl 删 1 不动锚）→ 3..5
    check("shift_range", view.selectedRows() == QList<int>({3, 4, 5}));
    view.selectAllRows();
    const auto all = view.selectedRows();
    check("select_all", all.size() == 6 && all.first() == 0 && all.last() == 5);
    view.selectAt(-1, Qt::NoModifier);
    check("clear_on_empty", view.selectedRows().isEmpty());

    // 选区夹回：先选 {0,5}，再把行集缩到 2 条（触发 reload）→ 只留 0
    view.selectAt(0, Qt::NoModifier);
    view.selectAt(5, Qt::ControlModifier);
    controller.setTracks({mk(0), mk(1)});
    check("clamp_after_shrink", view.selectedRows() == QList<int>({0}));

    // R15b-2 拖拽重排：纯移动算法 + reorderView（@all 全排列写回 / 非全排列拒绝 / 派生页只读）
    {
        const QStringList disp = {QStringLiteral("k0"), QStringLiteral("k1"), QStringLiteral("k2"),
                                  QStringLiteral("k3"), QStringLiteral("k4")};
        check("move_block_down", Collections::applyMove(disp, QSet<int>({1, 2}), 4) ==
                                     QStringList({QStringLiteral("k0"), QStringLiteral("k3"), QStringLiteral("k1"),
                                                  QStringLiteral("k2"), QStringLiteral("k4")}));
        check("move_single_front", Collections::applyMove(disp, QSet<int>({3}), 0) ==
                                       QStringList({QStringLiteral("k3"), QStringLiteral("k0"), QStringLiteral("k1"),
                                                    QStringLiteral("k2"), QStringLiteral("k4")}));
        check("move_noop_empty", Collections::applyMove(disp, QSet<int>{}, 2) == disp);
        check("move_noop_self", Collections::applyMove(disp, QSet<int>({0}), 0) == disp);

        auto tf = [](int i) { return Track(QUrl::fromLocalFile(QStringLiteral("/lib/x%1.mp3").arg(i))); };
        const QList<Track> four = {tf(0), tf(1), tf(2), tf(3)};
        QStringList keys;
        for (const Track &t : four)
            keys.append(t.identityKey());
        Collections col;
        col.setAllTracks(four);
        const QStringList moved = Collections::applyMove(keys, QSet<int>({0}), 3);
        check("applyMove_into_all", moved == QStringList({keys[1], keys[2], keys[0], keys[3]}));
        check(
            "reorder_all_applied", col.reorderView(Collections::kAllViewId, moved) && [&] {
                QStringList got;
                for (const Track &t : col.currentTracks())
                    got.append(t.identityKey());
                return got == moved;
            }());
        check("reorder_reject_nonperm",
              !col.reorderView(Collections::kAllViewId, QStringList(keys) << QStringLiteral("zz")));
        check("reorder_derived_readonly", !col.reorderView(Collections::kRadioViewId, keys));
    }

    return fail;
}

// R02 数据所有权探针：验「停在收藏页 / 搜索态时存盘」不会把主库缩水成子集，
// 电台 / 收藏 / 上次页跨重启完整。走真实产品入口（MainWindow::requestSave / restoreLibrary）。
static int runOwnershipProbe(AudioEnginePtr engine, PlayerController &controller, QTextStream &out) {
    int fail = 0;
    const auto check = [&](const char *name, bool ok) {
        out << "OWN_PROBE " << name << ' ' << (ok ? "PASS" : "FAIL") << '\n';
        if (!ok) ++fail;
    };
    const QString base =
        qEnvironmentVariable("TTPLAYER_TESTDIR", QDir::currentPath() + QStringLiteral("/testlib")) + QLatin1Char('/');
    const auto mk = [&base](const QString &n) { return Track(QUrl::fromLocalFile(base + n)); };
    const QString radioUrl = QStringLiteral("http://example.com/live");

    // 隔离存档：本探针不预先设档会读写真实用户 state.json，拿它当基线会把收藏/现场搅乱。
    QTemporaryDir st;
    qputenv("TTPLAYER_QT_STATE", (st.path() + QStringLiteral("/state.json")).toUtf8());

    {
        MainWindow w(&controller, engine);
        Collections &col = w.collections();
        const QList<Track> lib = {mk(QStringLiteral("a.wav")), mk(QStringLiteral("b.wav")), mk(QStringLiteral("c.wav")),
                                  mk(QStringLiteral("d.wav"))};
        col.setAllTracks(lib);
        col.setViewId(Collections::kAllViewId);
        controller.setTracks(col.currentTracks());
        col.registerTracks({Track::fromRadio(QUrl(radioUrl))}); // 电台也进主库
        check("all_count_5", col.allTracks().size() == 5);

        // 收藏前两首，切到 @fav：控制器只展示收藏页（2 行）
        col.toggleFavorite(lib[0].identityKey());
        col.toggleFavorite(lib[1].identityKey());
        col.setViewId(Collections::kFavViewId);
        controller.setTracks(col.currentTracks());
        check("fav_view_shown_2", controller.tracks().size() == 2);

        // 存盘：即便停在收藏页，主库仍应是 5（不是 2）—— R02 核心
        w.requestSave();
        const LibraryStore::Loaded s = LibraryStore::load();
        check("saved_full_library_5", s.trackPaths.size() == 5);
        check("saved_keeps_radio", s.trackPaths.contains(radioUrl));
        check("saved_fav_2", s.favoriteKeys.size() == 2);
    }
    {
        // 新窗口从存档恢复：@all 仍 5、收藏 2、电台在（上次页回固定页 @all）
        MainWindow w2(&controller, engine);
        w2.restoreLibrary();
        waitForLibraryRestore(w2);
        Collections &col = w2.collections();
        check("restored_all_5", col.allTracks().size() == 5);
        check("restored_fav_2", col.favorites().size() == 2);
        bool radioBack = false;
        for (const Track &t : col.allTracks())
            if (t.url().toString() == radioUrl) {
                radioBack = true;
                break;
            }
        check("restored_keeps_radio", radioBack);
    }
    out << "OWN_PROBE done fail=" << fail << '\n';
    return fail;
}

// R04 身份往返探针：CUE 分轨 / 归档条目 / 普通 / 电台四种形态经存盘→恢复后身份不丢。
// 走真实入口（CueSheet 解析 + Collections::resolveToken + MainWindow::requestSave/restoreLibrary）。
static int runIdentityProbe(AudioEnginePtr engine, PlayerController &controller, QTextStream &out) {
    int fail = 0;
    const auto check = [&](const char *name, bool ok) {
        out << "ID_PROBE " << name << ' ' << (ok ? "PASS" : "FAIL") << '\n';
        if (!ok) ++fail;
    };
    const QString base =
        qEnvironmentVariable("TTPLAYER_TESTDIR", QDir::currentPath() + QStringLiteral("/testlib")) + QLatin1Char('/');
    const QString cuePath = base + QStringLiteral("cuealbum.cue");
    // 隔离存档：requestSave/restoreLibrary 不预先设档会污染真实用户 state.json。
    QTemporaryDir st;
    qputenv("TTPLAYER_QT_STATE", (st.path() + QStringLiteral("/state.json")).toUtf8());
    const QList<Track> segs = CueSheet::toTracks(CueSheet::parseFile(cuePath));
    check("cue_parsed_3", segs.size() == 3);

    // 找第 2 段：标题 Track Two，起点 00:04:00 = 4s
    Track seg2;
    for (const Track &t : segs)
        if (t.isCueSegment() && t.cueNumber() == 2) {
            seg2 = t;
            break;
        }
    check("cue_seg2_found", seg2.isCueSegment());
    check("cue_seg2_start_4s", qAbs(seg2.playStart() - 4.0) < 0.05);

    // 纯 resolver：identityKey 形态 `sheet#track=2` 能重建回分轨（非整盘）
    const Track rs = Collections::resolveToken(seg2.identityKey());
    check("resolve_cue_is_segment", rs.isCueSegment() && rs.cueNumber() == 2);
    check("resolve_cue_start_kept", qAbs(rs.playStart() - 4.0) < 0.05);
    check("resolve_cue_title", rs.title() == QStringLiteral("Track Two"));

    // 归档：同一外层包的两条目不合并，身份带 fragment
    const QString arc = base + QStringLiteral("demo_archive.zip");
    const QStringList entries = Archive::listAudioEntries(arc);
    if (entries.size() >= 2) {
        const QUrl u1 = Archive::entryUrl(arc, entries[0]);
        const QUrl u2 = Archive::entryUrl(arc, entries[1]);
        const Track r1 = Collections::resolveToken(u1.toString());
        const Track r2 = Collections::resolveToken(u2.toString());
        check("archive_has_fragment", r1.url().hasFragment());
        check("archive_distinct_keys", r1.identityKey() != r2.identityKey());
    } else {
        out << "ID_PROBE archive_entries SKIP (\u5bb9\u5668\u4e0d\u53ef\u8bfb)\n";
    }

    // 存盘→恢复：CUE 分轨带真实段信息回来（不是整盘）
    {
        MainWindow w(&controller, engine);
        Collections &col = w.collections();
        col.setAllTracks(segs);
        col.setViewId(Collections::kAllViewId);
        controller.setTracks(col.currentTracks());
        w.requestSave();
        const LibraryStore::Loaded s = LibraryStore::load();
        bool tokenCarriesTrack = false;
        for (const QString &tk : s.trackPaths)
            if (tk.contains(QLatin1String("#track="))) {
                tokenCarriesTrack = true;
                break;
            }
        check("saved_token_has_trackno", tokenCarriesTrack);
    }
    {
        MainWindow w2(&controller, engine);
        w2.restoreLibrary();
        waitForLibraryRestore(w2);
        bool seg2Back = false;
        for (const Track &t : w2.collections().allTracks())
            if (t.isCueSegment() && t.cueNumber() == 2 && qAbs(t.playStart() - 4.0) < 0.05) {
                seg2Back = true;
                break;
            }
        check("restored_cue_segment2", seg2Back);
    }
    out << "ID_PROBE done fail=" << fail << '\n';
    return fail;
}

// 诊断：用真实 MainWindow / PlaylistWindow / EqWindow + 真实 SkinDock 量三窗宽度基准，
// 复现「点开播放列表撑大控制窗 / 宽度不一致」。仅打印数字供分析，返回 0。
static int runWidthProbe(AudioEnginePtr engine, PlayerController &controller, QTextStream &out) {
    int fail = 0;
    const auto check = [&](const char *name, bool ok) {
        out << "WIDTH_PROBE " << name << ' ' << (ok ? "PASS" : "FAIL") << '\n';
        if (!ok) ++fail;
    };
    QTemporaryDir st;
    qputenv("TTPLAYER_QT_STATE", (st.path() + QStringLiteral("/state.json")).toUtf8());

    MainWindow w(&controller, engine);
    w.show();
    QCoreApplication::processEvents();

    PlaylistWindow pl(&controller, &w.collections());
    EqWindow eq(engine);

    SkinDock dock;
    dock.registerPanel(SkinDock::Main, &w);
    dock.registerPanel(SkinDock::Equalizer, &eq);
    eq.setVisible(true);
    QCoreApplication::processEvents();
    out << "WIDTH main=" << w.width() << " eq=" << eq.width() << '\n';

    // 核心回归：打开列表窗不得把整组撑大到其初始宽，三窗同宽且紧凑
    dock.registerPanel(SkinDock::Playlist, &pl);
    pl.setVisible(true);
    QCoreApplication::processEvents();
    out << "WIDTH(+pl) main=" << w.width() << " eq=" << eq.width() << " pl=" << pl.width() << '\n';
    check("no_stretch_below_500", w.width() < 500); // 不被列表 600 初始宽带跑
    check("three_same_width", w.width() == eq.width() && w.width() == pl.width());

    // 主窗拉宽 → 整组同宽跟随
    w.resize(520, w.height());
    QCoreApplication::processEvents();
    check("widen_follows", w.width() == eq.width() && w.width() == pl.width());

    out << "WIDTH_PROBE done fail=" << fail << '\n';
    return fail;
}

// R16 歌词探针（纯逻辑 + 临时目录）：验 parse（多标签/小数位/offset 最后一行生效/排序）、
// 同名与模糊候选、CUE 整盘 mirrorShift、歧义不乱配、UTF-8/GB18030 中文回退。
static int runLyricProbe(QTextStream &out) {
    int fail = 0;
    const auto check = [&](const char *name, bool ok) {
        out << "LYRIC_PROBE " << name << ' ' << (ok ? "PASS" : "FAIL") << '\n';
        if (!ok) ++fail;
    };
    const auto writeFile = [](const QString &path, const QByteArray &bytes) {
        QFile f(path);
        if (f.open(QIODevice::WriteOnly)) {
            f.write(bytes);
            f.close();
        }
    };

    // 1) parse：多标签、mm:ss / .xx / .xxx、offset（正=提前，最后一行生效）
    {
        const QString text = QStringLiteral("[offset:+500]\n[offset:-1000]\n"
                                            "[00:10.00][00:30.50]副歌\n"
                                            "[00:05]前奏\n"
                                            "[00:20.250]第二段\n");
        const Lyric l = Lyric::parse(text);
        check("parse_line_count", l.lines().size() == 4);
        check("parse_offset_last_wins", std::abs(l.fileOffset() - (-1.0)) < 1e-6);
        // offsetSec=-1 → time = base +1：6(前奏),11(副歌),21.25(第二段),31.5(副歌)
        check("parse_sorted", l.lines()[0].text == QStringLiteral("前奏") && std::abs(l.lines()[0].time - 6.0) < 1e-6 &&
                                  std::abs(l.lines()[1].time - 11.0) < 1e-6 &&
                                  std::abs(l.lines()[3].time - 31.5) < 1e-6);
        check("parse_frac3", std::abs(l.lines()[2].time - 21.25) < 1e-6);
        check("lookup_before_first", l.lineIndexAt(5.0) == -1);
        check("lookup_mid", l.lineIndexAt(12.0) == 1);
    }

    // 内嵌词：USLT 的多语言键、大小写/别名、纯文本与时间词的确定性选择。
    const QString timedText = QStringLiteral("[offset:100]\n[00:01.00]内嵌中文\n");
    const QHash<QString, QString> embeddedTags{
        {"LYRICS", " "}, {"lyrics-eng", "Plain"}, {"lyrics-zho", timedText}, {"comment", "Not lyrics"}};
    check("embedded_timed_tag_preferred", Lyric::embeddedText(embeddedTags) == timedText);
    check("embedded_alias_tag", Lyric::embeddedText({{"UNSYNCED_LYRICS", "Alias"}}) == "Alias");
    check("embedded_non_lyric_metadata_ignored", Lyric::embeddedText({{"comment", "Not lyrics"}}).isEmpty());
    check("embedded_multilingual_selection_stable",
          Lyric::embeddedText({{"lyrics-zho", "Chinese"}, {"lyrics-eng", "English"}}) == "English");
    const Lyric plain = Lyric::parseEmbedded(QString(QChar(0xFEFF)) + QStringLiteral("第一句\r\n第二句") + QChar(0));
    check("embedded_plain_unicode",
          !plain.isEmpty() && !plain.isTimed() && plain.plainText() == QStringLiteral("第一句\n第二句"));
    check("embedded_plain_no_fake_timestamps", plain.lines().empty() && plain.lineIndexAt(100) == -1);
    check("embedded_empty_headers_rejected", Lyric::parseEmbedded("[ar:Test]\n[offset:100]\n ").isEmpty());
    const Lyric embeddedTimed = Lyric::parseEmbedded(timedText);
    check("embedded_lrc_offset", embeddedTimed.isTimed() && std::abs(embeddedTimed.fileOffset() - 0.1) < 1e-9 &&
                                     std::abs(embeddedTimed.lines().front().time - 0.9) < 1e-9);

    QTemporaryDir dir;
    const QString d = dir.path();

    // 2) CUE 轨配整盘同名词 → mirrorShift = 本段起点
    writeFile(d + "/album.flac", QByteArray());
    writeFile(d + "/album.lrc", QStringLiteral("[00:10.00]第一句\n[02:00.00]第二句\n").toUtf8());
    const Track cueSeg = Track::fromCueSegment(QUrl::fromLocalFile(d + "/album.flac"), 3,
                                               QUrl::fromLocalFile(d + "/album.cue"), 120.0, 180.0);
    const Lyric cl = Lyric::loadForTrack(cueSeg);
    check("cue_same_name_found", !cl.isEmpty());
    check("cue_album_wide_shift", std::abs(cl.mirrorShift() - 120.0) < 1e-6);
    check("cue_aligned_time", std::abs(cl.alignedTime(10.0, 0) - 130.0) < 1e-6); // 段内10s→整盘130s

    // 2b) 独立轨按轨名模糊命中（01 - Song.flac ↔ Song.lrc），非 CUE → mirrorShift=0
    writeFile(d + "/01 - Song.flac", QByteArray());
    writeFile(d + "/Song.lrc", QStringLiteral("[00:05.00]歌词一\n").toUtf8());
    const Track solo = Track(QUrl::fromLocalFile(d + "/01 - Song.flac"));
    const Lyric sl = Lyric::loadForTrack(solo);
    check("fuzzy_unique_hit",
          !sl.isEmpty() && sl.lines().size() == 1 && sl.lines()[0].text == QStringLiteral("歌词一"));
    check("fuzzy_not_albumwide", std::abs(sl.mirrorShift()) < 1e-6);

    // 3) 歧义不乱配：两个包合候选 → 宁缺毋滥
    writeFile(d + "/Title.flac", QByteArray());
    writeFile(d + "/A Title B.lrc", QStringLiteral("[00:01]x\n").toUtf8());
    writeFile(d + "/C Title D.lrc", QStringLiteral("[00:01]y\n").toUtf8());
    const Track amb = Track(QUrl::fromLocalFile(d + "/Title.flac"));
    check("fuzzy_ambiguous_none", Lyric::loadForTrack(amb).isEmpty());

    // 4) 编码回退：UTF-8 中文
    writeFile(d + "/utf.flac", QByteArray());
    writeFile(d + "/utf.lrc", QStringLiteral("[00:10.00]你好世界\n").toUtf8());
    const Track u = Track(QUrl::fromLocalFile(d + "/utf.flac"));
    const Lyric ul = Lyric::loadForTrack(u);
    check("utf8_chinese", !ul.isEmpty() && ul.lines()[0].text == QStringLiteral("你好世界"));
    Track embedded(u.url());
    embedded.setEmbeddedLyrics(timedText);
    const Lyric selectedEmbedded = Lyric::loadForTrack(embedded);
    check("embedded_before_external_lrc",
          selectedEmbedded.isTimed() && selectedEmbedded.lines().front().text == QStringLiteral("内嵌中文"));
    embedded.setEmbeddedLyrics(QStringLiteral("内嵌纯文本"));
    check("embedded_plain_before_external_timed",
          Lyric::loadForTrack(embedded).plainText() == QStringLiteral("内嵌纯文本"));
    embedded.setEmbeddedLyrics("[ar:Test]\n[offset:100]\n ");
    const Lyric fallback = Lyric::loadForTrack(embedded);
    check("embedded_empty_falls_back",
          fallback.isTimed() && fallback.lines().front().text == QStringLiteral("你好世界"));
    Track embeddedCue = cueSeg;
    embeddedCue.setEmbeddedLyrics("[02:00.00]Embedded CUE");
    const Lyric cueLyric = Lyric::loadForTrack(embeddedCue);
    check("embedded_cue_album_time",
          cueLyric.isTimed() && cueLyric.mirrorShift() == 120 && cueLyric.lineIndexAt(cueLyric.alignedTime(0, 0)) == 0);
    Track live = Track::fromRadio(QUrl("http://example.com/lyrics"));
    live.setEmbeddedLyrics(timedText);
    check("embedded_live_not_file_lyrics", Lyric::loadForTrack(live).isEmpty());

#ifdef TTPLAYER_HAVE_TEXTCODEC
    // GB18030/GBK 中文：用 codec 编出 GBK 字节，loadForTrack 应解回正确中文
    if (QTextCodec *gb = QTextCodec::codecForName("GB18030")) {
        const QByteArray gbk = gb->fromUnicode(QStringLiteral("[00:10.00]中文歌词\n"));
        writeFile(d + "/gbk.flac", QByteArray());
        writeFile(d + "/gbk.lrc", gbk);
        const Track g = Track(QUrl::fromLocalFile(d + "/gbk.flac"));
        const Lyric gl = Lyric::loadForTrack(g);
        check("gb18030_chinese", !gl.isEmpty() && gl.lines()[0].text == QStringLiteral("中文歌词"));
    } else {
        out << "LYRIC_PROBE gb18030_chinese SKIP\n";
    }
#else
    out << "LYRIC_PROBE gb18030_chinese SKIP\n";
#endif

    return fail;
}

// R13 固定页与最近档案探针（纯 Collections 逻辑，不碰设备/窗口）：
// 验左栏普通列表在前、电台入口在后的次序/身份、@radio 与 @library 投影、@recent 录入上限、
// 删行语义（@radio 真删、@library 只读）、空提示、viewListID/recent 存档往返。
static int runGroupsProbe(QTextStream &out) {
    int fail = 0;
    const auto check = [&](const char *name, bool ok) {
        out << "GROUPS_PROBE " << name << ' ' << (ok ? "PASS" : "FAIL") << '\n';
        if (!ok) ++fail;
    };
    auto keysOf = [](const QList<Track> &ts) {
        QStringList ks;
        for (const Track &t : ts)
            ks.append(t.identityKey());
        return ks;
    };

    const Track a = Track(QUrl::fromLocalFile("/lib/alpha.mp3"));
    const Track b = Track(QUrl::fromLocalFile("/lib/beta.flac"));
    const Track r = Track::fromRadio(QUrl(QStringLiteral("http://live.example/stream")));

    Collections col;
    col.setAllTracks({a, b, r});
    col.setLibraryKeys({a.identityKey()}); // 只有 a 来自扫描

    // 1) 固定页次序与身份（恒含「未分类电台」页，无自建分类/列表时恰好 7 行）
    const auto vl = col.viewList();
    QStringList order;
    for (const auto &p : vl)
        order.append(p.first);
    check("seven_fixed_pages", vl.size() == 7);
    check("page_order",
          order == QStringList({Collections::kAllViewId, Collections::kLibraryViewId, Collections::kRecentViewId,
                                Collections::kFavViewId, Collections::kRadioViewId, Collections::kRecentRadioViewId,
                                Collections::radioCatViewId(RadioStations::uncategorizedID)}));
    QStringList names;
    for (const auto &p : vl)
        names.append(p.second);
    check("page_names",
          names == QStringList({QStringLiteral("[默认]"), QStringLiteral("媒体库"), QStringLiteral("最近播放"),
                                QStringLiteral("我的收藏"), QStringLiteral("网络电台"), QStringLiteral("最近听的台"),
                                QStringLiteral("未分类电台")}));
    Collections grouped;
    QString firstList, secondList, firstCategory, secondCategory;
    grouped.radios().createCategory(QStringLiteral("通勤"), &firstCategory, nullptr);
    grouped.playlists().create(QStringLiteral("晨间"), &firstList);
    grouped.radios().createCategory(QStringLiteral("专注"), &secondCategory, nullptr);
    grouped.playlists().create(QStringLiteral("夜间"), &secondList);
    QStringList groupedIds;
    for (const auto &entry : grouped.viewList())
        groupedIds.append(entry.first);
    check("radio_entries_after_all_user_lists",
          groupedIds ==
              QStringList({Collections::kAllViewId, Collections::kLibraryViewId, Collections::kRecentViewId,
                           Collections::kFavViewId, firstList, secondList, Collections::kRadioViewId,
                           Collections::kRecentRadioViewId, Collections::radioCatViewId(RadioStations::uncategorizedID),
                           Collections::radioCatViewId(firstCategory), Collections::radioCatViewId(secondCategory)}));
    grouped.setViewId(Collections::radioCatViewId(firstCategory));
    LibraryStore::Loaded groupedState;
    grouped.saveTo(groupedState);
    Collections groupedBack;
    groupedBack.loadFrom(groupedState);
    check("sidebar_order_and_view_survive_restore",
          groupedBack.viewList() == grouped.viewList() && groupedBack.viewId() == grouped.viewId());

    // 2) 投影页
    check("all_has_three", keysOf(col.tracksOf(Collections::kAllViewId)).size() == 3);
    check("radio_projection", keysOf(col.tracksOf(Collections::kRadioViewId)) == QStringList({r.identityKey()}));
    check("library_projection", keysOf(col.tracksOf(Collections::kLibraryViewId)) == QStringList({a.identityKey()}));

    // 3) 最近录入：touch 语义（最近在前 + 去重）
    col.recordPlay(a.identityKey());
    col.recordPlay(b.identityKey());
    col.recordPlay(a.identityKey()); // 重播 a → a 提到最前，不重复
    check("recent_touch_front", col.recentKeys() == QStringList({a.identityKey(), b.identityKey()}));
    col.recordRadioPlay(r.identityKey());
    check("recent_radio_only_radio", col.recentRadioKeys() == QStringList({r.identityKey()}));
    Collections lim;
    for (int i = 0; i < 60; ++i)
        lim.recordPlay(QStringLiteral("k%1").arg(i));
    check("recent_cap_50", lim.recentKeys().size() == Collections::kRecentLimit &&
                               lim.recentKeys().first() == QStringLiteral("k59") &&
                               !lim.recentKeys().contains(QStringLiteral("k0")));
    Collections limr;
    for (int i = 0; i < 25; ++i)
        limr.recordRadioPlay(QStringLiteral("h%1").arg(i));
    check("recent_radio_cap_20", limr.recentRadioKeys().size() == Collections::kRecentRadioLimit &&
                                     limr.recentRadioKeys().first() == QStringLiteral("h24"));

    // 4) 删行语义
    check("library_readonly", !col.removeTrackFromView(Collections::kLibraryViewId, a.identityKey()) &&
                                  keysOf(col.tracksOf(Collections::kAllViewId)).contains(a.identityKey()));
    check("radio_real_delete", col.removeTrackFromView(Collections::kRadioViewId, r.identityKey()) &&
                                   !keysOf(col.tracksOf(Collections::kAllViewId)).contains(r.identityKey()) &&
                                   col.tracksOf(Collections::kRadioViewId).isEmpty());
    check("recent_delete_archive", col.removeTrackFromView(Collections::kRecentViewId, b.identityKey()) &&
                                       !col.recentKeys().contains(b.identityKey()));

    // 5) 空提示
    check("hint_default_empty", Collections::emptyHintFor(Collections::kAllViewId).isEmpty());
    check("hint_recent", Collections::emptyHintFor(Collections::kRecentViewId) == QStringLiteral("还没有播放记录"));
    check("hint_library", !Collections::emptyHintFor(Collections::kLibraryViewId).isEmpty());

    // 6) 持久化往返：固定页 + 两份历史 + 歌单页
    col.recordPlay(b.identityKey()); // 留一点历史
    col.setViewId(Collections::kRecentViewId);
    LibraryStore::Loaded s;
    col.saveTo(s);
    check("save_view_recent", s.viewListID == QStringLiteral("recent") && !s.recentKeys.isEmpty());
    Collections back;
    back.loadFrom(s);
    check("load_view_recent", back.viewId() == Collections::kRecentViewId);
    check("load_recent_keys", back.recentKeys() == col.recentKeys() && back.recentRadioKeys() == col.recentRadioKeys());

    Collections radioView;
    radioView.setViewId(Collections::kRadioViewId);
    LibraryStore::Loaded sr;
    radioView.saveTo(sr);
    check("save_view_radio", sr.viewListID == QStringLiteral("radio"));
    Collections backR;
    backR.loadFrom(sr);
    check("load_view_radio", backR.viewId() == Collections::kRadioViewId);

    // 歌单页 playlist:<id> 往返
    Collections withList;
    QString lid;
    withList.playlists().create(QStringLiteral("深夜"), &lid);
    withList.setViewId(lid);
    LibraryStore::Loaded sl;
    withList.saveTo(sl);
    check("save_view_playlist", sl.viewListID == QStringLiteral("playlist:") + lid);
    Collections backP;
    backP.loadFrom(sl);
    check("load_view_playlist", backP.viewId() == lid);

    // 认不出的页 → 回 [默认]
    LibraryStore::Loaded bogus;
    bogus.viewListID = QStringLiteral("nope");
    Collections backB;
    backB.loadFrom(bogus);
    check("unknown_page_falls_back", backB.viewId() == Collections::kAllViewId);

    return fail;
}

// R09 曲库自动监听探针：把临时目录挂为曲库文件夹，往目录里放/删一个音频，
// 跑事件循环让 QFileSystemWatcher 的 directoryChanged + 防抖 timer 生效，验 allTracks 自动同步。
// 无头环境下原生文件监听有延迟属正常，故给足轮询窗口（每段最多 ~5s）。
static int runWatchProbe(AudioEnginePtr engine, PlayerController &controller, QTextStream &out) {
    int fail = 0;
    const auto check = [&](const char *name, bool ok) {
        out << "WATCH_PROBE " << name << ' ' << (ok ? "PASS" : "FAIL") << '\n';
        if (!ok) ++fail;
    };
    QTemporaryDir st;
    qputenv("TTPLAYER_QT_STATE", (st.path() + QStringLiteral("/state.json")).toUtf8());
    QTemporaryDir lib;
    if (!lib.isValid()) {
        out << "WATCH_PROBE done fail=1\n";
        return 1;
    }

    MainWindow w(&controller, engine);
    w.show();
    QCoreApplication::processEvents();
    w.addLibraryFolder(lib.path());

    const QString src =
        qEnvironmentVariable("TTPLAYER_TESTDIR", QStringLiteral("testlib")) + QStringLiteral("/demo01.wav");
    const QString dst = lib.path() + QStringLiteral("/watch01.wav");
    if (!QFile::exists(src)) {
        out << "WATCH_PROBE add_detected SKIP (素材 testlib/demo01.wav 缺失)\n";
        out << "WATCH_PROBE done fail=0\n";
        return 0;
    }
    const int base = w.collections().allTracks().size();

    // 1) 新增：拷贝一个 wav 进监听目录 → 轮询到 allTracks 多一条
    QFile::copy(src, dst);
    bool added = false;
    for (int i = 0; i < 100 && !added; ++i) {
        QCoreApplication::processEvents();
        QThread::msleep(50);
        added = w.collections().allTracks().size() > base;
    }
    check("add_detected", added);

    // 2) 删除：移除该 wav → 轮询到 allTracks 回到原基线（stale 清除）
    bool removed = false;
    if (added) {
        QFile::remove(dst);
        for (int i = 0; i < 100 && !removed; ++i) {
            QCoreApplication::processEvents();
            QThread::msleep(50);
            removed = w.collections().allTracks().size() == base;
        }
    }
    check("remove_detected", removed);

    // 3) 播放现场不被重扫抹掉：setTracks 不碰队列（这里没开流，验 currentTrack 仍可空安全访问）
    check("engine_untouched", controller.currentTrack().isNull());

    out << "WATCH_PROBE done fail=" << fail << '\n';
    return fail;
}

// R03 现场恢复探针：走真实 saveState→restoreLibrary 往返，验游标/顺序/历史/
// 段身份不被浏览页覆盖，以及「恢复现场但停住」 vs「启用自动续播才开声」两条分支。
// 靠 dummy 音频：playRowAt 真开流（isPlaying 为真），saveState 据此记 resumeWasPlaying。
static int runResumeProbe(AudioEnginePtr engine, PlayerController &controller, QTextStream &out) {
    int fail = 0;
    const auto check = [&](const char *name, bool ok) {
        out << "RESUME_PROBE " << name << ' ' << (ok ? "PASS" : "FAIL") << '\n';
        if (!ok) ++fail;
    };
    const QString base =
        qEnvironmentVariable("TTPLAYER_TESTDIR", QDir::currentPath() + QStringLiteral("/testlib")) + QLatin1Char('/');
    const auto plain = [&base](const QString &n, const QString &ti) {
        Track t(QUrl::fromLocalFile(base + n));
        t.setTitle(ti);
        return t;
    };
    // cue 第 2 段作当前曲（镜像真实存在，playStart≈4s）：恢复后应仍是分轨而非整盘
    const QList<Track> segs = CueSheet::toTracks(CueSheet::parseFile(base + QStringLiteral("cuealbum.cue")));
    Track seg2;
    for (const Track &t : segs)
        if (t.isCueSegment() && t.cueNumber() == 2) {
            seg2 = t;
            break;
        }
    if (!seg2.isCueSegment()) {
        out << "RESUME_PROBE done fail=1\n"; // 素材缺失，直接判失败
        return 1;
    }

    QTemporaryDir st;
    qputenv("TTPLAYER_QT_STATE", (st.path() + QStringLiteral("/state.json")).toUtf8());

    const Track t0 = plain(QStringLiteral("demo01.wav"), QStringLiteral("D1"));
    const Track t2 = plain(QStringLiteral("demo02.wav"), QStringLiteral("D2"));
    const Track single = plain(QStringLiteral("art/single.wav"), QStringLiteral("Single"));
    const Track coverless = plain(QStringLiteral("art/coverless.wav"), QStringLiteral("Coverless"));
    const QList<Track> scene{t0, seg2, single, t2, coverless};

    // —— Phase A：从普通列表建立现场，关自动续播存盘 ——
    {
        MainWindow w(&controller, engine);
        w.collections().registerTracks(scene); // 先导入再播。
        controller.setTracks(scene);
        controller.setMode(PlayMode::Order);
        controller.playRowAt(1);    // 从 seg2 开声（dummy）。
        w.setAutoResumePlay(false); // 关自动续播 → 恢复应停在暂停
        const PlayQueue &q = controller.queue();
        check("phaseA_cursor_cue", q.current() && q.currentTrack().isCueSegment() && q.currentTrack().cueNumber() == 2);
    }

    // —— Phase B：重启恢复（autoResumePlay=false → 停住不开声，但现场完整）——
    {
        // 先把共享控制器擦干净（Phase A 它正播着 seg2），否则下面断言可能只反映残留、
        // 证明不了 restore 真的重建了现场。擦完 cursor 为空，恢复若没跑段身份就丢。
        controller.stop();
        controller.queue().reset();
        MainWindow w2(&controller, engine);
        w2.restoreLibrary();
        waitForLibraryRestore(w2);
        const PlayQueue &q = controller.queue();
        check("restored_cursor_cue", q.current() && q.currentTrack().isCueSegment() &&
                                         q.currentTrack().cueNumber() == 2 &&
                                         qAbs(q.currentTrack().playStart() - 4.0) < 0.05);
        check("restored_not_playing", !controller.isPlaying()); // autoResumePlay=false 不开声
        bool ordered = q.count() == scene.size();
        for (int i = 0; ordered && i < scene.size(); ++i)
            ordered &= q.items()[i].track.identityKey() == scene[i].identityKey();
        check("restored_base_order", ordered && q.cursor() == 1);
        const auto *next = controller.queue().peekOnFinish(PlayMode::Order);
        check("restored_next_identity", next && next->track.identityKey() == single.identityKey());
    }

    // —— Phase C：开自动续播、播着存盘 → 重启后应开声 ——
    {
        MainWindow w3(&controller, engine);
        w3.collections().registerTracks({t0, seg2, t2}); // 同上：库非空 restoreLibrary 才不提前 return
        controller.setTracks({t0, seg2, t2});
        controller.setMode(PlayMode::Order);
        controller.playRowAt(1); // 这次播着存盘（isPlaying=true）
        w3.setAutoResumePlay(true);
        for (int i = 0; i < 300 && !controller.isPlaying(); ++i) {
            QCoreApplication::processEvents();
            QThread::msleep(5);
        }
        w3.requestSave();
        check("phaseC_was_playing", controller.isPlaying());
    }
    {
        controller.stop();
        controller.queue().reset();
        MainWindow w4(&controller, engine);
        w4.restoreLibrary();
        waitForLibraryRestore(w4);
        for (int i = 0; i < 300 && !controller.isPlaying(); ++i) {
            QCoreApplication::processEvents();
            QThread::msleep(5);
        }
        check("autoresume_playing", controller.isPlaying()); // wasPlaying && autoResumePlay
        check("autoresume_cursor_cue", controller.queue().current() &&
                                           controller.queue().currentTrack().isCueSegment() &&
                                           controller.queue().currentTrack().cueNumber() == 2);
    }

    out << "RESUME_PROBE done fail=" << fail << '\n';
    return fail;
}

// R06 存档可靠性探针（纯 LibraryStore，不开设备）：
// ① 坏 JSON 不被静默当空档覆盖（首启迁移前先留 .corrupt-*，再建库）；
// ② 写入失败（数据库写锁）→ save 返回 false，已存的值不变。
static int runSaveProbe(QTextStream &out) {
    int fail = 0;
    const auto check = [&](const char *name, bool ok) {
        out << "SAVE_PROBE " << name << ' ' << (ok ? "PASS" : "FAIL") << '\n';
        if (!ok) ++fail;
    };
    QTemporaryDir st;
    const QString dir = st.path();
    const QString statePath = dir + QStringLiteral("/state.json");
    qputenv("TTPLAYER_QT_STATE", statePath.toUtf8());

    // ① 坏 JSON 保护
    {
        QFile w(statePath);
        w.open(QIODevice::WriteOnly);
        w.write("not-json{broken");
        w.close();
        LibraryStore::Loaded s;
        s.volume = 0.42;
        s.trackPaths = {QStringLiteral("file:///x/a.mp3")};
        check("save_after_corrupt_ok", LibraryStore::save(s));
        const LibraryStore::Loaded back = LibraryStore::load();
        check("new_state_valid", back.valid && std::abs(back.volume - 0.42) < 1e-9 && back.trackPaths.size() == 1);
        bool found = false;
        for (const QString &name : QDir(dir).entryList(QDir::Files))
            if (name.startsWith(QLatin1String("state.json.corrupt-"))) {
                QFile bf(dir + "/" + name);
                if (bf.open(QIODevice::ReadOnly) && bf.readAll() == QByteArray("not-json{broken")) found = true;
            }
        check("corrupt_bytes_preserved", found);
    }

    // ② 写失败旧档不变：用独立连接持有写锁，避免把 Windows 目录只读属性当成 ACL。
    {
        LibraryStore::closeDatabase();
        LibraryStore::Loaded s2;
        s2.volume = 0.99; // 故意不同值，证明没落盘
        const QString lockName = QStringLiteral("save_probe_lock");
        bool locked = false;
        bool ok = true;
        {
            QSqlDatabase blocker = QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"), lockName);
            blocker.setDatabaseName(LibraryStore::dbFilePath());
            if (blocker.open()) {
                QSqlQuery query(blocker);
                locked = query.exec(QStringLiteral("BEGIN EXCLUSIVE"));
                if (locked) {
                    ok = LibraryStore::save(s2);
                    query.exec(QStringLiteral("ROLLBACK"));
                }
                blocker.close();
            }
        }
        QSqlDatabase::removeDatabase(lockName);
        check("save_fails_on_locked_database", locked && !ok);
        check("old_state_unchanged", std::abs(LibraryStore::load().volume - 0.42) < 1e-9);
    }

    out << "SAVE_PROBE done fail=" << fail << '\n';
    return fail;
}

// 跨平台播放器入口。命令行可给文件/目录直接载入（自检与"双击即播"用）：
//   ttplayer testlib/demo01.wav
int main(int argc, char *argv[]) {
    // SDL3 已移除 SDL_SetMainReady：入口自管时不再需要提前通知，SDL_Init 可直接调用。
    // 三平台视觉一致：关掉所有原生平台对话框（文件/消息/颜色/字体），改用 Qt 自带实现。
    QCoreApplication::setAttribute(Qt::AA_DontUseNativeDialogs, true);
    PlayerApplication app(argc, argv);
    app.setApplicationName(QStringLiteral("TTPlayer"));
    // 应用/窗口图标：蓝玻璃底 + 白耳机，裸可执行运行时
    // Dock / 窗口标题栏 / Cmd-Tab 都认这一份自绘 QIcon，不再退成通用可执行图标。
    app.setWindowIcon(AppIcon::icon());
    // 跨平台视觉一致的地基：强制 Fusion + 固定 palette + 默认字体（必须在建窗之前）。
    Theme::applyAppStyle(&app);
    if (argc == 2 && QString::fromLocal8Bit(argv[1]) == QStringLiteral("--dump-formats")) {
        QTextStream out(stdout);
        auto extensions = ff::playableExtensions().values();
        extensions.sort();
        out << extensions.join(' ') << " cue m3u m3u8 zip tar 7z rar\n";
        return 0;
    }
    if (argc == 2 && QString::fromLocal8Bit(argv[1]) == QStringLiteral("--version")) {
        QTextStream out(stdout);
        out << "TTPlayer 1.1.5 Qt " << qVersion() << " " << QSysInfo::currentCpuArchitecture() << '\n';
        return 0;
    }
    std::unique_ptr<InstanceGuard> instance;
    if (!qEnvironmentVariableIsSet("TTPLAYER_QT_STATE") && !qEnvironmentVariableIsSet("TTPLAYER_SELFTEST")) {
        QStringList inputs;
        for (int i = 1; i < argc; ++i)
            inputs << QString::fromLocal8Bit(argv[i]);
        instance = std::make_unique<InstanceGuard>();
        if (!instance->becomePrimary(inputs)) return 0;
    }

    // 崩溃捕获：尽早装好（应用名已设、存档目录可解析），后续任何致命错误都能落 crash.log
    CrashHandler::install();

    // 崩溃自测钩子：TTPLAYER_QT_CRASH_TEST=segv|abort|null|throw 故意崩，验证 crash.log 拿到栈
    const QByteArray crashTest = qgetenv("TTPLAYER_QT_CRASH_TEST");
    if (crashTest == "segv" || crashTest == "null") {
        volatile int *p = nullptr;
        *p = 42; // 解引用空指针 → SIGSEGV
    } else if (crashTest == "abort") {
        std::abort(); // → SIGABRT
    } else if (crashTest == "throw") {
        throw std::runtime_error("boom"); // 逃逸异常 → std::terminate
    }

    // 图标导出钩子：TTPLAYER_QT_ICON_EXPORT=<png 路径>
    // 无头渲染一枚 256px 图标存盘即退，供打包脚本（R26）导出 .icns 与目视核对几何。
    const QByteArray iconExport = qgetenv("TTPLAYER_QT_ICON_EXPORT");
    if (!iconExport.isEmpty()) {
        AppIcon::pixmap(1024).save(QString::fromLocal8Bit(iconExport));
        return 0;
    }

    // searchlist 数据层探针：纯逻辑自检，不需要 SDL/引擎/窗口，跑完即退
    if (qEnvironmentVariableIsSet("TTPLAYER_QT_SL_PROBE")) {
        QTextStream out(stdout);
        const int failed = runSearchListProbe(out);
        out.flush();
        return failed == 0 ? 0 : 1;
    }

    // SkinDock 几何探针：三窗同宽 / 竖排 / 拖动跟随 / 拉宽联动
    if (qEnvironmentVariableIsSet("TTPLAYER_QT_DOCK_PROBE")) {
        QTextStream out(stdout);
        const int failed = runDockProbe(out);
        out.flush();
        return failed == 0 ? 0 : 1;
    }

    // R06 存档可靠性探针：纯 LibraryStore，不需 SDL/引擎，验完即退
    if (qEnvironmentVariableIsSet("TTPLAYER_QT_SAVE_PROBE")) {
        QTextStream out(stdout);
        const int failed = runSaveProbe(out);
        out.flush();
        return failed == 0 ? 0 : 1;
    }

    // R13 固定页/最近档案探针：纯 Collections 逻辑，不需 SDL/引擎，验完即退
    if (qEnvironmentVariableIsSet("TTPLAYER_QT_GROUPS_PROBE")) {
        QTextStream out(stdout);
        const int failed = runGroupsProbe(out);
        out.flush();
        return failed == 0 ? 0 : 1;
    }

    // R16 歌词探针：纯逻辑 + 临时目录，不开 SDL/设备
    if (qEnvironmentVariableIsSet("TTPLAYER_QT_LYRIC_PROBE")) {
        QTextStream out(stdout);
        const int failed = runLyricProbe(out);
        out.flush();
        return failed == 0 ? 0 : 1;
    }

    // SDL3 的 SDL_Init 返回 bool（true = 成功）。
    if (!SDL_Init(SDL_INIT_AUDIO)) {
        qWarning("SDL audio init failed: %s", SDL_GetError());
        return 1;
    }
    struct SDLLifetime {
        ~SDLLifetime() { SDL_Quit(); }
    } audioLifetime;
    ff::ensureInit();

    for (const QString &suite : regressionSuites()) {
        const QByteArray flag = QStringLiteral("TTPLAYER_QT_%1_PROBE").arg(suite).toLatin1();
        if (!qEnvironmentVariableIsSet(flag.constData())) continue;
        QTextStream out(stdout);
        const int result = runRegressionSuite(suite, out);
        out.flush();
        return result == 0 ? 0 : 1;
    }

    auto engine = AudioEngine::create();
    PlayerController controller(engine);

    // 新后端无头探针：验完即退（不弹窗、不开设备）
    if (qEnvironmentVariableIsSet("TTPLAYER_QT_SETTINGS_PROBE")) {
        QTextStream out(stdout);
        const int failed = runSettingsProbe(controller, out);
        out.flush();

        return failed == 0 ? 0 : 1;
    }

    // 出厂电台默认入表探针：验完即退
    if (qEnvironmentVariableIsSet("TTPLAYER_QT_RADIO_PROBE")) {
        QTextStream out(stdout);
        const int failed = runRadioSeedProbe(engine, controller, out);
        out.flush();

        return failed == 0 ? 0 : 1;
    }

    // R08 取证 harness：本机假电台模拟无响应/慢首包/停流/断线，验 UI 开流与 stop 不被拖死
    if (qEnvironmentVariableIsSet("TTPLAYER_QT_RADIOLIVE_PROBE")) {
        QTextStream out(stdout);
        const int failed = runRadioLiveProbe(engine.get(), controller, out);
        out.flush();

        return failed == 0 ? 0 : 1;
    }

    // R15b 多选选区探针（构造 PlaylistView，offscreen 不弹窗，验完即退）
    if (qEnvironmentVariableIsSet("TTPLAYER_QT_MULTI_PROBE")) {
        QTextStream out(stdout);
        const int failed = runMultiSelectProbe(controller, out);
        out.flush();

        return failed == 0 ? 0 : 1;
    }

    // R19 后台驻留探针（构造 MainWindow，验完即退）
    if (qEnvironmentVariableIsSet("TTPLAYER_QT_GROUPVIS_PROBE")) {
        QTextStream out(stdout);
        const int failed = runGroupVisProbe(engine, controller, out);
        out.flush();

        return failed == 0 ? 0 : 1;
    }

    // R13 电台分类探针（模型 + Collections 投影 + 存档往回，验完即退）
    if (qEnvironmentVariableIsSet("TTPLAYER_QT_RADIOCAT_PROBE")) {
        QTextStream out(stdout);
        const int failed = runRadioCatProbe(engine, controller, out);
        out.flush();

        return failed == 0 ? 0 : 1;
    }

    // R02 数据所有权探针（构造 MainWindow，验完即退）
    if (qEnvironmentVariableIsSet("TTPLAYER_QT_OWNERSHIP_PROBE")) {
        QTextStream out(stdout);
        const int failed = runOwnershipProbe(engine, controller, out);
        out.flush();

        return failed == 0 ? 0 : 1;
    }

    // R04 身份往返探针（构造 MainWindow，验完即退）
    if (qEnvironmentVariableIsSet("TTPLAYER_QT_IDENTITY_PROBE")) {
        QTextStream out(stdout);
        const int failed = runIdentityProbe(engine, controller, out);
        out.flush();

        return failed == 0 ? 0 : 1;
    }

    // R03 现场恢复探针（构造 MainWindow 走真实 saveState→restoreLibrary，验完即退）
    if (qEnvironmentVariableIsSet("TTPLAYER_QT_RESUME_PROBE")) {
        QTextStream out(stdout);
        const int failed = runResumeProbe(engine, controller, out);
        out.flush();

        return failed == 0 ? 0 : 1;
    }

    // 诊断：真实三窗宽度基准（验完即退）
    if (qEnvironmentVariableIsSet("TTPLAYER_QT_WIDTH_PROBE")) {
        QTextStream out(stdout);
        const int failed = runWidthProbe(engine, controller, out);
        out.flush();

        return failed == 0 ? 0 : 1;
    }

    // R09 曲库自动监听探针（QFileSystemWatcher 驱动，验完即退）
    if (qEnvironmentVariableIsSet("TTPLAYER_QT_WATCH_PROBE")) {
        QTextStream out(stdout);
        const int failed = runWatchProbe(engine, controller, out);
        out.flush();

        return failed == 0 ? 0 : 1;
    }

    MainWindow window(&controller, engine);
    window.show();
    app.openFiles = [&window](const QStringList &files) { window.loadPaths(files); };
    if (instance)
        instance->received = [&window](const QStringList &files) {
            window.restoreGroupFromBackground();
            window.showNormal();
            window.raise();
            window.activateWindow();
            if (!files.isEmpty()) window.loadPaths(files);
        };

    // 置顶（整组）无头探针：验「置顶覆盖所有可见窗 + 置顶后新开的窗继承 + 取消全解除」。
    if (qEnvironmentVariableIsSet("TTPLAYER_QT_PIN_PROBE")) {
        QTextStream out(stdout);
        int fail = 0;
        const auto check = [&](const char *name, bool ok) {
            out << "PIN_PROBE " << name << ' ' << (ok ? "PASS" : "FAIL") << '\n';
            if (!ok) ++fail;
        };
        // 只开列表 + 均衡器（歌词/封面/队列保持关）
        if (window.probeGroupVisible() == 1) window.togglePlaylistPanel();
        window.toggleEqPanel();
        QCoreApplication::processEvents();
        check("two_panels_visible", window.probeGroupVisible() == 3); // 主 + 列表 + 均衡器
        check("none_pinned_initially", window.probeGroupPinned() == 0);
        // 置顶 → 当前可见三窗一起 stays-on-top
        window.applyPinTop(true);
        QCoreApplication::processEvents();
        check("pin_covers_all_visible", window.probeGroupPinned() == 3 && window.probeGroupVisible() == 3);
        // 置顶之后再开歌词 → 继承置顶（用户诉求：当前显示的所有窗都要置顶）
        window.toggleLyricPanel();
        QCoreApplication::processEvents();
        check("late_open_inherits_pin", window.probeGroupVisible() == 4 && window.probeGroupPinned() == 4);
        // 取消置顶 → 全部解除
        window.applyPinTop(false);
        QCoreApplication::processEvents();
        check("unpin_clears_all", window.probeGroupPinned() == 0);
        window.applyPinTop(true);
        window.openSettings();
        window.openProperties(Track(QUrl::fromLocalFile("/pin/probe.mp3")));
        window.toggleCoverPanel();
        QCoreApplication::processEvents();
        check("aux_late_open_inherits_pin", window.probeGroupVisible() == 7 && window.probeGroupPinned() == 7);
        bool stable = true;
        for (int cycle = 0; cycle < 30; ++cycle) {
            window.applyPinTop(false);
            stable &= window.probeGroupPinned() == 0;
            window.applyPinTop(true);
            stable &= window.probeGroupPinned() == window.probeGroupVisible();
        }
        check("aux_group_pin_30", stable);
        window.applyPinTop(false);
        out << "PIN_PROBE done fail=" << fail << '\n';
        out.flush();

        return fail == 0 ? 0 : 1;
    }

    // 系统托盘后台（平台无托盘时自动降级，不影响主界面）
    TrayController tray(&window, &controller);
    auto mediaSession = qEnvironmentVariableIsSet("TTPLAYER_SELFTEST") ? std::unique_ptr<QObject>{}
                                                                       : createMediaSession(&controller, &window);

    // 任何退出路径（含程序化 quit）都落盘，作为 closeEvent 之外的兜底
    QObject::connect(&app, &QCoreApplication::aboutToQuit, [&window] { window.flushState(); });

    QStringList inputs;
    inputs = app.pendingFiles;
    for (int i = 1; i < argc; ++i)
        inputs << QString::fromLocal8Bit(argv[i]);
    window.restoreLibrary();
    if (!inputs.isEmpty()) {
        // 复用 MainWindow 的载入逻辑（含 CUE 分轨展开、目录扫描、元数据探测）
        window.loadPaths(inputs);

        // 元数据回写探针：走真实导入链（loadPaths→loadDirOrFiles→applyProbeToTrack），
        // 验容器标签（title/artist/album）与真实码率确实写回了 Track，不再只按文件名显示。
        if (qEnvironmentVariableIsSet("TTPLAYER_QT_META_PROBE")) {
            QTimer::singleShot(0, [&controller, &app] {
                QTextStream out(stdout);
                int fail = 0;
                const auto chk = [&out, &fail](const char *name, bool ok) {
                    out << "META_PROBE " << name << ' ' << (ok ? "PASS" : "FAIL") << '\n';
                    if (!ok) ++fail;
                };
                const QList<Track> &ts = controller.tracks();
                chk("imported", !ts.isEmpty());
                if (!ts.isEmpty()) {
                    const Track &t = ts.first();
                    out << "META_PROBE title=" << t.title() << " artist=" << t.artist() << " album=" << t.album()
                        << " bitrate=" << t.bitRateKbps() << '\n';
                    const QString stem = QFileInfo(t.url().toLocalFile()).completeBaseName();
                    chk("title_nonempty", !t.title().isEmpty());
                    chk("artist_nonempty", !t.artist().isEmpty());
                    chk("album_nonempty", !t.album().isEmpty());
                    chk("title_differs_from_filename", t.title() != stem);
                    chk("bitrate_positive", t.bitRateKbps() > 0);
                }
                out << "META_PROBE done fail=" << fail << '\n';
                out.flush();
                app.quit();
            });
        }
    }

    // 无头冒烟：TTPLAYER_QT_SMOKE=<毫秒> 时，播一会儿采样位置后自动退出。
    // position 只在 SDL 回调真正拉走解码帧时才前进，>0 即证明整条链跑通。
    const QByteArray smokeMs = qgetenv("TTPLAYER_QT_SMOKE");
    if (!smokeMs.isEmpty()) {
        QTimer::singleShot(smokeMs.toInt(), [&controller, &app] {
            QTextStream out(stdout);
            out << "SMOKE playing=" << (controller.isPlaying() ? 1 : 0) << " position=" << controller.position()
                << " duration=" << controller.duration() << "\n";
            out.flush();
            app.quit();
        });
    }

    // 出厂电台默认入表（F11）：两条启动路径都补种（不开庭、删过不回来）
    window.seedPresetRadios();

    // 无头截图：TTPLAYER_QT_SHOT=<png 路径> 时渲染主窗口存图后退出
    // （配 QT_QPA_PLATFORM=offscreen，不依赖真实屏幕，用于目视验证皮肤）。
    // 留 800ms 让频谱分析器热身：200ms 抓到的还是未平滑的刚起步帧，每次形状都不一样。
    const QByteArray shotPath = qgetenv("TTPLAYER_QT_SHOT");
    if (!shotPath.isEmpty()) {
        QTimer::singleShot(800, [&window, shotPath, &app] {
            const bool ok = window.grab().save(QString::fromLocal8Bit(shotPath));
            QTextStream out(stdout);
            out << "SHOT " << (ok ? "ok " : "fail ") << shotPath << "\n";
            out.flush();
            app.quit();
        });
    }

    // 均衡器窗单独截图（独立顶层窗，验证 FaderView/KnobView/刻度/读数）。
    const QByteArray eqShot = qgetenv("TTPLAYER_QT_SHOT_EQ");
    if (!eqShot.isEmpty()) {
        auto *eqw = new EqWindow(engine);
        eqw->show();
        QTimer::singleShot(200, [eqw, eqShot, &app] {
            const bool ok = eqw->grab().save(QString::fromLocal8Bit(eqShot));
            QTextStream out(stdout);
            out << "SHOT_EQ " << (ok ? "ok " : "fail ") << eqShot << "\n";
            out.flush();
            app.quit();
        });
    }

    // 歌词窗单独截图（需传入带内嵌歌词或外置 .lrc 的音频）。
    const QByteArray lyricShot = qgetenv("TTPLAYER_QT_SHOT_LYRIC");
    if (!lyricShot.isEmpty()) {
        auto *lw = new LyricWindow(&controller);
        lw->show();
        QTimer::singleShot(1600, [lw, lyricShot, &app] {
            const bool ok = lw->grab().save(QString::fromLocal8Bit(lyricShot));
            QTextStream out(stdout);
            out << "SHOT_LYRIC " << (ok ? "ok " : "fail ") << lyricShot << "\n";
            out.flush();
            app.quit();
        });
    }

    // 播放列表窗单独截图（需传入音频目录/文件，验证全自绘两列表格）。
    const QByteArray plShot = qgetenv("TTPLAYER_QT_SHOT_PLAYLIST");
    if (!plShot.isEmpty()) {
        auto *plw = new PlaylistWindow(&controller, &window.collections());
        plw->show();
        QTimer::singleShot(300, [plw, plShot, &app] {
            const bool ok = plw->grab().save(QString::fromLocal8Bit(plShot));
            QTextStream out(stdout);
            out << "SHOT_PLAYLIST " << (ok ? "ok " : "fail ") << plShot << "\n";
            out.flush();
            app.quit();
        });
    }

    // 搜索页截图：先建列表窗，再走真实搜索通路（关键字 → 命中表 + 来源标签）。
    const QByteArray searchShot = qgetenv("TTPLAYER_QT_SHOT_SEARCH");
    if (!searchShot.isEmpty()) {
        auto *plw = new PlaylistWindow(&controller, &window.collections());
        plw->resize(640, plw->height()); // 截图时展开曲名与来源，正常窗口默认尺寸不变。
        plw->show();
        QTimer::singleShot(300, [plw, searchShot, &app] {
            plw->probeSearch(QStringLiteral("夜航"));
            // 清空键是文本变非空后才可见的子控件：留一拍让它拿到几何再抓图。
            QTimer::singleShot(100, [plw, searchShot, &app] {
                const bool ok = plw->grab().save(QString::fromLocal8Bit(searchShot));
                QTextStream out(stdout);
                out << "SHOT_SEARCH " << (ok ? "ok " : "fail ") << searchShot << "\n";
                out.flush();
                app.quit();
            });
        });
    }

    // 网络电台页截图：造两台示例直播 + 一个自建分类，再切到电台页（真实投影）。
    const QByteArray radioShot = qgetenv("TTPLAYER_QT_SHOT_RADIO");
    if (!radioShot.isEmpty()) {
        auto *plw = new PlaylistWindow(&controller, &window.collections());
        plw->show();
        QTimer::singleShot(300, [plw, &window, radioShot, &app] {
            Collections &col = window.collections();
            col.setAllTracks({}); // 台页只演示示例台，不混出厂内置台
            QStringList keys;
            const auto addStation = [&col, &keys](const QString &name, const QString &address) {
                Track track = Track::fromRadio(QUrl(address));
                track.setTitle(name);
                col.registerTracks({track});
                col.radios().setAlias(track.identityKey(), name);
                keys << track.identityKey();
            };
            addStation(QStringLiteral("海港音乐台"), QStringLiteral("https://radio.example.com/harbor"));
            addStation(QStringLiteral("夜间古典"), QStringLiteral("https://radio.example.com/nocturne"));
            QString category;
            col.radios().createCategory(QStringLiteral("音乐台"), &category, nullptr);
            col.radios().moveRadios(keys, category, nullptr);
            col.refreshRadioTitles();
            plw->refreshGroups(); // 新分类先上左栏，再切页
            plw->probeShowView(Collections::kRadioViewId);
            const bool ok = plw->grab().save(QString::fromLocal8Bit(radioShot));
            QTextStream out(stdout);
            out << "SHOT_RADIO " << (ok ? "ok " : "fail ") << radioShot << "\n";
            out.flush();
            app.quit();
        });
    }

    // 封面大图窗单独截图（需传入带封面的音频）。
    const QByteArray coverShot = qgetenv("TTPLAYER_QT_SHOT_COVER");
    if (!coverShot.isEmpty()) {
        auto *cw = new CoverWindow(&controller);
        cw->show();
        QTimer::singleShot(300, [cw, coverShot, &app] {
            const bool ok = cw->grab().save(QString::fromLocal8Bit(coverShot));
            QTextStream out(stdout);
            out << "SHOT_COVER " << (ok ? "ok " : "fail ") << coverShot << "\n";
            out.flush();
            app.quit();
        });
    }

    // 属性对话框单独截图（需传入音频）。
    const QByteArray propShot = qgetenv("TTPLAYER_QT_SHOT_PROP");
    if (!propShot.isEmpty()) {
        auto *pw = new PropertyWindow(controller.currentTrack(), &controller);
        pw->show();
        QTimer::singleShot(300, [pw, propShot, &app] {
            const bool ok = pw->grab().save(QString::fromLocal8Bit(propShot));
            QTextStream out(stdout);
            out << "SHOT_PROP " << (ok ? "ok " : "fail ") << propShot << "\n";
            out.flush();
            app.quit();
        });
    }

    // 格式转换窗单独截图（需传入音频）。导入是异步的：等一会儿再开窗，
    // 拿不到列表时直接拿命令行路径兜底。
    const QByteArray convertShot = qgetenv("TTPLAYER_QT_SHOT_CONVERT");
    if (!convertShot.isEmpty()) {
        QTimer::singleShot(300, [&controller, &inputs, convertShot, &app] {
            QList<Track> tracks = controller.tracks();
            if (tracks.isEmpty())
                for (const QString &p : inputs)
                    tracks.append(Track(QUrl::fromLocalFile(p)));
            auto *cw = new ConvertWindow(tracks);
            cw->show();
            QTimer::singleShot(300, [cw, convertShot, &app] {
                const bool ok = cw->grab().save(QString::fromLocal8Bit(convertShot));
                QTextStream out(stdout);
                out << "SHOT_CONVERT " << (ok ? "ok " : "fail ") << convertShot << "\n";
                out.flush();
                app.quit();
            });
        });
    }

    // ReplayGain 无头探针：TTPLAYER_QT_RG_PROBE=<文件/目录> 已由命令行载入时，
    // 打印首曲标签解析结果 + 三档模式下的增益决定，验完即退出（不弹窗）。
    if (!qgetenv("TTPLAYER_QT_RG_PROBE").isEmpty()) {
        QTimer::singleShot(0, [&controller, &app] {
            QTextStream out(stdout);
            const QList<Track> &ts = controller.tracks();
            if (ts.isEmpty()) {
                out << "RG_PROBE no-track\n";
                app.quit();
                return;
            }
            const Track &t = ts.first();
            const auto tags = t.replayGainTags();
            out << "RG_PROBE tags_parsed=" << (tags.has_value() ? 1 : 0)
                << " track_gain=" << (tags && tags->trackGain ? *tags->trackGain : 0.0)
                << " album_gain=" << (tags && tags->albumGain ? *tags->albumGain : 0.0)
                << " track_peak=" << (tags && tags->trackPeak ? *tags->trackPeak : 0.0) << "\n";
            controller.setReplayGainMode(ReplayGainMode::Track);
            out << "RG_PROBE track: " << controller.replayGainDecision(t).summaryText() << "\n";
            controller.setReplayGainMode(ReplayGainMode::Album);
            out << "RG_PROBE album: " << controller.replayGainDecision(t).summaryText() << "\n";
            controller.setReplayGainPreamp(6.0);
            out << "RG_PROBE album+6: " << controller.replayGainDecision(t).summaryText() << "\n";
            out.flush();
            app.quit();
        });
    }

    // 设置对话框截图（分选项卡逐个抓）：目视验证分组 UI 与后端绑定。
    const QByteArray setShot = qgetenv("TTPLAYER_QT_SHOT_SETTINGS");
    if (!setShot.isEmpty()) {
        auto *sw = new SettingsWindow(&window);
        sw->show();
        QCoreApplication::processEvents();
        QTimer::singleShot(200, [sw, setShot, &app] {
            const bool ok = sw->grab().save(QString::fromLocal8Bit(setShot));
            QTextStream out(stdout);
            out << "SHOT_SETTINGS " << (ok ? "ok " : "fail ") << setShot << "\n";
            out.flush();
            app.quit();
        });
    }

    const int rc = app.exec();
    engine->stop();

    return rc;
}
