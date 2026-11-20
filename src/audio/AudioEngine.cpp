#include "AudioEngine.h"

#include <QCoreApplication>
#include <QMetaObject>

#include <algorithm>
#include <cstring>
#include <cmath>
#if defined(__APPLE__)
#include <CoreAudio/CoreAudio.h>
#endif


AudioEngine::AudioEngine() {
    m_ringL.assign(kRingCap, 0.0f);
    m_ringR.assign(kRingCap, 0.0f);
    m_cbL.assign(4096, 0.0f);
    m_cbR.assign(4096, 0.0f);
}

std::shared_ptr<AudioEngine> AudioEngine::create() {
    // Each device callback retains only its owner pointer; close waits for callbacks before destruction.
    auto e = std::shared_ptr<AudioEngine>(new AudioEngine());
    // 自检静音门控：只在测试环境变量置位时锁静设备输出，生产路径不变
    e->m_silentOutput = qEnvironmentVariableIsSet("TTPLAYER_SILENT_OUTPUT");
    e->startPump();
    return e;
}

AudioEngine::~AudioEngine() {
    m_abortCb = true;   // 在途回调不拿锁直接出静音，关设备不会等锁
    stopPump();         // 先 cancel 当前 IO（唤醒卡住的 read）再 join，不会吊死析构
    closeDevice();
    std::lock_guard<std::mutex> lk(m_mutex);
    m_decoder.reset();
}

void AudioEngine::startPump() {
    m_run = true;
    m_pump = std::thread([this] { pumpLoop(); });
}

void AudioEngine::stopPump() {
    m_run = false;
    // 若 producer 正卡在旧曲的阻塞 IO 上，先无锁唤醒它，join 才不会无限等
    std::shared_ptr<Decoder> cur;
    {
        std::lock_guard<std::mutex> lk(m_mutex);
        cur = m_decoder;
    }
    if (cur) cur->requestCancel();
    m_cv.notify_all();
    if (m_pump.joinable()) m_pump.join();
}

// —— 有界环（都在 m_mutex 下调用；O(1)，绝不跨 IO）——
void AudioEngine::ringClear() { m_ringHead = 0; m_ringCount = 0; }

void AudioEngine::ringPush(const float *l, const float *r, int n) {
    const int capacity = int(m_ringL.size());
    const int tail = (m_ringHead + m_ringCount) % capacity;
    const int first = std::min(n, capacity - tail);
    std::copy_n(l, first, m_ringL.data() + tail);
    std::copy_n(r, first, m_ringR.data() + tail);
    std::copy_n(l + first, n - first, m_ringL.data());
    std::copy_n(r + first, n - first, m_ringR.data());
    m_ringCount += n;
}

void AudioEngine::resetPlaybackBuffer() {
    ringClear();
    const int capacity = m_liveRadio ? int(m_sampleRate * kRadioCapacitySeconds) : kRingCap;
    m_ringL.resize(capacity);
    m_ringR.resize(capacity);
    m_starved = false;
    m_radioBufferState = m_liveRadio ? RadioBufferState::Priming : RadioBufferState::Playing;
}

int AudioEngine::ringPop(float *l, float *r, int n) {
    if(m_ringCount>=int(m_sampleRate*0.2))m_starved=false;
    const int capacity = int(m_ringL.size());
    const int take = std::min(n, m_ringCount);
    const int first = std::min(take, capacity - m_ringHead);
    std::copy_n(m_ringL.data() + m_ringHead, first, l);
    std::copy_n(m_ringR.data() + m_ringHead, first, r);
    std::copy_n(m_ringL.data(), take - first, l + first);
    std::copy_n(m_ringR.data(), take - first, r + first);
    m_ringHead = (m_ringHead + take) % capacity;
    m_ringCount -= take;
    return take;
}

