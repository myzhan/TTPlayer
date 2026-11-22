#include "FFmpeg.h"

#include <cstdio>
#include <cstdarg>
#include <cmath>
#include <cstring>
#include <mutex>

namespace ff {

static std::once_flag gInitFlag;

static void logCallback(void *ptr, int level, const char *fmt, va_list vl) {
    (void)ptr;
    if (level > AV_LOG_WARNING) return; // 比 WARNING 更不重要的直接丢，防刷屏
    char buf[1024];
    vsnprintf(buf, sizeof(buf), fmt, vl);
    QString text = QString::fromUtf8(buf).trimmed();
    if (text.isEmpty()) return;
    if (level <= AV_LOG_ERROR)
        fprintf(stderr, "ffmpeg(error): %s\n", qUtf8Printable(text));
    else
        fprintf(stderr, "ffmpeg: %s\n", qUtf8Printable(text));
}

void ensureInit() {
    std::call_once(gInitFlag, [] { av_log_set_callback(logCallback); });
}

QString versionString() {
    ensureInit();
    return QString::fromUtf8(av_version_info());
}

QString errstr(int code) {
    char buf[256];
    av_strerror(code, buf, sizeof(buf));
    QString s = QString::fromUtf8(buf);
    return s.isEmpty() ? QStringLiteral("ffmpeg error %1").arg(code) : s;
}

/// pcm_sXXle/be 里抠出位深标签；浮点/对数等变体不认（走覆盖表）
static QString pcmBitsLabel(const QString &raw) {
    static const QHash<QString, QString> bits{
        {"pcm_s8", "8bit"},     {"pcm_u8", "8bit"},     {"pcm_s16le", "16bit"}, {"pcm_s16be", "16bit"},
        {"pcm_s24le", "24bit"}, {"pcm_s24be", "24bit"}, {"pcm_s32le", "32bit"}, {"pcm_s32be", "32bit"},
    };
    return bits.value(raw);
}

/// 覆盖表：把 FFmpeg 内部编码名翻译成用户看到的叫法
static const QHash<QString, QString> &nameOverrides() {
    static const QHash<QString, QString> table{
        {"pcm_s8", "PCM 8bit"},
        {"pcm_u8", "PCM 8bit"},
        {"pcm_s16le", "PCM 16bit"},
        {"pcm_s16be", "PCM 16bit"},
        {"pcm_s24le", "PCM 24bit"},
        {"pcm_s24be", "PCM 24bit"},
        {"pcm_s32le", "PCM 32bit"},
        {"pcm_s32be", "PCM 32bit"},
        {"pcm_f32le", "PCM 32bit 浮点"},
        {"pcm_f32be", "PCM 32bit 浮点"},
        {"pcm_f64le", "PCM 64bit 浮点"},
        {"pcm_f64be", "PCM 64bit 浮点"},
        {"pcm_alaw", "A-law"},
        {"pcm_mulaw", "μ-law"},
        {"mp1", "MP1"},
        {"mp2", "MP2"},
        {"mp3", "MP3"},
        {"aac", "AAC"},
        {"aac_latm", "AAC LATM"},
        {"flac", "FLAC"},
        {"vorbis", "Vorbis"},
        {"opus", "Opus"},
        {"alac", "ALAC"},
        {"ape", "APE"},
        {"wavpack", "WavPack"},
        {"tta", "TTA"},
        {"wmav1", "WMA"},
        {"wmav2", "WMA"},
        {"wmapro", "WMA Pro"},
        {"wmalossless", "WMA Lossless"},
        {"wmavoice", "WMA Voice"},
        {"dts", "DTS"},
        {"musepack7", "Musepack SV7"},
        {"musepack8", "Musepack SV8"},
        {"tak", "TAK"},
        {"shorten", "Shorten"},
        {"amr_nb", "AMR-NB"},
        {"amr_wb", "AMR-WB"},
        {"dsd_lsbf", "DSD"},
        {"dsd_msbf", "DSD"},
        {"dsd_lsbf_planar", "DSD"},
        {"dsd_msbf_planar", "DSD"},
        {"ac3", "AC-3"},
        {"eac3", "E-AC-3"},
        {"mlp", "MLP"},
        {"truehd", "TrueHD"},
        {"adpcm_ima_qt", "IMA ADPCM"},
        {"adpcm_ima_wav", "IMA ADPCM"},
        {"adpcm_ms", "MS ADPCM"},
        {"adpcm_ieee_adpcm", "IMA ADPCM"},
    };
    return table;
}

QString codecName(AVCodecID id, int profile, const QString &container) {
    if (id == AV_CODEC_ID_NONE) return QString();
    const QString raw = QString::fromUtf8(avcodec_get_name(id));
    // HE-AAC（SBR）/ HE-AACv2（SBR+PS）不能只写 "AAC"，否则用户分不清码流档位
    if (id == AV_CODEC_ID_AAC) {
        switch (profile) {
        case AV_PROFILE_AAC_HE:
            return QStringLiteral("HE-AAC");
        case AV_PROFILE_AAC_HE_V2:
            return QStringLiteral("HE-AACv2");
        case AV_PROFILE_AAC_LD:
            return QStringLiteral("AAC-LD");
        case AV_PROFILE_AAC_ELD:
            return QStringLiteral("AAC-ELD");
        default:
            break;
        }
    }
    if (id == AV_CODEC_ID_DTS) {
        switch (profile) {
        case AV_PROFILE_DTS_HD_HRA:
            return QStringLiteral("DTS-HD HRA");
        case AV_PROFILE_DTS_HD_MA:
            return QStringLiteral("DTS-HD MA");
        case AV_PROFILE_DTS_EXPRESS:
            return QStringLiteral("DTS Express");
        default:
            break;
        }
    }
    // 需要给 PCM 家族加容器前缀的裸容器：AU / Wave64（属性面板可辨壳）
    static const QHash<QString, QString> containerPrefixes{{"au", "AU"}, {"w64", "Wave64"}};
    if (!container.isEmpty() && raw.startsWith(QStringLiteral("pcm_"))) {
        const QString tag = containerPrefixes.value(container);
        const QString bits = pcmBitsLabel(raw);
        if (!tag.isEmpty() && !bits.isEmpty()) return tag + QLatin1Char(' ') + bits;
    }
    QString override = nameOverrides().value(raw);
    if (!override.isEmpty()) return override;
    return raw.toUpper();
}

QString dsdLabel(AVCodecID codecId, int dsdBitRate) {
    (void)codecId;
    if (dsdBitRate <= 0) return QStringLiteral("DSD");
    const double a = double(dsdBitRate) / 44100.0;
    const double b = double(dsdBitRate) / 48000.0;
    const double order = (std::fabs(a - std::nearbyint(a)) < std::fabs(b - std::nearbyint(b))) ? a : b;
    return QStringLiteral("DSD%1 %2MHz").arg(int(std::nearbyint(order))).arg(QString::number(dsdBitRate / 1e6, 'g', 4));
}

bool isDSDCodec(AVCodecID id) {
    switch (id) {
    case AV_CODEC_ID_DSD_LSBF:
    case AV_CODEC_ID_DSD_MSBF:
    case AV_CODEC_ID_DSD_LSBF_PLANAR:
    case AV_CODEC_ID_DSD_MSBF_PLANAR:
        return true;
    default:
        return false;
    }
}

QSet<QString> demuxerExtensions() {
    ensureInit();
    QSet<QString> result;
    void *opaque = nullptr;
    while (const AVInputFormat *f = av_demuxer_iterate(&opaque)) {
        if (!f->extensions) continue;
        const QStringList parts = QString::fromUtf8(f->extensions).split(QLatin1Char(','));
        for (QString e : parts) {
            e = e.toLower();
            // 只认 1~6 位的正常字母数字扩展名，防怪值撑歪白名单
            if (e.size() >= 1 && e.size() <= 6 &&
                std::all_of(e.begin(), e.end(), [](QChar c) { return c.isLetterOrNumber(); }))
                result.insert(e);
        }
    }
    return result;
}

const QSet<QString> &playableExtensions() {
    // 枚举一次就够（demuxer 表进程生命周期内不变），兼做 floor/undeclared 补齐
    static const QSet<QString> set = [] {
        QSet<QString> s = demuxerExtensions();
        // 部分 demuxer 不声明后缀；另补常用别名，扫描与文件选择器共用。
        const QStringList undeclared{"dsf",  "dff", "au",   "snd", "w64", "wma", "asf", "wmv", "wv",  "ape",
                                     "aifc", "afc", "opus", "oga", "mp1", "mpp", "mp+", "amr", "awb", "truehd"};
        // 保底白名单：本项目从第一天就支持的格式（运行时查询失败时仍可用）
        const QStringList floor{"mp3", "m4a", "mp4", "aac", "flac", "wav", "aiff", "aif", "caf"};
        for (const QString &e : undeclared)
            s.insert(e);
        for (const QString &e : floor)
            s.insert(e);
        return s;
    }();
    return set;
}

} // namespace ff
