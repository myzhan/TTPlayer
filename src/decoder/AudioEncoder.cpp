#include "AudioEncoder.h"

#include "Decoder.h"
#include "FFmpeg.h"

#include <QFile>

extern "C" {
#include <libavformat/avformat.h>
#include <libavutil/opt.h>
#include <libswresample/swresample.h>
}

#include <algorithm>
#include <cerrno>
#include <cmath>
#include <memory>
#include <vector>

namespace {

QString errText(const QString &what, int code) {
    return QStringLiteral("%1：%2").arg(what, ff::errstr(code));
}

// 输出侧资源集合：任何一步提前返回，已开的句柄都由析构收干净。
struct Output {
    AVFormatContext *fmt = nullptr;
    AVCodecContext *cc = nullptr;
    AVStream *st = nullptr;
    SwrContext *swr = nullptr;
    AVFrame *frame = nullptr;
    AVFrame *scratch = nullptr; // swr 产出暂存，攒够一帧再交给编码器
    AVPacket *pkt = nullptr;
    bool wroteHeader = false;

    ~Output() {
        if (pkt) av_packet_free(&pkt);
        if (scratch) av_frame_free(&scratch);
        if (frame) av_frame_free(&frame);
        if (swr) swr_free(&swr);
        if (cc) avcodec_free_context(&cc);
        if (fmt) {
            // 成功路径已经在主流程里写过尾，这里只兜失败/取消的半截输出。
            if (wroteHeader) av_write_trailer(fmt);
            if (!(fmt->oformat->flags & AVFMT_NOFILE) && fmt->pb) avio_closep(&fmt->pb);
            avformat_free_context(fmt);
        }
    }
};

AudioEncoder::Result encode(const QString &input, const QString &output, const EncodeTarget &target,
                            const AudioEncoder::Progress &progress, const std::atomic<bool> &cancel) {
    AudioEncoder::Result result;
    auto fail = [&result](const QString &what, int code) {
        result.ok = false;
        result.error = code < 0 ? errText(what, code) : what;
        return result;
    };

    const AVCodec *codec = avcodec_find_encoder(target.codecId);
    if (!codec) return fail(QStringLiteral("当前构建没有这个编码器"), AVERROR_ENCODER_NOT_FOUND);

    std::unique_ptr<Decoder> dec = Decoder::openFile(input);
    if (!dec) return fail(QStringLiteral("打开源文件失败"), AVERROR_INVALIDDATA);
    if (dec->sampleRate() <= 0) return fail(QStringLiteral("源文件采样率不可用"), AVERROR_INVALIDDATA);

    Output out;
    int rc = avformat_alloc_output_context2(&out.fmt, nullptr, nullptr, output.toUtf8().constData());
    if (rc < 0 || !out.fmt) return fail(QStringLiteral("按扩展名找不到封装器"), rc < 0 ? rc : AVERROR_MUXER_NOT_FOUND);

    const int outRate = target.sampleRate > 0 ? target.sampleRate : int(dec->sampleRate());
    const int srcCh = dec->channelCount() > 0 ? std::min(dec->channelCount(), 2) : 2;
    const int outCh = target.channels > 0 ? target.channels : srcCh;

    out.st = avformat_new_stream(out.fmt, nullptr);
    if (!out.st) return fail(QStringLiteral("创建输出流失败"), AVERROR(ENOMEM));
    out.cc = avcodec_alloc_context3(codec);
    if (!out.cc) return fail(QStringLiteral("创建编码器失败"), AVERROR(ENOMEM));
    out.cc->sample_rate = outRate;
    out.cc->time_base = AVRational{1, outRate};
    av_channel_layout_default(&out.cc->ch_layout, outCh);
    if (target.bitrateKbps > 0) out.cc->bit_rate = qint64(target.bitrateKbps) * 1000;
    if (target.compressionLevel >= 0) out.cc->compression_level = target.compressionLevel;
    if (out.fmt->oformat->flags & AVFMT_GLOBALHEADER) out.cc->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
    // 编码器首选采样格式（flac/aac 是 fltp，pcm 是 s16）；取不到就按 fltp 试。
    // FFmpeg 9 把 codec->sample_fmts 换成了 avcodec_get_supported_config 查询。
    const void *fmts = nullptr;
    int fmtCount = 0;
    if (avcodec_get_supported_config(nullptr, codec, AV_CODEC_CONFIG_SAMPLE_FORMAT, 0, &fmts, &fmtCount) < 0 ||
        !fmts || fmtCount <= 0) {
        out.cc->sample_fmt = AV_SAMPLE_FMT_FLTP;
    } else {
        out.cc->sample_fmt = *static_cast<const AVSampleFormat *>(fmts);
    }
    // 整数采样格式显式声明位深：否则 flac / alac 编码器把「未指定」当成要压缩到 24 bit 并告警。
    switch (out.cc->sample_fmt) {
    case AV_SAMPLE_FMT_S16:
    case AV_SAMPLE_FMT_S16P: out.cc->bits_per_raw_sample = 16; break;
    case AV_SAMPLE_FMT_S32:
    case AV_SAMPLE_FMT_S32P: out.cc->bits_per_raw_sample = 24; break;
    default: break;
    }

    rc = avcodec_open2(out.cc, codec, nullptr);
    if (rc < 0) return fail(QStringLiteral("编码器不接受这些参数（采样率 / 声道 / 码率）"), rc);
    rc = avcodec_parameters_from_context(out.st->codecpar, out.cc);
    if (rc < 0) return fail(QStringLiteral("导出编码器参数失败"), rc);
    out.st->time_base = out.cc->time_base;

    // Decoder 恒交付立体声 float 平面帧，这里一次转换到目标采样率 / 声道 / 采样格式。
    AVChannelLayout inLayout;
    av_channel_layout_default(&inLayout, 2);
    rc = swr_alloc_set_opts2(&out.swr, &out.cc->ch_layout, out.cc->sample_fmt, outRate, &inLayout, AV_SAMPLE_FMT_FLTP,
                             int(dec->sampleRate()), 0, nullptr);
    if (rc < 0 || !out.swr) return fail(QStringLiteral("重采样初始化失败"), rc);
    if (std::abs(target.gainDb) > 1e-9) {
        // rematrix_volume 是 swr 的输出总增益，正好用来做「音量调整」而不多跑一遍。
        rc = av_opt_set_double(out.swr, "rematrix_volume", std::pow(10.0, target.gainDb / 20.0), 0);
        if (rc < 0) return fail(QStringLiteral("音量增益设置失败"), rc);
    }
    rc = swr_init(out.swr);
    if (rc < 0) return fail(QStringLiteral("重采样初始化失败"), rc);

    if (!(out.fmt->oformat->flags & AVFMT_NOFILE)) {
        rc = avio_open(&out.fmt->pb, output.toUtf8().constData(), AVIO_FLAG_WRITE);
        if (rc < 0) return fail(QStringLiteral("无法写入目标文件"), rc);
    }
    rc = avformat_write_header(out.fmt, nullptr);
    if (rc < 0) return fail(QStringLiteral("写封装头失败"), rc);
    out.wroteHeader = true;

    out.frame = av_frame_alloc();
    out.scratch = av_frame_alloc();
    if (!out.frame || !out.scratch) return fail(QStringLiteral("分配编码帧失败"), AVERROR(ENOMEM));
    const int cap = out.cc->frame_size > 0 ? out.cc->frame_size : 4096;
    for (AVFrame *f : {out.frame, out.scratch}) {
        f->nb_samples = cap;
        f->format = out.cc->sample_fmt;
        f->sample_rate = outRate;
        av_channel_layout_copy(&f->ch_layout, &out.cc->ch_layout);
        rc = av_frame_get_buffer(f, 0);
        if (rc < 0) return fail(QStringLiteral("分配编码缓冲失败"), rc);
    }
    out.pkt = av_packet_alloc();
    if (!out.pkt) return fail(QStringLiteral("分配写包缓冲失败"), AVERROR(ENOMEM));

    auto encodeFrame = [&result, &out](AVFrame *f) {
        int e = avcodec_send_frame(out.cc, f);
        if (e < 0) {
            result.error = errText(QStringLiteral("编码失败"), e);
            return false;
        }
        while (true) {
            e = avcodec_receive_packet(out.cc, out.pkt);
            if (e == AVERROR(EAGAIN) || e == AVERROR_EOF) return true;
            if (e < 0) {
                result.error = errText(QStringLiteral("编码失败"), e);
                return false;
            }
            out.pkt->stream_index = out.st->index;
            av_packet_rescale_ts(out.pkt, AVRational{1, int(out.cc->sample_rate)}, out.st->time_base);
            e = av_interleaved_write_frame(out.fmt, out.pkt);
            av_packet_unref(out.pkt);
            if (e < 0) {
                result.error = errText(QStringLiteral("写入目标文件失败"), e);
                return false;
            }
        }
    };

    std::vector<float> left(static_cast<size_t>(cap));
    std::vector<float> right(static_cast<size_t>(cap));
    const int inRate = int(dec->sampleRate());
    const int64_t total = std::max<int64_t>(1, dec->totalFrames());
    int64_t inPos = 0, pts = 0;

    // 编码器要求固定帧长（AAC 必须 1024）：swr 产出先攒进 frame，攒满 cap 才发一帧。
    // 末尾不足一帧的样本作为末帧（可短）发出。
    int pending = 0;
    auto flushFrame = [&]() -> bool {
        if (pending <= 0) return true;
        out.frame->nb_samples = pending;
        out.frame->pts = pts;
        const bool ok = encodeFrame(out.frame);
        out.frame->nb_samples = cap;
        pts += pending;
        pending = 0;
        return ok;
    };
    auto pump = [&](const uint8_t **in, int inCount) -> bool {
        while (true) {
            const int space = cap - pending;
            const int produced = swr_convert(out.swr, out.scratch->data, space, in, in ? inCount : 0);
            if (produced < 0) {
                result.error = errText(QStringLiteral("重采样失败"), produced);
                return false;
            }
            if (produced > 0) {
                av_samples_copy(out.frame->extended_data, out.scratch->extended_data, pending, 0, produced,
                                out.cc->ch_layout.nb_channels, out.cc->sample_fmt);
                pending += produced;
            }
            if (pending >= cap && !flushFrame()) return false;
            in = nullptr; // 输入只在第一轮给，之后由 swr 内部积压供数
            if (produced <= 0) return true;
        }
    };

    while (true) {
        if (cancel.load()) {
            dec->requestCancel();
            result.cancelled = true;
            return result;
        }
        // 按速率折算每轮要读多少输入帧，保证一次 swr_convert 的产出不会超过 cap。
        int need = int(av_rescale(cap, inRate, outRate));
        need = std::clamp(need, 1, cap);
        const int got = dec->read(left.data(), right.data(), need, inPos);
        if (got <= 0) break;
        inPos += got;
        const uint8_t *in[2] = {reinterpret_cast<const uint8_t *>(left.data()),
                                reinterpret_cast<const uint8_t *>(right.data())};
        if (!pump(in, got)) return result;
        if (progress) progress(std::clamp(double(inPos) / double(total), 0.0, 1.0));
    }

    // 冲掉重采样器积压与未满一帧的尾巴
    if (!pump(nullptr, 0)) return result;
    if (!flushFrame()) return result;
    if (!encodeFrame(nullptr)) return result;

    rc = av_write_trailer(out.fmt);
    if (rc < 0) return fail(QStringLiteral("写封装尾失败"), rc);
    out.wroteHeader = false; // 尾已写实，析构别再补一次

    if (progress) progress(1.0);
    result.ok = true;
    return result;
}

} // namespace

AudioEncoder::Result AudioEncoder::convert(const QString &input, const QString &output, const EncodeTarget &target,
                                           const Progress &progress, const std::atomic<bool> &cancel) {
    ff::ensureInit();
    Result result = encode(input, output, target, progress, cancel);
    // 失败/取消会留下半截文件：删掉，别让人以为转成功了。
    if (!result.ok) QFile::remove(output);
    return result;
}