// —— producer 线程：唯一碰解码器 IO 的地方，块间持锁只做 push（不跨 read 持锁）——
void AudioEngine::pumpLoop() {
    std::vector<float> bl(kPumpChunk), br(kPumpChunk);
    std::unique_lock<std::mutex> lk(m_mutex);
    while (m_run) {
        m_cv.wait(lk, [&] {
            return !m_run || m_retired || m_retiredNext || (m_playing && m_next && !m_next->ready)
                         || (m_playing && m_decoder && !m_eos && m_readPos < m_endFrame
                              && ringFree() >= kPumpChunk);
        });
        if (!m_run) break;
        if (m_retired || m_retiredNext) {
            auto retired = std::move(m_retired); auto pending = std::move(m_retiredNext);
            lk.unlock();retired.reset();pending.reset();lk.lock();continue;
        }
        if (m_playing && m_next && !m_next->ready) {
            auto next = m_next;
            const int64_t start = int64_t(next->start * m_sampleRate);
            const int wanted = next->end >= 0 ? int(std::min<int64_t>(4096,
                                 std::max<int64_t>(0, int64_t(next->end*m_sampleRate)-start))) : 4096;
            lk.unlock();
            const int count = next->decoder->read(next->l.data(), next->r.data(), wanted, start);
            lk.lock();
            if (m_next == next) { next->count = count;next->ready = true; }
            continue;
        }
        if (!(m_playing && m_decoder && !m_eos && m_readPos < m_endFrame)) continue;

        // 快照需要的量后放开锁去做阻塞解码——这是 R08 的核心：read 期间不持 m_mutex
        std::shared_ptr<Decoder> dec = m_decoder;
        const double rate=m_sampleRate;
        const int64_t from = m_readPos;
        const uint64_t generation = m_gen.load();
        const int avail = int(std::min<int64_t>(kPumpChunk, m_endFrame - from));
        lk.unlock();
        const bool configured=std::abs(dec->sampleRate()-rate)<0.5||dec->resampleTo(int(rate));
        const int got = configured && avail > 0 ? dec->read(bl.data(), br.data(), avail, from) : 0;
        lk.lock();

        // 解码期间被换曲/停止 → 丢弃这批在途样本，别污染新曲
        if (m_decoder != dec || !m_run || generation != m_gen.load() || from != m_readPos) continue;
        if (got <= 0) { m_eos = true; continue; }   // 真 EOF（取消也会走到这，但上面已先 continue）
        ringPush(bl.data(), br.data(), got);
        m_readPos += got;
        if (m_readPos >= m_endFrame) m_eos = true;   // CUE 区间尾：解码到此为止（无区间尾时 endFrame=INT64_MAX）
    }
}

void AudioEngine::pauseDevice(bool paused) {
#ifdef __APPLE__
    if(m_nativeOutput) {
        const OSStatus status=paused?AudioOutputUnitStop(static_cast<AudioUnit>(m_nativeOutput)):AudioOutputUnitStart(static_cast<AudioUnit>(m_nativeOutput));
        if(status!=noErr){std::lock_guard<std::mutex> lock(m_mutex);m_playing=false;m_outputProblem=QStringLiteral("输出设备启动失败（%1）").arg(status);}
        return;
    }
#endif
    SDL_PauseAudioDevice(m_deviceId,paused?1:0);
}

