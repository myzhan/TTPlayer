#include <QApplication>
#include <QTemporaryDir>
#include <QFile>
#include <QThread>
#include <iostream>
#include "audio/AudioEngine.h"
#include "core/PlayerController.h"
#include "core/Collections.h"
#include "ui/MainWindow.h"
#include "ui/PlaylistWindow.h"
#include "ui/PlaylistView.h"
#include "models/LibraryStore.h"
#include "models/PlaylistM3U.h"
#include "decoder/Archive.h"

class GateSource : public StreamSource {
public:
 QByteArray data; qint64 pos=0;std::mutex mx;std::condition_variable cv;bool armed=false,blocked=false,go=false;
 int64_t read(uint8_t *b,int n) override {
  {std::unique_lock<std::mutex> l(mx);if(armed&&!go){blocked=true;cv.notify_all();cv.wait(l,[&]{return go;});}}
  n=std::min<int>(n,std::min<qint64>(4096,data.size()-pos));if(n<=0)return 0;memcpy(b,data.constData()+pos,n);pos+=n;return n;
 }
 bool seekable()const override{return true;}
 int64_t seek(int64_t off,int whence)override{
  if(whence==AVSEEK_SIZE)return data.size();whence &= ~AVSEEK_FORCE;
  pos=whence==SEEK_SET?off:whence==SEEK_CUR?pos+off:data.size()+off;return pos;
 }
 void cancel()override{std::lock_guard<std::mutex>l(mx);go=true;cv.notify_all();}
};

int main(int argc, char **argv) {
 QApplication app(argc,argv); app.setApplicationName("TTPlayerReview");
 SDL_Init(SDL_INIT_AUDIO);
 QTemporaryDir tmp; qputenv("TTPLAYER_QT_STATE",(tmp.path()+"/state.json").toUtf8());
 const QString path=QDir::currentPath()+"/testlib/demo01.wav";
 auto e=AudioEngine::create(); e->stopPump();
 if(argc>1 && QString(argv[1])=="seek-race") {
  int bad=0;
  for(int i=0;i<30;++i){
   auto src=std::make_shared<GateSource>();QFile f("/tmp/tt-review2-ramp.wav");f.open(QIODevice::ReadOnly);src->data=f.readAll();
   auto dec=Decoder::openStream(src,"ramp");if(!dec)return 3;dec->seek(0);
   e->m_decoder=std::shared_ptr<Decoder>(std::move(dec));e->m_sampleRate=44100;e->m_readPos=0;e->m_delivered=0;e->m_playing=true;e->m_eos=false;e->m_endFrame=INT64_MAX;e->ringClear();
   src->armed=true;e->startPump();
   {std::unique_lock<std::mutex>l(src->mx);if(!src->cv.wait_for(l,std::chrono::seconds(2),[&]{return src->blocked;}))return 4;}
   e->seekSeconds(20);src->cancel();
   for(int j=0;j<100;++j){QThread::msleep(1);std::lock_guard<std::mutex>l(e->m_mutex);if(e->m_ringCount){bad+=e->m_ringL[e->m_ringHead]<0.3f;break;}}
   e->stopPump();e->stop();
  }
  std::cout<<"seek_old_PCM_accepted="<<bad<<"/30"<<std::endl;return 0;
 }
 if(argc>1 && QString(argv[1])=="reorder") {
  PlayerController c(e);Collections col;
  col.setAllTracks({Track(QUrl::fromLocalFile("/a.wav")),Track(QUrl::fromLocalFile("/b.wav")),Track(QUrl::fromLocalFile("/c.wav"))});
  c.setTracks(col.allTracks());PlaylistWindow w(&c,&col);w.m_view->selectAt(0,Qt::NoModifier);
  w.reorderCurrentView(3);
  std::cout<<"reorder_first="<<col.allTracks().first().url().toString().toStdString()<<std::endl;
  return 0;
 }
 int stale=0, tail=0, cue=0;
 for(int n=0;n<30;++n){
  e->m_decoder=std::shared_ptr<Decoder>(Decoder::openFile(path));
  if(!e->m_decoder){std::cerr<<"missing fixture";return 2;}
  e->m_playing=true;e->m_eos=true;e->m_finishPending=false;e->ringClear();
  int called=0;e->onFinished=[&]{++called;};
  std::vector<float> b(16384,123.0f); e->callback(b.data(),8192);
  bool untouched=true;for(int i=8192;i<16384;++i)untouched &= b[i]==123.0f;
  tail+=untouched;
  e->stop(); QCoreApplication::processEvents(); stale+=called>0;
  e->m_decoder=std::shared_ptr<Decoder>(Decoder::openFile(path));
  e->m_sampleRate=44100;e->m_endFrame=44100;e->m_playStart=0;e->m_eos=true;
  e->seekSeconds(1.0);
  cue+= !e->m_eos && e->m_readPos>=e->m_endFrame;
 }
 e->onFinished=nullptr;e->stop();
 std::cout<<"stale_EOF_after_stop="<<stale<<"/30\ncallback_unwritten_tail="<<tail<<"/30\ncue_end_seek_unreachable_EOS="<<cue<<"/30\n";
 const QString token=Archive::entryUrl(tmp.path()+"/album.zip","disc/a.flac").toString();
 Track a{QUrl(token)}; const QString list=tmp.path()+"/x.m3u8";
 PlaylistM3U::exportTracks({a},list);PlaylistM3U::Imported imp;PlaylistM3U::importFile(list,imp);
 std::cout<<"archive_original="<<token.toStdString()<<"\narchive_roundtrip="<<imp.keys.value(0).toStdString()<<"\n";
 auto t=Collections::resolveToken("C:/Music/song.flac");
 std::cout<<"windows_token_local="<<t.url().isLocalFile()<<" scheme="<<t.url().scheme().toStdString()<<"\n";
 LibraryStore::Loaded s;s.trackPaths={QUrl::fromLocalFile(path).toString()};s.resumeValid=true;s.resumeCursor=0;s.resumeQueue={{path,0}};s.resumePosition=1;
 LibraryStore::save(s);
 {PlayerController c(e);MainWindow w(&c,e);w.restoreLibrary();
  std::cout<<"catalog_RG_loaded="<<w.collections().allTracks().first().replayGainTags().has_value()<<" resume_RG_loaded="<<c.currentTrack().replayGainTags().has_value()<<"\n";
  c.stop();}
 e.reset(); SDL_Quit();
}
