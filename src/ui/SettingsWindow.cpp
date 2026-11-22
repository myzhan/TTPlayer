#include "SettingsWindow.h"
#include "MainWindow.h"
#include "playback/PlayerController.h"
#include "audio/AudioEngine.h"
#include "models/PlayQueue.h"
#include "models/ReplayGain.h"
#include "Theme.h"
#include "SkinWidgets.h"
#include "SkinParts.h"

#include <QWidget>
#include <QVBoxLayout>
#include <QHBoxLayout>
#include <QLabel>
#include <QFileDialog>
#include <QMessageBox>
#include <QTimer>
#include <QSignalBlocker>
#include <QPlainTextEdit>
#include <QScrollBar>
#include <QStyle>
#include <algorithm>

// 统一毛玻璃：设置窗不再用原生 Fusion 控件（QTabWidget/QGroupBox/QComboBox/QCheckBox/
// QSpinBox/QSlider/QPushButton/QListWidget/QDialogButtonBox 那套不透明白灰方块），
// 全换皮肤自绘控件（SkinWidgets），静止融进玻璃、仅 hover 轻亮，浅底深字。

namespace {
// 文本按钮（替 QPushButton）：走 hover-face，静止透明、hover 轻亮。
TTButton *mkTextBtn(const QString &t, QWidget *parent) {
    auto *b = new TTButton(parent);
    b->setTextLabel(t);
    b->setFace(TTButton::Face::Glass);
    b->setPreferredSize({int(16 + t.length() * 13), 22});
    return b;
}
} // namespace

SettingsWindow::SettingsWindow(MainWindow *main, QWidget *parent)
    : SkinWindow(QStringLiteral("设置"), TitleButtons::Close, parent), m_main(main) {
    setAttribute(Qt::WA_DeleteOnClose);
    setWindowModality(Qt::NonModal);
    resize(480, 440 + 30); // 高度补上自绘标题条（~30）

    auto *outer = new QVBoxLayout(body());
    auto *tabs = new SkinTabWidget(body());
    tabs->addTab(buildPlayback(), QStringLiteral("播放"));
    tabs->addTab(buildAudioFx(), QStringLiteral("音效"));
    tabs->addTab(buildOutput(), QStringLiteral("输出设备"));
    tabs->addTab(buildLyric(), QStringLiteral("歌词"));
    tabs->addTab(buildAppearance(), QStringLiteral("外观"));
    tabs->addTab(buildLibrary(), QStringLiteral("媒体库"));
    outer->addWidget(tabs);

    auto *row = new QHBoxLayout;
    row->addStretch();
    auto *closeBtn = mkTextBtn(QStringLiteral("关闭"), body());
    connect(closeBtn, &TTButton::clicked, this, &QWidget::close);
    row->addWidget(closeBtn);
    outer->addLayout(row);
}

