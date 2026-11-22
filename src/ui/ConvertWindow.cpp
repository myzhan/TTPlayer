#include "ConvertWindow.h"

#include "SkinParts.h"
#include "SkinWidgets.h"
#include "Theme.h"
#include "media/AudioEncoder.h"

#include <QCloseEvent>
#include <QDir>
#include <QFileDialog>
#include <QFileInfo>
#include <QGridLayout>
#include <QHBoxLayout>
#include <QLabel>
#include <QLineEdit>
#include <QVBoxLayout>

#include <cmath>

namespace {

QLabel *hintLabel(QWidget *parent, const QString &text = QString()) {
    auto *label = new QLabel(text, parent);
    label->setFont(Fonts::small);
    label->setStyleSheet(QStringLiteral("color:%1;background:transparent;").arg(Theme::inkOnGlassSoft.name()));
    return label;
}

} // namespace

ConvertWindow::ConvertWindow(const QList<Track> &tracks, QWidget *parent)
    : SkinWindow(QStringLiteral("格式转换"), TitleButtons::Close, parent) {
    setAttribute(Qt::WA_DeleteOnClose);
    // 辅助窗不跟随半透明：参数行压在播放列表上时不串底。
    setGlassTransparencyFollows(false);

    // 只留真正能转的：本地文件、不是电台 / CUE 分轨 / 归档条目、文件还在。
    for (const Track &t : tracks) {
        const QUrl &url = t.url();
        if (t.isNull() || t.isRadio() || t.isCueSegment()) continue;
        if (!url.isLocalFile() || !url.fragment().isEmpty()) continue;
        if (!QFileInfo::exists(url.toLocalFile())) continue;
        m_jobs.append(t);
    }

    auto *root = new QVBoxLayout(body());
    root->setContentsMargins(12, 10, 12, 10);
    root->setSpacing(8);

    // 顶部：要转谁
    QString head;
    if (m_jobs.isEmpty()) {
        head = QStringLiteral("没有可转换的曲目（电台 / CUE 分轨 / 归档条目不支持转换）");
    } else if (m_jobs.size() == 1) {
        const Track &t = m_jobs.first();
        const QString name = t.title().isEmpty() ? t.fileName() : t.title();
        head = t.artist().isEmpty() ? QStringLiteral("转换：%1").arg(name)
                                    : QStringLiteral("转换：%1 - %2").arg(t.artist(), name);
    } else {
        head = QStringLiteral("转换 %1 首曲目（按列表顺序逐首转）").arg(m_jobs.size());
    }
    auto *title = new QLabel(head, this);
    title->setFont(Fonts::small);
    title->setStyleSheet(QStringLiteral("color:%1;background:transparent;").arg(Theme::inkOnGlass.name()));
    root->addWidget(title);

    // —— 输出格式 ——
    auto *formatSection = new SkinSection(QStringLiteral("输出格式"), this);
    auto *formatLayout = new QVBoxLayout(formatSection->content());
    formatLayout->setContentsMargins(4, 0, 4, 0);
    formatLayout->setSpacing(4);
    m_format = new SkinComboBox(this);
    for (const ConvertFormat &f : AudioConvert::formats())
        m_format->addItem(f.label, f.id);
    m_format->setCurrentIndex(0);
    formatLayout->addWidget(m_format);
    m_codecHint = hintLabel(this);
    formatLayout->addWidget(m_codecHint);
    root->addWidget(formatSection);

    // —— 音频参数 ——
    auto *paramSection = new SkinSection(QStringLiteral("音频参数"), this);
    auto *grid = new QGridLayout(paramSection->content());
    grid->setContentsMargins(4, 0, 4, 0);
    grid->setHorizontalSpacing(10);
    grid->setVerticalSpacing(6);

    m_bitrate = new SkinSpinBox(this);
    m_bitrate->setRange(32, 512);
    m_bitrate->setValue(256);
    m_bitrate->setSuffix(QStringLiteral(" kbps"));

    m_compression = new SkinSpinBox(this);
    m_compression->setRange(0, 12);
    m_compression->setValue(5);
    m_compression->setSuffix(QStringLiteral(" 档"));

    m_rate = new SkinComboBox(this);
    m_rate->addItem(QStringLiteral("保持原样"), 0);
    for (int rate : {22050, 32000, 44100, 48000, 96000})
        m_rate->addItem(QStringLiteral("%1 Hz").arg(rate), rate);
    m_rate->setCurrentIndex(0);

    m_channels = new SkinComboBox(this);
    m_channels->addItem(QStringLiteral("保持原样"), 0);
    m_channels->addItem(QStringLiteral("单声道"), 1);
    m_channels->addItem(QStringLiteral("立体声"), 2);
    m_channels->setCurrentIndex(0);

    m_gain = new SkinSpinBox(this);
    m_gain->setRange(-20, 20);
    m_gain->setValue(0);
    m_gain->setSuffix(QStringLiteral(" dB"));

    int row = 0;
    const auto addRow = [&](const QString &label, QWidget *w) {
        grid->addWidget(hintLabel(this, label), row, 0);
        grid->addWidget(w, row, 1);
        grid->setColumnStretch(1, 1);
        ++row;
    };
    addRow(QStringLiteral("码率"), m_bitrate);
    addRow(QStringLiteral("压缩档"), m_compression);
    addRow(QStringLiteral("采样率"), m_rate);
    addRow(QStringLiteral("声道"), m_channels);
    addRow(QStringLiteral("音量"), m_gain);
    root->addWidget(paramSection);

    // —— 输出位置 ——
    auto *outSection = new SkinSection(QStringLiteral("输出"), this);
    auto *outLayout = new QGridLayout(outSection->content());
    outLayout->setContentsMargins(4, 0, 4, 0);
    outLayout->setHorizontalSpacing(8);
    outLayout->setVerticalSpacing(4);
    outLayout->addWidget(hintLabel(this, QStringLiteral("目录")), 0, 0);
    m_dir = new SkinLineEdit(this);
    m_dir->setPlaceholderText(QStringLiteral("留空 = 与源文件同目录"));
    if (!m_jobs.isEmpty()) m_dir->setText(QFileInfo(m_jobs.first().url().toLocalFile()).absolutePath());
    m_dir->edit()->setCursorPosition(0); // 长路径默认显示开头（盘符/家目录）而不是尾巴
    outLayout->addWidget(m_dir, 0, 1);
    m_browse = new TTButton(this);
    m_browse->setTextLabel(QStringLiteral("浏览…"));
    m_browse->setFace(TTButton::Face::Glass);
    m_browse->setPreferredSize({64, 24});
    outLayout->addWidget(m_browse, 0, 2);
    outLayout->setColumnStretch(1, 1);
    outLayout->addWidget(hintLabel(this, QStringLiteral("同名文件已存在时自动加序号，不覆盖原文件")), 1, 0, 1, 3);
    root->addWidget(outSection);

    // —— 进度 + 状态 ——
    m_progress = new SkinProgress(this);
    m_progress->setRatio(0.0);
    m_progress->setCaption(QStringLiteral("0%"));
    root->addWidget(m_progress);
    m_status = hintLabel(this, QStringLiteral("选好格式与参数后点「开始转换」"));
    m_status->setWordWrap(true);
    root->addWidget(m_status);

    // —— 按钮 ——
    m_start = new TTButton(this);
    m_start->setTextLabel(QStringLiteral("开始转换"));
    m_start->setFace(TTButton::Face::Glass);
    m_start->setPreferredSize({84, 24});
    m_cancelBtn = new TTButton(this);
    m_cancelBtn->setTextLabel(QStringLiteral("取消"));
    m_cancelBtn->setFace(TTButton::Face::Glass);
    m_cancelBtn->setPreferredSize({56, 24});
    m_cancelBtn->setEnabled(false);
    m_close = new TTButton(this);
    m_close->setTextLabel(QStringLiteral("关闭"));
    m_close->setFace(TTButton::Face::Glass);
    m_close->setPreferredSize({56, 24});
    auto *btnRow = new QHBoxLayout();
    btnRow->setSpacing(8);
    btnRow->addStretch();
    btnRow->addWidget(m_start);
    btnRow->addWidget(m_cancelBtn);
    btnRow->addWidget(m_close);
    root->addLayout(btnRow);

    // —— 接线 ——
    connect(m_browse, &TTButton::clicked, this, [this] {
        const QString dir = QFileDialog::getExistingDirectory(this, QStringLiteral("选择输出目录"), m_dir->text());
        if (!dir.isEmpty()) m_dir->setText(dir);
    });
    connect(m_start, &TTButton::clicked, this, &ConvertWindow::start);
    connect(m_cancelBtn, &TTButton::clicked, this, &ConvertWindow::cancelBatch);
    connect(m_close, &TTButton::clicked, this, &QWidget::close);
    connect(m_format, &SkinComboBox::currentIndexChanged, this, [this](int) { updateFormatUi(); });
    connect(m_bitrate, &SkinSpinBox::valueChanged, this, [this](int) { updateFormatUi(); });

    // 工作线程只发值类型信号，这里用默认排队连接回到 UI 线程。
    connect(this, &ConvertWindow::jobStarted, this, [this](int index, const QString &fileName) {
        setStatus(QStringLiteral("正在转换（%1/%2）：%3").arg(index + 1).arg(m_jobs.size()).arg(fileName));
    });
    connect(this, &ConvertWindow::jobProgress, this, &ConvertWindow::setOverall);
    connect(this, &ConvertWindow::jobFailed, this, [this](const QString &fileName, const QString &message) {
        setStatus(QStringLiteral("转换失败：%1 · %2").arg(fileName, message), true);
    });
    connect(this, &ConvertWindow::batchFinished, this, [this](int okCount, int failedCount, bool cancelled) {
        joinWorker(); // 线程已经发完最后一条信号，这里收干净
        applyRunning(false);
        if (cancelled) {
            setStatus(QStringLiteral("已取消（已完成的 %1 首保留）").arg(okCount));
        } else if (failedCount == 0) {
            // 具体失败原因由 jobFailed 写在状态行，这里不覆盖
            setOverall(1.0);
            setStatus(QStringLiteral("转换完成：%1 首 · 输出在 %2").arg(okCount).arg(m_outDir));
        }
    });

    updateFormatUi();
    if (m_jobs.isEmpty()) {
        m_start->setEnabled(false);
        setStatus(QStringLiteral("没有可转换的曲目"), true);
    }

    resize(470, 500);
    setMinimumSize(400, 420);
}

