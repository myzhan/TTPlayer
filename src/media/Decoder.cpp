#include "Decoder.h"
#include "FFmpeg.h"
extern "C" {
#include <libswresample/swresample.h>
}

#include <algorithm>
#include <cstring>

std::unique_ptr<Decoder> Decoder::openFile(const QString &path, std::shared_ptr<std::atomic<bool>> cancel) {
    std::unique_ptr<Decoder> d(new Decoder());
    d->m_externalCancel = std::move(cancel);
    if (!d->init(path)) d.reset();
    return d;
}

std::unique_ptr<Decoder> Decoder::openStream(std::shared_ptr<StreamSource> src, const QString &displayName,
                                             std::shared_ptr<std::atomic<bool>> cancel) {
    std::unique_ptr<Decoder> d(new Decoder());
    d->m_externalCancel = std::move(cancel);
    if (!d->initStream(std::move(src))) {
        if (!displayName.isEmpty()) qWarning("[decoder] open stream failed: %s", displayName.toUtf8().constData());
        d.reset();
    }
    return d;
}

void Decoder::cleanup() {
    if (m_packet) av_packet_free(&m_packet);
    if (m_frame) av_frame_free(&m_frame);
    if (m_swr) swr_free(&m_swr);
    if (m_cc) avcodec_free_context(&m_cc);
    if (m_fmt) avformat_close_input(&m_fmt); // AVFMT_FLAG_CUSTOM_IO 时不碰 pb
    // 自定义 AVIO：只释放当前 pb（avio_context_free 会 av_free 它自己那份 buffer）；
    // 不拿初始 m_ioBuffer 指针去 free——probe 期间 FFmpeg 可能 realloc 过（踩坑记忆）
    if (m_pb) {
        avio_context_free(&m_pb);
        m_pb = nullptr;
    }
    m_ioBuffer = nullptr;
}

Decoder::~Decoder() {
    cleanup();
}

int Decoder::readPacket(void *opaque, uint8_t *buf, int buf_size) {
    Decoder *d = static_cast<Decoder *>(opaque);
    if (d->isCancelled()) return AVERROR_EXIT; // R08：已取消 → 不再阻塞等网络/磁盘
    if (!d->m_streamSrc) return AVERROR(EIO);
    const int64_t n = d->m_streamSrc->read(buf, buf_size);
    if (d->isCancelled()) return AVERROR_EXIT;
    if (n == 0) return AVERROR_EOF;
    if (n < 0) return int(n); // StreamSource 约定负值已是 AVERROR
    return int(n);
}

// FFmpeg 在块操（find_stream_info / av_read_frame 等）间隙轮询此回调；非 0 即中断。
// 让 m_abort 能打断“正在等字节”的探测/读取，而不必等它自己超时。
int Decoder::interruptCb(void *opaque) {
    Decoder *d = static_cast<Decoder *>(opaque);
    return d && d->isCancelled() ? 1 : 0;
}

void Decoder::requestCancel() {
    m_abort.store(true);
    if (m_streamSrc) m_streamSrc->cancel(); // 唤醒卡在背压/等字节的取流线（仅置位+notify）
}

int64_t Decoder::seekPacket(void *opaque, int64_t offset, int whence) {
    Decoder *d = static_cast<Decoder *>(opaque);
    if (!d->m_streamSrc || !d->m_streamSrc->seekable()) return -1;
    return d->m_streamSrc->seek(offset, whence);
}

// 建立 m_fmt 并完成 find_stream_info：path 非空走文件，null 走已挂好的自定义 pb
bool Decoder::openFormat(const QString *path) {
    ff::ensureInit();
    m_stageL.assign(kStageCap, 0.0f);
    m_stageR.assign(kStageCap, 0.0f);

    if (!m_fmt) m_fmt = avformat_alloc_context();
    if (!m_fmt || isCancelled()) return false;
    m_fmt->interrupt_callback.callback = interruptCb;
    m_fmt->interrupt_callback.opaque = this;
    int ret;
    if (path) {
        ret = avformat_open_input(&m_fmt, path->toUtf8().constData(), nullptr, nullptr);
    } else {
        ret = avformat_open_input(&m_fmt, nullptr, nullptr, nullptr);
        if (m_fmt) m_pb = m_fmt->pb; // probe 可能换掉 pb，取当前这份用于释放
    }
    if (ret < 0 || !m_fmt) {
        m_error = ff::errstr(ret);
        cleanup();
        return false;
    }
    // 在 find_stream_info 之前挂上中断回调：网络 stall 时 requestCancel 能即时打断探测
    m_fmt->interrupt_callback.callback = interruptCb;
    m_fmt->interrupt_callback.opaque = this;
    ret = avformat_find_stream_info(m_fmt, nullptr);
    if (ret < 0) {
        m_error = ff::errstr(ret);
        cleanup();
        return false;
    }
    return true;
}

