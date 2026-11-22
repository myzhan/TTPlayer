#include "LibraryStore.h"
#include "media/FFmpeg.h"

#include <QCoreApplication>
#include <QDateTime>
#include <QDir>
#include <QDirIterator>
#include <QFile>
#include <QFileInfo>
#include <QHash>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QSet>
#include <QPair>
#include <QSqlDatabase>
#include <QSqlError>
#include <QSqlQuery>
#include <QStandardPaths>
#include <QThread>
#include <QUrl>
#include <QVariant>
#include <algorithm>
#include <cmath>
#include <iterator>

// 持久化实现：SQLite（state.db）。这里只做四件事：
//   1) 首次启动把旧 state.json / resume.json 迁进来（原档改名 .migrated-<时间戳> 留底）；
//   2) 读：整库 → Loaded（缺表缺行一律当默认，单个怪值不判死整库）；
//   3) 写：save 全量替换、saveResume 只动现场，都在一个事务里；
//   4) 升级：表名带世代前缀（v1_），user_version 与之一致，老库按 kMigrations 链路逐版搬数据。
// 库坏了（不是 SQLite、或结构读不出）与旧 JSON 坏档同一纪律：先备份再重建，备份失败就不覆盖。
// 但「迁移写不进去」不算坏库：保留原库、本轮报失败，下次启动重试，绝不自动删库。