bool AudioEngine::openNativeDevice(double sampleRate) {
#ifdef __APPLE__
    AudioDeviceID selected=0;
    AudioObjectPropertyAddress defaults{kAudioHardwarePropertyDefaultOutputDevice,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};
    UInt32 size=sizeof(selected);
    if(AudioObjectGetPropertyData(kAudioObjectSystemObject,&defaults,0,nullptr,&size,&selected)!=noErr)return false;
    const AudioDeviceID defaultDevice=selected;
    m_defaultOutput=QString::number(defaultDevice);m_outputProblem.clear();
    const QString wanted=QString::fromUtf8(m_outputDevice);
    AudioObjectPropertyAddress devices{kAudioHardwarePropertyDevices,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};
    size=0;AudioObjectGetPropertyDataSize(kAudioObjectSystemObject,&devices,0,nullptr,&size);
    std::vector<AudioDeviceID> ids(size/sizeof(AudioDeviceID));
    if(size)AudioObjectGetPropertyData(kAudioObjectSystemObject,&devices,0,nullptr,&size,ids.data());
    auto text=[](AudioDeviceID device,AudioObjectPropertySelector selector) {
        AudioObjectPropertyAddress property{selector,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};
        CFStringRef value=nullptr;UInt32 length=sizeof(value);
        if(AudioObjectGetPropertyData(device,&property,0,nullptr,&length,&value)!=noErr||!value)return QString();
        const QString result=QString::fromCFString(value);CFRelease(value);return result;
    };
    if(!wanted.isEmpty()) {
        selected=0;
        for(AudioDeviceID id:ids)if(text(id,kAudioDevicePropertyDeviceUID)==wanted){selected=id;break;}
        if(!selected){selected=defaultDevice;m_outputProblem=QStringLiteral("所选设备不可用，已回退系统默认");}
    }
    auto open=[&](AudioDeviceID device)->bool {
        AudioComponentDescription description{};description.componentType=kAudioUnitType_Output;
        description.componentSubType=kAudioUnitSubType_HALOutput;description.componentManufacturer=kAudioUnitManufacturer_Apple;
        const AudioComponent component=AudioComponentFindNext(nullptr,&description);AudioUnit unit=nullptr;
        if(!component||AudioComponentInstanceNew(component,&unit)!=noErr)return false;
        auto fail=[&]{AudioComponentInstanceDispose(unit);return false;};
        if(AudioUnitSetProperty(unit,kAudioOutputUnitProperty_CurrentDevice,kAudioUnitScope_Global,0,&device,sizeof(device))!=noErr)return fail();
        Float64 rate=sampleRate;
        AudioObjectPropertyAddress nominal{kAudioDevicePropertyNominalSampleRate,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};
        UInt32 length=sizeof(rate);
        if(AudioObjectGetPropertyData(device,&nominal,0,nullptr,&length,&rate)!=noErr||rate<=0)rate=sampleRate;
        AudioStreamBasicDescription format{};format.mSampleRate=rate;format.mFormatID=kAudioFormatLinearPCM;
        format.mFormatFlags=kAudioFormatFlagIsFloat|kAudioFormatFlagIsPacked;format.mBytesPerPacket=8;format.mFramesPerPacket=1;
        format.mBytesPerFrame=8;format.mChannelsPerFrame=2;format.mBitsPerChannel=32;
        if(AudioUnitSetProperty(unit,kAudioUnitProperty_StreamFormat,kAudioUnitScope_Input,0,&format,sizeof(format))!=noErr)return fail();
        AURenderCallbackStruct callback{nativeCallback,this};
        if(AudioUnitSetProperty(unit,kAudioUnitProperty_SetRenderCallback,kAudioUnitScope_Input,0,&callback,sizeof(callback))!=noErr)return fail();
        if(AudioUnitInitialize(unit)!=noErr)return fail();
        m_nativeOutput=unit;m_boundDevice=device;m_deviceRate=rate;m_deviceOpen=true;
        m_actualOutput=text(device,kAudioObjectPropertyName);return true;
    };
    if(open(selected))return true;
    if(selected!=defaultDevice&&open(defaultDevice)){m_outputProblem=QStringLiteral("所选设备无法打开，已回退系统默认");return true;}
    m_outputProblem=QStringLiteral("没有可用的音频输出设备");return false;
#else
    (void)sampleRate;return false;
#endif
}

#ifdef __APPLE__
OSStatus AudioEngine::nativeCallback(void *opaque,AudioUnitRenderActionFlags *,const AudioTimeStamp *,UInt32,UInt32 frames,AudioBufferList *buffers) {
    if(!buffers)return noErr;
    for(UInt32 index=0;index<buffers->mNumberBuffers;++index)
        if(buffers->mBuffers[index].mData)memset(buffers->mBuffers[index].mData,0,buffers->mBuffers[index].mDataByteSize);
    if(buffers->mNumberBuffers==1&&buffers->mBuffers[0].mData&&buffers->mBuffers[0].mDataByteSize>=frames*8)
        static_cast<AudioEngine *>(opaque)->callback(static_cast<float *>(buffers->mBuffers[0].mData),int(frames));
    return noErr;
}
#endif

