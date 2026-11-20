#include "MediaSession.h"
#include "core/PlayerController.h"
#include "ui/MainWindow.h"
#include "models/CoverArt.h"
#include <QBuffer>
#include <QApplication>
#include <QPointer>
#import <AppKit/AppKit.h>
#import <MediaPlayer/MPNowPlayingInfoCenter.h>
#import <MediaPlayer/MPRemoteCommandCenter.h>
#import <MediaPlayer/MPRemoteCommand.h>
#import <MediaPlayer/MPRemoteCommandEvent.h>
#import <MediaPlayer/MPMediaItem.h>

class MacMediaSession final : public QObject {
    PlayerController *controller;
    NSMutableArray *commands = [NSMutableArray array];
    NSMutableArray *tokens = [NSMutableArray array];
public:
    explicit MacMediaSession(PlayerController *ctl):controller(ctl) {
        MPRemoteCommandCenter *center=MPRemoteCommandCenter.sharedCommandCenter;
        QPointer<MacMediaSession> guard(this);
        auto add=[&](MPRemoteCommand *command, std::function<void()> action) {
            command.enabled=YES;
            id token=[command addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *) {
                QMetaObject::invokeMethod(qApp,[guard,action]{if(guard)action();},Qt::QueuedConnection);
                return MPRemoteCommandHandlerStatusSuccess;
            }];
            [commands addObject:command];[tokens addObject:token];
        };
        add(center.togglePlayPauseCommand,[ctl]{ctl->togglePlay();});
        add(center.playCommand,[ctl]{if(!ctl->isPlaying())ctl->togglePlay();});
        add(center.pauseCommand,[ctl]{if(ctl->isPlaying())ctl->togglePlay();});
        add(center.stopCommand,[ctl]{ctl->stop();});add(center.nextTrackCommand,[ctl]{ctl->next();});
        add(center.previousTrackCommand,[ctl]{ctl->prev();});
        id positionToken=[center.changePlaybackPositionCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
            const double seconds=((MPChangePlaybackPositionCommandEvent *)event).positionTime;
            QMetaObject::invokeMethod(qApp,[guard,ctl,seconds]{if(guard)ctl->seekTo(seconds);},Qt::QueuedConnection);
            return MPRemoteCommandHandlerStatusSuccess;
        }];
        [commands addObject:center.changePlaybackPositionCommand];[tokens addObject:positionToken];
        connect(ctl,&PlayerController::trackChanged,this,[this]{update(true);});
        connect(ctl,&PlayerController::playbackStateChanged,this,[this]{update(false);});
        connect(ctl,&PlayerController::positionTicked,this,[this](double,double){update(false);});
        update(true);
    }
    ~MacMediaSession() override {
        for(NSUInteger i=0;i<commands.count;++i)[(MPRemoteCommand *)commands[i] removeTarget:tokens[i]];
        MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo=nil;
    }
    void update(bool metadata) {
        const Track track=controller->currentTrack();
        if(track.isNull()){MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo=nil;return;}
        NSMutableDictionary *info=[MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo mutableCopy];
        if(!info)info=[NSMutableDictionary dictionary];
        if(metadata) {
            info[MPMediaItemPropertyTitle]=track.title().toNSString();
            info[MPMediaItemPropertyArtist]=track.artist().toNSString();
            info[MPMediaItemPropertyAlbumTitle]=track.album().toNSString();
            const QImage art=CoverArt::imageForTrack(track,256);
            if(!art.isNull()) {
                QByteArray bytes;QBuffer buffer(&bytes);buffer.open(QIODevice::WriteOnly);art.save(&buffer,"PNG");
                NSImage *image=[[NSImage alloc] initWithData:[NSData dataWithBytes:bytes.constData() length:bytes.size()]];
                if(image)info[MPMediaItemPropertyArtwork]=[[MPMediaItemArtwork alloc] initWithBoundsSize:image.size requestHandler:^NSImage *(CGSize){return image;}];
            }else[info removeObjectForKey:MPMediaItemPropertyArtwork];
        }
        info[MPMediaItemPropertyPlaybackDuration]=@(controller->duration());
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime]=@(controller->position());
        info[MPNowPlayingInfoPropertyPlaybackRate]=@(controller->isPlaying()?1.0:0.0);
        MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo=info;
        MPNowPlayingInfoCenter.defaultCenter.playbackState=controller->isPlaying()?MPNowPlayingPlaybackStatePlaying:MPNowPlayingPlaybackStatePaused;
    }
};
std::unique_ptr<QObject> createMediaSession(PlayerController *controller,MainWindow *) {
    return std::make_unique<MacMediaSession>(controller);
}