namespace {

// ---- 旧 JSON 的字段名：只在迁移路径使用，改名时唯一真相在这里 ----
const QString kKeyTrackPaths = QStringLiteral("trackPaths");
const QString kKeyLibraryFolders = QStringLiteral("libraryFolders");
const QString kKeyLibraryKeys = QStringLiteral("libraryKeys");
const QString kKeyDefaultKeys = QStringLiteral("defaultKeys");
const QString kKeyTrackEdits = QStringLiteral("trackEdits");
const QString kKeyUserLists = QStringLiteral("userLists");
const QString kKeyFavorites = QStringLiteral("favoriteKeys");
const QString kKeyRecent = QStringLiteral("recentKeys");
const QString kKeyRecentRadio = QStringLiteral("recentRadioKeys");
const QString kKeyDeclinedRadio = QStringLiteral("declinedRadioKeys");
const QString kKeyLyricShifts = QStringLiteral("lyricShifts");
const QString kKeyRadioAliases = QStringLiteral("radioAliases");
const QString kKeyRadioCategories = QStringLiteral("radioCategories");
const QString kKeyRadioAssignments = QStringLiteral("radioAssignments");

/// 已知的顶层键；迁移时「其余的都算未知」→ meta 表整段留底
QSet<QString> knownStateKeys() {
    return {kKeyTrackPaths,
            kKeyLibraryFolders,
            kKeyLibraryKeys,
            kKeyDefaultKeys,
            kKeyTrackEdits,
            kKeyUserLists,
            kKeyFavorites,
            kKeyRecent,
            kKeyRecentRadio,
            kKeyDeclinedRadio,
            kKeyLyricShifts,
            kKeyRadioAliases,
            kKeyRadioCategories,
            kKeyRadioAssignments,
            QStringLiteral("volume"),
            QStringLiteral("muted"),
            QStringLiteral("playMode"),
            QStringLiteral("eqEnabled"),
            QStringLiteral("eqPreGain"),
            QStringLiteral("eqGains"),
            QStringLiteral("transparency"),
            QStringLiteral("glass"),
            QStringLiteral("windowFrame"),
            QStringLiteral("dockFrame"),
            QStringLiteral("panelFrames"),
            QStringLiteral("skinLayout"),
            QStringLiteral("autoResumePlay"),
            QStringLiteral("listVisible"),
            QStringLiteral("eqVisible"),
            QStringLiteral("replayGainMode"),
            QStringLiteral("replayGainPreamp"),
            QStringLiteral("replayGainPeakLimit"),
            QStringLiteral("viewListID"),
            QStringLiteral("gaplessPlay"),
            QStringLiteral("sleepFade"),
            QStringLiteral("outputDeviceUID"),
            QStringLiteral("outputDeviceName"),
            QStringLiteral("resumeValid"),
            QStringLiteral("resumeTrackKey"),
            QStringLiteral("resumePosition"),
            QStringLiteral("resumeWasPlaying"),
            QStringLiteral("resumeCursor"),
            QStringLiteral("resumeHistoryIndexes"),
            QStringLiteral("resumeQueue")};
}

// ---- 迁移用的 JSON → 值（与旧 load() 的宽容口径逐字段对齐）----
QStringList jsonToStringList(const QJsonValue &v) {
    QStringList out;
    if (v.isArray())
        for (const auto &e : v.toArray())
            if (e.isString()) out << e.toString();
    return out;
}

QList<UserPlaylist> jsonToUserLists(const QJsonValue &v) {
    QList<UserPlaylist> out;
    if (!v.isArray()) return out;
    for (const auto &e : v.toArray()) {
        if (!e.isObject()) continue;
        const QJsonObject obj = e.toObject();
        out.append(UserPlaylist(obj.value(QStringLiteral("id")).toString(),
                                obj.value(QStringLiteral("name")).toString(),
                                jsonToStringList(obj.value(QStringLiteral("keys")))));
    }
    return out;
}

QMap<QString, double> jsonToLyricShifts(const QJsonValue &v) {
    QMap<QString, double> out;
    if (!v.isObject()) return out;
    const QJsonObject o = v.toObject();
    for (auto it = o.constBegin(); it != o.constEnd(); ++it)
        if (it.value().isDouble()) out.insert(it.key(), it.value().toDouble());
    return out;
}

QHash<QString, QString> jsonToStringHash(const QJsonValue &v) {
    QHash<QString, QString> out;
    if (!v.isObject()) return out;
    const QJsonObject o = v.toObject();
    for (auto it = o.constBegin(); it != o.constEnd(); ++it)
        if (it.value().isString()) out.insert(it.key(), it.value().toString());
    return out;
}

QList<RadioCategory> jsonToRadioCategories(const QJsonValue &v) {
    QList<RadioCategory> out;
    if (!v.isArray()) return out;
    for (const auto &e : v.toArray()) {
        if (!e.isObject()) continue;
        const QJsonObject obj = e.toObject();
        out.append(
            RadioCategory{obj.value(QStringLiteral("id")).toString(), obj.value(QStringLiteral("name")).toString()});
    }
    return out;
}

// 旧来源仅在此适配：保留基础项和真实当前曲，其他插队项不再恢复。
void normalizeResume(LibraryStore::Loaded &out, const QList<QPair<QString, int>> &legacy) {
    const int oldCursor = out.resumeCursor;
    QList<int> remap;
    for (int i = 0; i < legacy.size(); ++i) {
        const auto &entry = legacy[i];
        const bool current = out.resumeValid && i == oldCursor && !out.resumeTrackKey.isEmpty() &&
                             entry.first == out.resumeTrackKey && (entry.second == 1 || entry.second == 2);
        if (entry.first.isEmpty() || (entry.second != 0 && !current)) {
            remap.append(-1);
            continue;
        }
        remap.append(out.resumeQueue.size());
        out.resumeQueue.append(entry.first);
    }
    out.resumeCursor = oldCursor >= 0 && oldCursor < remap.size() ? remap[oldCursor] : -1;
    QList<int> history;
    for (int index : std::as_const(out.resumeHistoryIndexes))
        if (index >= 0 && index < remap.size() && remap[index] >= 0) history.append(remap[index]);
    out.resumeHistoryIndexes = history;
    out.resumeValid = out.resumeValid && out.resumeCursor >= 0;
    if (!std::isfinite(out.resumePosition) || out.resumePosition < 0) out.resumePosition = 0;
    if (!out.resumeValid) {
        out.resumeTrackKey.clear();
        out.resumePosition = 0;
        out.resumeWasPlaying = false;
        out.resumeHistoryIndexes.clear();
    }
}

/// 旧 load() 的逐字段解析（文件 I/O 与 resume.json 合并已在迁移入口做过）
LibraryStore::Loaded fromJsonObject(const QJsonObject &o) {
    using LibraryStore::Loaded;
    Loaded out;
    out.trackPaths = jsonToStringList(o.value(kKeyTrackPaths));
    out.libraryFolders = jsonToStringList(o.value(kKeyLibraryFolders));
    out.libraryKeys = jsonToStringList(o.value(kKeyLibraryKeys));
    out.defaultKeys = jsonToStringList(o.value(kKeyDefaultKeys));
    out.hasDefaultKeys = o.contains(kKeyDefaultKeys);
    out.trackEdits = o.value(kKeyTrackEdits).toObject();

    if (o.contains(QStringLiteral("volume"))) out.volume = o.value(QStringLiteral("volume")).toDouble(0.8);
    out.muted = o.value(QStringLiteral("muted")).toBool(false);
    out.eqVisible = o.value(QStringLiteral("eqVisible")).toBool(false);
    out.mode = LibraryStore::intToMode(o.value(QStringLiteral("playMode")).toInt(2));
    out.eqEnabled = o.value(QStringLiteral("eqEnabled")).toBool(true);
    out.eqPreGain = o.value(QStringLiteral("eqPreGain")).toDouble(0);
    if (o.value(QStringLiteral("eqGains")).isArray()) {
        const QJsonArray g = o.value(QStringLiteral("eqGains")).toArray();
        for (int i = 0; i < Equalizer::kBands && i < g.size(); ++i)
            out.eqGains[i] = g[i].toDouble(0);
    }
    out.transparency = o.value(QStringLiteral("transparency")).toDouble(0.15);
    out.glass = o.value(QStringLiteral("glass")).toBool(true);
    out.windowFrame = o.value(QStringLiteral("windowFrame")).toString();
    out.dockFrame = o.value(QStringLiteral("dockFrame")).toString();
    out.panelFrames = o.value(QStringLiteral("panelFrames")).toString();
    out.skinLayout = o.value(QStringLiteral("skinLayout")).toInt(0);
    out.autoResumePlay = o.value(QStringLiteral("autoResumePlay")).toBool(false);
    out.listVisible = o.value(QStringLiteral("listVisible")).toBool(true);
    out.replayGainMode = o.value(QStringLiteral("replayGainMode")).toInt(0);
    out.replayGainPreamp = o.value(QStringLiteral("replayGainPreamp")).toDouble(0);
    out.replayGainPeakLimit = o.value(QStringLiteral("replayGainPeakLimit")).toBool(true);
    out.favoriteKeys = jsonToStringList(o.value(kKeyFavorites));
    out.userLists = jsonToUserLists(o.value(kKeyUserLists));
    out.viewListID = o.value(QStringLiteral("viewListID")).toString();
    out.recentKeys = jsonToStringList(o.value(kKeyRecent));
    out.recentRadioKeys = jsonToStringList(o.value(kKeyRecentRadio));
    out.gaplessPlay = o.value(QStringLiteral("gaplessPlay")).toBool(true);
    out.sleepFade = o.value(QStringLiteral("sleepFade")).toBool(true);
    out.outputDeviceUID = o.value(QStringLiteral("outputDeviceUID")).toString();
    out.outputDeviceName = o.value(QStringLiteral("outputDeviceName")).toString();
    out.lyricShifts = jsonToLyricShifts(o.value(kKeyLyricShifts));
    out.declinedRadioKeys = jsonToStringList(o.value(kKeyDeclinedRadio));
    out.radioAliases = jsonToStringHash(o.value(kKeyRadioAliases));
    out.radioCategories = jsonToRadioCategories(o.value(kKeyRadioCategories));
    out.radioAssignments = jsonToStringHash(o.value(kKeyRadioAssignments));

    QList<QPair<QString, int>> legacy;
    if (o.contains(QStringLiteral("resumeQueue"))) {
        out.resumeValid = o.value(QStringLiteral("resumeValid")).toBool(false);
        out.resumeTrackKey = o.value(QStringLiteral("resumeTrackKey")).toString();
        out.resumePosition = o.value(QStringLiteral("resumePosition")).toDouble(0);
        out.resumeWasPlaying = o.value(QStringLiteral("resumeWasPlaying")).toBool(false);
        out.resumeCursor = o.value(QStringLiteral("resumeCursor")).toInt(-1);
        if (o.value(QStringLiteral("resumeHistoryIndexes")).isArray())
            for (const auto &v : o.value(QStringLiteral("resumeHistoryIndexes")).toArray())
                out.resumeHistoryIndexes.append(v.toInt(-1));
        for (const auto &v : o.value(QStringLiteral("resumeQueue")).toArray()) {
            const QJsonObject it = v.toObject();
            const int source = it.contains(QStringLiteral("s")) ? it.value(QStringLiteral("s")).toInt(-1) : 0;
            legacy.append({it.value(QStringLiteral("k")).toString(), source});
        }
    }
    normalizeResume(out, legacy);
    return out;
}

// ---- 连接管理 ----
// QSqlDatabase 的连接不能跨线程用；resume 落盘与设置落盘都发生在 GUI 线程，
// 但探针/自检可能另起线程，所以按线程分连接名，同一线程复用一个。
QString connName() {
    const auto tid = quintptr(QThread::currentThreadId());
    return QStringLiteral("ttplayer-state-0x%1").arg(tid, 0, 16);
}

QString resumeFilePath() {
    const QFileInfo info(LibraryStore::stateFilePath());
    return info.absolutePath() + QLatin1Char('/') +
           (info.fileName() == QStringLiteral("state.json") ? QStringLiteral("resume.json")
                                                            : info.completeBaseName() + QStringLiteral(".resume.json"));
}

bool looksLikeSqlite(const QString &path) {
    QFile f(path);
    if (!f.open(QIODevice::ReadOnly)) return false;
    return f.read(16) == QByteArrayLiteral("SQLite format 3\0");
}

/// 把 path 复制到 path.<kind>-<毫秒>；失败返回 false（调用方据此决定「不要覆盖」）
bool backupFile(const QString &path, const QString &kind) {
    const QString bak =
        path + QLatin1Char('.') + kind + QLatin1Char('-') + QString::number(QDateTime::currentMSecsSinceEpoch());
    return QFile::copy(path, bak);
}

bool run(QSqlDatabase &db, const QString &sql) {
    QSqlQuery q(db);
    if (q.exec(sql)) return true;
    qWarning("sqlite: %s | %s", qPrintable(sql), qPrintable(q.lastError().text()));
    return false;
}

/// 建表（幂等）。旧库升级时也走这里：只补缺的表，不动已有数据。
bool createSchema(QSqlDatabase &db) {
    static const char *kTables[] = {
        "CREATE TABLE IF NOT EXISTS v1_settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)",
        "CREATE TABLE IF NOT EXISTS v1_list_items (list TEXT NOT NULL, position INTEGER NOT NULL,"
        " key TEXT NOT NULL, PRIMARY KEY (list, position))",
        "CREATE TABLE IF NOT EXISTS v1_library_folders (position INTEGER PRIMARY KEY, path TEXT NOT NULL)",
        "CREATE TABLE IF NOT EXISTS v1_track_edits (key TEXT PRIMARY KEY, title TEXT NOT NULL DEFAULT '',"
        " artist TEXT NOT NULL DEFAULT '', album TEXT NOT NULL DEFAULT '',"
        " extra TEXT NOT NULL DEFAULT '')",
        "CREATE TABLE IF NOT EXISTS v1_playlists (id TEXT PRIMARY KEY, name TEXT NOT NULL,"
        " position INTEGER NOT NULL)",
        "CREATE TABLE IF NOT EXISTS v1_playlist_items (playlist_id TEXT NOT NULL,"
        " position INTEGER NOT NULL, key TEXT NOT NULL, PRIMARY KEY (playlist_id, position))",
        "CREATE TABLE IF NOT EXISTS v1_lyric_shifts (key TEXT PRIMARY KEY, seconds REAL NOT NULL)",
        "CREATE TABLE IF NOT EXISTS v1_eq_bands (band INTEGER PRIMARY KEY, gain REAL NOT NULL)",
        "CREATE TABLE IF NOT EXISTS v1_radio_aliases (address TEXT PRIMARY KEY, name TEXT NOT NULL)",
        "CREATE TABLE IF NOT EXISTS v1_radio_categories (id TEXT PRIMARY KEY, name TEXT NOT NULL,"
        " position INTEGER NOT NULL)",
        "CREATE TABLE IF NOT EXISTS v1_radio_assignments (address TEXT PRIMARY KEY,"
        " category_id TEXT NOT NULL)",
        "CREATE TABLE IF NOT EXISTS v1_resume_queue (position INTEGER PRIMARY KEY, key TEXT NOT NULL,"
        " source INTEGER NOT NULL)",
        "CREATE TABLE IF NOT EXISTS v1_resume_history (position INTEGER PRIMARY KEY, idx INTEGER NOT NULL)",
        "CREATE TABLE IF NOT EXISTS v1_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)",
    };
    for (const char *sql : kTables)
        if (!run(db, QString::fromLatin1(sql))) return false;
    return true;
}

// ---- schema 世代与升级 ----
// 表名 = v<世代>_<逻辑名>，前缀必须与 PRAGMA user_version 一致。改 schema 的规矩：
//   1) 全文件把表名前缀换成新的 vN_（旧前缀只允许出现在 kMigrations 的迁移 SQL 里）；
//   2) 在 kMigrations 尾部追加 migrateToVN：逐表建 vN_ 新表 → INSERT ... SELECT 搬数据
//      → DROP 旧表；新增列在 SELECT 里直接给默认值，不要指望列 DEFAULT 去补老行；
//   3) LibraryStore.h 的 kSchemaVersion 加一，static_assert 会对上数组长度。
// 迁移只会读到本进程能识别的旧结构；更高版本的库在 openDb 已经按只读拦下，不回写。

/// 表名版本化之前建的库：user_version 已经是 1，但表名裸写。就地 ALTER TABLE RENAME
/// 对齐到 v1 命名（数据、主键、索引原样保留），只在第一次打开时生效。
struct TableRename {
    const char *from;
    const char *to;
};
constexpr TableRename kLegacyTables[] = {
    {"settings", "v1_settings"},
    {"list_items", "v1_list_items"},
    {"library_folders", "v1_library_folders"},
    {"track_edits", "v1_track_edits"},
    {"playlists", "v1_playlists"},
    {"playlist_items", "v1_playlist_items"},
    {"lyric_shifts", "v1_lyric_shifts"},
    {"eq_bands", "v1_eq_bands"},
    {"radio_aliases", "v1_radio_aliases"},
    {"radio_categories", "v1_radio_categories"},
    {"radio_assignments", "v1_radio_assignments"},
    {"resume_queue", "v1_resume_queue"},
    {"resume_history", "v1_resume_history"},
    {"meta", "v1_meta"},
};

/// sqlite_master 里的表名；查询失败返回空集，后续建表/备份重建会接手。
QSet<QString> tableNames(QSqlDatabase &db) {
    QSet<QString> names;
    QSqlQuery q(db);
    if (!q.exec(QStringLiteral("SELECT name FROM sqlite_master WHERE type='table'"))) return names;
    while (q.next())
        names.insert(q.value(0).toString());
    return names;
}

bool hasUnversionedTables(QSqlDatabase &db) {
    const QSet<QString> names = tableNames(db);
    for (const TableRename &rename : kLegacyTables)
        if (names.contains(QLatin1String(rename.from)) && !names.contains(QLatin1String(rename.to))) return true;
    return false;
}

bool adoptUnversionedTables(QSqlDatabase &db) {
    QSet<QString> names = tableNames(db);
    for (const TableRename &rename : kLegacyTables) {
        const QString from = QLatin1String(rename.from);
        const QString to = QLatin1String(rename.to);
        if (!names.contains(from) || names.contains(to)) continue;
        if (!run(db, QStringLiteral("ALTER TABLE %1 RENAME TO %2").arg(from, to))) return false;
        names.remove(from);
        names.insert(to);
    }
    return true;
}

/// 一次升级：把 from 版搬到 from+1 版。只追加，不改历史步骤。
using Migration = bool (*)(QSqlDatabase &);

/// v0 → v1：首版没有前序结构，历史裸表名由 adoptUnversionedTables 处理。
bool migrateToV1(QSqlDatabase &db) {
    Q_UNUSED(db)
    return true;
}

/// 下标 i 对应「i 版升到 i+1 版」；数组长度就是当前 schema 版本。
constexpr Migration kMigrations[] = {migrateToV1};
static_assert(static_cast<int>(std::size(kMigrations)) == LibraryStore::kSchemaVersion,
              "表名世代与 kSchemaVersion 必须同步");

/// 升级事务：改名 + 迁移链，全成或全退。失败时库仍停在原版本，下次启动重试。
bool upgradeSchema(QSqlDatabase &db, int from) {
    if (from < 0) from = 0; // PRAGMA 读不出：当空库处理，后续 createSchema 接手建表
    if (!db.transaction()) return false;
    bool ok = adoptUnversionedTables(db);
    for (int v = from; ok && v < LibraryStore::kSchemaVersion; ++v)
        ok = kMigrations[v](db);
    if (!ok || !db.commit()) {
        db.rollback();
        return false;
    }
    return true;
}

int schemaVersion(QSqlDatabase &db) {
    QSqlQuery q(db);
    if (!q.exec(QStringLiteral("PRAGMA user_version")) || !q.next()) return -1;
    return q.value(0).toInt();
}

bool markSchemaVersion(QSqlDatabase &db) {
    return run(db, QStringLiteral("PRAGMA user_version = %1").arg(LibraryStore::kSchemaVersion));
}

// ---- 库 → Loaded ----
QHash<QString, QString> readSettings(QSqlDatabase &db) {
    QHash<QString, QString> out;
    QSqlQuery q(db);
    if (!q.exec(QStringLiteral("SELECT key, value FROM v1_settings"))) return out;
    while (q.next())
        out.insert(q.value(0).toString(), q.value(1).toString());
    return out;
}

QStringList readList(QSqlDatabase &db, const QString &list) {
    QStringList out;
    QSqlQuery q(db);
    q.prepare(QStringLiteral("SELECT key FROM v1_list_items WHERE list = ? ORDER BY position"));
    q.addBindValue(list);
    if (!q.exec()) return out;
    while (q.next())
        out << q.value(0).toString();
    return out;
}

LibraryStore::Loaded readSnapshot(QSqlDatabase &db) {
    LibraryStore::Loaded out;
    const QHash<QString, QString> st = readSettings(db);
    const auto text = [&st](const char *key, const QString &def = QString()) {
        return st.value(QLatin1String(key), def);
    };
    const auto number = [&text](const char *key, double def) {
        bool ok = false;
        const double v = text(key).toDouble(&ok);
        return ok ? v : def;
    };
    const auto integer = [&text](const char *key, int def) {
        bool ok = false;
        const int v = text(key).toInt(&ok);
        return ok ? v : def;
    };
    const auto flag = [&text](const char *key, bool def) {
        const QString v = text(key);
        if (v.isEmpty()) return def;
        return v != QLatin1String("0") && v.compare(QLatin1String("false"), Qt::CaseInsensitive) != 0;
    };

    out.trackPaths = readList(db, QStringLiteral("default"));
    out.libraryKeys = readList(db, QStringLiteral("library"));
    out.favoriteKeys = readList(db, QStringLiteral("favorites"));
    out.recentKeys = readList(db, QStringLiteral("recent"));
    out.recentRadioKeys = readList(db, QStringLiteral("recent_radio"));
    out.declinedRadioKeys = readList(db, QStringLiteral("declined_radio"));
    out.defaultKeys = readList(db, QStringLiteral("default_keys"));
    out.hasDefaultKeys = flag("hasDefaultKeys", false);

    {
        QSqlQuery q(db);
        if (q.exec(QStringLiteral("SELECT path FROM v1_library_folders ORDER BY position")))
            while (q.next())
                out.libraryFolders << q.value(0).toString();
    }

    out.volume = number("volume", 0.8);
    out.muted = flag("muted", false);
    out.mode = LibraryStore::intToMode(integer("playMode", 2));
    out.eqEnabled = flag("eqEnabled", true);
    out.eqPreGain = number("eqPreGain", 0);
    out.transparency = number("transparency", 0.15);
    out.glass = flag("glass", true);
    out.windowFrame = text("windowFrame");
    out.dockFrame = text("dockFrame");
    out.panelFrames = text("panelFrames");
    out.skinLayout = integer("skinLayout", 0);
    out.autoResumePlay = flag("autoResumePlay", false);
    out.listVisible = flag("listVisible", true);
    out.eqVisible = flag("eqVisible", false);
    out.replayGainMode = integer("replayGainMode", 0);
    out.replayGainPreamp = number("replayGainPreamp", 0);
    out.replayGainPeakLimit = flag("replayGainPeakLimit", true);
    out.viewListID = text("viewListID");
    out.gaplessPlay = flag("gaplessPlay", true);
    out.sleepFade = flag("sleepFade", true);
    out.outputDeviceUID = text("outputDeviceUID");
    out.outputDeviceName = text("outputDeviceName");

    {
        QSqlQuery q(db);
        if (q.exec(QStringLiteral("SELECT band, gain FROM v1_eq_bands")))
            while (q.next()) {
                const int band = q.value(0).toInt();
                if (band >= 0 && band < Equalizer::kBands) out.eqGains[band] = q.value(1).toDouble();
            }
    }
    {
        QSqlQuery q(db);
        if (q.exec(QStringLiteral("SELECT key, seconds FROM v1_lyric_shifts")))
            while (q.next())
                out.lyricShifts.insert(q.value(0).toString(), q.value(1).toDouble());
    }
    {
        QSqlQuery q(db);
        if (q.exec(QStringLiteral("SELECT key, title, artist, album, extra FROM v1_track_edits")))
            while (q.next()) {
                QJsonObject edit;
                const QString extra = q.value(4).toString();
                if (!extra.isEmpty()) {
                    const QJsonObject saved = QJsonDocument::fromJson(extra.toUtf8()).object();
                    for (auto it = saved.constBegin(); it != saved.constEnd(); ++it)
                        edit.insert(it.key(), it.value());
                }
                edit.insert(QStringLiteral("title"), q.value(1).toString());
                edit.insert(QStringLiteral("artist"), q.value(2).toString());
                edit.insert(QStringLiteral("album"), q.value(3).toString());
                out.trackEdits.insert(q.value(0).toString(), edit);
            }
    }
    {
        QSqlQuery q(db);
        if (q.exec(QStringLiteral("SELECT id, name FROM v1_playlists ORDER BY position")))
            while (q.next()) {
                const QString id = q.value(0).toString();
                QStringList keys;
                QSqlQuery items(db);
                items.prepare(QStringLiteral("SELECT key FROM v1_playlist_items WHERE playlist_id = ?"
                                             " ORDER BY position"));
                items.addBindValue(id);
                if (items.exec())
                    while (items.next())
                        keys << items.value(0).toString();
                out.userLists.append(UserPlaylist(id, q.value(1).toString(), keys));
            }
    }
    {
        QSqlQuery q(db);
        if (q.exec(QStringLiteral("SELECT id, name FROM v1_radio_categories ORDER BY position")))
            while (q.next())
                out.radioCategories.append({q.value(0).toString(), q.value(1).toString()});
    }
    {
        QSqlQuery q(db);
        if (q.exec(QStringLiteral("SELECT address, name FROM v1_radio_aliases")))
            while (q.next())
                out.radioAliases.insert(q.value(0).toString(), q.value(1).toString());
        QSqlQuery assign(db);
        if (assign.exec(QStringLiteral("SELECT address, category_id FROM v1_radio_assignments")))
            while (assign.next())
                out.radioAssignments.insert(assign.value(0).toString(), assign.value(1).toString());
    }

    out.resumeValid = flag("resumeValid", false);
    out.resumeTrackKey = text("resumeTrackKey");
    out.resumePosition = number("resumePosition", 0);
    out.resumeWasPlaying = flag("resumeWasPlaying", false);
    out.resumeCursor = integer("resumeCursor", -1);
    QList<QPair<QString, int>> legacy;
    {
        QSqlQuery q(db);
        if (q.exec(QStringLiteral("SELECT key, source FROM v1_resume_queue ORDER BY position")))
            while (q.next()) {
                bool valid = false;
                const int source = q.value(1).toInt(&valid);
                legacy.append({q.value(0).toString(), valid ? source : -1});
            }
        QSqlQuery hist(db);
        if (hist.exec(QStringLiteral("SELECT idx FROM v1_resume_history ORDER BY position")))
            while (hist.next()) {
                bool valid = false;
                const int index = hist.value(0).toInt(&valid);
                if (valid) out.resumeHistoryIndexes.append(index);
            }
    }
    normalizeResume(out, legacy);
    return out;
}

// ---- Loaded → 库 ----
QString encodeDouble(double v) {
    return QString::number(v, 'g', 17);
}
QString encodeBool(bool v) {
    return v ? QStringLiteral("1") : QStringLiteral("0");
}
// Qt 把 null QString 绑成 SQL NULL；这些列都是 NOT NULL 的文本，统一落成空串。
QString encodeText(const QString &v) {
    return v.isNull() ? QStringLiteral("") : v;
}

bool writeSetting(QSqlQuery &q, const char *key, const QString &value) {
    q.bindValue(0, QString::fromLatin1(key));
    q.bindValue(1, encodeText(value));
    if (q.exec()) return true;
    qWarning("sqlite: settings %s | %s", key, qPrintable(q.lastError().text()));
    return false;
}

bool writeList(QSqlDatabase &db, const QString &list, const QStringList &keys) {
    QSqlQuery q(db);
    q.prepare(QStringLiteral("INSERT INTO v1_list_items (list, position, key) VALUES (?, ?, ?)"));
    for (qsizetype i = 0; i < keys.size(); ++i) {
        q.bindValue(0, encodeText(list));
        q.bindValue(1, qint64(i));
        q.bindValue(2, encodeText(keys[i]));
        if (!q.exec()) {
            qWarning("sqlite: list %s | %s", qPrintable(list), qPrintable(q.lastError().text()));
            return false;
        }
    }
    return true;
}

bool writeMeta(QSqlDatabase &db, const QString &key, const QString &value) {
    QSqlQuery q(db);
    if (!q.prepare(QStringLiteral("INSERT OR REPLACE INTO v1_meta (key, value) VALUES (?, ?)"))) return false;
    q.addBindValue(key);
    q.addBindValue(encodeText(value));
    return q.exec();
}

bool writeResume(QSqlDatabase &db, const LibraryStore::Loaded &v) {
    if (!run(db, QStringLiteral("DELETE FROM v1_resume_queue")) ||
        !run(db, QStringLiteral("DELETE FROM v1_resume_history")))
        return false;
    {
        QSqlQuery q(db);
        q.prepare(QStringLiteral("INSERT INTO v1_resume_queue (position, key, source) VALUES (?, ?, ?)"));
        for (qsizetype i = 0; i < v.resumeQueue.size(); ++i) {
            q.bindValue(0, qint64(i));
            q.bindValue(1, encodeText(v.resumeQueue[i]));
            q.bindValue(2, 0); // v1 兼容列，新现场不再携带来源。
            if (!q.exec()) return false;
        }
    }
    {
        QSqlQuery q(db);
        q.prepare(QStringLiteral("INSERT INTO v1_resume_history (position, idx) VALUES (?, ?)"));
        for (qsizetype i = 0; i < v.resumeHistoryIndexes.size(); ++i) {
            q.bindValue(0, qint64(i));
            q.bindValue(1, v.resumeHistoryIndexes[i]);
            if (!q.exec()) return false;
        }
    }
    QSqlQuery setting(db);
    if (!setting.prepare(QStringLiteral("INSERT OR REPLACE INTO v1_settings (key, value) VALUES (?, ?)"))) return false;
    return writeSetting(setting, "resumeValid", encodeBool(v.resumeValid)) &&
           writeSetting(setting, "resumeTrackKey", v.resumeTrackKey) &&
           writeSetting(setting, "resumePosition", encodeDouble(v.resumePosition)) &&
           writeSetting(setting, "resumeWasPlaying", encodeBool(v.resumeWasPlaying)) &&
           writeSetting(setting, "resumeCursor", QString::number(v.resumeCursor));
}

bool writeSnapshot(QSqlDatabase &db, const LibraryStore::Loaded &v) {
    static const char *kClear[] = {
        "DELETE FROM v1_settings",         "DELETE FROM v1_list_items",        "DELETE FROM v1_library_folders",
        "DELETE FROM v1_track_edits",      "DELETE FROM v1_playlist_items",    "DELETE FROM v1_playlists",
        "DELETE FROM v1_lyric_shifts",     "DELETE FROM v1_eq_bands",          "DELETE FROM v1_radio_aliases",
        "DELETE FROM v1_radio_categories", "DELETE FROM v1_radio_assignments",
    };
    for (const char *sql : kClear)
        if (!run(db, QString::fromLatin1(sql))) return false;

    QSqlQuery setting(db);
    if (!setting.prepare(QStringLiteral("INSERT INTO v1_settings (key, value) VALUES (?, ?)"))) return false;
    if (!writeSetting(setting, "volume", encodeDouble(v.volume)) ||
        !writeSetting(setting, "muted", encodeBool(v.muted)) ||
        !writeSetting(setting, "playMode", QString::number(LibraryStore::modeToInt(v.mode))) ||
        !writeSetting(setting, "eqEnabled", encodeBool(v.eqEnabled)) ||
        !writeSetting(setting, "eqPreGain", encodeDouble(v.eqPreGain)) ||
        !writeSetting(setting, "transparency", encodeDouble(v.transparency)) ||
        !writeSetting(setting, "glass", encodeBool(v.glass)) || !writeSetting(setting, "windowFrame", v.windowFrame) ||
        !writeSetting(setting, "dockFrame", v.dockFrame) || !writeSetting(setting, "panelFrames", v.panelFrames) ||
        !writeSetting(setting, "skinLayout", QString::number(v.skinLayout)) ||
        !writeSetting(setting, "autoResumePlay", encodeBool(v.autoResumePlay)) ||
        !writeSetting(setting, "listVisible", encodeBool(v.listVisible)) ||
        !writeSetting(setting, "eqVisible", encodeBool(v.eqVisible)) ||
        !writeSetting(setting, "replayGainMode", QString::number(v.replayGainMode)) ||
        !writeSetting(setting, "replayGainPreamp", encodeDouble(v.replayGainPreamp)) ||
        !writeSetting(setting, "replayGainPeakLimit", encodeBool(v.replayGainPeakLimit)) ||
        !writeSetting(setting, "viewListID", v.viewListID) ||
        !writeSetting(setting, "gaplessPlay", encodeBool(v.gaplessPlay)) ||
        !writeSetting(setting, "sleepFade", encodeBool(v.sleepFade)) ||
        !writeSetting(setting, "outputDeviceUID", v.outputDeviceUID) ||
        !writeSetting(setting, "outputDeviceName", v.outputDeviceName) ||
        !writeSetting(setting, "hasDefaultKeys", encodeBool(v.hasDefaultKeys)))
        return false;

    if (!writeList(db, QStringLiteral("default"), v.trackPaths) ||
        !writeList(db, QStringLiteral("default_keys"), v.defaultKeys) ||
        !writeList(db, QStringLiteral("library"), v.libraryKeys) ||
        !writeList(db, QStringLiteral("favorites"), v.favoriteKeys) ||
        !writeList(db, QStringLiteral("recent"), v.recentKeys) ||
        !writeList(db, QStringLiteral("recent_radio"), v.recentRadioKeys) ||
        !writeList(db, QStringLiteral("declined_radio"), v.declinedRadioKeys))
        return false;

    {
        QSqlQuery q(db);
        q.prepare(QStringLiteral("INSERT INTO v1_library_folders (position, path) VALUES (?, ?)"));
        for (qsizetype i = 0; i < v.libraryFolders.size(); ++i) {
            q.bindValue(0, qint64(i));
            q.bindValue(1, encodeText(v.libraryFolders[i]));
            if (!q.exec()) return false;
        }
    }
    {
        QSqlQuery edit(db);
        edit.prepare(QStringLiteral("INSERT INTO v1_track_edits (key, title, artist, album, extra)"
                                    " VALUES (?, ?, ?, ?, ?)"));
        for (auto it = v.trackEdits.constBegin(); it != v.trackEdits.constEnd(); ++it) {
            const QJsonObject obj = it.value().toObject();
            QJsonObject extra = obj;
            extra.remove(QStringLiteral("title"));
            extra.remove(QStringLiteral("artist"));
            extra.remove(QStringLiteral("album"));
            edit.bindValue(0, encodeText(it.key()));
            edit.bindValue(1, encodeText(obj.value(QStringLiteral("title")).toString()));
            edit.bindValue(2, encodeText(obj.value(QStringLiteral("artist")).toString()));
            edit.bindValue(3, encodeText(obj.value(QStringLiteral("album")).toString()));
            edit.bindValue(4, extra.isEmpty() ? QStringLiteral("")
                                              : QString::fromUtf8(QJsonDocument(extra).toJson(QJsonDocument::Compact)));
            if (!edit.exec()) return false;
        }
    }
    {
        QSqlQuery list(db);
        list.prepare(QStringLiteral("INSERT INTO v1_playlists (id, name, position) VALUES (?, ?, ?)"));
        for (qsizetype i = 0; i < v.userLists.size(); ++i) {
            const UserPlaylist &p = v.userLists[i];
            list.bindValue(0, encodeText(p.id));
            list.bindValue(1, encodeText(p.name));
            list.bindValue(2, qint64(i));
            if (!list.exec()) return false;
            QSqlQuery item(db);
            item.prepare(QStringLiteral("INSERT INTO v1_playlist_items (playlist_id, position, key)"
                                        " VALUES (?, ?, ?)"));
            for (qsizetype k = 0; k < p.keys.size(); ++k) {
                item.bindValue(0, encodeText(p.id));
                item.bindValue(1, qint64(k));
                item.bindValue(2, encodeText(p.keys[k]));
                if (!item.exec()) return false;
            }
        }
    }
    {
        QSqlQuery q(db);
        q.prepare(QStringLiteral("INSERT INTO v1_lyric_shifts (key, seconds) VALUES (?, ?)"));
        for (auto it = v.lyricShifts.constBegin(); it != v.lyricShifts.constEnd(); ++it) {
            q.bindValue(0, encodeText(it.key()));
            q.bindValue(1, it.value());
            if (!q.exec()) return false;
        }
    }
    {
        QSqlQuery q(db);
        q.prepare(QStringLiteral("INSERT INTO v1_eq_bands (band, gain) VALUES (?, ?)"));
        for (int i = 0; i < Equalizer::kBands; ++i) {
            q.bindValue(0, i);
            q.bindValue(1, v.eqGains[i]);
            if (!q.exec()) return false;
        }
    }
    {
        QSqlQuery q(db);
        q.prepare(QStringLiteral("INSERT INTO v1_radio_aliases (address, name) VALUES (?, ?)"));
        for (auto it = v.radioAliases.constBegin(); it != v.radioAliases.constEnd(); ++it) {
            q.bindValue(0, encodeText(it.key()));
            q.bindValue(1, encodeText(it.value()));
            if (!q.exec()) return false;
        }
        QSqlQuery cat(db);
        cat.prepare(QStringLiteral("INSERT INTO v1_radio_categories (id, name, position) VALUES (?, ?, ?)"));
        for (qsizetype i = 0; i < v.radioCategories.size(); ++i) {
            cat.bindValue(0, encodeText(v.radioCategories[i].id));
            cat.bindValue(1, encodeText(v.radioCategories[i].name));
            cat.bindValue(2, qint64(i));
            if (!cat.exec()) return false;
        }
        QSqlQuery assign(db);
        assign.prepare(QStringLiteral("INSERT INTO v1_radio_assignments (address, category_id) VALUES (?, ?)"));
        for (auto it = v.radioAssignments.constBegin(); it != v.radioAssignments.constEnd(); ++it) {
            assign.bindValue(0, encodeText(it.key()));
            assign.bindValue(1, encodeText(it.value()));
            if (!assign.exec()) return false;
        }
    }
    return writeResume(db, v);
}

// ---- 旧 JSON 迁移 ----
QJsonObject readJsonObject(const QString &path, bool &ok) {
    ok = false;
    QFile f(path);
    if (!f.open(QIODevice::ReadOnly)) return {};
    const QJsonDocument doc = QJsonDocument::fromJson(f.readAll());
    if (!doc.isObject()) return {};
    ok = true;
    return doc.object();
}

/// 把 resume.json（含旧版场景格式）合并进 state 的 resume* 键，口径与旧 load() 一致
void mergeResumeScene(QJsonObject &state, const QJsonObject &scene) {
    if (scene.contains(QStringLiteral("queueKeys"))) {
        QJsonArray queue;
        const auto keys = scene.value(QStringLiteral("queueKeys")).toArray();
        const auto next = scene.value(QStringLiteral("queueNext")).toArray();
        const auto explicitItems = scene.value(QStringLiteral("queueExplicit")).toArray();
        for (qsizetype i = 0; i < keys.size(); ++i)
            queue.append(QJsonObject{
                {QStringLiteral("k"), keys[i]},
                {QStringLiteral("s"), next.size() == keys.size() && next[i].toBool()                     ? 2
                                      : explicitItems.size() == keys.size() && explicitItems[i].toBool() ? 1
                                                                                                         : 0}});
        state.insert(QStringLiteral("resumeQueue"), queue);
        state.insert(QStringLiteral("resumeValid"), !keys.isEmpty());
        state.insert(QStringLiteral("resumeCursor"), scene.value(QStringLiteral("queueIndex")));
        state.insert(QStringLiteral("resumePosition"), scene.value(QStringLiteral("position")));
        state.insert(QStringLiteral("resumeWasPlaying"), scene.value(QStringLiteral("wasPlaying")));
        state.insert(QStringLiteral("resumeHistoryIndexes"), scene.value(QStringLiteral("historyIndexes")));
    } else {
        for (auto it = scene.constBegin(); it != scene.constEnd(); ++it)
            if (it.key().startsWith(QLatin1String("resume"))) state.insert(it.key(), it.value());
    }
}

/// 迁移入口：读旧档 → 事务写入 → 原档改名留底。返回 false 时调用方必须放弃新库。
bool migrateLegacyJson(QSqlDatabase &db) {
    const QString statePath = LibraryStore::stateFilePath();
    const QString resumePath = resumeFilePath();
    QJsonObject state;
    bool haveLegacy = false;
    if (QFileInfo::exists(statePath)) {
        bool ok = false;
        state = readJsonObject(statePath, ok);
        if (!ok) {
            // 坏 JSON：先留原始字节，备份失败就不建库（与旧版 save 的纪律一致）
            if (!backupFile(statePath, QStringLiteral("corrupt"))) return false;
            QFile::remove(statePath);
        } else {
            haveLegacy = true;
        }
    }
    if (QFileInfo::exists(resumePath)) {
        bool ok = false;
        const QJsonObject scene = readJsonObject(resumePath, ok);
        if (!ok) {
            if (!backupFile(resumePath, QStringLiteral("corrupt"))) return false;
            QFile::remove(resumePath);
        } else {
            mergeResumeScene(state, scene);
            haveLegacy = haveLegacy || !scene.isEmpty();
        }
    }

    const LibraryStore::Loaded loaded = fromJsonObject(state);
    QJsonObject unknown;
    const QSet<QString> known = knownStateKeys();
    for (auto it = state.constBegin(); it != state.constEnd(); ++it)
        if (!known.contains(it.key())) unknown.insert(it.key(), it.value());

    if (!db.transaction()) return false;
    const bool written = writeSnapshot(db, loaded) &&
                         writeMeta(db, QStringLiteral("legacy_unknown"),
                                   QString::fromUtf8(QJsonDocument(unknown).toJson(QJsonDocument::Compact))) &&
                         writeMeta(db, QStringLiteral("migrated_from"),
                                   haveLegacy ? QStringLiteral("state.json") : QStringLiteral("none")) &&
                         markSchemaVersion(db);
    if (!written || !db.commit()) {
        db.rollback();
        return false;
    }
    // 库已经写好，再搬旧档：改名失败只影响回滚便利，不影响正确性
    const QString stamp = QString::number(QDateTime::currentMSecsSinceEpoch());
    if (QFileInfo::exists(statePath) && !QFile::rename(statePath, statePath + QStringLiteral(".migrated-") + stamp))
        qWarning("迁移完成但 state.json 改名失败：%s", qPrintable(statePath));
    if (QFileInfo::exists(resumePath) && !QFile::rename(resumePath, resumePath + QStringLiteral(".migrated-") + stamp))
        qWarning("迁移完成但 resume.json 改名失败：%s", qPrintable(resumePath));
    return true;
}

struct Db {
    QSqlDatabase handle;
    bool ok = false;
    bool writable = false;
};

#ifdef Q_OS_WIN
/// 绿色版换过位置：旧版本把档放在 %APPDATA%/TTPlayer，首次启动把原件复制到 exe 目录。
/// 只在目标目录完全没有存档痕迹时做一次；复制后不删源文件，回退旧版本仍有数据。
void importLegacyAppDataStore() {
    if (!qEnvironmentVariableIsEmpty("TTPLAYER_QT_STATE")) return; // 自检/探针走隔离目录
    const QString targetDb = LibraryStore::dbFilePath();
    const QString targetDir = QFileInfo(targetDb).absolutePath();
    // 哨兵跟着绿色文件夹走：迁过一次就不再搬，用户删库重置后也不会被旧档复活
    const QString sentinel = targetDir + QStringLiteral("/.state-imported");
    if (QFileInfo::exists(targetDb) || QFileInfo::exists(LibraryStore::stateFilePath()) || QFileInfo::exists(sentinel))
        return;
    const QString legacyDir = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
    if (legacyDir.isEmpty()) return;
    // Windows 路径大小写不敏感：同一目录时直接放弃，避免把库复制到自己身上
    if (QDir::cleanPath(QFileInfo(legacyDir).absoluteFilePath())
            .compare(QDir::cleanPath(targetDir), Qt::CaseInsensitive) == 0)
        return;

    QStringList copied;
    const QString legacyDb = legacyDir + QStringLiteral("/state.db");
    if (QFileInfo::exists(legacyDb)) {
        // 最新设置可能还在 -wal 里，三个文件一起复制，否则开库会回滚到最后一次 checkpoint
        bool ok = true;
        for (const char *suffix : {"", "-wal", "-shm"}) {
            const QString from = legacyDb + QLatin1String(suffix);
            if (!QFileInfo::exists(from)) continue;
            const QString to = targetDb + QLatin1String(suffix);
            QFile::remove(to); // 目标侧残留（如坟掉的 wal）不阻断复制
            if (!QFile::copy(from, to)) {
                ok = false;
                break;
            }
            copied << to;
        }
        if (!ok) { // 半跛库比旧库更坑：撤掉本次复制，下次启动重试
            for (const QString &name : copied)
                QFile::remove(name);
            return;
        }
    } else {
        for (const char *name : {"state.json", "resume.json"}) {
            const QString from = legacyDir + QLatin1Char('/') + QLatin1String(name);
            const QString to = targetDir + QLatin1Char('/') + QLatin1String(name);
            if (!QFileInfo::exists(from) || QFileInfo::exists(to)) continue;
            if (QFile::copy(from, to)) copied << to;
        }
        if (copied.isEmpty()) return;
    }

    QFile mark(sentinel);
    if (mark.open(QIODevice::WriteOnly | QIODevice::Text))
        mark.write(QStringLiteral("imported from %1\n").arg(legacyDir).toUtf8());
}
#endif

/// 打开库（必要时建库 / 迁旧档 / 备份坏档）。
/// create=false（load 路径）：库与旧档都不存在时返回 ok=false，避免首启凭空建库改变语义。
bool openDb(Db &out, bool create) {
#ifdef Q_OS_WIN
    importLegacyAppDataStore();
#endif
    const QString path = LibraryStore::dbFilePath();
    const QString name = connName();
    QSqlDatabase db = QSqlDatabase::database(name, false);
    if (!db.isValid()) db = QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"), name);
    if (db.isOpen()) {
        const int version = schemaVersion(db);
        out.handle = db;
        out.ok = true;
        out.writable = version <= LibraryStore::kSchemaVersion;
        return true;
    }

    const bool fresh = !QFileInfo::exists(path);
    const bool legacyPresent = QFileInfo::exists(LibraryStore::stateFilePath()) || QFileInfo::exists(resumeFilePath());
    if (fresh && !create && !legacyPresent) return false;
    if (!fresh && !looksLikeSqlite(path)) {
        // 明显不是 SQLite：与坏 JSON 同样处理——先备份，备份成功才重建
        if (!backupFile(path, QStringLiteral("corrupt"))) return false;
        QFile::remove(path);
    }

    db.setDatabaseName(path);
    if (!db.open()) return false;
    QSqlQuery pragma(db);
    pragma.exec(QStringLiteral("PRAGMA journal_mode=WAL"));
    pragma.exec(QStringLiteral("PRAGMA synchronous=NORMAL"));
    pragma.exec(QStringLiteral("PRAGMA busy_timeout=3000"));

    const int version = schemaVersion(db);
    if (version > LibraryStore::kSchemaVersion) {
        // 更新版本写过的库：能读不能写，免得旧版把新版结构覆盖回去
        qWarning("state.db schema v%d 高于本版 v%d，只读打开", version, LibraryStore::kSchemaVersion);
        out.handle = db;
        out.ok = true;
        out.writable = false;
        return true;
    }
    const bool needsUpgrade = version < LibraryStore::kSchemaVersion || hasUnversionedTables(db);
    if (needsUpgrade && !upgradeSchema(db, version)) {
        // 迁移写不进去（只读位置、磁盘满等）：不动原库，关连接等下次启动重试。
        // 上层会当成「无存档」并提示保存失败，而不是静默删掉用户档。
        qWarning("state.db 升级到 v%d 失败，原库保留待重试", int(LibraryStore::kSchemaVersion));
        db.close();
        db = QSqlDatabase();
        QSqlDatabase::removeDatabase(name);
        return false;
    }
    if (!createSchema(db)) {
        // 能打开但结构读不出：备份后重建，只重试一次
        db.close();
        db = QSqlDatabase();
        QSqlDatabase::removeDatabase(name);
        if (!backupFile(path, QStringLiteral("corrupt"))) return false;
        QFile::remove(path);
        QFile::remove(path + QStringLiteral("-wal"));
        QFile::remove(path + QStringLiteral("-shm"));
        QSqlDatabase retry = QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"), name);
        retry.setDatabaseName(path);
        if (!retry.open() || !createSchema(retry)) return false;
        db = retry;
    }
    if (fresh && legacyPresent && !migrateLegacyJson(db)) {
        // 旧档坏且备份不了：不建库、不动旧档，让上层看到「保存失败」
        db.close();
        db = QSqlDatabase();
        QSqlDatabase::removeDatabase(name);
        QFile::remove(path);
        QFile::remove(path + QStringLiteral("-wal"));
        QFile::remove(path + QStringLiteral("-shm"));
        return false;
    }
    if (version < LibraryStore::kSchemaVersion) markSchemaVersion(db);
    out.handle = db;
    out.ok = true;
    out.writable = true;
    return true;
}

} // namespace