bool AudioEngine::openDevice(double sampleRate) {
    closeDevice();
#ifdef __APPLE__
    if(QString::fromUtf8(SDL_GetCurrentAudioDriver())==QStringLiteral("coreaudio"))
        return openNativeDevice(sampleRate);
#endif
    SDL_AudioSpec want {}, have {};
    want.freq = int(sampleRate);
    want.format = AUDIO_F32SYS;
    want.channels = 2;
    want.samples = 2048;
    want.callback = sdlCallback;
    want.userdata = this; // SDL_CloseAudioDevice waits for callbacks before destruction.
    QByteArray deviceName=m_outputDevice;
    for(const auto &device:outputDeviceDescriptors())if(device.id==QString::fromUtf8(m_outputDevice))deviceName=device.name.toUtf8();
    const char *dev = deviceName.isEmpty() ? nullptr : deviceName.constData();
    m_deviceId = SDL_OpenAudioDevice(dev, 0, &want, &have, SDL_AUDIO_ALLOW_FREQUENCY_CHANGE);
    m_outputProblem.clear();m_actualOutput=QString::fromUtf8(deviceName);
    if (m_deviceId == 0 && dev) {
        m_outputProblem=QStringLiteral("所选设备不可用，已回退系统默认");m_actualOutput.clear();
        m_deviceId = SDL_OpenAudioDevice(nullptr, 0, &want, &have, SDL_AUDIO_ALLOW_FREQUENCY_CHANGE);
    }
    char *defaultName=nullptr;SDL_AudioSpec defaultSpec{};
    if(SDL_GetDefaultAudioInfo(&defaultName,&defaultSpec,0)==0) {
        m_defaultOutput=QString::fromUtf8(defaultName);SDL_free(defaultName);
        if(m_actualOutput.isEmpty())m_actualOutput=m_defaultOutput;
    }
    m_deviceOpen = m_deviceId != 0;
    if (!m_deviceOpen) qWarning("[audio] SDL_OpenAudioDevice failed: %s", SDL_GetError());
    if (m_deviceOpen) m_deviceRate = have.freq > 0 ? have.freq : sampleRate;
    return m_deviceOpen;
}

void AudioEngine::closeDevice() {
    if (m_deviceOpen) {
#ifdef __APPLE__
        if(m_nativeOutput) {
            auto unit=static_cast<AudioUnit>(m_nativeOutput);
            AudioOutputUnitStop(unit);AudioUnitUninitialize(unit);AudioComponentInstanceDispose(unit);
            m_nativeOutput=nullptr;m_boundDevice=0;
        } else
#endif
        SDL_CloseAudioDevice(m_deviceId);
        m_deviceOpen = false;
    }
}

bool AudioEngine::play(std::unique_ptr<Decoder> decoder, double playStart, double playEnd,
                       bool autoPlay, double position, float gain, bool liveRadio) {
    if (!decoder) return false;
    std::shared_ptr<Decoder> dec(std::move(decoder));
    const double sourceRate=dec->sampleRate();
    double rate = sourceRate;
    // 换采样率 = 重开设备。设备开/关不持 m_mutex：先立 m_abortCb 让在途回调直接出静音，
    // SDL 的关/暂停等在途回调才不会与持锁的主线程互等
    if (!m_deviceOpen || (!m_nativeOutput && std::abs(rate - m_sampleRate) >= 1.0)) {
        m_abortCb = true;
        if (!openDevice(rate)) { m_abortCb = false; return false; }
    }
    rate=m_deviceRate; // Producer resamples off the UI thread before its first read.
    std::shared_ptr<Decoder> old;
    {
        std::lock_guard<std::mutex> lk(m_mutex);
        old = m_decoder;                       // 旧曲解码器交给外面 requestCancel（下面），不在此持锁等 IO
        m_decoder = dec;
        m_next.reset();
        m_playStart = playStart;
        m_playEnd = playEnd;
        m_endFrame = playEnd >= 0 ? int64_t(playEnd * rate) : INT64_MAX;
        const double total = double(dec->totalFrames()) / sourceRate;
        const double length = std::max(0.0, (playEnd >= 0 ? playEnd : total) - playStart);
        position = std::isfinite(position) ? std::clamp(position, 0.0, length) : 0;
        m_readPos = int64_t((playStart + position) * rate);
        m_delivered = m_readPos;
        m_eos = m_readPos >= m_endFrame;   // 退化的空区间（起点已在尾）直接当 EOS，否则交给 producer
        m_finishPending = false;
        m_eq.setSampleRate(rate);
        m_spectrum.setSampleRate(rate);
        m_sampleRate = rate;m_totalFrames=int64_t(dec->totalFrames()*rate/sourceRate);
        m_liveRadio = liveRadio;
        resetPlaybackBuffer();
        m_playing = autoPlay;
        m_replayGainLinear = gain;
        ++m_gen;
    }
    if (old) old->requestCancel();             // 唤醒可能卡在旧曲网络读的 producer（producer 自己会丢弃在途）
    m_abortCb = false;
    m_cv.notify_all();
    pauseDevice(!autoPlay);
    return true;
}

void AudioEngine::pause() {
    {
        std::lock_guard<std::mutex> lk(m_mutex);
        m_playing = false;
    }
    if (m_deviceOpen) pauseDevice(true);
    m_cv.notify_all();
}

