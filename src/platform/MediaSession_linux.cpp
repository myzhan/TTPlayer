#include "MediaSession.h"
#include "core/PlayerController.h"
#include "ui/MainWindow.h"
#include <QApplication>
#include <QTemporaryDir>
#include "models/CoverArt.h"
#include <QDBusAbstractAdaptor>
#include <QDBusConnection>
#include <QDBusMessage>
#include <QDBusObjectPath>

class MprisRoot final : public QDBusAbstractAdaptor {
    Q_OBJECT
    Q_CLASSINFO("D-Bus Interface", "org.mpris.MediaPlayer2")
    Q_PROPERTY(bool CanQuit READ canQuit CONSTANT)
    Q_PROPERTY(bool CanRaise READ canRaise CONSTANT)
    Q_PROPERTY(bool HasTrackList READ hasTrackList CONSTANT)
    Q_PROPERTY(QString Identity READ identity CONSTANT)
    Q_PROPERTY(QStringList SupportedUriSchemes READ schemes CONSTANT)
    Q_PROPERTY(QStringList SupportedMimeTypes READ mimeTypes CONSTANT)
    MainWindow *window;

public:
    MprisRoot(QObject *owner, MainWindow *w) : QDBusAbstractAdaptor(owner), window(w) {}
    bool canQuit() const { return true; }
    bool canRaise() const { return true; }
    bool hasTrackList() const { return false; }
    QString identity() const { return QStringLiteral("TTPlayer"); }
    QStringList schemes() const { return {"file", "http", "https"}; }
    QStringList mimeTypes() const { return {"audio/flac", "audio/mpeg", "audio/ogg", "audio/wav"}; }
public slots:
    void Quit() { qApp->quit(); }
    void Raise() {
        window->restoreGroupFromBackground();
        window->showNormal();
        window->raise();
        window->activateWindow();
    }
};
class MprisPlayer final : public QDBusAbstractAdaptor {
    Q_OBJECT
    Q_CLASSINFO("D-Bus Interface", "org.mpris.MediaPlayer2.Player")
    Q_PROPERTY(QString PlaybackStatus READ status)
    Q_PROPERTY(QString LoopStatus READ loop WRITE setLoop)
    Q_PROPERTY(bool Shuffle READ shuffle WRITE setShuffle)
    Q_PROPERTY(double Rate READ rate)
    Q_PROPERTY(double MinimumRate READ rate CONSTANT)
    Q_PROPERTY(double MaximumRate READ rate CONSTANT)
    Q_PROPERTY(double Volume READ volume WRITE setVolume)
    Q_PROPERTY(qlonglong Position READ position)
    Q_PROPERTY(QVariantMap Metadata READ metadata)
    Q_PROPERTY(bool CanControl READ canControl CONSTANT)
    Q_PROPERTY(bool CanGoNext READ canControl CONSTANT)
    Q_PROPERTY(bool CanGoPrevious READ canControl CONSTANT)
    Q_PROPERTY(bool CanPlay READ canControl CONSTANT)
    Q_PROPERTY(bool CanPause READ canControl CONSTANT)
    Q_PROPERTY(bool CanSeek READ canSeek)
    PlayerController *ctl;
    MainWindow *window;
    QTemporaryDir artwork;
    QString artworkUrl;

public:
    MprisPlayer(QObject *owner, PlayerController *c, MainWindow *w) : QDBusAbstractAdaptor(owner), ctl(c), window(w) {
        auto changed = [this] {
            auto message = QDBusMessage::createSignal("/org/mpris/MediaPlayer2", "org.freedesktop.DBus.Properties",
                                                      "PropertiesChanged");
            message << QStringLiteral("org.mpris.MediaPlayer2.Player")
                    << QVariantMap{{"PlaybackStatus", status()},
                                   {"Metadata", metadata()},
                                   {"Volume", volume()},
                                   {"LoopStatus", loop()},
                                   {"Shuffle", shuffle()}}
                    << QStringList{};
            QDBusConnection::sessionBus().send(message);
        };
        connect(ctl, &PlayerController::trackChanged, this, [this, changed] {
            const QImage cover = CoverArt::imageForTrack(ctl->currentTrack(), 256);
            artworkUrl.clear();
            if (!cover.isNull() && artwork.isValid()) {
                const QString path = artwork.path() + QStringLiteral("/cover.png");
                if (cover.save(path)) artworkUrl = QUrl::fromLocalFile(path).toString();
            }
            changed();
        });
        connect(ctl, &PlayerController::playbackStateChanged, this, changed);
        connect(ctl, &PlayerController::modeChanged, this, changed);
    }
    QString status() const {
        return ctl->isPlaying() ? "Playing" : ctl->currentTrack().isNull() ? "Stopped" : "Paused";
    }
    QString loop() const {
        return ctl->mode() == PlayMode::SingleLoop ? "Track" : ctl->mode() == PlayMode::ListLoop ? "Playlist" : "None";
    }
    void setLoop(const QString &v) {
        ctl->setMode(v == "Track" ? PlayMode::SingleLoop : v == "Playlist" ? PlayMode::ListLoop : PlayMode::Order);
    }
    bool shuffle() const { return ctl->mode() == PlayMode::Random; }
    void setShuffle(bool on) { ctl->setMode(on ? PlayMode::Random : PlayMode::Order); }
    double rate() const { return 1; }
    bool canControl() const { return true; }
    bool canSeek() const {
        return !ctl->currentTrack().isNull() && !ctl->currentTrack().isRadio() && ctl->duration() > 0;
    }
    double volume() const { return window->userVolume(); }
    void setVolume(double v) { window->setUserVolume(v); }
    qlonglong position() const { return qlonglong(ctl->position() * 1000000); }
    QDBusObjectPath trackPath() const {
        const auto t = ctl->currentTrack();
        return QDBusObjectPath(t.isNull() ? "/org/mpris/MediaPlayer2/TrackList/NoTrack"
                                          : "/org/mpris/MediaPlayer2/track/t" + t.id().toString(QUuid::Id128));
    }
    QVariantMap metadata() const {
        const Track t = ctl->currentTrack();
        if (t.isNull()) return {};
        QVariantMap result{{"mpris:trackid", QVariant::fromValue(trackPath())},
                           {"mpris:length", qlonglong(ctl->duration() * 1000000)},
                           {"xesam:title", t.title()},
                           {"xesam:artist", QStringList{t.artist()}},
                           {"xesam:album", t.album()},
                           {"xesam:url", t.url().toString()}};
        if (!artworkUrl.isEmpty()) result.insert("mpris:artUrl", artworkUrl);
        return result;
    }
public slots:
    void PlayPause() { ctl->togglePlay(); }
    void Play() {
        if (!ctl->isPlaying()) ctl->togglePlay();
    }
    void Pause() {
        if (ctl->isPlaying()) ctl->togglePlay();
    }
    void Stop() { ctl->stop(); }
    void Next() { ctl->next(); }
    void Previous() { ctl->prev(); }
    void Seek(qlonglong offset) {
        if (canSeek()) {
            ctl->seekTo(ctl->position() + offset / 1000000.0);
            emit Seeked(position());
        }
    }
    void SetPosition(const QDBusObjectPath &id, qlonglong value) {
        if (canSeek() && id.path() == trackPath().path()) {
            ctl->seekTo(value / 1000000.0);
            emit Seeked(position());
        }
    }
    void OpenUri(const QString &uri) { window->loadPaths({uri}); }
signals:
    void Seeked(qlonglong position);
};
class LinuxMediaSession final : public QObject {
    QString service;

public:
    LinuxMediaSession(PlayerController *ctl, MainWindow *window) {
        new MprisRoot(this, window);
        new MprisPlayer(this, ctl, window);
        service = QStringLiteral("org.mpris.MediaPlayer2.TTPlayer.instance%1").arg(QCoreApplication::applicationPid());
        QDBusConnection::sessionBus().registerService(service);
        QDBusConnection::sessionBus().registerObject("/org/mpris/MediaPlayer2", this, QDBusConnection::ExportAdaptors);
    }
    ~LinuxMediaSession() override {
        QDBusConnection::sessionBus().unregisterObject("/org/mpris/MediaPlayer2");
        QDBusConnection::sessionBus().unregisterService(service);
    }
};
std::unique_ptr<QObject> createMediaSession(PlayerController *controller, MainWindow *window) {
    return std::make_unique<LinuxMediaSession>(controller, window);
}
#include "MediaSession_linux.moc"