// —— 播放：模式 / 启动自动续播 / 无缝 / 睡眠定时器 ——
QWidget *SettingsWindow::buildPlayback() {
    auto *page = new QWidget;
    auto *v = new QVBoxLayout(page);

    auto *modeSec = new SkinSection(QStringLiteral("播放模式"), page);
    auto *mf = new QVBoxLayout(modeSec->content());
    m_mode = new SkinComboBox(modeSec->content());
    m_mode->setObjectName(QStringLiteral("settingsPlayMode"));
    m_mode->addItem(QStringLiteral("顺序播放"), int(PlayMode::Order));
    m_mode->addItem(QStringLiteral("列表循环"), int(PlayMode::ListLoop));
    m_mode->addItem(QStringLiteral("单曲循环"), int(PlayMode::SingleLoop));
    m_mode->addItem(QStringLiteral("随机播放"), int(PlayMode::Random));
    for (int i = 0; i < m_mode->count(); ++i)
        if (m_mode->itemData(i).toInt() == int(m_main->controller()->mode())) {
            m_mode->setCurrentIndex(i);
            break;
        }
    connect(m_mode, &SkinComboBox::activated, this, [this](int i) {
        m_main->controller()->setMode(PlayMode(m_mode->itemData(i).toInt()));
        m_main->requestSave();
    });
    connect(m_main->controller(), &PlayerController::modeChanged, this, [this] {
        const QSignalBlocker blocker(m_mode);
        for (int i = 0; i < m_mode->count(); ++i)
            if (m_mode->itemData(i).toInt() == int(m_main->controller()->mode())) m_mode->setCurrentIndex(i);
    });
    mf->addWidget(m_mode);
    v->addWidget(modeSec);

    auto *optSec = new SkinSection(QStringLiteral("播放行为"), page);
    auto *of = new QVBoxLayout(optSec->content());
    auto *autoResume = new SkinCheckBox(QStringLiteral("启动后自动继续播放"), optSec->content());
    autoResume->setChecked(m_main->autoResumePlay());
    connect(autoResume, &SkinCheckBox::toggled, this, [this](bool on) { m_main->setAutoResumePlay(on); });
    of->addWidget(autoResume);

    auto *gapless = new SkinCheckBox(QStringLiteral("无缝播放（切歌不留空白）"), optSec->content());
    gapless->setChecked(m_main->controller()->gaplessEnabled());
    connect(gapless, &SkinCheckBox::toggled, this, [this](bool on) {
        m_main->controller()->setGaplessEnabled(on);
        m_main->requestSave();
    });
    of->addWidget(gapless);
    v->addWidget(optSec);

    auto *sleepSec = new SkinSection(QStringLiteral("睡眠定时器"), page);
    auto *sf = new QVBoxLayout(sleepSec->content());
    auto *row1 = new QHBoxLayout;
    m_sleepPreset = new SkinComboBox(sleepSec->content());
    m_sleepPreset->addItem(QStringLiteral("不设置"), 0);
    for (int m : {15, 30, 45, 60})
        m_sleepPreset->addItem(QStringLiteral("%1 分钟").arg(m), m);
    auto *custom = new SkinSpinBox(sleepSec->content());
    custom->setRange(1, 7 * 24 * 60);
    custom->setSuffix(QStringLiteral(" 分钟"));
    auto *applyBtn = mkTextBtn(QStringLiteral("应用"), sleepSec->content());
    row1->addWidget(m_sleepPreset);
    row1->addWidget(custom);
    row1->addWidget(applyBtn);
    sf->addLayout(row1);

    connect(applyBtn, &TTButton::clicked, this, [this, custom] {
        m_main->controller()->setSleepMinutes(custom->value());
        m_main->requestSave();
    });
    connect(m_sleepPreset, &SkinComboBox::activated, this, [this](int i) {
        m_main->controller()->setSleepMinutes(m_sleepPreset->itemData(i).toInt());
        m_main->requestSave();
    });

    auto *row2 = new QHBoxLayout;
    auto *afterTrack = mkTextBtn(QStringLiteral("播完当前曲后停止"), sleepSec->content());
    connect(afterTrack, &TTButton::clicked, this, [this] {
        m_main->controller()->setSleepAfterCurrentTrack();
        m_main->requestSave();
    });
    row2->addWidget(afterTrack);
    row2->addStretch();
    sf->addLayout(row2);

    auto *sleepFade = new SkinCheckBox(QStringLiteral("到点前淡出最后 10 秒"), sleepSec->content());
    sleepFade->setChecked(m_main->controller()->sleepFadeEnabled());
    connect(sleepFade, &SkinCheckBox::toggled, this, [this](bool on) {
        m_main->controller()->setSleepFadeEnabled(on);
        m_main->requestSave();
    });
    connect(m_main->controller(), &PlayerController::sleepChanged, this, [this, sleepFade] {
        const QSignalBlocker blocker(sleepFade);
        sleepFade->setChecked(m_main->controller()->sleepFadeEnabled());
    });
    sf->addWidget(sleepFade);
    v->addWidget(sleepSec);
    v->addStretch();
    return page;
}

