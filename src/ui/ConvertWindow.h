#pragma once

// 「格式转换」对话框：把列表里选中的本地曲目转成别的封装 / 编码。
//
// 转换走内嵌 libav*（decoder/AudioEncoder），不需要外部 ffmpeg 命令行：
// 解码复用 Decoder，编码用 FFmpeg 自带 AAC / ALAC / FLAC / PCM 编码器。
// 本窗负责挑格式与音频参数（码率 / 压缩档 / 采样率 / 声道 / 音量）、选输出目录、
// 在后台线程按首顺序转换并显示总进度；取消/关窗会收掉工作线程。
// 输出名沿用源文件主名，同名已存在自动加序号——绝不覆盖原文件。

#include "core/AudioConvert.h"
#include "models/Track.h"
#include "SkinWindow.h"

#include <QList>
#include <QString>

#include <atomic>
#include <thread>

class QCloseEvent;
class QLabel;
class SkinComboBox;
class SkinLineEdit;
class SkinProgress;
class SkinSpinBox;
class TTButton;

class ConvertWindow : public SkinWindow {
    Q_OBJECT
public:
    /// tracks 里不可转的（电台 / CUE 分轨 / 归档条目 / 文件已不在）会被滤掉
    explicit ConvertWindow(const QList<Track> &tracks, QWidget *parent = nullptr);
    ~ConvertWindow() override;

    /// 开始本批转换（按钮与自检都走这一个入口）；运行中重复调用会被忽略。
    void start();

signals:
    // 工作线程 → UI：不带参对象的直连会串线程，这里只发值类型，靠排队连接回主线程。
    void jobStarted(int index, const QString &fileName);
    void jobProgress(double overall);
    void jobFailed(const QString &fileName, const QString &message);
    void batchFinished(int okCount, int failedCount, bool cancelled);

protected:
    void closeEvent(QCloseEvent *event) override;

private:
    void cancelBatch();
    void joinWorker();
    void runBatch();
    ConvertParams currentParams() const;
    QString selectedFormatId() const;
    void updateFormatUi();
    void applyRunning(bool running);
    void setStatus(const QString &text, bool error = false);
    void setOverall(double ratio);

    QList<Track> m_jobs; // 真正要转的本地文件（顺序即转换顺序）
    ConvertParams m_params; // 开转前在 UI 线程快照，工作线程只读这份
    QString m_outDir;
    bool m_running = false;

    std::thread m_worker;
    std::atomic<bool> m_cancel{false};

    SkinComboBox *m_format = nullptr;
    SkinSpinBox *m_bitrate = nullptr;
    SkinSpinBox *m_compression = nullptr;
    SkinComboBox *m_rate = nullptr;
    SkinComboBox *m_channels = nullptr;
    SkinSpinBox *m_gain = nullptr;
    SkinLineEdit *m_dir = nullptr;
    QLabel *m_codecHint = nullptr;
    SkinProgress *m_progress = nullptr;
    QLabel *m_status = nullptr;
    TTButton *m_browse = nullptr;
    TTButton *m_start = nullptr;
    TTButton *m_cancelBtn = nullptr;
    TTButton *m_close = nullptr;
};