bool Decoder::init(const QString &path) {
    if (!openFormat(&path)) return false;
    return finishInit();
}

bool Decoder::initStream(std::shared_ptr<StreamSource> src) {
    if (!src) return false;
    ff::ensureInit();
    m_streamSrc = std::move(src);
    m_fmt = avformat_alloc_context();
    if (!m_fmt) {
        cleanup();
        return false;
    }
    static constexpr int kIoBuf = 32768;
    m_ioBuffer = static_cast<uint8_t *>(av_malloc(kIoBuf));
    if (!m_ioBuffer) {
        cleanup();
        return false;
    }
    m_pb = avio_alloc_context(m_ioBuffer, kIoBuf, 0, this, readPacket, nullptr,
                              m_streamSrc->seekable() ? seekPacket : nullptr);
    if (!m_pb) {
        cleanup();
        return false;
    }
    m_fmt->pb = m_pb;
    m_fmt->flags |= AVFMT_FLAG_CUSTOM_IO;
    // openFormat 会把 m_pb 校正为 m_fmt->pb（probe 可能 realloc）
    if (!openFormat(nullptr)) return false;
    return finishInit();
}

bool Decoder::finishInit() {
    int ret = 0;
    // 快照容器级 metadata（键统一小写）：ReplayGain 标签随各家标签器写法大小写不一，
    // 下游按小写键查找；avformat 已把 Vorbis comment / ID3 TXXX / MP4 ilst 归一到这一份 dict
    for (const AVDictionaryEntry *e = nullptr; (e = av_dict_get(m_fmt->metadata, "", e, AV_DICT_IGNORE_SUFFIX));)
        m_tags.insert(QString::fromUtf8(e->key).toLower(), QString::fromUtf8(e->value));
    const int32_t idx = av_find_best_stream(m_fmt, AVMEDIA_TYPE_AUDIO, -1, -1, nullptr, 0);
    if (idx < 0 || !m_fmt->streams[idx]) {
        m_error = QStringLiteral("没有音频流");
        cleanup();
        return false;
    }
    const AVStream *st = m_fmt->streams[idx];
    m_inputChannels = st->codecpar->ch_layout.nb_channels;
    for (const AVDictionaryEntry *entry = nullptr;
         (entry = av_dict_get(st->metadata, "", entry, AV_DICT_IGNORE_SUFFIX));)
        m_tags.insert(QString::fromUtf8(entry->key).toLower(), QString::fromUtf8(entry->value));
    m_timeBase = st->time_base;
    const AVCodecParameters *par = st->codecpar;
    const AVCodec *dec = avcodec_find_decoder(par->codec_id);
    if (!dec) {
        m_error = QStringLiteral("无解码器");
        cleanup();
        return false;
    }
    m_cc = avcodec_alloc_context3(dec);
    if (!m_cc || avcodec_parameters_to_context(m_cc, par) < 0) {
        m_error = QStringLiteral("参数复制失败");
        cleanup();
        return false;
    }
    // 把包的时基交给解码器：它丢掉 priming / padding 时靠这个把 frame->pts 一起挪过去。
    // 不设（实测）mp3 会丢 1105 个样本而时间戳不动——拿 pts 推可听帧号就会一直多 1105
    m_cc->pkt_timebase = m_timeBase;
    ret = avcodec_open2(m_cc, dec, nullptr);
    if (ret < 0) {
        m_error = ff::errstr(ret);
        cleanup();
        return false;
    }

    const int32_t inRate = m_cc->sample_rate;
    const AVSampleFormat inFmt = m_cc->sample_fmt;
    // n9.0 的 DSD 解码器直接输出 FLTP；demuxer 把 sample_rate 折成位率/8，比可听 PCM
    // 基准还高 8 倍，须再过一层 swr 降到 PCM 基准率（DSD64→44100、DSD128→88200）
    const bool isDSD = ff::isDSDCodec(par->codec_id);
    m_outRate = isDSD ? std::max(1, inRate / 8) : inRate;

    // 重采样：任意输入布局/格式 → 立体声 FLTP @ outRate
    AVChannelLayout outLayout;
    av_channel_layout_default(&outLayout, 2);
    AVChannelLayout inLayout = m_cc->ch_layout;
    ret = swr_alloc_set_opts2(&m_swr, &outLayout, AV_SAMPLE_FMT_FLTP, m_outRate, &inLayout, inFmt, inRate, 0, nullptr);
    if (ret < 0 || !m_swr || swr_init(m_swr) < 0) {
        m_error = QStringLiteral("重采样器建立失败");
        cleanup();
        return false;
    }

    m_packet = av_packet_alloc();
    m_frame = av_frame_alloc();
    if (!m_packet || !m_frame) {
        m_error = QStringLiteral("缓冲分配失败");
        cleanup();
        return false;
    }

    m_streamIndex = idx;
    m_swrInRate = inRate;
    m_swrInFormat = inFmt;
    m_sampleRate = m_outRate;
    // 真实码率：n9.0 已删 AVStream.bit_rate，取编码参数 bit_rate，退回容器总码率；拿不到留 0（不假装）
    int64_t br = par->bit_rate;
    if (br <= 0) br = m_fmt->bit_rate;
    m_bitRateKbps = br > 0 ? int(br / 1000) : 0;
    m_outTB = AVRational{1, m_outRate > 0 ? m_outRate : 1};
    if (isDSD) {
        m_formatName = ff::dsdLabel(par->codec_id, int(inRate) * 8);
    } else {
        const QString container = m_fmt->iformat ? QString::fromUtf8(m_fmt->iformat->name) : QString();
        m_formatName = ff::codecName(par->codec_id, par->profile, container);
    }

    // 总时长：流 duration → 容器 duration → nb_frames
    if (st->duration > 0)
        m_totalFrames = av_rescale_q(st->duration, st->time_base, m_outTB);
    else if (m_fmt->duration > 0)
        m_totalFrames = av_rescale_q(m_fmt->duration, AVRational{1, AV_TIME_BASE}, m_outTB);
    else if (st->nb_frames > 0)
        m_totalFrames = st->nb_frames;

    m_gapless.encoderDelay = m_cc->initial_padding;
    m_gapless.trailingPadding = m_cc->trailing_padding;
    m_gapless.seekPreroll = m_cc->seek_preroll;
    m_gapless.streamDelay = par->initial_padding;
    m_gapless.streamTrailing = par->trailing_padding;

    // 先拿容器/解码器报的编码延迟当基准（没解过也能 seek 得准）；
    // 真解出第一帧后会用实测的 pts 基准覆写一次（见 emitFrame）。
    // 这个推算在 mp3（报 0，真基准 1105）与 aac（报 1024，真基准 0）两边都是错的，
    // 而基准只错在「第一帧解出来之前」——所以开完文件就立即推一次，不要等到第一次 seek
    m_ptsBase = av_rescale_q(m_cc->initial_padding, AVRational{1, inRate}, m_outTB);
    // A live stream cannot replay a primed frame at a new device rate.
    // Decode its first frame once the output rate is known.
    if (!forwardOnly()) primeAudibleBase();
    return true;
}

