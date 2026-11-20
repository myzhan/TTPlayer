#include "PlaylistM3U.h"

#include "decoder/FFmpeg.h"
#include "models/LibraryStore.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QTextStream>
#include <QUrl>
#include <QRegularExpression>
#include "decoder/Archive.h"
#include "CueSheet.h"
#include <QDirIterator>
#include <QTextCodec>

namespace PlaylistM3U {

const QString marker = QStringLiteral("#EXT-X-TTPLAYER:1");
const QString compatibilityNote =
    QStringLiteral("# TTPlayer 扩展：带 #track= 的行是分轨表里精确的一轨，"
                   "带 #archive-entry= 的行是归档里的一个条目；其它播放器读不懂这两类行");

QString lineFor(const Track &track) {
    return track.identityKey();
}

bool exportKeys(const QStringList &keys, const QHash<QString, QString> &names,
                const QHash<QString, double> &durations, const QString &path) {
    QString text = QStringLiteral("#EXTM3U\n") + marker + QChar('\n') + compatibilityNote + QChar('\n');
    for (const QString &key : keys) {
        const QString name = names.value(key);
        const double dur = durations.value(key, 0.0);
        text += QStringLiteral("#EXTINF:%1,%2\n")
                    .arg(dur > 0 ? qRound(dur) : -1).arg(name);
        text += key;
        text += QChar('\n');
    }
    QFile f(path);
    if (!f.open(QIODevice::WriteOnly | QIODevice::Truncate)) return false;
    f.write(text.toUtf8());
    return true;
}

bool exportTracks(const QList<Track> &tracks, const QString &path) {
    QStringList keys;
    QHash<QString, QString> names;
    QHash<QString, double> durations;
    for (const Track &t : tracks) {
        const QString key = t.identityKey();
        names.insert(key, t.artist().isEmpty() ? t.title()
                                               : t.artist() + QStringLiteral(" - ") + t.title());
        durations.insert(key, t.duration());
        keys.append(key);
    }
    return exportKeys(keys, names, durations, path);
}

namespace {

QString readText(const QString &path) {
    QFile f(path);
    if (!f.open(QIODevice::ReadOnly | QIODevice::Text)) return QString();
    const QByteArray bytes = f.readAll();
    const QString text = QString::fromUtf8(bytes);
    return text.contains(QChar::ReplacementCharacter) ? QTextCodec::codecForName("GB18030")->toUnicode(bytes) : text;
}

/// 文件段（# 之前）解析成绝对本地路径；file:// 走 URL、裸相对路径按 baseDir 拼
QString resolveFilePart(const QString &head, const QString &baseDir) {
    static const QRegularExpression drive(QStringLiteral("^[A-Za-z]:[/\\\\]"));
    if (drive.match(head).hasMatch() || head.startsWith(QLatin1String("\\\\"))) return head;
    if (head.startsWith(QLatin1String("file://")))
        return QUrl(head).toLocalFile();
    if (head.startsWith(QLatin1Char('/')))
        return head;
    return QDir(baseDir).absoluteFilePath(head);
}

/// 把一行归一成 identityKey 形态的身份；带 # 的扩展写法解析路径段后原样接回尾段
QString toIdentityKey(const QString &line, const QString &baseDir, bool *isExtended) {
    QString archivePath, entry;
    if (Archive::parseEntryUrl(QUrl(line), archivePath, entry)) {
        if (isExtended) *isExtended = true;
        return Archive::entryUrl(archivePath, entry).toString();
    }
    const int hash = line.indexOf(QLatin1Char('#'));
    if (hash >= 0) {
        if (isExtended) *isExtended = true;
        return resolveFilePart(line.left(hash), baseDir) + line.mid(hash);
    }
    if (isExtended) *isExtended = false;
    return resolveFilePart(line, baseDir);
}

bool filePartExists(const QString &key) {
    QString archivePath, entry;
    if (Archive::parseEntryUrl(QUrl(key), archivePath, entry)) return QFileInfo::exists(archivePath);
    const int hash = key.indexOf(QLatin1Char('#'));
    const QString file = hash >= 0 ? key.left(hash) : key;
    return QFileInfo::exists(file);
}

/// 一次导入的内部状态：visited 是循环引用防护（a.m3u 引 b.m3u 引 a.m3u 不能没完）
struct Reader {
    const std::atomic<bool> *cancel = nullptr;
    QSet<QString> visited;
    const QSet<QString> exts = ff::playableExtensions();