// —— 音效：响度均衡模式 / 峰值防削波 / 前置增益 ——
QWidget *SettingsWindow::buildAudioFx() {
    auto *page = new QWidget;
    auto *v = new QVBoxLayout(page);
    auto *sec = new SkinSection(QStringLiteral("响度均衡（ReplayGain）"), page);
    auto *f = new QVBoxLayout(sec->content());

    m_rgMode = new SkinComboBox(sec->content());
    m_rgMode->addItem(QStringLiteral("关闭"), int(ReplayGainMode::Off));
    m_rgMode->addItem(QStringLiteral("按曲目"), int(ReplayGainMode::Track));
    m_rgMode->addItem(QStringLiteral("按专辑"), int(ReplayGainMode::Album));
    for (int i = 0; i < m_rgMode->count(); ++i)
        if (m_rgMode->itemData(i).toInt() == int(m_main->controller()->replayGainMode())) {
            m_rgMode->setCurrentIndex(i);
            break;
        }
    connect(m_rgMode, &SkinComboBox::activated, this, [this](int i) {
        m_main->controller()->setReplayGainMode(ReplayGainMode(m_rgMode->itemData(i).toInt()));
        m_main->requestSave();
    });
    f->addWidget(m_rgMode);

    auto *peak = new SkinCheckBox(QStringLiteral("峰值防削波"), sec->content());
    peak->setChecked(m_main->controller()->replayGainPeakLimit());
    connect(peak, &SkinCheckBox::toggled, this, [this](bool on) {
        m_main->controller()->setReplayGainPeakLimit(on);
        m_main->requestSave();
    });
    f->addWidget(peak);

    auto *preRow = new QHBoxLayout;
    auto *preLbl = new QLabel(QStringLiteral("前置增益"), sec->content());
    preLbl->setStyleSheet(QStringLiteral("color:%1;background:transparent;").arg(Theme::inkOnGlass.name()));
    m_preamp = new SkinSlider(sec->content());
    m_preamp->setRange(-12, 12);
    m_preamp->setValue(int(std::lround(m_main->controller()->replayGainPreamp())));
    m_preampLabel = new QLabel(sec->content());
    m_preampLabel->setText(QStringLiteral("%1 dB").arg(m_preamp->value()));
    m_preampLabel->setStyleSheet(QStringLiteral("color:%1;background:transparent;").arg(Theme::inkOnGlassSoft.name()));
    preRow->addWidget(preLbl);
    preRow->addWidget(m_preamp);
    preRow->addWidget(m_preampLabel);
    f->addLayout(preRow);
    connect(m_preamp, &SkinSlider::valueChanged, this, [this](int v) {
        m_preampLabel->setText(QStringLiteral("%1 dB").arg(v));
        m_main->controller()->setReplayGainPreamp(v);
    });
    connect(m_preamp, &SkinSlider::sliderReleased, this, [this] { m_main->requestSave(); });
    connect(m_main->controller(), &PlayerController::replayGainChanged, this, [this, peak] {
        const QSignalBlocker modeBlocker(m_rgMode), peakBlocker(peak), preampBlocker(m_preamp);
        for (int i = 0; i < m_rgMode->count(); ++i)
            if (m_rgMode->itemData(i).toInt() == int(m_main->controller()->replayGainMode()))
                m_rgMode->setCurrentIndex(i);
        peak->setChecked(m_main->controller()->replayGainPeakLimit());
        m_preamp->setValue(int(std::lround(m_main->controller()->replayGainPreamp())));
        m_preampLabel->setText(QStringLiteral("%1 dB").arg(m_preamp->value()));
    });

    v->addWidget(sec);
    v->addStretch();
    return page;
}

