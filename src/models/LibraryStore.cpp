#include "LibraryStore.h"
#include "decoder/FFmpeg.h"

#include <QCoreApplication>
#include <QDateTime>
#include <QDir>
#include <QDirIterator>
#include <QFile>
#include <QSaveFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <cmath>
#include <QJsonObject>
#include <QStandardPaths>
#include <QUrl>

namespace {

QString arrKey() { return QStringLiteral("trackPaths"); }

QStringList jsonToStringList(const QJsonValue &v) {
    QStringList out;
    if (v.isArray())
        for (const QJsonValue &e : v.toArray())
            if (e.isString()) out << e.toString();
    return out;
}

QJsonArray stringListToJson(const QStringList &list) {
    QJsonArray a;
    for (const QString &s : list) a.append(s);
    return a;
}

QJsonArray userListsToJson(const QList<UserPlaylist> &lists) {
    QJsonArray arr;
    for (const UserPlaylist &p : lists) {
        QJsonObject obj;
        obj.insert(QStringLiteral("id"), p.id);
        obj.insert(QStringLiteral("name"), p.name);
        obj.insert(QStringLiteral("keys"), stringListToJson(p.keys));
        arr.append(obj);
    }
    return arr;
}

QList<UserPlaylist> jsonToUserLists(const QJsonValue &v) {
    QList<UserPlaylist> out;
    if (!v.isArray()) return out;
    for (const QJsonValue &e : v.toArray()) {
        if (!e.isObject()) continue;
        const QJsonObject obj = e.toObject();
        out.append(UserPlaylist(obj.value(QStringLiteral("id")).toString(),
                                obj.value(QStringLiteral("name")).toString(),
                                jsonToStringList(obj.value(QStringLiteral("keys")))));
    }
    return out;
}

QJsonObject lyricShiftsToJson(const QMap<QString, double> &m) {
    QJsonObject o;
    for (auto it = m.constBegin(); it != m.constEnd(); ++it)
        o.insert(it.key(), it.value());
    return o;
}

QMap<QString, double> jsonToLyricShifts(const QJsonValue &v) {
    QMap<QString, double> out;
    if (!v.isObject()) return out;
    const QJsonObject o = v.toObject();
    for (auto it = o.constBegin(); it != o.constEnd(); ++it) {
        if (it.value().isDouble()) out.insert(it.key(), it.value().toDouble());
    }
    return out;
}

QJsonObject stringHashToJson(const QHash<QString, QString> &m) {
    QJsonObject o;
    for (auto it = m.constBegin(); it != m.constEnd(); ++it)
        o.insert(it.key(), it.value());
    return o;
}

QHash<QString, QString> jsonToStringHash(const QJsonValue &v) {
    QHash<QString, QString> out;
    if (!v.isObject()) return out;
    const QJsonObject o = v.toObject();
    for (auto it = o.constBegin(); it != o.constEnd(); ++it)
        if (it.value().isString()) out.insert(it.key(), it.value().toString());
    return out;
}

QJsonArray radioCategoriesToJson(const QList<RadioCategory> &cats) {
    QJsonArray arr;
    for (const RadioCategory &c : cats) {
        QJsonObject obj;
        obj.insert(QStringLiteral("id"), c.id);
        obj.insert(QStringLiteral("name"), c.name);
        arr.append(obj);
    }
    return arr;
}

QList<RadioCategory> jsonToRadioCategories(const QJsonValue &v) {
    QList<RadioCategory> out;
    if (!v.isArray()) return out;
    for (const QJsonValue &e : v.toArray()) {
        if (!e.isObject()) continue;
        const QJsonObject obj = e.toObject();
        out.append(RadioCategory{obj.value(QStringLiteral("id")).toString(),
                                 obj.value(QStringLiteral("name")).toString()});
    }
    return out;
}

} // namespace