ConvertWindow::~ConvertWindow() {
    m_cancel.store(true);
    joinWorker();
}

void ConvertWindow::closeEvent(QCloseEvent *event) {
    // 关窗＝放弃这批转换：先让工作线程收手再放行，避免线程比窗口活得久。
    m_cancel.store(true);
    joinWorker();
    QWidget::closeEvent(event);
}

void ConvertWindow::start() {
    if (m_running || m_jobs.isEmpty()) return;

    QString dir = m_dir->text().trimmed();
    if (dir.isEmpty()) dir = QFileInfo(m_jobs.first().url().toLocalFile()).absolutePath();
    if (!QDir(dir).exists() && !QDir().mkpath(dir)) {
        setStatus(QStringLiteral("无法创建输出目录：%1").arg(dir), true);
        return;
    }
    m_outDir = dir;
    m_dir->setText(dir);
    m_dir->edit()->setCursorPosition(0);
    m_params = currentParams(); // 参数在 UI 线程定稿，工作线程不再碰控件

    joinWorker(); // 上一轮（如果刚结束）先收掉
    m_cancel.store(false);
    applyRunning(true);
    setOverall(0.0);
    setStatus(QStringLiteral("准备转换 %1 首…").arg(m_jobs.size()));
    m_worker = std::thread([this] { runBatch(); });
}