// —— 输出设备：跟随系统默认 / SDL 枚举到的每一台 ——
QWidget *SettingsWindow::buildOutput() {
    auto *page = new QWidget;
    auto *v = new QVBoxLayout(page);
    auto *sec = new SkinSection(QStringLiteral("输出设备"), page);
    auto *f = new QVBoxLayout(sec->content());

    m_device = new SkinComboBox(sec->content());
    m_device->addItem(QStringLiteral("跟随系统默认"), QString());
    const auto devs = AudioEngine::outputDeviceDescriptors();
    const QString current = m_main->engine()->outputDevice();
    int curIdx = 0;
    for (const auto &d : devs) {
        m_device->addItem(d.name, d.id);
        if (d.id == current || d.name == current) curIdx = m_device->count() - 1;
    }
    m_device->setCurrentIndex(curIdx);
    connect(m_device, &SkinComboBox::activated, this, [this](int i) {
        m_main->controller()->setOutputDevice(m_device->itemData(i).toString());
        m_main->requestSave();
    });
    f->addWidget(m_device);
    auto *actual = new QLabel(sec->content());
    const auto update = [this, actual] {
        actual->setText(QStringLiteral("当前实际输出：%1\n%2")
                            .arg(m_main->engine()->actualOutputDevice(), m_main->engine()->outputProblem()));
    };
    update();
    auto *timer = new QTimer(actual);
    timer->setInterval(1000);
    connect(timer, &QTimer::timeout, actual, update);
    timer->start();
    f->addWidget(actual);
    if (devs.isEmpty()) {
        auto *tip = new QLabel(QStringLiteral("未枚举到输出设备（可能无音频硬件）"), sec->content());
        tip->setStyleSheet(QStringLiteral("color:%1;background:transparent;").arg(Theme::inkOnGlassSoft.name()));
        f->addWidget(tip);
    }

    v->addWidget(sec);
    v->addStretch();
    return page;
}

// —— 歌词：对当前曲的时间校准 ——
QWidget *SettingsWindow::buildLyric() {
    auto *page = new QWidget;
    auto *v = new QVBoxLayout(page);
    auto *sec = new SkinSection(QStringLiteral("歌词时间校准（当前曲）"), page);
    auto *f = new QVBoxLayout(sec->content());

    m_lyricStatus = new QLabel(sec->content());
    m_lyricStatus->setWordWrap(true);
    m_lyricStatus->setStyleSheet(QStringLiteral("color:%1;background:transparent;").arg(Theme::inkOnGlass.name()));
    f->addWidget(m_lyricStatus);

    auto *row = new QHBoxLayout;
    auto *earlier = mkTextBtn(QStringLiteral("提前 0.5 秒"), sec->content());
    auto *later = mkTextBtn(QStringLiteral("延后 0.5 秒"), sec->content());
    auto *reset = mkTextBtn(QStringLiteral("归零"), sec->content());
    row->addWidget(earlier);
    row->addWidget(later);
    row->addWidget(reset);
    row->addStretch();
    f->addLayout(row);

    connect(earlier, &TTButton::clicked, this, [this] {
        m_main->controller()->nudgeLyricShift(-PlayerController::kLyricShiftStep);
        m_main->requestSave();
        refreshLyricStatus();
    });
    connect(later, &TTButton::clicked, this, [this] {
        m_main->controller()->nudgeLyricShift(PlayerController::kLyricShiftStep);
        m_main->requestSave();
        refreshLyricStatus();
    });
    connect(reset, &TTButton::clicked, this, [this] {
        m_main->controller()->resetLyricShift();
        m_main->requestSave();
        refreshLyricStatus();
    });

    connect(m_main->controller(), &PlayerController::lyricShiftChanged, this, [this] { refreshLyricStatus(); });
    connect(m_main->controller(), &PlayerController::trackChanged, this, [this] { refreshLyricStatus(); });
    refreshLyricStatus();

    v->addWidget(sec);
    v->addStretch();
    return page;
}

void SettingsWindow::refreshLyricStatus() {
    m_lyricStatus->setText(m_main->controller()->lyricShiftDetail());
}