bool AudioEngine::resume() {
    {
        std::lock_guard<std::mutex> lk(m_mutex);
        m_playing = m_decoder != nullptr && !m_finishPending;
        if (!m_playing) return false;
    }
    pauseDevice(false);
    m_cv.notify_all();
    return true;
}

void AudioEngine::stop() {
    std::shared_ptr<Decoder> old;
    {
        std::lock_guard<std::mutex> lk(m_mutex);
        old = m_decoder;
        m_decoder = nullptr;
        m_next.reset();
        m_playing = false;
        m_eos = false;
        m_finishPending = false;
        m_delivered = 0;
        m_readPos = 0;
        m_playStart = 0;
        m_playEnd = -1;
        m_endFrame = INT64_MAX;
        ringClear();
        ++m_gen;
    }
    if (m_deviceOpen) SDL_PauseAudioDevice(m_deviceId, 1);
    if (old) old->requestCancel();             // 断流时也能秒回：只置位+notify，不 join、不等 IO 完成
    m_cv.notify_all();
}

double AudioEngine::sampleRate() const {
    std::lock_guard<std::mutex> lk(m_mutex);
    return m_sampleRate;
}

bool AudioEngine::isPlaying() const {
    std::lock_guard<std::mutex> lk(m_mutex);
    return m_playing;
}

QStringList AudioEngine::outputDevices() {
    QStringList list;
    const int n = SDL_GetNumAudioDevices(0);   // 0 = 播放（输出）设备
    for (int i = 0; i < n; ++i) {
        const char *name = SDL_GetAudioDeviceName(i, 0);
        if (name) list << QString::fromUtf8(name);
    }
    return list;
}

QList<AudioEngine::OutputDevice> AudioEngine::outputDeviceDescriptors() {
    QList<OutputDevice> result;
#if defined(__APPLE__)
    AudioObjectPropertyAddress address{kAudioHardwarePropertyDevices,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};
    UInt32 size=0;
    if(AudioObjectGetPropertyDataSize(kAudioObjectSystemObject,&address,0,nullptr,&size)==noErr) {
        std::vector<AudioDeviceID> devices(size/sizeof(AudioDeviceID));
        if(AudioObjectGetPropertyData(kAudioObjectSystemObject,&address,0,nullptr,&size,devices.data())==noErr)
            for(AudioDeviceID device:devices) {
                AudioObjectPropertyAddress stream{kAudioDevicePropertyStreams,kAudioDevicePropertyScopeOutput,kAudioObjectPropertyElementMain};UInt32 streamSize=0;
                if(AudioObjectGetPropertyDataSize(device,&stream,0,nullptr,&streamSize)!=noErr||!streamSize)continue;
                auto text=[device](AudioObjectPropertySelector selector){
                    AudioObjectPropertyAddress property{selector,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};CFStringRef value=nullptr;UInt32 n=sizeof(value);
                    if(AudioObjectGetPropertyData(device,&property,0,nullptr,&n,&value)!=noErr||!value)return QString();
                    const QString result=QString::fromCFString(value);CFRelease(value);return result;
                };
                const QString uid=text(kAudioDevicePropertyDeviceUID),name=text(kAudioObjectPropertyName);
                if(!uid.isEmpty()&&!uid.startsWith("CADefaultDeviceAggregate-")&&!name.startsWith("CADefaultDeviceAggregate-"))
                    result.append({uid,name});
            }
    }
#else
    for(const QString &name:outputDevices())result.append({name,name});
#endif
    return result;
}

bool AudioEngine::pollDevices() {
    if(!m_deviceOpen)return false;
    char *name=nullptr;SDL_AudioSpec spec{};
    QString currentDefault;
    if(SDL_GetDefaultAudioInfo(&name,&spec,0)==0){currentDefault=QString::fromUtf8(name);SDL_free(name);}
#ifdef __APPLE__
    if(m_nativeOutput&&m_outputDevice.isEmpty()) {
        AudioObjectPropertyAddress property{kAudioHardwarePropertyDefaultOutputDevice,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};
        AudioDeviceID device=0;UInt32 size=sizeof(device);
        if(AudioObjectGetPropertyData(kAudioObjectSystemObject,&property,0,nullptr,&size,&device)==noErr)
            currentDefault=QString::number(device);
    }
#endif
    bool present=m_outputDevice.isEmpty();
    for(const auto &device:outputDeviceDescriptors())if(device.id==QString::fromUtf8(m_outputDevice)||device.name==QString::fromUtf8(m_outputDevice))present=true;
    const bool reopen=(m_outputDevice.isEmpty()&&currentDefault!=m_defaultOutput)||(!present&&m_outputProblem.isEmpty())||(present&&!m_outputProblem.isEmpty());
    if(!reopen)return false;
    const bool playing=isPlaying();const double rate=sampleRate();
    m_abortCb=true;const bool opened=openDevice(rate);m_abortCb=false;
    if(opened)adoptDeviceRate();
    if(opened)pauseDevice(!playing);else pause();
    return true;
}