namespace LibraryStore {

static QString resumeFilePath() {
    const QFileInfo info(stateFilePath());
    return info.absolutePath()+QLatin1Char('/')+(info.fileName()==QStringLiteral("state.json")?QStringLiteral("resume.json"):info.completeBaseName()+QStringLiteral(".resume.json"));
}

QString stateFilePath() {
    // 自检 / 验证可用 TTPLAYER_QT_STATE 指向隔离存档，不串用户实时 state.json
    const QByteArray override = qgetenv("TTPLAYER_QT_STATE");
    if (!override.isEmpty()) {
        QDir().mkpath(QFileInfo(QString::fromLocal8Bit(override)).absolutePath());
        return QString::fromLocal8Bit(override);
    }
    QString dir = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
    if (dir.isEmpty()) dir = QCoreApplication::applicationDirPath();
    QDir().mkpath(dir);
    return dir + QStringLiteral("/state.json");
}

int modeToInt(PlayMode m) {
    switch (m) {
    case PlayMode::Order: return 0;
    case PlayMode::SingleLoop: return 1;
    case PlayMode::ListLoop: return 2;
    case PlayMode::Random: return 3;
    }
    return 2;
}

PlayMode intToMode(int v) {
    switch (v) {
    case 0: return PlayMode::Order;
    case 1: return PlayMode::SingleLoop;
    case 2: return PlayMode::ListLoop;
    case 3: return PlayMode::Random;
    default: return PlayMode::ListLoop;
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
    for (int i = 0; i < 4; ++i) { v[i] = parts[i].toInt(&ok); if (!ok) return false; }
    x = v[0]; y = v[1]; w = v[2]; h = v[3];
    return w > 0 && h > 0;
}

Loaded load() {
    Loaded out;
    QFile f(stateFilePath());
    if (!f.exists() || !f.open(QIODevice::ReadOnly)) return out;
    const QJsonDocument doc = QJsonDocument::fromJson(f.readAll());
    if (!doc.isObject()) return out;
    QJsonObject o = doc.object();
    QFile resume(resumeFilePath());
    if (resume.open(QIODevice::ReadOnly)) {
        const QJsonObject scene=QJsonDocument::fromJson(resume.readAll()).object();
        if (scene.contains("queueKeys")) {
            QJsonArray queue;const auto keys=scene.value("queueKeys").toArray();
            const auto next=scene.value("queueNext").toArray(), explicitItems=scene.value("queueExplicit").toArray();
            for(qsizetype i=0;i<keys.size();++i)queue.append(QJsonObject{{"k",keys[i]},{"s",next.size()==keys.size()&&next[i].toBool()?2:explicitItems.size()==keys.size()&&explicitItems[i].toBool()?1:0}});
            o.insert("resumeQueue",queue);o.insert("resumeValid",!keys.isEmpty());
            o.insert("resumeCursor",scene.value("queueIndex"));o.insert("resumePosition",scene.value("position"));
            o.insert("resumeWasPlaying",scene.value("wasPlaying"));o.insert("resumeHistoryIndexes",scene.value("historyIndexes"));
        } else {
            for(auto it=scene.begin();it!=scene.end();++it)if(it.key().startsWith("resume"))o.insert(it.key(),it.value());
        }
    }
    out.valid = true;

    out.trackPaths = jsonToStringList(o.value(arrKey()));
    out.libraryFolders = jsonToStringList(o.value(QStringLiteral("libraryFolders")));
    out.libraryKeys = jsonToStringList(o.value(QStringLiteral("libraryKeys")));
    out.defaultKeys = jsonToStringList(o.value(QStringLiteral("defaultKeys")));
    out.hasDefaultKeys = o.contains(QStringLiteral("defaultKeys"));
    out.trackEdits=o.value(QStringLiteral("trackEdits")).toObject();

    if (o.contains(QStringLiteral("volume"))) out.volume = o.value(QStringLiteral("volume")).toDouble(0.8);
    out.muted = o.value(QStringLiteral("muted")).toBool(false);
    out.eqVisible=o.value(QStringLiteral("eqVisible")).toBool(false);
    out.mode = intToMode(o.value(QStringLiteral("playMode")).toInt(2));
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
    out.favoriteKeys = jsonToStringList(o.value(QStringLiteral("favoriteKeys")));
    out.userLists = jsonToUserLists(o.value(QStringLiteral("userLists")));
    out.viewListID = o.value(QStringLiteral("viewListID")).toString();
    // 最近播放 / 最近听的台：旧档缺 = 空（升级后边播边长）
    out.recentKeys = jsonToStringList(o.value(QStringLiteral("recentKeys")));
    out.recentRadioKeys = jsonToStringList(o.value(QStringLiteral("recentRadioKeys")));
    // 新增四项：默认与 Swift 一致（gapless/sleepFade 开、设备 UID/名 空、校准表 空）
    out.gaplessPlay = o.value(QStringLiteral("gaplessPlay")).toBool(true);
    out.sleepFade = o.value(QStringLiteral("sleepFade")).toBool(true);
    out.outputDeviceUID = o.value(QStringLiteral("outputDeviceUID")).toString();
    out.outputDeviceName = o.value(QStringLiteral("outputDeviceName")).toString();
    out.lyricShifts = jsonToLyricShifts(o.value(QStringLiteral("lyricShifts")));
    // 旧档缺这一项 = 谁也没删过内置电台 = 空（升级后首次启动会补种一台）
    out.declinedRadioKeys = jsonToStringList(o.value(QStringLiteral("declinedRadioKeys")));
    // 电台档案（R13）：旧档缺这三项 = 空（谁也没起过名字 / 没建过分类）
    out.radioAliases = jsonToStringHash(o.value(QStringLiteral("radioAliases")));
    out.radioCategories = jsonToRadioCategories(o.value(QStringLiteral("radioCategories")));
    out.radioAssignments = jsonToStringHash(o.value(QStringLiteral("radioAssignments")));

    // R03 现场恢复：旧档没这些键 → 保持默认（resumeValid=false，无现场）；有则逐字段取。
    if (o.contains(QStringLiteral("resumeQueue"))) {
        out.resumeValid = o.value(QStringLiteral("resumeValid")).toBool(false);
        out.resumeTrackKey = o.value(QStringLiteral("resumeTrackKey")).toString();
        out.resumePosition = o.value(QStringLiteral("resumePosition")).toDouble(0);
        out.resumeWasPlaying = o.value(QStringLiteral("resumeWasPlaying")).toBool(false);
        out.resumeCursor = o.value(QStringLiteral("resumeCursor")).toInt(-1);
        if (o.value(QStringLiteral("resumeHistoryIndexes")).isArray())
            for (const QJsonValue &v : o.value(QStringLiteral("resumeHistoryIndexes")).toArray())
                out.resumeHistoryIndexes.append(v.toInt());
        for (const QJsonValue &v : o.value(QStringLiteral("resumeQueue")).toArray()) {
            const QJsonObject it = v.toObject();
            out.resumeQueue.append({ it.value(QStringLiteral("k")).toString(),
                                     it.value(QStringLiteral("s")).toInt(0) });
        }
    }
    if(!std::isfinite(out.resumePosition)||out.resumePosition<0)out.resumePosition=0;
    if(!out.resumeQueue.isEmpty())out.resumeCursor=std::clamp(out.resumeCursor,0,int(out.resumeQueue.size())-1);
    out.resumeHistoryIndexes.removeIf([&out](int index){return index<0||index>=out.resumeQueue.size();});
    for(auto &entry:out.resumeQueue)if(entry.second<0||entry.second>2)entry.second=int(QueueSource::Later);
    return out;
}

bool save(const Loaded &values) {
    const QString target = stateFilePath();
    // 先读原始整份，保留本模块不负责的键（未移植功能的用户数据）
    QJsonObject o;
    bool corruptExisting = false;
    QFile f(target);
    if (f.open(QIODevice::ReadOnly)) {
        const QByteArray raw = f.readAll();
        f.close();
        if (!raw.isEmpty()) {
            const QJsonDocument doc = QJsonDocument::fromJson(raw);
            if (doc.isObject()) o = doc.object();
            else corruptExisting = true;   // 坏 JSON：不能静默当空档覆盖，写前先原样备份
        }
    }

    o.insert(arrKey(), stringListToJson(values.trackPaths));
    o.insert(QStringLiteral("libraryFolders"), stringListToJson(values.libraryFolders));
    o.insert(QStringLiteral("libraryKeys"), stringListToJson(values.libraryKeys));
    if (values.hasDefaultKeys) o.insert(QStringLiteral("defaultKeys"), stringListToJson(values.defaultKeys));
    o.insert(QStringLiteral("trackEdits"),values.trackEdits);
    o.insert(QStringLiteral("volume"), values.volume);
    o.insert(QStringLiteral("muted"), values.muted);
    o.insert(QStringLiteral("playMode"), modeToInt(values.mode));
    o.insert(QStringLiteral("eqEnabled"), values.eqEnabled);
    o.insert(QStringLiteral("eqPreGain"), values.eqPreGain);
    QJsonArray g;
    for (int i = 0; i < Equalizer::kBands; ++i) g.append(values.eqGains[i]);
    o.insert(QStringLiteral("eqGains"), g);
    o.insert(QStringLiteral("transparency"), values.transparency);
    o.insert(QStringLiteral("glass"), values.glass);
    o.insert(QStringLiteral("windowFrame"), values.windowFrame);
    o.insert(QStringLiteral("dockFrame"), values.dockFrame);
    o.insert(QStringLiteral("panelFrames"), values.panelFrames);
    o.insert(QStringLiteral("skinLayout"), values.skinLayout);
    o.insert(QStringLiteral("autoResumePlay"), values.autoResumePlay);
    o.insert(QStringLiteral("listVisible"), values.listVisible);
    o.insert(QStringLiteral("eqVisible"), values.eqVisible);
    o.insert(QStringLiteral("replayGainMode"), values.replayGainMode);
    o.insert(QStringLiteral("replayGainPreamp"), values.replayGainPreamp);
    o.insert(QStringLiteral("replayGainPeakLimit"), values.replayGainPeakLimit);
    o.insert(QStringLiteral("favoriteKeys"), stringListToJson(values.favoriteKeys));
    o.insert(QStringLiteral("userLists"), userListsToJson(values.userLists));
    o.insert(QStringLiteral("viewListID"), values.viewListID);
    o.insert(QStringLiteral("recentKeys"), stringListToJson(values.recentKeys));
    o.insert(QStringLiteral("recentRadioKeys"), stringListToJson(values.recentRadioKeys));
    o.insert(QStringLiteral("gaplessPlay"), values.gaplessPlay);
    o.insert(QStringLiteral("sleepFade"), values.sleepFade);
    o.insert(QStringLiteral("outputDeviceUID"), values.outputDeviceUID);
    o.insert(QStringLiteral("outputDeviceName"), values.outputDeviceName);
    o.insert(QStringLiteral("lyricShifts"), lyricShiftsToJson(values.lyricShifts));
    o.insert(QStringLiteral("declinedRadioKeys"), stringListToJson(values.declinedRadioKeys));
    o.insert(QStringLiteral("radioAliases"), stringHashToJson(values.radioAliases));
    o.insert(QStringLiteral("radioCategories"), radioCategoriesToJson(values.radioCategories));
    o.insert(QStringLiteral("radioAssignments"), stringHashToJson(values.radioAssignments));

    // R03 现场：无论有无都写回（无则写空数组，能清除陈旧现场）
    o.insert(QStringLiteral("resumeValid"), values.resumeValid);
    o.insert(QStringLiteral("resumeTrackKey"), values.resumeTrackKey);
    o.insert(QStringLiteral("resumePosition"), values.resumePosition);
    o.insert(QStringLiteral("resumeWasPlaying"), values.resumeWasPlaying);
    o.insert(QStringLiteral("resumeCursor"), values.resumeCursor);
    QJsonArray hi;
    for (int i : values.resumeHistoryIndexes) hi.append(i);
    o.insert(QStringLiteral("resumeHistoryIndexes"), hi);
    QJsonArray qa;
    for (const auto &kv : values.resumeQueue) {
        QJsonObject it;
        it.insert(QStringLiteral("k"), kv.first);
        it.insert(QStringLiteral("s"), kv.second);
        qa.append(it);
    }
    o.insert(QStringLiteral("resumeQueue"), qa);

    // 坏 JSON 先留一份原始字节（时间戳旁路文件），再写合法新档：既不丢可救内容，
    // 也不会让应用永久卡在那份坏档（R06「坏 JSON 不应被静默当空档覆盖」）。
    if (corruptExisting) {
        const QString bak = target + QStringLiteral(".corrupt-%1")
                                .arg(QDateTime::currentMSecsSinceEpoch());
        if(!QFile::copy(target, bak))return false;
    }
    // 原子写：QSaveFile 写临时缓冲、commit 时才原子替换目标，崩溃/写失败都不会留半截档，
    // 也不存在「删原档→改名」之间的丢档窗口。commit 结果回传上层。
    QSaveFile w(target);
    if (!w.open(QIODevice::WriteOnly)) return false;
    const QByteArray bytes=QJsonDocument(o).toJson(QJsonDocument::Compact);
    if (w.write(bytes) != bytes.size()) { w.cancelWriting(); return false; }
    return w.commit();
}

QStringList scanFolders(const QStringList &folders) {
    const QSet<QString> exts = ff::playableExtensions();
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

bool saveResume(const Loaded &s) {
    QJsonArray queue, history;
    for(const auto &item:s.resumeQueue)queue.append(QJsonObject{{"k",item.first},{"s",item.second}});
    for(int index:s.resumeHistoryIndexes)history.append(index);
    const QJsonObject object{{"resumeQueue",queue},{"resumeValid",s.resumeValid},
        {"resumeCursor",s.resumeCursor},{"resumePosition",s.resumePosition},
        {"resumeWasPlaying",s.resumeWasPlaying},{"resumeHistoryIndexes",history}};
    QSaveFile file(resumeFilePath());
    if(!file.open(QIODevice::WriteOnly))return false;
    const QByteArray bytes=QJsonDocument(object).toJson(QJsonDocument::Compact);
    return file.write(bytes)==bytes.size()&&file.commit();
}

} // namespace LibraryStore