/// 解一帧把可听基准定下来（同时把这一帧留在暂存里，下一次 read(from: 0) 直接拿它）。
/// 解不动（坏文件）就放弃：后面真交付第一帧时 emitFrame 会自己认基准。
/// 上限 64 次：某些编码要几个包才出第一帧，但坏文件不能在这无限转
void Decoder::primeAudibleBase() {
    int tries = 0;
    while (!m_ptsCalibrated && tries < 64) {
        tries += 1;
        if (!fillStage()) return;
    }
}

/// 冷启动重建 swr：seek 时用同样参数重来，保证「同一位置重复 seek」逐字节可重复
/// （swr 带滤波器记忆，不重置会沿用上次尾巴的 warm 态而漂移）
void Decoder::configureSwr() {
    if (!m_cc) return;
    if (m_swr) {
        swr_free(&m_swr);
        m_swr = nullptr;
    }
    AVChannelLayout outLayout;
    av_channel_layout_default(&outLayout, 2);
    AVChannelLayout inLayout = m_cc->ch_layout;
    if (swr_alloc_set_opts2(&m_swr, &outLayout, AV_SAMPLE_FMT_FLTP, m_outRate, &inLayout, m_swrInFormat, m_swrInRate, 0,
                            nullptr) < 0 ||
        !m_swr || swr_init(m_swr) < 0) {
        m_swr = nullptr;
    }
}