namespace LibraryStore {

QString stateFilePath() {
    // 存档锚点：真正落盘的是 dbFilePath() 派生的 state.db，这里返回的旧 JSON 路径
    // 只用于一次性迁移与隔离定位；TTPLAYER_QT_STATE 指到别的目录时库也跟着走。
    const QByteArray override = qgetenv("TTPLAYER_QT_STATE");
    if (!override.isEmpty()) {
        QDir().mkpath(QFileInfo(QString::fromLocal8Bit(override)).absolutePath());
        return QString::fromLocal8Bit(override);
    }
#ifdef Q_OS_WIN
    // Windows 保持绿色版：库跟 ttplayer.exe 同目录，整个文件夹可拷贝/删除，不写 %APPDATA%
    const QString dir = QCoreApplication::applicationDirPath();
#else
    QString dir = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
    if (dir.isEmpty()) dir = QCoreApplication::applicationDirPath();
#endif
    QDir().mkpath(dir);
    return dir + QStringLiteral("/state.json");
}

QString dbFilePath() {
    // 与 state.json 同目录同主名：TTPLAYER_QT_STATE 指到临时目录时库也跟着隔离。
    const QFileInfo info(stateFilePath());
    if (info.suffix().compare(QLatin1String("json"), Qt::CaseInsensitive) == 0)
        return info.absolutePath() + QLatin1Char('/') + info.completeBaseName() + QStringLiteral(".db");
    return stateFilePath() + QStringLiteral(".db");
}

int modeToInt(PlayMode m) {
    switch (m) {
    case PlayMode::Order:
        return 0;
    case PlayMode::SingleLoop:
        return 1;
    case PlayMode::ListLoop:
        return 2;
    case PlayMode::Random:
        return 3;
    }
    return 2;
}

PlayMode intToMode(int v) {
    switch (v) {
    case 0:
        return PlayMode::Order;
    case 1:
        return PlayMode::SingleLoop;
    case 2:
        return PlayMode::ListLoop;
    case 3:
        return PlayMode::Random;
    default:
        return PlayMode::ListLoop;
    }
}

QString frameToString(int x, int y, int w, int h) {
    return QStringLiteral("%1,%2,%3,%4").arg(x).arg(y).arg(w).arg(h);
}

bool frameFromString(const QString &s, int &x, int &y, int &w, int &h) {
    const QStringList parts = s.split(QLatin1Char(','));
    if (parts.size() != 4) return false;
    bool ok = true;
    int v[4];
    for (int i = 0; i < 4; ++i) {
        v[i] = parts[i].toInt(&ok);
        if (!ok) return false;
    }
    x = v[0];
    y = v[1];
    w = v[2];
    h = v[3];
    return w > 0 && h > 0;
}

Loaded load() {
    Loaded out;
    Db db;
    if (!openDb(db, false)) return out;
    out = readSnapshot(db.handle);
    out.valid = true;
    return out;
}

bool save(const Loaded &values) {
    Db db;
    if (!openDb(db, true)) return false;
    if (!db.writable) {
        qWarning("state.db 由更新版本创建，拒绝写入");
        return false;
    }
    if (!db.handle.transaction()) return false;
    if (!writeSnapshot(db.handle, values) || !db.handle.commit()) {
        db.handle.rollback();
        return false;
    }
    return true;
}

bool saveResume(const Loaded &values) {
    Db db;
    if (!openDb(db, true)) return false;
    if (!db.writable) return false;
    if (!db.handle.transaction()) return false;
    if (!writeResume(db.handle, values) || !db.handle.commit()) {
        db.handle.rollback();
        return false;
    }
    return true;
}

void closeDatabase() {
    const QString name = connName();
    {
        QSqlDatabase db = QSqlDatabase::database(name, false);
        if (db.isValid()) db.close();
    }
    QSqlDatabase::removeDatabase(name);
}

QJsonObject legacyUnknownFields() {
    Db db;
    if (!openDb(db, false)) return {};
    QSqlQuery q(db.handle);
    q.prepare(QStringLiteral("SELECT value FROM v1_meta WHERE key = ?"));
    q.addBindValue(QStringLiteral("legacy_unknown"));
    if (!q.exec() || !q.next()) return {};
    return QJsonDocument::fromJson(q.value(0).toString().toUtf8()).object();
}

QStringList scanFolders(const QStringList &folders) {
    const QSet<QString> &exts = ff::playableExtensions();
    QStringList out;
    for (const QString &root : folders) {
        QDirIterator it(root, QDir::Files, QDirIterator::Subdirectories);
        while (it.hasNext()) {
            it.next();
            if (exts.contains(QFileInfo(it.filePath()).suffix().toLower()))
                out << QUrl::fromLocalFile(it.filePath()).toString();
        }
    }
    out.sort();
    return out;
}

} // namespace LibraryStore