QString AudioEngine::outputDevice() const {
    return QString::fromUtf8(m_outputDevice);
}

void AudioEngine::adoptDeviceRate() {
    std::lock_guard<std::mutex> lock(m_mutex);
    if(std::abs(m_sampleRate-m_deviceRate)<0.5)return;
    if(m_next){m_next->decoder->requestCancel();m_retiredNext=std::move(m_next);}
    const double ratio=m_deviceRate/m_sampleRate;
    m_sampleRate=m_deviceRate;m_totalFrames=int64_t(m_totalFrames*ratio);
    m_delivered=int64_t(m_delivered*ratio);m_readPos=m_delivered;
    if(m_endFrame!=INT64_MAX)m_endFrame=int64_t(m_endFrame*ratio);
    m_eq.setSampleRate(m_sampleRate);m_spectrum.setSampleRate(m_sampleRate);
    m_eos=m_readPos>=m_endFrame;m_finishPending=false;++m_gen;resetPlaybackBuffer();m_cv.notify_all();
}

void AudioEngine::setOutputDevice(const QString &uid) {
    const QByteArray next = uid.toUtf8();
    if (next == m_outputDevice) return;
    m_outputDevice = next;
    if (!m_deviceOpen) return;   // 没开着：下一次 play 自会用新选择
    // 已开着：原地重开。不能持 m_mutex 调 SDL（SDL 关设备等在途回调），走同一套 m_abortCb 序列
    double rate;
    bool wasPlaying;
    {
        std::lock_guard<std::mutex> lk(m_mutex);
        rate = m_sampleRate;
        wasPlaying = m_playing;
    }
    m_abortCb = true;
    const bool ok = openDevice(rate);
    m_abortCb = false;
    if(ok)adoptDeviceRate();else pause();
    if (ok) pauseDevice(!wasPlaying);
}

bool AudioEngine::seekSeconds(double sec) {
    std::lock_guard<std::mutex> lk(m_mutex);
    if (!m_decoder || m_sampleRate <= 0) return false;
    if (!std::isfinite(sec)) return false;
    const int64_t last = m_endFrame == INT64_MAX ? (m_totalFrames?m_totalFrames:m_decoder->totalFrames()) : m_endFrame;
    const int64_t target = std::clamp<int64_t>(int64_t((m_playStart + std::max(0.0, sec)) * m_sampleRate),
                                             int64_t(m_playStart * m_sampleRate),
                                             std::max(int64_t(m_playStart * m_sampleRate), last));
    m_readPos = target;
    m_delivered = target;
    m_eos = target >= last;
    ++m_gen;
    m_finishPending = false;
    ringClear();           // 丢掉旧位置已解码但未交付的样本
    m_cv.notify_all();     // 唤醒 producer 从新位置重解（read 内部按需 seek）
    return true;
}

double AudioEngine::positionSeconds() {
    std::lock_guard<std::mutex> lk(m_mutex);
    if (!m_decoder || m_sampleRate <= 0) return 0;
    return double(m_delivered) / m_sampleRate - m_playStart;
}

double AudioEngine::durationSeconds() {
    std::lock_guard<std::mutex> lk(m_mutex);
    if (!m_decoder) return 0;
    const double total = double(m_totalFrames) / m_sampleRate;
    const double end = m_playEnd >= 0 ? m_playEnd : total;
    return std::max(0.0, end - m_playStart);
}

void AudioEngine::setVolume(double v) {
    std::lock_guard<std::mutex> lk(m_mutex);
    m_volume = std::clamp(v, 0.0, 1.0);
}

