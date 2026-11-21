#include "MediaSession.h"
#include "playback/PlayerController.h"
#include "ui/MainWindow.h"
#include <windows.h>
#include <QApplication>
#include <QTemporaryDir>
#include <QPointer>
#include "media/CoverArt.h"
#include <winrt/Windows.Storage.h>
#include <winrt/Windows.Storage.Streams.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Media.h>
#include <systemmediatransportcontrolsinterop.h>

using namespace winrt::Windows::Media;
class WindowsMediaSession final : public QObject {
    PlayerController *ctl;
    QTemporaryDir artwork;
    uint64_t artworkGeneration = 0;
    SystemMediaTransportControls controls{nullptr};
    winrt::event_token buttonToken{}, positionToken{};

public:
    WindowsMediaSession(PlayerController *c, MainWindow *window) : ctl(c) {
        auto factory =
            winrt::get_activation_factory<SystemMediaTransportControls, ISystemMediaTransportControlsInterop>();
        winrt::check_hresult(factory->GetForWindow(reinterpret_cast<HWND>(window->winId()),
                                                   winrt::guid_of<SystemMediaTransportControls>(),
                                                   winrt::put_abi(controls)));
        controls.IsEnabled(true);
        controls.IsPlayEnabled(true);
        controls.IsPauseEnabled(true);
        controls.IsStopEnabled(true);
        controls.IsNextEnabled(true);
        controls.IsPreviousEnabled(true);
        QPointer<WindowsMediaSession> guard(this);
        buttonToken = controls.ButtonPressed([guard](auto const &, auto const &args) {
            const auto button = args.Button();
            QMetaObject::invokeMethod(
                qApp,
                [guard, button] {
                    if (!guard) return;
                    auto *ctl = guard->ctl;
                    if (button == SystemMediaTransportControlsButton::Play && !ctl->isPlaying())
                        ctl->togglePlay();
                    else if (button == SystemMediaTransportControlsButton::Pause && ctl->isPlaying())
                        ctl->togglePlay();
                    else if (button == SystemMediaTransportControlsButton::Stop)
                        ctl->stop();
                    else if (button == SystemMediaTransportControlsButton::Next)
                        ctl->next();
                    else if (button == SystemMediaTransportControlsButton::Previous)
                        ctl->prev();
                },
                Qt::QueuedConnection);
        });
        positionToken = controls.PlaybackPositionChangeRequested([guard](auto const &, auto const &args) {
            const double seconds = args.RequestedPlaybackPosition().count() / 10000000.0;
            QMetaObject::invokeMethod(
                qApp,
                [guard, seconds] {
                    if (guard) guard->ctl->seekTo(seconds);
                },
                Qt::QueuedConnection);
        });
        connect(ctl, &PlayerController::trackChanged, this, [this] { update(true); });
        connect(ctl, &PlayerController::playbackStateChanged, this, [this] { update(false); });
        connect(ctl, &PlayerController::positionTicked, this, [this](double, double) { update(false); });
        update(true);
    }
    ~WindowsMediaSession() override {
        if (controls) {
            controls.ButtonPressed(buttonToken);
            controls.PlaybackPositionChangeRequested(positionToken);
            controls.IsEnabled(false);
        }
    }
    void update(bool metadata) {
        const Track track = ctl->currentTrack();
        if (!controls) return;
        if (metadata && !track.isNull()) {
            auto display = controls.DisplayUpdater();
            display.Type(MediaPlaybackType::Music);
            display.MusicProperties().Title(winrt::hstring(track.title().toStdWString()));
            display.MusicProperties().Artist(winrt::hstring(track.artist().toStdWString()));
            display.MusicProperties().AlbumTitle(winrt::hstring(track.album().toStdWString()));
            display.Update();
            const uint64_t generation = ++artworkGeneration;
            const QImage cover = CoverArt::imageForTrack(track, 256);
            if (cover.isNull()) {
                display.Thumbnail(nullptr);
                display.Update();
            } else if (artwork.isValid()) {
                const QString path = artwork.path() + QStringLiteral("/cover.png");
                if (cover.save(path)) {
                    QPointer<WindowsMediaSession> guard(this);
                    auto operation =
                        winrt::Windows::Storage::StorageFile::GetFileFromPathAsync(winrt::hstring(path.toStdWString()));
                    operation.Completed([guard, generation](auto const &op, auto status) {
                        if (status != winrt::Windows::Foundation::AsyncStatus::Completed) return;
                        try {
                            auto file = op.GetResults();
                            QMetaObject::invokeMethod(
                                qApp,
                                [guard, generation, file] {
                                    if (!guard || guard->artworkGeneration != generation) return;
                                    auto updater = guard->controls.DisplayUpdater();
                                    updater.Thumbnail(
                                        winrt::Windows::Storage::Streams::RandomAccessStreamReference::CreateFromFile(
                                            file));
                                    updater.Update();
                                },
                                Qt::QueuedConnection);
                        } catch (const winrt::hresult_error &) {}
                    });
                }
            }
        }
        controls.PlaybackStatus(ctl->isPlaying() ? MediaPlaybackStatus::Playing
                                : track.isNull() ? MediaPlaybackStatus::Stopped
                                                 : MediaPlaybackStatus::Paused);
        SystemMediaTransportControlsTimelineProperties timeline;
        timeline.StartTime(std::chrono::seconds(0));
        timeline.MinSeekTime(std::chrono::seconds(0));
        timeline.EndTime(std::chrono::milliseconds(qint64(ctl->duration() * 1000)));
        timeline.MaxSeekTime(timeline.EndTime());
        timeline.Position(std::chrono::milliseconds(qint64(ctl->position() * 1000)));
        controls.UpdateTimelineProperties(timeline);
    }
};
std::unique_ptr<QObject> createMediaSession(PlayerController *controller, MainWindow *window) {
    try {
        return std::make_unique<WindowsMediaSession>(controller, window);
    } catch (const winrt::hresult_error &error) {
        qWarning("SMTC unavailable: 0x%lx", static_cast<unsigned long>(error.code().value));
        return {};
    }
}