// —— 外观：半透明玻璃 / 透明度 ——
QWidget *SettingsWindow::buildAppearance() {
    auto *page = new QWidget;
    auto *v = new QVBoxLayout(page);
    auto *sec = new SkinSection(QStringLiteral("玻璃外观"), page);
    auto *f = new QVBoxLayout(sec->content());

    auto *glass = new SkinCheckBox(QStringLiteral("半透明玻璃（主面板及设置 / 文件信息 / 封面）"), sec->content());
    glass->setChecked(GlassStyle::enabled());
    connect(glass, &SkinCheckBox::toggled, this, [this](bool on) {
        GlassStyle::setEnabled(on);
        m_main->requestSave();
    });
    f->addWidget(glass);

    auto *row = new QHBoxLayout;
    auto *lbl = new QLabel(QStringLiteral("透明度"), sec->content());
    lbl->setStyleSheet(QStringLiteral("color:%1;background:transparent;").arg(Theme::inkOnGlass.name()));
    m_transparency = new SkinSlider(sec->content());
    m_transparency->setRange(0, 100);
    m_transparency->setValue(int(std::lround(GlassStyle::transparency() * 100)));
    m_transparencyLabel = new QLabel(sec->content());
    m_transparencyLabel->setText(QStringLiteral("%1%").arg(m_transparency->value()));
    m_transparencyLabel->setStyleSheet(
        QStringLiteral("color:%1;background:transparent;").arg(Theme::inkOnGlassSoft.name()));
    row->addWidget(lbl);
    row->addWidget(m_transparency);
    row->addWidget(m_transparencyLabel);
    f->addLayout(row);
    connect(m_transparency, &SkinSlider::valueChanged, this, [this](int p) {
        m_transparencyLabel->setText(QStringLiteral("%1%").arg(p));
        GlassStyle::setTransparency(float(p) / 100.0f);
    });
    connect(m_transparency, &SkinSlider::sliderReleased, this, [this] { m_main->requestSave(); });
    connect(&GlassNotifier::instance(), &GlassNotifier::changed, this, [this, glass] {
        const QSignalBlocker glassBlocker(glass), alphaBlocker(m_transparency);
        glass->setChecked(GlassStyle::enabled());
        m_transparency->setValue(int(std::lround(GlassStyle::transparency() * 100)));
        m_transparencyLabel->setText(QStringLiteral("%1%").arg(m_transparency->value()));
    });

    v->addWidget(sec);
    v->addStretch();
    return page;
}