double AudioEngine::volume() const { std::lock_guard<std::mutex> lk(m_mutex); return m_volume; }
void AudioEngine::setEQEnabled(bool on) { std::lock_guard<std::mutex> lk(m_mutex); m_eq.setEnabled(on); }
void AudioEngine::setEQGains(const std::array<double, Equalizer::kBands> &g) {
    std::lock_guard<std::mutex> lk(m_mutex); m_eq.setGains(g);
}
void AudioEngine::setEQPreamp(double db) {
    std::lock_guard<std::mutex> lk(m_mutex); m_eqPreamp = std::isfinite(db) ? std::clamp(db, -12.0, 12.0) : 0;
}
double AudioEngine::eqPreamp() const { std::lock_guard<std::mutex> lk(m_mutex); return m_eqPreamp; }
std::array<double, Equalizer::kBands> AudioEngine::eqGains() const {
    std::lock_guard<std::mutex> lk(m_mutex); return m_eq.gains();
}
bool AudioEngine::eqEnabled() const { std::lock_guard<std::mutex> lk(m_mutex); return m_eq.enabled(); }

void AudioEngine::setReplayGainLinear(float g) {
    std::lock_guard<std::mutex> lk(m_mutex);
    m_replayGainLinear = g > 0 ? g : 1.0f;
}

void AudioEngine::prepareNext(std::unique_ptr<Decoder> decoder, double start, double end,
                              float gain, const QString &key) {
    if (!decoder) { clearNext();return; }
    auto pending = std::make_shared<Prepared>();
    pending->decoder = std::shared_ptr<Decoder>(std::move(decoder));
    pending->start=start;pending->end=end;pending->gain=gain;pending->key=key;
    {std::lock_guard<std::mutex> lk(m_mutex);
     if (std::abs(pending->decoder->sampleRate()-m_sampleRate)>0.5) return;
     m_next = std::move(pending);}
    m_cv.notify_all();
}

void AudioEngine::clearNext() {
    std::shared_ptr<Prepared> old;
    {std::lock_guard<std::mutex> lk(m_mutex);old=std::move(m_next);}
    if(old)old->decoder->requestCancel();
}

bool AudioEngine::promoteNext() {
    if (!m_eos || m_ringCount || !m_next || !m_next->ready || m_next->count <= 0) return false;
    auto &next = *m_next;
    m_retired = std::move(m_decoder);m_decoder=next.decoder;
    m_playStart=next.start;m_playEnd=next.end;m_totalFrames=next.decoder->totalFrames();
    m_endFrame=next.end>=0?int64_t(next.end*m_sampleRate):INT64_MAX;
    m_delivered=int64_t(next.start*m_sampleRate);m_readPos=m_delivered+next.count;
    m_eos=m_readPos>=m_endFrame;m_finishPending=false;m_replayGainLinear=next.gain;
    ringPush(next.l.data(),next.r.data(),next.count);
    const QString key=next.key;const uint64_t generation=++m_gen;
    m_retiredNext=std::move(m_next);
    std::weak_ptr<AudioEngine> weak=shared_from_this();
    QMetaObject::invokeMethod(qApp,[weak,key,generation]{
        if(auto engine=weak.lock();engine&&engine->m_gen.load()==generation&&engine->onTransition)
            engine->onTransition(key);
    },Qt::QueuedConnection);
    m_cv.notify_all();return true;
}

void AudioEngine::setFadeTarget(double target, double seconds) {
    std::lock_guard<std::mutex> lk(m_mutex);
    m_fadeTarget = std::clamp(target, 0.0, 1.0);
    if (seconds <= 0 || m_fadeCur == m_fadeTarget) {
        m_fadeCur = m_fadeTarget;
        m_fadeStep = 0.0;
        return;
    }
    m_fadeStep = (m_fadeTarget - m_fadeCur) / (seconds * m_sampleRate);
}

bool AudioEngine::spectrumBands(float *out) {
    std::lock_guard<std::mutex> lk(m_mutex);
    return m_spectrum.bands(out);
}

void AudioEngine::sdlCallback(void *userdata, Uint8 *stream, int len) {
    auto *e = static_cast<AudioEngine *>(userdata);
    if (!e) { memset(stream, 0, size_t(len)); return; }
    e->callback(reinterpret_cast<float *>(stream), len / int(sizeof(float) * 2));
}