void ConvertWindow::cancelBatch() {
    if (!m_running) return;
    m_cancel.store(true);
    m_cancelBtn->setEnabled(false);
    setStatus(QStringLiteral("正在取消…"));
}

void ConvertWindow::joinWorker() {
    if (m_worker.joinable()) m_worker.join();
}

// 工作线程体：逐首转换，全程只发信号，不碰任何控件。
void ConvertWindow::runBatch() {
    const ConvertParams params = m_params;
    const ConvertFormat *fmt = AudioConvert::formatById(params.formatId);
    if (!fmt) {
        emit jobFailed(QString(), QStringLiteral("未知的输出格式"));
        emit batchFinished(0, 1, false);
        return;
    }
    const EncodeTarget target = AudioConvert::targetFor(params);
    const int total = int(m_jobs.size());
    int done = 0;

    for (int i = 0; i < total; ++i) {
        if (m_cancel.load()) {
            emit batchFinished(done, 0, true);
            return;
        }
        const QString in = m_jobs[i].url().toLocalFile();
        const QString out = AudioConvert::uniqueOutputPath(in, m_outDir, fmt->extension);
        const QString name = QFileInfo(in).fileName();
        emit jobStarted(i, name);

        const double base = double(i) / double(total);
        const double span = 1.0 / double(total);
        const AudioEncoder::Result r = AudioEncoder::convert(
            in, out, target, [this, base, span](double ratio) { emit jobProgress(base + span * ratio); }, m_cancel);

        if (r.cancelled) {
            emit batchFinished(done, 0, true);
            return;
        }
        if (!r.ok) {
            emit jobFailed(name, r.error);
            emit batchFinished(done, 1, false);
            return;
        }
        ++done;
        emit jobProgress(base + span);
    }
    emit batchFinished(done, 0, false);
}