// —— 媒体库：文件夹清单 / 添加 / 移除 / 重新扫描 ——
QWidget *SettingsWindow::buildLibrary() {
    auto *page = new QWidget;
    auto *v = new QVBoxLayout(page);
    auto *sec = new SkinSection(QStringLiteral("音乐文件夹"), page);
    auto *f = new QVBoxLayout(sec->content());

    m_folders = new SkinListView(sec->content());
    m_folders->setRowHeight(24);
    for (const QString &p : m_main->libraryFolders())
        m_folders->addItem(p);
    f->addWidget(m_folders);

    auto *row = new QHBoxLayout;
    auto *add = mkTextBtn(QStringLiteral("添加…"), sec->content());
    auto *remove = mkTextBtn(QStringLiteral("移除"), sec->content());
    auto *rescan = mkTextBtn(QStringLiteral("重新扫描"), sec->content());
    row->addWidget(add);
    row->addWidget(remove);
    row->addWidget(rescan);
    auto *cancel = mkTextBtn(QStringLiteral("取消扫描"), sec->content());
    row->addWidget(cancel);
    connect(cancel, &TTButton::clicked, this, [this] { m_main->cancelLibraryScan(); });
    row->addStretch();
    f->addLayout(row);

    connect(add, &TTButton::clicked, this, [this] {
        const QString dir = QFileDialog::getExistingDirectory(this, QStringLiteral("选择音乐文件夹"));
        if (dir.isEmpty()) return;
        m_main->addLibraryFolder(dir);
        m_folders->addItem(dir);
    });
    connect(remove, &TTButton::clicked, this, [this] {
        const int rowIdx = m_folders->currentRow();
        if (rowIdx < 0) return;
        const QString path = m_folders->rowText(rowIdx);
        m_main->removeLibraryFolder(path);
        m_folders->removeRow(rowIdx);
    });
    connect(rescan, &TTButton::clicked, this, [this] { m_main->rescanLibrary(); });
    auto *relocate = mkTextBtn(QStringLiteral("重新定位目录…"), sec->content());
    f->addWidget(relocate);
    connect(relocate, &TTButton::clicked, this, [this] {
        const int row = m_folders->currentRow();
        if (row < 0) return;
        const QString old = m_folders->rowText(row);
        const QString path = QFileDialog::getExistingDirectory(this, QStringLiteral("选择搬迁后的音乐目录"));
        if (path.isEmpty()) return;
        const QString error = m_main->relocateLibraryRoot(old, path);
        if (!error.isEmpty())
            QMessageBox::information(this, QStringLiteral("重新定位"), error);
        else {
            m_folders->clear();
            for (const QString &root : m_main->libraryFolders())
                m_folders->addItem(root);
        }
    });
    auto *status = new QLabel(sec->content());
    status->setWordWrap(true);
    f->addWidget(status);
    v->addWidget(sec, 1);
    v->addWidget(new QLabel(QStringLiteral("最近扫描 / 导入拒收明细（可选择复制）"), page));
    auto *details = new QPlainTextEdit(page);
    details->setObjectName(QStringLiteral("libraryProblems"));
    details->setReadOnly(true);
    details->setFrameShape(QFrame::NoFrame);
    details->setFont(Fonts::base);
    details->setMinimumHeight(80);
    details->setPlaceholderText(QStringLiteral("没有拒收明细"));
    details->setHorizontalScrollBarPolicy(Qt::ScrollBarAlwaysOff);
    v->addWidget(details, 1);
    auto *bar = details->verticalScrollBar();
    const int barWidth = bar->sizeHint().width();
    const int minHandle = bar->style()->pixelMetric(QStyle::PM_ScrollBarSliderMin, nullptr, bar);
    const auto updateStyle = [details, bar, barWidth, minHandle] {
        details->setStyleSheet(QStringLiteral("QPlainTextEdit{background:transparent;color:%1;border:none;}")
                                   .arg(Theme::inkOnGlass.name()));
        details->setAutoFillBackground(false);
        details->viewport()->setAutoFillBackground(false);
        QColor handle = Theme::inkOnGlassSoft;
        handle.setAlphaF(GlassStyle::enabled() ? GlassStyle::glassAlpha() : 1.0f);
        bar->setStyleSheet(
            QStringLiteral(
                "QScrollBar:vertical{background:transparent;width:%1px;margin:0;border:none;}"
                "QScrollBar::handle:vertical{background:rgba(%2,%3,%4,%5);border-radius:3px;min-height:%6px;}"
                "QScrollBar::add-line:vertical,QScrollBar::sub-line:vertical{height:0;background:transparent;}"
                "QScrollBar::add-page:vertical,QScrollBar::sub-page:vertical{background:transparent;}")
                .arg(barWidth)
                .arg(handle.red())
                .arg(handle.green())
                .arg(handle.blue())
                .arg(handle.alpha())
                .arg(minHandle));
        bar->setAutoFillBackground(false);
    };
    connect(&GlassNotifier::instance(), &GlassNotifier::changed, details, updateStyle);
    updateStyle();
    // 缓存正文快照，空闲轮询不会重排长报告或丢掉滚动位置、选择区。
    status->setText(m_main->operationStatus());
    details->setPlainText(m_main->operationProblems());
    const auto updateReport = [this, status, details, last = m_main->operationProblems()]() mutable {
        status->setText(m_main->operationStatus());
        const QString report = m_main->operationProblems();
        if (last == report) return;
        last = report;
        details->setPlainText(report);
    };
    auto *timer = new QTimer(status);
    timer->setInterval(250);
    connect(timer, &QTimer::timeout, status, updateReport);
    timer->start();
    return page;
}