/// 回调（SDL 线程）：纯 CPU——从环取样本 → EQ → fade/volume/gain → 交织。环空即出静音，
/// 不碰解码器、不等 IO。一次请求可能大于暂存容量，按片处理。
void AudioEngine::callback(float *outInterleaved, int frames) {
    memset(outInterleaved, 0, size_t(frames) * 2 * sizeof(float));
    if (m_abortCb) { memset(outInterleaved, 0, size_t(frames) * 2 * sizeof(float)); return; }
    std::unique_lock<std::mutex> lk(m_mutex);
    if (!m_playing) return;
    if (m_radioBufferState != RadioBufferState::Playing) {
        // A live sender often supplies exactly one second of audio per second.
        // Leave the PCM untouched until we have a reserve, or drain a finite tail at EOF.
        if (!m_eos && m_ringCount < int(m_sampleRate * kRadioPrerollSeconds)) {
            m_peakL.store(0, std::memory_order_relaxed);
            m_peakR.store(0, std::memory_order_relaxed);
            return;
        }
        m_radioBufferState = RadioBufferState::Playing;
    }
    const float preamp = m_eq.enabled() ? float(std::pow(10.0, m_eqPreamp / 20.0)) : 1.0f;
    float pkL = 0.0f, pkR = 0.0f;   // 本窗交付样本峰值（电平表用）
    int done = 0;
    while (done < frames) {
        if (!m_ringCount) promoteNext();
        const int slice = std::min(frames - done, int(m_cbL.size()));
        const int have = ringPop(m_cbL.data(), m_cbR.data(), slice);

        if (have > 0) {
            m_eq.process(m_cbL.data(), m_cbR.data(), have);
            for (int i = 0; i < have; ++i) {
                if (m_fadeStep != 0.0) {
                    m_fadeCur += m_fadeStep;
                    if ((m_fadeStep > 0 && m_fadeCur >= m_fadeTarget) ||
                        (m_fadeStep < 0 && m_fadeCur <= m_fadeTarget)) {
                        m_fadeCur = m_fadeTarget;
                        m_fadeStep = 0.0;
                    }
                }
                const float g = float(m_fadeCur * m_volume) * m_replayGainLinear * preamp;
                const float sl = m_cbL[i] * g, sr = m_cbR[i] * g;
                outInterleaved[(done + i) * 2] = sl;
                outInterleaved[(done + i) * 2 + 1] = sr;
                const float al = sl < 0.0f ? -sl : sl, ar = sr < 0.0f ? -sr : sr;
                if (al > pkL) pkL = al;
                if (ar > pkR) pkR = ar;
            }
            m_delivered += have;
            m_spectrum.feed(m_cbL.data(), m_cbR.data(), have);
        }
        // 不足一片（含 have==0）：余量填静音，位置不前进（暂停/断流/未起播都走这里）
        if (have < slice) {
            if (m_liveRadio && !m_eos) m_radioBufferState = RadioBufferState::Refilling;
            if(!m_eos&&!m_starved){++m_underruns;m_starved=true;}
            if (promoteNext()) { done += have;continue; }
            for (int i = have; i < slice; ++i) {
                outInterleaved[(done + i) * 2] = 0.0f;
                outInterleaved[(done + i) * 2 + 1] = 0.0f;
            }
            // 环空且 producer 已到 EOF：自然播完，主线程推进下一曲（代际在 play 时已对齐）
            if (have == 0 && m_eos && m_playing && m_decoder && !m_finishPending) {
                m_finishPending = true;
                std::weak_ptr<AudioEngine> weak = shared_from_this();
                const uint64_t generation = m_gen.load();
                QMetaObject::invokeMethod(qApp, [weak, generation] {
                    if (auto e = weak.lock(); e && e->m_gen.load() == generation && e->onFinished)
                        e->onFinished();
                }, Qt::QueuedConnection);
            }
        }
        done += slice;
        m_cv.notify_all();   // 腾出环空间，唤醒可能卡在等空间的 producer
        if (have < slice) break;   // 已静音补齐本请求，不必再转
    }
    // 电平表：本窗峰值写回原子（无锁供 UI 读）；静音窗自然归 0，显示端做峰保持/衰减
    m_peakL.store(pkL, std::memory_order_relaxed);
    m_peakR.store(pkR, std::memory_order_relaxed);
    // 自检静音：链上（position/EQ/spectrum）已用真实 PCM 跑完，这里把送设备缓冲整体归零
    const size_t copied=std::min(size_t(frames)*2,m_testCapture.size()-m_testCaptured);
    if(copied){std::copy_n(outInterleaved,copied,m_testCapture.data()+m_testCaptured);m_testCaptured+=copied;}
    if (m_silentOutput)
        memset(outInterleaved, 0, size_t(frames) * 2 * sizeof(float));
}