void Decoder::seek(int64_t frame) {
    if (!m_fmt || !m_cc) return;
    const int64_t target = std::max<int64_t>(0, frame);
    // 可听帧号 → 容器时间戳：把第 0 帧那份偏移加回去（mp3 上不加就落后一个 encoder
    // delay）；回到开头时直接 seek 0，让 demuxer 自己从头重新丢 priming
    const int64_t ts = target == 0 ? 0 : av_rescale_q(target + m_ptsBase, m_outTB, m_timeBase);
    av_seek_frame(m_fmt, m_streamIndex, ts, AVSEEK_FLAG_BACKWARD);
    avcodec_flush_buffers(m_cc);
    configureSwr();
    m_stageCount = 0;
    m_stageCursor = 0;
    m_flushSent = false;
    m_nextOutPos = target;
    m_runningOutPos = target;
    m_outputPosAnchored = false;
    m_discardUntil = target;
    m_ptsCalibrated = true; // seek 之后的首帧 pts 不是第 0 帧的，基准不能再重认
}

int Decoder::read(float *outL, float *outR, int need, int64_t fromPos) {
    if (need <= 0 || !m_fmt) return 0;
    if (m_abort.load()) return 0; // R08：取消后不再产出，回调侧会当 EOF 处理
    if (!forwardOnly() && fromPos != m_nextOutPos) seek(fromPos);

    int produced = 0;
    while (produced < need) {
        if (m_stageCursor >= m_stageCount) {
            if (!fillStage()) break;
            if (m_stageCursor >= m_stageCount) break;
        }
        const int take = std::min(need - produced, m_stageCount - m_stageCursor);
        memcpy(outL + produced, m_stageL.data() + m_stageCursor, take * sizeof(float));
        memcpy(outR + produced, m_stageR.data() + m_stageCursor, take * sizeof(float));
        m_stageCursor += take;
        produced += take;
        m_nextOutPos += take;
    }
    return produced;
}

int64_t Decoder::countProducedFrames() {
    int64_t total = 0, pos = 0;
    std::vector<float> buf(std::size_t{8192} * 2);
    while (total < 200000000) { // 坏文件不能无限数下去（~76 分钟上限）
        const int got = read(buf.data(), buf.data() + 8192, 8192, pos);
        if (got <= 0) break;
        pos += got;
        total += got;
    }
    return total;
}

bool Decoder::resampleTo(int rate) {
    if (rate <= 0 || !m_cc) return false;
    if (rate == m_outRate) return true;
    m_totalFrames = av_rescale(m_totalFrames, rate, m_outRate);
    m_ptsBase = av_rescale(m_ptsBase, rate, m_outRate);
    m_sampleRate = m_outRate = rate;
    m_outTB = AVRational{1, rate};
    if (forwardOnly()) {
        configureSwr();
    } else {
        seek(0);
    }
    return m_swr != nullptr;
}

/// 标准 FFmpeg 解码流水：receive 帧，没帧就 send 包；EOF 后冲 swr 尾。
bool Decoder::fillStage() {
    if (!m_cc || !m_swr || !m_frame || !m_packet) return false;
    while (true) {
        int r = avcodec_receive_frame(m_cc, m_frame);
        if (r == AVERROR(EAGAIN)) {
            if (!feedOnePacket()) {
                if (!m_flushSent) {
                    avcodec_send_packet(m_cc, nullptr);
                    m_flushSent = true;
                }
            }
            continue;
        }
        if (r == AVERROR_EOF) return drainSwrTail();
        if (r < 0) return false;
        // 已产出的 flush 后再 receive 仍可能持续给 EOF；drain 完尾巴就收手
        if (emitFrame(m_frame)) {
            av_frame_unref(m_frame);
            return true;
        }
        av_frame_unref(m_frame);
    }
}