    void absorbPlaylist(const QString &path, Imported &r) {
        const QString canonical = QFileInfo(path).absoluteFilePath();
        if (visited.contains(canonical)) return;   // 循环/重复引用防护
        visited.insert(canonical);
        const QString text = readText(canonical);
        if (text.isEmpty()) { r.fail(); return; }
        const QString baseDir = QFileInfo(canonical).absolutePath();
        const QStringList lines = text.split(QChar('\n'), Qt::SkipEmptyParts);
        QString title;
        for (const QString &raw : lines) {
            if (cancel && cancel->load()) return;
            const QString line = raw.trimmed();
            if (line.isEmpty()) continue;
            if (line.startsWith("#EXTINF:", Qt::CaseInsensitive)) { title = line.section(',',1); continue; }
            if (line.startsWith(QLatin1Char('#'))) continue;   // 注释/EXTINF/marker 一律跳过
            absorbLine(line, baseDir, r);
            if (!title.isEmpty() && (line.startsWith("http://") || line.startsWith("https://"))) r.names.insert(line,title);
            title.clear();
        }
    }

    void absorbLine(const QString &line, const QString &baseDir, Imported &r) {
        // 电台：地址本身就是全部内容
        if (cancel && cancel->load()) return;
        const QUrl u(line);
        if (u.scheme() == QLatin1String("http") || u.scheme() == QLatin1String("https")) {
            r.keep(line, true);
            return;
        }
        bool isExtended = false;
        const QString key = toIdentityKey(line, baseDir, &isExtended);
        if (isExtended) {   // TTPlayer 扩展写法：精确的一条 CUE 分轨 / 归档里的一个条目
            r.keep(key, filePartExists(key));
            return;
        }
        // 普通路径：目录→展开、m3u→递归、可播文件→留路径、不在盘上→按可播形态留成失效、否则算读不懂
        const QFileInfo fi(key);
        if (fi.isDir()) {
            const QString canonical = fi.canonicalFilePath();
            if (visited.contains(canonical)) return;
            visited.insert(canonical);
            QDir directory(key);
            const auto files = directory.entryInfoList(QDir::Files | QDir::Dirs | QDir::NoDotAndDotDot | QDir::NoSymLinks, QDir::Name);
            for (const QFileInfo &entry : files) absorbLine(entry.absoluteFilePath(), key, r);
            return;
        }
        const QString suffix = fi.suffix().toLower();
        if (suffix == QLatin1String("m3u") || suffix == QLatin1String("m3u8")) {
            if (fi.exists()) absorbPlaylist(key, r);
            else r.fail();
            return;
        }
        if (suffix == "cue" && fi.exists()) {
            for (const Track &track : CueSheet::toTracks(CueSheet::parseFile(key))) {
                r.keep(track.identityKey(), QFileInfo::exists(track.url().toLocalFile()));
                r.coveredImages.insert(track.url().toLocalFile());
            }
            return;
        }
        if (Archive::looksLikeArchive(key) && fi.exists()) {
            for (const QString &entry : Archive::listAudioEntries(key)) r.keep(Archive::entryUrl(key,entry).toString(),true);
            return;
        }
        if (fi.exists()) {
            if (exts.contains(suffix)) r.keep(key, true);
            else r.fail();   // 不可播的后缀（备注/封面/别的支持不了的）留下只是假条目
        } else {
            if (exts.contains(suffix)) r.keep(key, false);   // 声明为可播但文件不在盘上：留成失效
            else r.fail();
        }
    }
};

} // namespace

bool importFile(const QString &path, Imported &out) {
    if (!QFileInfo::exists(path)) return false;
    importPaths({path}, out);
    return true;
}

void importPaths(const QStringList &paths, Imported &out, const std::atomic<bool> *cancel) {
    Reader reader;reader.cancel=cancel;
    for (const QString &path : paths) reader.absorbLine(path,QDir::currentPath(),out);
    for (const QString &image : out.coveredImages) out.keys.removeAll(image);
}

} // namespace PlaylistM3U