ConvertParams ConvertWindow::currentParams() const {
    ConvertParams params;
    params.formatId = selectedFormatId();
    params.bitrateKbps = m_bitrate->value();
    params.compressionLevel = m_compression->value();
    params.sampleRate = m_rate->itemData(m_rate->currentIndex()).toInt();
    params.channels = m_channels->itemData(m_channels->currentIndex()).toInt();
    params.gainDb = double(m_gain->value());
    return params;
}

QString ConvertWindow::selectedFormatId() const {
    return m_format->itemData(m_format->currentIndex()).toString();
}

void ConvertWindow::updateFormatUi() {
    const ConvertFormat *fmt = AudioConvert::formatById(selectedFormatId());
    if (!fmt) return;
    m_bitrate->setEnabled(!m_running && !fmt->lossless);
    m_compression->setEnabled(!m_running && fmt->supportsCompression);
    if (fmt->supportsCompression) {
        // 每种格式的压缩档上限不一样（FLAC 0–12、ALAC 0–2），切格式时收窄并夹住旧值。
        m_compression->setRange(0, fmt->maxCompression);
        if (m_compression->value() > fmt->maxCompression) m_compression->setValue(fmt->maxCompression);
    }
    if (fmt->lossless) {
        m_codecHint->setText(
            fmt->supportsCompression
                ? QStringLiteral("%1 · 无损，压缩档 0–%2（越大越省空间）").arg(fmt->label).arg(fmt->maxCompression)
                : QStringLiteral("%1 · 无损，码率与压缩档不适用").arg(fmt->label));
    } else {
        m_codecHint->setText(QStringLiteral("%1 · 有损，%2 kbps").arg(fmt->label).arg(m_bitrate->value()));
    }
}

void ConvertWindow::applyRunning(bool running) {
    m_running = running;
    const QList<QWidget *> inputs{static_cast<QWidget *>(m_format), static_cast<QWidget *>(m_bitrate),
                                  static_cast<QWidget *>(m_rate),   static_cast<QWidget *>(m_channels),
                                  static_cast<QWidget *>(m_gain),   static_cast<QWidget *>(m_dir)};
    for (QWidget *w : inputs)
        w->setEnabled(!running);
    m_browse->setEnabled(!running);
    m_start->setEnabled(!running && !m_jobs.isEmpty());
    m_cancelBtn->setEnabled(running);
    m_close->setEnabled(!running);
    if (!running) updateFormatUi(); // 无损/有损的可编辑项按格式重新放开
}

void ConvertWindow::setStatus(const QString &text, bool error) {
    m_status->setText(text);
    m_status->setStyleSheet(
        QStringLiteral("color:%1;background:transparent;").arg((error ? Theme::textAccent : Theme::inkOnGlass).name()));
}

void ConvertWindow::setOverall(double ratio) {
    const double r = qBound(0.0, ratio, 1.0);
    m_progress->setRatio(r);
    m_progress->setCaption(QStringLiteral("%1%").arg(int(std::lround(r * 100.0))));
}