/// 读一个本流音频包并送入解码器；返回 false 表示 av_read_frame 已无更多输入。
bool Decoder::feedOnePacket() {
    if (!m_fmt || !m_cc) return false;
    while (true) {
        if (m_abort.load()) return false; // R08：取消后不再从网络/磁盘拉包
        av_packet_unref(m_packet);
        if (av_read_frame(m_fmt, m_packet) < 0) return false;
        if (m_packet->stream_index == m_streamIndex) {
            if (avcodec_send_packet(m_cc, m_packet) >= 0) return true;
        }
    }
}

/// 把当前 AVFrame 重采样进立体声暂存，应用 seek 丢弃；返回是否产生了可交付样本。
bool Decoder::emitFrame(AVFrame *frame) {
    const int inCount = frame->nb_samples;
    if (inCount <= 0) return false;

    // 时间戳只用于可听基准与冷启动定位：FFmpeg 在解码器里丢 priming 时会把 pts 一起
    // 往后挪（实测 lame mp3 第一帧 pts = 576 样本），直接拿它当帧号会和实交帧数对不上。
    // 可听帧号 = pts 坐标 − 基准（基准 = 第 0 帧的 pts，没解过先拿报上来的编码延迟算）
    int64_t ptsCoord;
    if (frame->pts != kNoPTS)
        ptsCoord = av_rescale_q(frame->pts, m_timeBase, m_outTB);
    else
        ptsCoord = m_runningOutPos + m_ptsBase;
    if (!m_ptsCalibrated) {
        m_ptsCalibrated = true;
        m_gapless.firstOutPTS = ptsCoord;
        // 实测基准无条件盖掉开文件时推算的那个，**包括 0**：aac 报 initial_padding
        // = 1024 可第一帧 pts 就是 0。留着 1024 当基准会让可听坐标从 −1024 起算、
        // seek 又多容器坐标加 1024 —— 两头各错一次，等于凭空丢头 23 ms
        m_ptsBase = ptsCoord;
    }
    // swr 会保留滤波延迟，后续输入帧 PTS 并不是当前输出块的起点。
    // 冷启动只从首个输入帧建立时间轴（即使它尚未产出），随后按实产 PCM 推进。
    if (!m_outputPosAnchored) {
        m_runningOutPos = ptsCoord - m_ptsBase;
        m_outputPosAnchored = true;
    }
    const int got = convert(const_cast<const uint8_t **>(frame->extended_data), inCount);
    if (got <= 0) return false;

    int valid = got;
    const int64_t start = m_runningOutPos;
    m_runningOutPos += got;

    if (m_discardUntil >= 0) {
        if (start + valid <= m_discardUntil) return false;
        if (start < m_discardUntil) {
            const int drop = int(m_discardUntil - start);
            shiftStageLeft(drop);
            valid -= drop;
        }
        m_discardUntil = -1;
    }

    m_stageCount = valid;
    m_stageCursor = 0;
    return true;
}

/// 冲 swr 端延迟：NULL 输入再转一次，把内部缓冲尾巴落到暂存。
bool Decoder::drainSwrTail() {
    const int valid0 = convert(nullptr, 0);
    if (valid0 <= 0) return false;
    int v = valid0;
    const int64_t start = m_runningOutPos;
    m_runningOutPos += valid0;
    if (m_discardUntil >= 0) {
        if (start + v <= m_discardUntil) return false;
        if (start < m_discardUntil) {
            shiftStageLeft(int(m_discardUntil - start));
            v -= int(m_discardUntil - start);
        }
        m_discardUntil = -1;
    }
    m_stageCount = v;
    m_stageCursor = 0;
    return true;
}

/// swr_convert 到立体声 stageL/stageR（FLTP）。返回产出的每声道帧数。
int Decoder::convert(const uint8_t **inData, int inCount) {
    uint8_t *planes[2] = {
        reinterpret_cast<uint8_t *>(m_stageL.data()),
        reinterpret_cast<uint8_t *>(m_stageR.data()),
    };
    const int got = swr_convert(m_swr, planes, kStageCap, inData, inCount);
    return std::max(0, got);
}

/// 把暂存左移 drop 帧（丢头部样本），保持容量不变（尾部补零）。
void Decoder::shiftStageLeft(int drop) {
    if (drop <= 0) return;
    m_stageL.erase(m_stageL.begin(), m_stageL.begin() + drop);
    m_stageL.insert(m_stageL.end(), size_t(drop), 0.0f);
    m_stageR.erase(m_stageR.begin(), m_stageR.begin() + drop);
    m_stageR.insert(m_stageR.end(), size_t(drop), 0.0f);
}
