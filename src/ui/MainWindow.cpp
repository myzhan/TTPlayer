#include "MainWindow.h"
#include "AppIcon.h"
#include "PlayerKeys.h"
#include "SpectrumView.h"
#include "TransportBar.h"
#include "PlaylistWindow.h"
#include "EqWindow.h"
#include "LyricWindow.h"
#include "CoverWindow.h"
#include "PropertyWindow.h"
#include "ConvertWindow.h"
#include "SkinDock.h"
#include "SettingsWindow.h"
#include "media/CoverArt.h"
#include "media/CueSheet.h"
#include "library/LibraryStore.h"
#include "media/PlaylistM3U.h"
#include "library/Importer.h"
#include <QtConcurrent/QtConcurrentRun>
#include <QFutureWatcher>
#include "models/RadioPresets.h"
#include "models/ReplayGain.h"
#include "media/Archive.h"
#include "Painter.h"
#include "Theme.h"
#include "SkinParts.h"
#include "media/Decoder.h"
#include "media/FFmpeg.h"

#include <QVBoxLayout>
#include <QHBoxLayout>
#include <QLabel>
#include <QWidget>
#include <QPainter>
#include <QPixmap>
#include <QTimer>
#include <QPaintEvent>
#include <algorithm>
#include <QPainterPath>
#include <QLinearGradient>
#include <QFileDialog>
#include <QInputDialog>
#include <QDialog>
#include <QDialogButtonBox>
#include <QFormLayout>
#include <QMessageBox>
#include <QLineEdit>
#include <QFileInfo>
#include <QDir>
#include <QSystemTrayIcon>
#include <QDirIterator>
#include <QFileSystemWatcher>
#include <QUrl>
#include <QHash>
#include <cmath>
#include <memory>
#include <QDropEvent>
#include <QMimeData>
#include <QMouseEvent>
#include <QWindow>
#include "SkinWidgets.h"
#include <QShortcut>
#include <QKeySequence>
#include <functional>
#include <QGuiApplication>
#include <QScreen>
#include <QCloseEvent>
#include <QShowEvent>
#ifdef Q_OS_WIN
#include <windows.h>
#endif

// 无边框主窗外壳圆角半径（px）：mask 与自绘壳用同一个值，轮廓与描边对齐。
// 4px 布局内边距让子控件方角落在圆弧内侧，不致露出直角。
static constexpr qreal kSkinRadius = 10.0;

// 皮肤布局版本（R20）：改窗口尺寸 / 面板划分时递增，旧档几何一次性丢弃回到紧凑默认。
// 旧档 skinLayoutVersion=6 的度量不同，取 7 表示「首次 Qt 布局」。
static constexpr int kSkinLayoutVersion = 7;

namespace {

// Windows 的工具面板归属主窗，主窗最小化/恢复时由系统收起/带回；其他平台保留原关系。
QWidget *panelOwner(QWidget *mainWindow) {
#ifdef Q_OS_WIN
    return mainWindow;
#else
    Q_UNUSED(mainWindow)
    return nullptr;
#endif
}

bool pathWithinRoot(const QString &path, const QString &root) {
    if (path.isEmpty() || root.isEmpty()) return false;
    const QString relative = QDir(root).relativeFilePath(path);
    return !QDir::isAbsolutePath(relative) && relative != QLatin1String("..") &&
           !relative.startsWith(QLatin1String("../"));
}

// 添加与编辑共用一张表单；确认前不改变集合，取消时整组字段一起丢弃。
std::optional<Track> promptRadioInfo(QWidget *parent, const Track &current = {}) {
    const bool adding = current.isNull();
    QDialog dialog(parent);
    dialog.setObjectName(QStringLiteral("radioInfoDialog"));
    dialog.setWindowTitle(adding ? QStringLiteral("添加网络电台") : QStringLiteral("编辑显示信息"));
    auto *root = new QVBoxLayout(&dialog);
    auto *form = new QFormLayout();
    auto field = [&](const char *name, const QString &label, const QString &value) {
        auto *edit = new QLineEdit(value, &dialog);
        edit->setObjectName(QString::fromLatin1(name));
        form->addRow(label, edit);
        return edit;
    };
    auto *address = field("radioAddress", QStringLiteral("电台地址（http / https）"),
                          adding ? QString() : current.url().toString());
    address->setReadOnly(!adding);
    auto *title = field("radioTitle", QStringLiteral("标题 / 台名"), adding ? QString() : current.title());
    title->setMaxLength(RadioStations::aliasLimit);
    title->setPlaceholderText(QStringLiteral("留空使用内置台名或地址"));
    auto *artist = field("radioArtist", QStringLiteral("艺术家"), adding ? QString() : current.artist());
    auto *album = field("radioAlbum", QStringLiteral("专辑"), adding ? QString() : current.album());
    root->addLayout(form);
    auto *error = new QLabel(&dialog);
    error->setObjectName(QStringLiteral("radioAddressError"));
    error->setWordWrap(true);
    root->addWidget(error);
    auto *buttons = new QDialogButtonBox(QDialogButtonBox::Ok | QDialogButtonBox::Cancel, &dialog);
    root->addWidget(buttons);
    QObject::connect(buttons, &QDialogButtonBox::rejected, &dialog, &QDialog::reject);
    QObject::connect(buttons, &QDialogButtonBox::accepted, &dialog, [&] {
        if (RadioURL::normalize(address->text()).isEmpty()) {
            error->setText(QStringLiteral("请输入有效的 HTTP / HTTPS 电台地址"));
            address->setFocus();
            return;
        }
        dialog.accept();
    });
    if (dialog.exec() != QDialog::Accepted) return std::nullopt;
    Track result = Track::fromRadio(RadioURL::normalize(address->text()));
    result.setTitle(title->text().trimmed());
    result.setArtist(artist->text().trimmed());
    result.setAlbum(album->text().trimmed());
    return result;
}

// L/R 电平表：从引擎无锁读本窗峰值，自己做峰保持 + 衰减（参考图右侧那两短条）。
// 只在可见时重绘（隐/遮挡时 update 不触发 paint，timer 空转代价极小）。
class LevelMeter : public QWidget {
public:
    explicit LevelMeter(AudioEngine *eng, QWidget *parent = nullptr) : QWidget(parent), m_eng(eng) {
        setObjectName(QStringLiteral("levelMeter"));
        setFixedSize(72, 40);
        // L/R 单独使用小字号，沿用现有拉丁字体及 Windows 减 1 pt 的规则。
        QFont labelFont = Fonts::numericTiny;
        labelFont.setPointSize(qMax(1, labelFont.pointSize() - 2));
        setFont(labelFont);
        setAttribute(Qt::WA_TransparentForMouseEvents, true);
    }
    void advanceFrame() {
        float l = 0, r = 0;
        m_eng->levels(l, r);
        // 先做一阶低通再峰保持：逐窗峰值不再直接顶到柱体，回落也比上升慢（视觉上更稳）。
        m_levelL = smoothed(m_levelL, l, 0.42f, 0.14f);
        m_levelR = smoothed(m_levelR, r, 0.42f, 0.14f);
        float nextL = std::max(m_levelL, m_holdL * 0.90f);
        float nextR = std::max(m_levelR, m_holdR * 0.90f);
        // 收到底就归零，安静时不再每帧都改像素
        if (nextL < 0.002f) nextL = 0.0f;
        if (nextR < 0.002f) nextR = 0.0f;
        if (nextL == m_holdL && nextR == m_holdR) return;
        m_holdL = nextL;
        m_holdR = nextR;
        // Labels and outlines are static, only invalidate the two bar interiors.
        update(QRect(17, 8, width() - 20, 24));
    }

protected:
    void paintEvent(QPaintEvent *) override {
        QPainter p(this);
        p.setRenderHint(QPainter::TextAntialiasing, true);
        drawBar(p, QRectF(16, 7, width() - 18, 9), m_holdL, QStringLiteral("L"));
        drawBar(p, QRectF(16, 24, width() - 18, 9), m_holdR, QStringLiteral("R"));
    }

private:
    /// 一阶低通：上升和回落各用一个系数；差得很小就吸附，避免无穷小的逐帧变化
    static float smoothed(float current, float target, float attack, float release) {
        if (std::abs(target - current) < 0.0015f) return target;
        return current + (target - current) * (target > current ? attack : release);
    }

    void drawBar(QPainter &p, const QRectF &track, float v, const QString &lab) {
        // 统一毛玻璃：电平表落在深玻璃上，轨道/标签走亮墨色；柱体经典绿/削峰红。
        p.setPen(QPen(Theme::inkOnGlassSoft, 1));
        p.setBrush(Qt::NoBrush);
        p.drawRect(track);
        const float w = qBound(0.0f, v, 1.0f) * float(track.width() - 2);
        p.fillRect(QRectF(track.left() + 1, track.top() + 1, w, track.height() - 2),
                   v > 0.98f ? Theme::meterRed : Theme::meterGreen);
        p.setPen(Theme::inkOnGlassSoft);
        // 标签与电平条中心对齐，但不再挤进仅 9 px 高的条内绘制区。
        p.drawText(QRectF(0, track.center().y() - 8, 14, 16), Qt::AlignCenter, lab);
    }
    AudioEngine *m_eng;
    float m_levelL = 0.0f, m_levelR = 0.0f; // 平滑后的电平
    float m_holdL = 0.0f, m_holdR = 0.0f;
};

// Track → 可往返 token（R04）：CUE 分轨用 identityKey `<sheet>#track=N`（url 会丢轨号），
// 其余用 url 串（普通 file:// / 电台 http / 归档 file://…#archive-entry=）；restore 侧 Collections::resolveToken 还原。
QString trackToken(const Track &t) {
    return t.isCueSegment() ? t.identityKey() : t.url().toString();
}

// 统一元数据落回：title/artist/album 取容器标签
// （FFmpeg 已归一小写）；单曲艺人缺失时退回整盘艺人（album_artist/composer）。空标签不覆盖
// 已有值，留给文件名 / CUE 兜底。
struct RestoredLibraryData {
    QList<Track> defaults, all;
};

// 渐变条：标题条（浅玻璃壳）与显示槽底部条（深玻璃）共用，alpha 从 GlassStyle 取。
class GradientBar : public QWidget {
public:
    QColor top, bottom, edge;
    qreal radius = 0;
    bool gloss = false;
    bool draggable = false; // 仅标题条置真：无边框窗靠它拖动

    explicit GradientBar(QWidget *parent = nullptr) : QWidget(parent) {
        connect(&GlassNotifier::instance(), &GlassNotifier::changed, this, [this] { update(); });
    }

protected:
    void paintEvent(QPaintEvent *) override {
        QPainter p(this);
        float a = GlassStyle::glassAlpha();
        if (!GlassStyle::enabled()) a = 1.0f;
        Painter::drawBody(&p, QRectF(rect()), top, bottom, a, radius, edge, gloss);
    }

    // 无边框窗没有原生标题栏可拖：按下标题条空白处交给系统移动整窗
    //（startSystemMove 会连续吃掉拖拽并发 Move 事件，SkinDock 据此整组跟随）
    void mousePressEvent(QMouseEvent *e) override {
        if (draggable && e->button() == Qt::LeftButton) {
            if (auto *wh = window()->windowHandle(); wh && wh->startSystemMove()) {
                QWidget::mousePressEvent(e);
                return;
            }
        }
        QWidget::mousePressEvent(e);
    }
};

// 封面格：有封面贴缩略图，无封面画一张光盘；点击回调交给主窗开大图窗
class CoverBox : public QWidget {
public:
    explicit CoverBox(QWidget *parent = nullptr) : QWidget(parent) {
        setFixedSize(56, 56);
        setCursor(Qt::PointingHandCursor);
        connect(&GlassNotifier::instance(), &GlassNotifier::changed, this, [this] { update(); });
    }

    void setImage(const QImage &img) {
        m_image = img;
        update();
    }
    std::function<void()> onClick;

protected:
    void paintEvent(QPaintEvent *) override {
        QPainter p(this);
        p.setRenderHint(QPainter::Antialiasing, true);
        const QRectF r = QRectF(rect()).adjusted(0.5, 0.5, -0.5, -0.5);
        QPainterPath path;
        path.addRoundedRect(r, 3, 3);
        if (!m_image.isNull()) {
            const QImage scaled = m_image.scaled(size(), Qt::KeepAspectRatioByExpanding, Qt::SmoothTransformation);
            QRectF ir(0, 0, scaled.width(), scaled.height());
            ir.moveCenter(r.center());
            p.setClipPath(path);
            p.drawImage(ir.topLeft(), scaled);
            p.setClipping(false);
            p.setBrush(Qt::NoBrush);
            p.setPen(QPen(Theme::hairline, 1));
            p.drawPath(path);
            return;
        }
        // 无封面：与壳同调的深玻璃底 + 发丝边，光盘图形作占位（中性银灰，不再走蓝调）。
        QLinearGradient g(r.topLeft(), r.bottomLeft());
        g.setColorAt(0.0, Theme::windowTop);
        g.setColorAt(1.0, Theme::windowBottom);
        p.fillPath(path, g);
        p.setBrush(Qt::NoBrush);
        p.setPen(QPen(Theme::hairline, 1));
        p.drawPath(path);
        // 光盘
        const QRectF disc = r.adjusted(7, 7, -7, -7);
        p.setPen(Qt::NoPen);
        p.setBrush(QColor(0xC4, 0xC8, 0xCC, 235));
        p.drawEllipse(disc);
        p.setBrush(QColor(0x86, 0x8C, 0x92, 200));
        p.drawEllipse(
            disc.adjusted(disc.width() * 0.22, disc.width() * 0.22, -disc.width() * 0.22, -disc.width() * 0.22));
        p.setBrush(Theme::textAccent);
        p.drawEllipse(disc.center(), 2.5, 2.5);
    }

    void mousePressEvent(QMouseEvent *e) override {
        if (e->button() == Qt::LeftButton && onClick) onClick();
        QWidget::mousePressEvent(e);
    }

private:
    QImage m_image;
};

} // namespace

MainWindow::MainWindow(PlayerController *controller, AudioEnginePtr engine, QWidget *parent)
    : QWidget(parent), m_controller(controller), m_engine(std::move(engine)) {
    setWindowTitle(QStringLiteral("千千静听"));
    // 无边框：主窗自绘了主题标题栏，不能再挂原生标题栏（否则叠成两条、又高又丑）。
    // 拖动靠标题条 startSystemMove，缩放靠下面 mousePressEvent 的 startSystemResize。
    setWindowFlags(Qt::Window | Qt::FramelessWindowHint);
    // 真透明背景：让自绘壳的半透明渐变（GlassStyle.transparency）真正透出桌面，
    // 而不是画在不透明 backing 上白搭。圆角也顺势由 drawBody 的圆角裁剪自然形成
    //（圆弧外不绘制→透明），无需 setMask（那会把边缘切成锯齿、又与真透明冲突）。
    setAttribute(Qt::WA_TranslucentBackground, true);
    setMinimumWidth(420);
    resize(460, 206); // 紧凑默认宽（主窗自身布局下限≈449），与列表/均衡器同一基准
    setAcceptDrops(true);
    setMouseTracking(true); // 未按键也收 move 事件，边缘光标才能提前变缩放形状

    auto *root = new QVBoxLayout(this);
    root->setContentsMargins(4, 4, 4, 6);
    root->setSpacing(3);

    // —— 标题条（浅玻璃壳）——
    auto *titleBar = new GradientBar(this);
    titleBar->top = Theme::titleTop;
    titleBar->bottom = Theme::titleBottom;
    titleBar->edge = Theme::skinEdge;
    titleBar->gloss = true;
    titleBar->draggable = true; // 无边框窗：拖这条移动整窗
    titleBar->setFixedHeight(22);
    auto *tl = new QHBoxLayout(titleBar);
    tl->setContentsMargins(8, 1, 4, 1);
    tl->setSpacing(3);
    // 品牌图标与窗口、托盘和发布包共用同一枚耳机。
    auto *brandIcon = new QLabel(titleBar);
    brandIcon->setObjectName(QStringLiteral("appIcon"));
    brandIcon->setPixmap(AppIcon::icon().pixmap(QSize(16, 16), devicePixelRatioF()));
    brandIcon->setFixedSize(16, 16);
    brandIcon->setStyleSheet(QStringLiteral("background:transparent;"));
    auto *brand = new QLabel(QStringLiteral("千千静听"), titleBar);
    brand->setFont(Fonts::panelTitle);
    brand->setStyleSheet(QStringLiteral("color:%1;background:transparent;").arg(Theme::titleText.name()));
    // 播放方式徽章：随 controller.modeChanged 刷新（对齐参考图 [列表循环]）
    m_modeBadge = new QLabel(titleBar);
    m_modeBadge->setFont(Fonts::small);
    m_modeBadge->setStyleSheet(QStringLiteral("color:%1;background:transparent;").arg(Theme::titleText.name()));
    updateModeBadge();
    auto *openBtn = new TTButton(titleBar);
    openBtn->setGlyph(Skin::Glyph::Menu);
    openBtn->setFace(TTButton::Face::Glass);
    openBtn->setPreferredSize({22, 18});
    openBtn->setObjectName(QStringLiteral("mainSettings"));
    openBtn->setToolTip(QStringLiteral("设置…"));
    m_pin = new TTButton(titleBar);
    m_pin->setGlyph(Skin::Glyph::Pin);
    m_pin->setFace(TTButton::Face::Glass);
    m_pin->setCheckable(true);
    m_pin->setPreferredSize({22, 18});
    m_pin->setToolTip(QStringLiteral("置顶窗口"));
    connect(m_pin, &QAbstractButton::toggled, this, &MainWindow::togglePinTop);
    auto *hideBtn = new TTButton(titleBar);
    hideBtn->setObjectName(QStringLiteral("mainMinimize"));
    hideBtn->setGlyph(Skin::Glyph::Minus);
    hideBtn->setFace(TTButton::Face::Glass);
    hideBtn->setPreferredSize({22, 18});
    hideBtn->setToolTip(QStringLiteral("最小化"));
    auto *closeBtn = new TTButton(titleBar);
    closeBtn->setGlyph(Skin::Glyph::Close);
    closeBtn->setFace(TTButton::Face::Glass);
    closeBtn->setPreferredSize({22, 18});
    closeBtn->setToolTip(QStringLiteral("关闭"));
    tl->addWidget(brandIcon);
    tl->addWidget(brand);
    tl->addWidget(m_modeBadge);
    tl->addStretch();
    tl->addWidget(openBtn);
    tl->addWidget(m_pin);
    tl->addWidget(hideBtn);
    tl->addWidget(closeBtn);
    root->addWidget(titleBar);
    connect(m_controller, &PlayerController::modeChanged, this, &MainWindow::updateModeBadge);

    // —— 显示大槽 ——
    auto *well = new WellView(this);
    well->setDark(true);
    well->setCornerRadius(5);
    auto *wl = new QVBoxLayout(well);
    wl->setContentsMargins(6, 5, 6, 4);
    wl->setSpacing(2);

    m_marquee = new QLabel(QStringLiteral("千千静听 复刻版"), well);
    m_marquee->setFont(Fonts::title);
    m_marquee->setStyleSheet(QStringLiteral("color:%1;background:transparent;").arg(Theme::inkOnGlass.name()));
    m_marquee->setWordWrap(false);
    m_channel = new QLabel(QStringLiteral("立体声"), well);
    m_channel->setFont(Fonts::small);
    m_channel->setAlignment(Qt::AlignRight | Qt::AlignVCenter);
    m_channel->setFixedWidth(76);
    m_channel->setStyleSheet(QStringLiteral("color:%1;background:transparent;").arg(Theme::inkOnGlassAccent.name()));
    auto *row1 = new QHBoxLayout();
    row1->setContentsMargins(0, 0, 0, 0);
    row1->addWidget(m_marquee, 1);
    row1->addWidget(m_channel);

    m_status = new QLabel(QStringLiteral("状态: 停止"), well);
    m_status->setFont(Fonts::small);
    m_status->setAlignment(Qt::AlignRight | Qt::AlignVCenter);
    m_status->setStyleSheet(QStringLiteral("color:%1;background:transparent;").arg(Theme::inkOnGlassSoft.name()));
    m_codec = new QLabel(QStringLiteral("拖入文件开始播放"), well);
    m_codec->setFont(Fonts::tiny);
    m_codec->setAlignment(Qt::AlignRight | Qt::AlignVCenter);
    m_codec->setWordWrap(false);
    m_codec->setStyleSheet(QStringLiteral("color:%1;background:transparent;").arg(Theme::inkOnGlassSoft.name()));

    wl->addLayout(row1);

    wl->addWidget(m_status);
    wl->addWidget(m_codec);

    auto *midRow = new QHBoxLayout();
    midRow->setContentsMargins(0, 0, 0, 0);
    midRow->setSpacing(8);
    m_cover = new CoverBox(well);
    static_cast<CoverBox *>(m_cover)->onClick = [this] { toggleCoverPanel(); };
    m_spectrum = new SpectrumView(m_engine, well);
    m_spectrum->setMinimumHeight(40);
    midRow->addWidget(m_cover);
    midRow->addWidget(m_spectrum, 1);
    auto *meter = new LevelMeter(m_engine.get(), well);
    connect(m_spectrum, &SpectrumView::frameRequested, meter, &LevelMeter::advanceFrame);
    midRow->addWidget(meter);
    wl->addLayout(midRow, 1);

    // 底部条（与壳同调的浅玻璃）：音量 · 静音 · 传输带 ·（列表/均衡器/歌词）
    auto *strip = new GradientBar(well);
    strip->top = Theme::windowTop;
    strip->bottom = Theme::windowBottom;
    strip->edge = Theme::skinEdge;
    strip->radius = 4;
    strip->setFixedHeight(26);
    auto *sl = new QHBoxLayout(strip);
    sl->setContentsMargins(4, 2, 4, 2);
    sl->setSpacing(3);
    m_volume = new VolumeSlider(strip);
    m_volume->setFixedWidth(96);
    m_mute = new TTButton(strip);
    m_mute->setGlyph(Skin::Glyph::Volume);
    m_mute->setFace(TTButton::Face::Glass);
    m_mute->setPreferredSize({24, 20});
    m_mute->setToolTip(QStringLiteral("静音"));
    m_transport = new TransportBar(m_controller, strip);
    auto makeText = [&](const QString &t, int w) {
        auto *b = new TTButton(strip);
        b->setTextLabel(t);
        b->setFace(TTButton::Face::Glass);
        b->setPreferredSize({w, 20});
        return b;
    };
    m_list = makeText(QStringLiteral("列表"), 34);
    m_eq = makeText(QStringLiteral("均衡器"), 42);
    m_lyric = makeText(QStringLiteral("歌词"), 34);
    m_list->setToolTip(QStringLiteral("播放列表"));
    m_eq->setToolTip(QStringLiteral("均衡器"));
    m_lyric->setToolTip(QStringLiteral("歌词"));
    sl->addWidget(m_volume);
    sl->addWidget(m_mute);
    sl->addWidget(m_transport);
    sl->addStretch();
    sl->addWidget(m_list);
    sl->addWidget(m_eq);
    sl->addWidget(m_lyric);
    wl->addWidget(strip);

    root->addWidget(well, 1);

    // —— 独立进度行 ——
    m_seek = new TimeSlider(this);
    m_seek->setFixedHeight(16);
    root->addWidget(m_seek);

    // —— 接线 ——
    connect(openBtn, &TTButton::clicked, this, &MainWindow::openSettings);
    connect(hideBtn, &TTButton::clicked, this, &MainWindow::hideGroupToBackground);
    connect(closeBtn, &TTButton::clicked, qApp, &QCoreApplication::quit); // R19：× 直退进程

    connect(m_volume, &VolumeSlider::valueChanged, this, [this](double v) {
        m_vol = v;
        if (m_muted && v > 0) {
            m_muted = false;
            m_volume->setMuted(false);
        }
        applyVolume();
    });
    connect(m_mute, &TTButton::clicked, this, [this] {
        m_muted = !m_muted;
        m_volume->setMuted(m_muted);
        applyVolume();
    });
    connect(m_seek, &TimeSlider::seekRatio, this, [this](double r) {
        const double dur = m_controller->duration();
        if (dur > 0) m_controller->seekTo(r * dur);
    });
    connect(m_list, &TTButton::clicked, this, [this] { togglePlaylistPanel(); });
    connect(m_eq, &TTButton::clicked, this, [this] { toggleEqPanel(); });
    connect(m_lyric, &TTButton::clicked, this, [this] { toggleLyricPanel(); });

    connect(m_controller, &PlayerController::trackChanged, this, [this] {
        // F06 最近播放/最近听的台：开播即记一笔（trackChanged 只在装载/播放路径发，
        // 不会被单纯选中行误触；touch 幂等，重播同一首只把它提到最前）。
        const Track cur = m_controller->currentTrack();
        if (!cur.isNull()) {
            m_collections.recordPlay(cur.identityKey());
            if (cur.isRadio()) m_collections.recordRadioPlay(cur.identityKey());
        }
        syncNowPlaying();
        syncState();
    });
    connect(m_controller, &PlayerController::listChanged, this, &MainWindow::syncNowPlaying);
    connect(m_controller, &PlayerController::playbackStateChanged, this, [this] {
        syncState();
        writeResume();
    });
    auto *sceneTimer = new QTimer(this);
    sceneTimer->setInterval(5000);
    connect(sceneTimer, &QTimer::timeout, this, &MainWindow::writeResume);
    sceneTimer->start();
    connect(m_controller, &PlayerController::positionTicked, this,
            [this](double pos, double dur) { m_seek->setProgress(dur > 0 ? pos / dur : 0.0); });

    m_engine->setVolume(m_vol);
    m_volume->setValue(m_vol);
    applyVolume();
    loadState(); // 玻璃/音量/均衡/模式/几何从 state.db 恢复
    syncNowPlaying();
    syncState();

    // R09：曲库文件夹自动监听（文件系统事件的 Qt 等价）。QFileSystemWatcher 只报
    // 目录级增删改，非递归，故 updateLibraryWatch 要把子目录一并挂上；改动经防抖定时器合并
    // 成一次 rescanLibrary（增量 diff 保留手工项/电台/播放现场，setTracks 不碰队列）。
    m_rescanTimer = new QTimer(this);
    m_rescanTimer->setSingleShot(true);
    m_rescanTimer->setInterval(700);
    connect(m_rescanTimer, &QTimer::timeout, this, [this] {
        rescanLibrary();
        updateLibraryWatch(); // 重扫后目录树可能变了，重新挂监听
        saveState();
    });
    m_libWatcher = new QFileSystemWatcher(this);
    connect(m_libWatcher, &QFileSystemWatcher::directoryChanged, this, [this](const QString &) { onLibraryChanged(); });
    updateLibraryWatch();

    // 键盘加速键（Cmd 组合）：只在主窗获得焦点时生效，
    // 不抢其它窗（搜索框/对话框）的键入。窗口开关复用底部条按钮的 click()，与鼠标同一条懒建通路。
    auto sc = [this](QKeySequence k, std::function<void()> fn) {
        auto *s = new QShortcut(k, this);
        s->setContext(Qt::ApplicationShortcut);
        connect(s, &QShortcut::activated, this, [fn = std::move(fn)] { fn(); });
    };
    sc(QKeySequence(Qt::CTRL | Qt::Key_Space), [this] { m_controller->togglePlay(); });
    sc(QKeySequence(Qt::CTRL | Qt::Key_1), [this] { m_list->click(); });
    sc(QKeySequence(Qt::CTRL | Qt::Key_E), [this] { m_eq->click(); });
    sc(QKeySequence(Qt::CTRL | Qt::Key_L), [this] { m_lyric->click(); });
    sc(QKeySequence(Qt::CTRL | Qt::Key_O), [this] { openFiles(); });
    sc(QKeySequence(Qt::CTRL | Qt::Key_D), [this] { toggleFavoriteCurrent(); });
    sc(QKeySequence(Qt::CTRL | Qt::Key_F), [this] {
        if (!m_playlist || !m_playlist->isVisible()) m_list->click(); // 先开窗
        if (m_playlist) m_playlist->focusSearch();
    });
    new PlayerKeys(this);
}

void MainWindow::applyVolume() {
    m_engine->setVolume(m_muted ? 0.0 : m_vol);
    m_mute->setGlyph(m_muted ? Skin::Glyph::Mute : Skin::Glyph::Volume);
    m_mute->setLit(m_muted);
}

MainWindow::~MainWindow() {
    if (m_watchCancel) m_watchCancel->store(true);
    if (m_importCancel) m_importCancel->store(true);
    if (m_restoreCancel) m_restoreCancel->store(true);
    cancelLibraryScan();
    m_sceneReady = false;
    delete m_dock;
    m_dock = nullptr;
    m_dockReady = false;
    const auto group = groupWindows();
    for (const auto &panel : group) {
        if (panel && panel != this) {
            QObject::disconnect(panel, nullptr, this, nullptr);
            delete panel.data();
        }
    }
    m_auxiliaryWindows.clear();
    m_groupBeforeHide.clear();
    m_playlist = nullptr;
    m_eqWindow = nullptr;
    m_lyricWindow = nullptr;
    m_coverWindow = nullptr;
}
void MainWindow::toggleMute() {
    m_mute->click();
}

void MainWindow::setUserVolume(double volume) {
    m_vol = std::clamp(volume, 0.0, 1.0);
    m_muted = false;
    m_volume->setValue(m_vol);
    m_volume->setMuted(false);
    applyVolume();
    saveState();
}

// Cmd+D 与行内爱心复用集合层及页面刷新，不重建播放上下文。
void MainWindow::toggleFavoriteCurrent() {
    const Track t = m_controller->currentTrack();
    if (t.isNull()) return;
    m_collections.toggleFavorite(t.identityKey());
    if (m_playlist) m_playlist->refreshFavorites();
    saveState();
}

// 标题条播放方式徽章：把当前 PlayMode 映射成中文短标签，包在方括号里。
void MainWindow::updateModeBadge() {
    if (!m_modeBadge) return;
    QString name;
    switch (m_controller->mode()) {
    case PlayMode::Order:
        name = QStringLiteral("顺序播放");
        break;
    case PlayMode::ListLoop:
        name = QStringLiteral("列表循环");
        break;
    case PlayMode::SingleLoop:
        name = QStringLiteral("单曲循环");
        break;
    case PlayMode::Random:
        name = QStringLiteral("随机播放");
        break;
    }
    m_modeBadge->setText(QStringLiteral("[%1]").arg(name));
}

// Windows 的 QWindow::setFlags 会重写扩展样式，先移除再恢复 WS_EX_LAYERED，
// 破坏透明窗的合成表面；原生置顶只改层级，不隐藏、不重建、不改 owner。
// 其他平台沿用 QWindow 就地改 flags，未建平台窗时才写 QWidget flags。
void MainWindow::setWindowPinTop(QWidget *w, bool on) {
    if (!w) return;
#ifdef Q_OS_WIN
    if (QGuiApplication::platformName() == QStringLiteral("windows")) {
        // 首次置顶隐藏面板时先建 HWND，不把 hint 留在 Qt flags 中，避免重开恢复旧 hint。
        if (!on && !w->internalWinId()) return;
        const HWND hwnd = reinterpret_cast<HWND>(w->winId());
        if (IsWindow(hwnd) && ((GetWindowLongPtrW(hwnd, GWL_EXSTYLE) & WS_EX_TOPMOST) != 0) == on) return;
        if (!SetWindowPos(hwnd, on ? HWND_TOPMOST : HWND_NOTOPMOST, 0, 0, 0, 0,
                          SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_NOOWNERZORDER)) {
            const DWORD error = GetLastError();
            m_status->setText(QStringLiteral("窗口置顶切换失败（%1）").arg(error));
            qWarning("窗口置顶切换失败（%lu）", static_cast<unsigned long>(error));
        }
        return;
    }
#endif
    QWindow *win = w->windowHandle();
    // QWindow 的就地修改不会同步 QWidget flags，判等读平台窗记录。
    const Qt::WindowFlags cur = win ? win->flags() : w->windowFlags();
    if (cur.testFlag(Qt::WindowStaysOnTopHint) == on) return;
    Qt::WindowFlags f = cur;
    f.setFlag(Qt::WindowStaysOnTopHint, on);
    if (win)
        win->setFlags(f);
    else
        w->setWindowFlags(f);
}

// 置顶：用户置顶 = 整组置顶。主窗、可见副面板及辅助窗一起 stays-on-top；
// 置顶之后才打开的窗在各自 show 点用 setWindowPinTop 继承当前置顶态（见各按钮 handler）。
void MainWindow::togglePinTop(bool on) {
    m_pinTop = on; // 先记权威态，置顶后新开的窗据此继承
    for (const auto &w : groupWindows())
        if (w && w->isVisible()) setWindowPinTop(w, on);
}

// 面板开合（标题/底部按钮与无头探针共用同一条通路）：懒建 + 开/关，显示时继承当前置顶态。
void MainWindow::togglePlaylistPanel() {
    if (!m_playlist) {
        m_playlist = new PlaylistWindow(m_controller, &m_collections, panelOwner(this));
        m_playlist->setEnabled(!m_restoringLibrary);
        connect(m_playlist, &PlaylistWindow::collectionsChanged, this, [this] {
            m_collections.invalidateIndex();
            saveState();
        });
        // 删掉内置电台 → 记进黑名单，以后启动不再塞回（trackRemoved 先于 collectionsChanged）
        connect(m_playlist, &PlaylistWindow::trackRemoved, this, [this](const Track &t) {
            if (!RadioPresets::nameFor(t.url()).isEmpty()) {
                const QString key = t.identityKey();
                if (!m_declinedRadioKeys.contains(key)) m_declinedRadioKeys << key;
            }
        });
        // 右键「添加文件…」：开文件对话框（与主窗同一条载入通路）
        connect(m_playlist, &PlaylistWindow::addRequested, this, [this] { openFiles(); });
        // 右键「添加文件夹…」：选目录后整棵导入
        connect(m_playlist, &PlaylistWindow::addFolderRequested, this, [this] { openFolder(); });
        // 右键「添加网络电台…」：同时填写地址与显示信息
        connect(m_playlist, &PlaylistWindow::radioRequested, this, [this] { addRadioPrompt(); });
        // 右键「属性」：开曲目属性窗
        connect(m_playlist, &PlaylistWindow::propertiesRequested, this, &MainWindow::openProperties);
        // 右键「转换为其他格式…」：开转换窗（走内嵌 libav*，不开外部进程）
        connect(m_playlist, &PlaylistWindow::convertRequested, this,
                [this](const QList<Track> &tracks) { (new ConvertWindow(tracks, this))->show(); });
        connect(m_playlist, &PlaylistWindow::editRequested, this, &MainWindow::editRadioPrompt);
        auto replace = [this](const Track &old, Track replacement) {
            const QString key = old.identityKey();
            if (!m_collections.replaceKey(key, replacement)) {
                QMessageBox::warning(this, QStringLiteral("无法替换"),
                                     QStringLiteral("目标身份已在列表中，不能覆盖另一个条目"));
                return;
            }
            m_controller->replaceTrackReferences({{key, replacement}});
            if (!RadioPresets::nameFor(old.url()).isEmpty() && !m_declinedRadioKeys.contains(key))
                m_declinedRadioKeys << key;
            const bool gapless = m_controller->gaplessEnabled();
            m_controller->setGaplessEnabled(false);
            m_controller->setGaplessEnabled(gapless);
            m_controller->setTracks(m_collections.currentTracks());
            syncNowPlaying();
            saveState();
        };
        connect(m_playlist, &PlaylistWindow::radioAddressRequested, this, [this, replace](const Track &track) {
            bool ok = false;
            const QString text =
                QInputDialog::getText(this, QStringLiteral("修改电台地址"), QStringLiteral("HTTP / HTTPS 地址"),
                                      QLineEdit::Normal, track.url().toString(), &ok);
            if (!ok) return;
            const QUrl url = RadioURL::normalize(text);
            if (url.isEmpty()) return;
            const bool playing =
                m_controller->isPlaying() && m_controller->currentTrack().identityKey() == track.identityKey();
            replace(track, Track::fromRadio(url));
            if (playing) m_controller->retryRadio();
        });
        connect(m_playlist, &PlaylistWindow::relocateRequested, this, [this, replace](const Track &track) {
            const QString path = QFileDialog::getOpenFileName(this, QStringLiteral("重新定位文件"));
            if (path.isEmpty()) return;
            Track replacement(QUrl::fromLocalFile(path));
            if (track.isCueSegment())
                replacement = Collections::resolveToken(path + QStringLiteral("#track=%1").arg(track.cueNumber()));
            else {
                QString archive, entry;
                if (Archive::parseEntryUrl(track.url(), archive, entry))
                    replacement = Track(Archive::entryUrl(path, entry));
            }
            Importer::probe(replacement);
            if (!replacement.decodeProblem().isEmpty()) return;
            replace(track, replacement);
        });
        if (m_dock) m_dock->registerPanel(SkinDock::Playlist, m_playlist);
    }
    const bool show = !m_playlist->isVisible();
    if (show) {
        m_playlist->refreshGroups();
        setWindowPinTop(m_playlist, m_pinTop);
    }
    m_playlist->setVisible(show); // 显示后 Show 事件→停靠组重排（同宽 + 竖排）
    m_list->setLit(show);
    m_listVisible = show;
}

void MainWindow::toggleEqPanel() {
    if (!m_eqWindow) {
        m_eqWindow = new EqWindow(m_engine, panelOwner(this));
        connect(m_eqWindow, &EqWindow::volumeRequested, this, [this](double value) {
            m_vol = value;
            m_muted = false;
            m_volume->setValue(value);
            m_volume->setMuted(false);
            applyVolume();
        });
        if (m_dock) m_dock->registerPanel(SkinDock::Equalizer, m_eqWindow);
    }
    const bool show = !m_eqWindow->isVisible();
    if (show) {
        m_eqWindow->syncFromEngine();
        setWindowPinTop(m_eqWindow, m_pinTop);
    }
    m_eqWindow->setVisible(show);
    m_eq->setLit(show);
}

void MainWindow::toggleLyricPanel() {
    if (!m_lyricWindow) {
        m_lyricWindow = new LyricWindow(m_controller, panelOwner(this));
        if (m_dock) m_dock->registerPanel(SkinDock::Lyric, m_lyricWindow);
    }
    const bool show = !m_lyricWindow->isVisible();
    if (show) {
        m_lyricWindow->reload();
        setWindowPinTop(m_lyricWindow, m_pinTop);
    }
    m_lyricWindow->setVisible(show); // 显示后 Show 事件→停靠组重排（吸附到组下方）
    m_lyric->setLit(show);
}

void MainWindow::toggleCoverPanel() {
    if (!m_coverWindow) m_coverWindow = new CoverWindow(m_controller, this);
    const bool show = !m_coverWindow->isVisible();
    if (show) {
        m_coverWindow->reload();
        showAuxiliary(m_coverWindow);
    } else {
        m_coverWindow->hide();
    }
}

void MainWindow::openSettings() {
    if (!m_settingsWindow) m_settingsWindow = new SettingsWindow(this, this);
    showAuxiliary(m_settingsWindow);
}

void MainWindow::openProperties(const Track &track) {
    showAuxiliary(new PropertyWindow(track, m_controller, this));
}

void MainWindow::showAuxiliary(QWidget *w) {
    ensureDock();
    m_auxiliaryWindows.removeIf([](const auto &guard) { return guard.isNull(); });
    if (!m_auxiliaryWindows.contains(w)) {
        m_auxiliaryWindows.append(w);
        m_dock->registerAuxiliary(w);
    }
    setWindowPinTop(w, m_pinTop);
    w->showNormal();
    w->raise();
    w->activateWindow();
}

QList<QPointer<QWidget>> MainWindow::groupWindows() const {
    QList<QPointer<QWidget>> out;
    auto add = [&out](QWidget *w) {
        if (w && !out.contains(w)) out.append(w);
    };
    add(const_cast<MainWindow *>(this));
    add(m_playlist);
    add(m_eqWindow);
    add(m_lyricWindow);
    for (const auto &w : m_auxiliaryWindows)
        add(w);
    return out;
}

// 探针与组操作共用去重的安全窗口集合。
int MainWindow::probeGroupVisible() const {
    int n = 0;
    for (const auto &w : groupWindows())
        if (w && w->isVisible()) ++n;
    return n;
}

int MainWindow::probeGroupPinned() const {
    int n = 0;
    for (const auto &w : groupWindows()) {
        if (!w || !w->isVisible()) continue;
#ifdef Q_OS_WIN
        if (QGuiApplication::platformName() == QStringLiteral("windows")) {
            const HWND hwnd = reinterpret_cast<HWND>(w->internalWinId());
            if (IsWindow(hwnd) && (GetWindowLongPtrW(hwnd, GWL_EXSTYLE) & WS_EX_TOPMOST) != 0) ++n;
            continue;
        }
#endif
        // 非 Windows 原生窗口按 QWindow flags 计数，未建窗时回退 QWidget flags。
        QWindow *win = w->windowHandle();
        const Qt::WindowFlags f = win ? win->flags() : w->windowFlags();
        if (f.testFlag(Qt::WindowStaysOnTopHint)) ++n;
    }
    return n;
}

// R19 后台驻留：整组包含已创建的副面板与辅助窗。
// 隐藏时只记住当前可见的那几扇，恢复时只弹回它们（不强制打开本来关着的）。
void MainWindow::hideGroupToBackground() {
    if (m_groupHidden) return;
    // 无托盘平台退化为最小化：否则整组藏起来后没有任何恢复入口（探针可 bypass 走真路径）
    if (!m_groupHideBypassTray && !QSystemTrayIcon::isSystemTrayAvailable()) {
        showMinimized();
        return;
    }
    m_groupBeforeHide.clear();
    for (const auto &w : groupWindows())
        if (w && w->isVisible()) {
            m_groupBeforeHide.append(w);
            w->hide();
        }
    m_groupHidden = true; // 不碰 controller：音频继续播
}

void MainWindow::restoreGroupFromBackground() {
    if (!m_groupHidden) {
        showNormal();
        raise();
        activateWindow();
        return;
    }
    for (const auto &w : std::as_const(m_groupBeforeHide)) {
        if (!w) continue;
        setWindowPinTop(w, m_pinTop);
        w->show();
    }
    m_groupBeforeHide.clear();
    m_groupHidden = false;
    showNormal();
    raise();
    activateWindow();
}

void MainWindow::toggleGroupVisibility() {
    if (m_groupHidden || (!isVisible() && !isMinimized()))
        restoreGroupFromBackground();
    else
        hideGroupToBackground();
}

void MainWindow::loadState() {
    const LibraryStore::Loaded s = LibraryStore::load();
    if (!s.valid) return;
    m_collections.loadFrom(s); // 收藏 / 歌单 / 上次在看的页先恢复（F04/F05）
    GlassStyle::setEnabled(s.glass);
    GlassStyle::setTransparency(float(s.transparency));
    m_vol = s.volume;
    m_muted = s.muted;
    m_volume->setValue(m_vol);
    applyVolume();
    m_controller->setMode(s.mode);
    m_engine->setEQEnabled(s.eqEnabled);
    m_engine->setEQPreamp(s.eqPreGain);
    m_engine->setEQGains(s.eqGains);
    m_autoResumePlay = s.autoResumePlay;
    m_listVisible = s.listVisible;
    m_libraryFolders = s.libraryFolders;
    // 响度均衡设置回放（int ↔ 枚举，越界一律兜底为关）
    const int rm = s.replayGainMode;
    m_controller->setReplayGainMode(rm == 1   ? ReplayGainMode::Track
                                    : rm == 2 ? ReplayGainMode::Album
                                              : ReplayGainMode::Off);
    m_controller->setReplayGainPreamp(s.replayGainPreamp);
    m_controller->setReplayGainPeakLimit(s.replayGainPeakLimit);
    // 本版新增设置回放：歌词校准表 / 无缝 / 睡眠淡出 / 输出设备
    m_controller->setLyricShiftTable(s.lyricShifts);
    m_controller->setGaplessEnabled(s.gaplessPlay);
    m_controller->setSleepFadeEnabled(s.sleepFade);
    m_engine->setOutputDevice(s.outputDeviceUID);
    m_declinedRadioKeys = s.declinedRadioKeys; // 旧档缺这一项 = 空 = 谁也没删过
    // R20：皮肤布局版本迁移。当前窗口度量与旧档（含 600 宽）不同，
    // 版本不符就一次性丢掉 windowFrame/dockFrame，回落到构造函数里的紧凑默认宽（460），
    // 并写回新版本；之后用户手动缩放照常记住。
    QString winFrame = s.windowFrame, dockFrame = s.dockFrame;
    if (s.skinLayout != kSkinLayoutVersion) {
        winFrame.clear();
        dockFrame.clear();
        LibraryStore::Loaded m = s;
        m.skinLayout = kSkinLayoutVersion;
        m.windowFrame.clear();
        m.dockFrame.clear();
        m.panelFrames.clear(); // 停靠模型变了，旧面板几何一并丢弃，回落全默认吸附
        if (!LibraryStore::save(m)) m_persistenceProblem = QStringLiteral("布局迁移保存失败，请检查存储空间和目录权限");
    }
    int x, y, w, h;
    if (LibraryStore::frameFromString(winFrame, x, y, w, h))
        setGeometry(SkinDock::clampToScreens(QRect(x, y, w, h))); // 旧几何可能在屏幕外，夹回可用屏
    m_savedEQVisible = s.eqVisible;
    m_savedFrame = dockFrame; // 停靠组锚点（首次显示时交给 SkinDock 还原，内部同样夹屏）
    m_savedPanelFrames = s.skinLayout == kSkinLayoutVersion
                             ? s.panelFrames
                             : QString(); // 各面板几何+吸附态（dock 就绪后 setSavedPanels 套用）
}

void MainWindow::saveState() {
    if (m_restoringLibrary) {
        m_saveAfterRestore = true;
        return;
    }
    LibraryStore::Loaded s;
    s.skinLayout = kSkinLayoutVersion; // 记住当前布局版本，用户之后手动缩放的几何才会被沿用
    // 存的是媒体库主表 @all（集合层真相），不是控制器当前展示的那一页——
    // 后者会被切页/搜索换成收藏页/命中表，拿它存盘会把「全部」缩水成子集（R02）。
    QStringList paths;
    for (const Track &t : m_collections.allTracks())
        paths << trackToken(t);
    s.trackPaths = paths;
    s.libraryFolders = m_libraryFolders;
    s.volume = m_vol;
    s.muted = m_muted;
    s.mode = m_controller->mode();
    s.eqEnabled = m_engine->eqEnabled();
    s.eqPreGain = m_engine->eqPreamp();
    s.eqGains = m_engine->eqGains();
    s.transparency = GlassStyle::transparency();
    s.glass = GlassStyle::enabled();
    const QRect g = geometry();
    s.windowFrame = LibraryStore::frameToString(g.x(), g.y(), g.width(), g.height());
    if (m_dock) s.dockFrame = m_dock->geometryString();      // 停靠组锚点左上角 + 同宽
    if (m_dock) s.panelFrames = m_dock->panelFramesString(); // 各面板几何 + 吸附/浮动态
    s.autoResumePlay = m_autoResumePlay;
    // 首次显示前列表尚未懒建，保存时不能把默认显示意图误写成隐藏。
    s.listVisible = m_playlist ? m_playlist->isVisible() : m_listVisible;
    s.eqVisible = m_eqWindow && m_eqWindow->isVisible();
    s.replayGainMode = int(m_controller->replayGainMode());
    s.replayGainPreamp = m_controller->replayGainPreamp();
    s.replayGainPeakLimit = m_controller->replayGainPeakLimit();
    s.lyricShifts = m_controller->lyricShiftTable();
    s.gaplessPlay = m_controller->gaplessEnabled();
    s.sleepFade = m_controller->sleepFadeEnabled();
    s.outputDeviceUID = m_engine->outputDevice();
    s.outputDeviceName = m_engine->outputDevice();
    s.declinedRadioKeys = m_declinedRadioKeys;
    m_collections.saveTo(s); // 收藏 / 歌单 / 当前页写回（不覆盖上面已填的字段）

    captureResume(s);
    if (m_sceneReady) writeResume();
    m_persistenceProblem = LibraryStore::save(s) ? QString() : QStringLiteral("设置保存失败，请检查存储空间和目录权限");
    if (!m_persistenceProblem.isEmpty()) {
        m_status->setText(m_persistenceProblem);
        qWarning("%s", qPrintable(m_persistenceProblem));
    }
}

void MainWindow::captureResume(LibraryStore::Loaded &s) const {
    // 基础播放现场：序列、当前游标、实际历史、位置和在播状态。
    const PlayQueue &q = m_controller->queue();
    if (q.current()) {
        s.resumeValid = true;
        s.resumePosition = m_controller->position();
        s.resumeWasPlaying = m_controller->isPlaying();
        s.resumeCursor = q.cursor().value_or(0);
        // 历史（QUuid）→ 下标：恢复时按下标重建（新 UUID 不同，靠位置对齐）
        const QList<QueueItem> items = q.items();
        for (const QUuid &hid : q.history())
            for (int i = 0; i < items.size(); ++i)
                if (items[i].id == hid) {
                    s.resumeHistoryIndexes.append(i);
                    break;
                }
        for (const QueueItem &it : items) {
            s.resumeQueue.append(trackToken(it.track));
            if (q.current() && it.id == q.current()->id) s.resumeTrackKey = trackToken(it.track);
        }
    }
}
void MainWindow::writeResume() {
    if (!m_sceneReady) return;
    LibraryStore::Loaded scene;
    captureResume(scene);
    if (!LibraryStore::saveResume(scene)) {
        m_persistenceProblem = QStringLiteral("播放现场保存失败，请检查存储空间和目录权限");
        m_status->setText(m_persistenceProblem);
        qWarning("%s", qPrintable(m_persistenceProblem));
    }
}

void MainWindow::restoreLibrary() {
    if (m_restoreCancel) m_restoreCancel->store(true);
    const LibraryStore::Loaded s = LibraryStore::load();
    const uint64_t generation = ++m_restoreGeneration;
    if (!s.valid) {
        m_restoringLibrary = false;
        m_sceneReady = true;
        m_restoreCancel.reset();
        if (m_playlist) m_playlist->setEnabled(true);
        return;
    }
    auto cancel = std::make_shared<std::atomic<bool>>(false);
    m_restoreCancel = cancel;
    m_restoringLibrary = true;
    m_sceneReady = false;
    m_operationStatus = QStringLiteral("正在恢复曲库…");
    m_status->setText(m_operationStatus);
    if (m_playlist) m_playlist->setEnabled(false);
    auto *watcher = new QFutureWatcher<RestoredLibraryData>(this);
    connect(watcher, &QFutureWatcher<RestoredLibraryData>::finished, this, [this, watcher, s, generation, cancel] {
        const auto data = watcher->result();
        watcher->deleteLater();
        if (cancel->load() || generation != m_restoreGeneration) return;
        m_collections.loadFrom(s);
        m_collections.setAllTracks(data.defaults);
        m_collections.registerTracks(data.all, false);
        m_scannedKeys = m_collections.libraryKeys();
        m_controller->setTracks(m_collections.currentTracks());
        // 重建上次基础播放现场；旧插队来源已在读档适配器过滤。
        // 旧档没这一节 → resumeValid=false，直接跳过（退化成只恢复曲库，不凭空开声）。
        // 条目用 resolveToken 单独还原（不依赖当前浏览页/搜索命中表，R02 分离的正是这个），
        // 解析不出的丢弃并同步 remap，保证游标/历史下标指向重建后的真条目。
        if (s.resumeValid && !s.resumeQueue.isEmpty() && s.resumeCursor >= 0) {
            QList<QueueItem> items;
            QList<int> remap; // 存档下标 → 重建后下标（-1 = 解析不出，已丢）
            for (int i = 0; i < s.resumeQueue.size(); ++i) {
                Track t = m_collections.trackForKey(s.resumeQueue[i]);
                if (t.isNull()) {
                    remap.append(-1);
                    continue;
                }
                QueueItem it;
                it.track = t;
                remap.append(items.size());
                items.append(it);
            }
            const int cursor = (s.resumeCursor < remap.size()) ? remap[s.resumeCursor] : -1;
            QList<int> hist;
            for (int hi : s.resumeHistoryIndexes)
                if (hi >= 0 && hi < remap.size() && remap[hi] >= 0) hist.append(remap[hi]);
            if (cursor >= 0)
                // 「恢复现场但停住」与「启用自动续播才开声」分开：两个条件都成立才真放。
                m_controller->restoreResume(items, cursor, hist, s.resumePosition,
                                            s.resumeWasPlaying && m_autoResumePlay && m_deferredImports.isEmpty());
        }

        m_restoringLibrary = false;
        m_sceneReady = true;
        m_restoreCancel.reset();
        if (m_playlist) {
            m_playlist->setEnabled(true);
            m_playlist->refreshGroups();
        }
        m_operationStatus = QStringLiteral("已恢复 %1 首").arg(data.all.size());
        syncNowPlaying();
        syncState();
        if (std::exchange(m_seedAfterRestore, false)) seedPresetRadios();
        if (std::exchange(m_saveAfterRestore, false)) saveState();
        const auto inputs = std::exchange(m_deferredImports, QStringList{});
        const auto radioEdits = std::exchange(m_deferredRadioEdits, QHash<QString, QJsonObject>{});
        if (!inputs.isEmpty()) loadDirOrFiles(inputs, radioEdits);
        const bool scan =
            std::exchange(m_rescanAfterRestore, false) || (!m_libraryFolders.isEmpty() && s.libraryKeys.isEmpty());
        if (scan) rescanLibrary();
    });
    watcher->setFuture(QtConcurrent::run([s, cancel] {
        RestoredLibraryData data;
        QStringList tokens = s.trackPaths;
        tokens.append(s.defaultKeys);
        tokens.append(s.libraryKeys);
        tokens.append(s.favoriteKeys);
        tokens.append(s.recentKeys);
        tokens.append(s.recentRadioKeys);
        for (const auto &list : s.userLists)
            tokens.append(list.keys);
        for (const auto &item : s.resumeQueue)
            tokens.append(item);
        QHash<QString, Track> resolved;
        for (const QString &token : tokens) {
            if (cancel->load()) return data;
            if (resolved.contains(token)) continue;
            Track track = Collections::resolveToken(token);
            if (track.isNull()) continue;
            const QString identity = track.identityKey();
            if (resolved.contains(identity))
                track = resolved.value(identity);
            else {
                Importer::probe(track, cancel);
                resolved.insert(identity, track);
                data.all.append(track);
            }
            resolved.insert(token, track);
        }
        QSet<QString> seen;
        for (const QString &token : s.trackPaths) {
            const Track track = resolved.value(token);
            if (!track.isNull() && !seen.contains(track.identityKey())) {
                seen.insert(track.identityKey());
                data.defaults.append(track);
            }
        }
        return data;
    }));
}

// 出厂电台默认入表（F11）：入口埋得深的东西等于没有，启动直接塞进列表。
// 四句话：删过不回来（黑名单）、不开播（playNow=false）、同一条通路（走集合层 registerTracks）、
// 台名不写档（RadioPresets::nameFor 按地址兜底）。只追加到 @all（媒体库/当前）。
int MainWindow::seedPresetRadios() {
    if (m_restoringLibrary) {
        m_seedAfterRestore = true;
        return 0;
    }
    int seeded = 0;
    for (const RadioPreset &p : RadioPresets::all()) {
        const QUrl u = p.url();
        if (u.isEmpty()) continue; // 内置地址写错了（自检钉住，运行时不该遇到）
        const QString key = u.toString();
        if (m_declinedRadioKeys.contains(key)) continue; // 删过就不回来
        bool present = false;
        for (const Track &t : m_collections.allTracks())
            if (t.identityKey() == key) {
                present = true;
                break;
            }
        if (present) continue; // 已在表（含从 state.db 恢复回来的）
        m_collections.registerTracks({p.toTrack()});
        ++seeded;
    }
    if (seeded > 0) {
        // 当前停在 @all 才把新台顶到眼前；在别的页不打扰用户正在看的
        if (m_collections.viewId() == Collections::kAllViewId) m_controller->setTracks(m_collections.currentTracks());
        if (m_playlist) m_playlist->refreshGroups();
        saveState();
    }
    return seeded;
}

// 曲库文件夹增删与重扫（F08）：存目录本身，扫描结果交给集合层
void MainWindow::addLibraryFolder(const QString &path) {
    if (path.isEmpty() || m_libraryFolders.contains(path)) return;
    m_libraryFolders << path;
    rescanLibrary();
    updateLibraryWatch();
    saveState();
}

QString MainWindow::relocateLibraryRoot(const QString &oldRoot, const QString &newRoot) {
    const QString from = QDir::cleanPath(QFileInfo(oldRoot).absoluteFilePath());
    const QString to = QDir::cleanPath(QFileInfo(newRoot).absoluteFilePath());
    if (!m_libraryFolders.contains(oldRoot) || !QFileInfo(to).isDir())
        return QStringLiteral("请选择有效的原目录和新目录");
    if (from == to) return {};
    QList<QPair<QString, Track>> plan;
    QSet<QString> targets;
    for (const Track &track : m_collections.allTracks()) {
        if (track.isRadio()) continue;
        QString token = track.identityKey();
        const QString path = track.isCueSegment() ? track.cueSheetUrl().toLocalFile() : track.url().toLocalFile();
        if (!pathWithinRoot(path, from)) continue;
        const QString moved = to + path.mid(from.size());
        if (!QFileInfo::exists(moved)) return QStringLiteral("新目录缺少 %1，未更改任何引用").arg(moved);
        if (track.isCueSegment())
            token = moved + QStringLiteral("#track=%1").arg(track.cueNumber());
        else {
            QUrl url = track.url();
            const QUrl local = QUrl::fromLocalFile(moved);
            // fromLocalFile 会补 Windows 盘符前的斜杠并解析 UNC host；fragment 原样保留。
            url.setHost(local.host());
            url.setPath(local.path(QUrl::FullyDecoded));
            token = url.toString();
        }
        Track replacement = Collections::resolveToken(token);
        const QString key = replacement.identityKey();
        if (replacement.isNull() || targets.contains(key)) return QStringLiteral("重定位后的身份重复，未更改任何引用");
        for (const Track &existing : m_collections.allTracks())
            if (existing.identityKey() == key && key != track.identityKey())
                return QStringLiteral("新位置已经在曲库中，未更改任何引用");
        targets.insert(key);
        replacement.setTitle(track.title());
        replacement.setArtist(track.artist());
        replacement.setAlbum(track.album());
        replacement.setMetadata(track.duration(), track.sampleRate(), track.channels(), track.bitRateKbps());
        replacement.setFormatName(track.formatName());
        if (const auto gain = track.replayGainTags()) replacement.setReplayGainTags(*gain);
        plan.append({track.identityKey(), replacement});
    }
    cancelLibraryScan();
    QHash<QString, Track> references;
    for (const auto &change : plan) {
        m_collections.replaceKey(change.first, change.second);
        references.insert(change.first, change.second);
    }
    m_controller->replaceTrackReferences(references);
    for (QString &root : m_libraryFolders)
        if (root == oldRoot) root = to;
    m_scannedKeys = m_collections.libraryKeys();
    m_controller->setTracks(m_collections.currentTracks());
    updateLibraryWatch();
    saveState();
    return {};
}

void MainWindow::removeLibraryFolder(const QString &path) {
    m_libraryFolders.removeAll(path);
    rescanLibrary();
    updateLibraryWatch();
    saveState();
}

void MainWindow::rescanLibrary() {
    if (m_restoringLibrary) {
        m_rescanAfterRestore = true;
        return;
    }
    cancelLibraryScan();
    const auto cancel = std::make_shared<std::atomic<bool>>(false);
    m_scanCancel = cancel;
    m_operationStatus = QStringLiteral("正在扫描音乐文件夹…");
    m_operationProblems.clear();
    const uint64_t operation = ++m_operationGeneration;
    const QStringList roots = m_libraryFolders;
    const uint64_t generation = ++m_scanGeneration;
    auto *watcher = new QFutureWatcher<Importer::Result>(this);
    connect(watcher, &QFutureWatcher<Importer::Result>::finished, this, [this, watcher, roots, generation, operation] {
        const Importer::Result result = watcher->result();
        watcher->deleteLater();
        if (qEnvironmentVariableIsSet("TTPLAYER_SELFTEST"))
            qInfo("scan generation=%llu current=%llu tracks=%lld cancelled=%d", (unsigned long long)generation,
                  (unsigned long long)m_scanGeneration, (long long)result.tracks.size(), result.cancelled);
        if (generation != m_scanGeneration || result.cancelled) return;
        if (operation == m_operationGeneration) {
            m_operationProblems = result.problems.join(QLatin1Char('\n'));
            m_operationStatus =
                QStringLiteral("扫描完成：%1 首，拒收 %2 项").arg(result.tracks.size()).arg(result.problems.size());
            if (!result.problems.isEmpty()) m_operationStatus += QStringLiteral("；明细见设置 → 媒体库");
        }
        QList<Track> tracks = result.tracks;
        // An offline root is not a confirmed deletion. Keep its last successful snapshot.
        for (const Track &track : m_collections.tracksOf(Collections::kLibraryViewId)) {
            for (const QString &root : roots)
                if (!QFileInfo(root).isDir() && pathWithinRoot(track.url().toLocalFile(), root)) {
                    tracks << track;
                    break;
                }
        }
        m_collections.replaceLibrary(tracks);
        m_scannedKeys = m_collections.libraryKeys();
        m_controller->setTracks(m_collections.currentTracks());
        if (m_playlist) m_playlist->refreshGroups();
        updateLibraryWatch();
        saveState();
    });
    watcher->setFuture(QtConcurrent::run([roots, cancel] { return Importer::read(roots, true, cancel.get()); }));
}

void MainWindow::cancelLibraryScan() {
    if (m_scanCancel) m_scanCancel->store(true);
    ++m_scanGeneration;
    ++m_operationGeneration;
    m_operationProblems.clear();
    m_operationStatus = QStringLiteral("扫描已取消");
}

// R09：把当前曲库文件夹连同其子目录挂上 watcher。QFileSystemWatcher 非递归，而
// scanFolders 会递归扫子目录，所以子目录里的增删也要能触发重扫。不存在的目录 addPaths 会忽略。
void MainWindow::updateLibraryWatch() {
    if (!m_libWatcher) return;
    if (m_watchCancel) m_watchCancel->store(true);
    auto cancel = std::make_shared<std::atomic<bool>>(false);
    m_watchCancel = cancel;
    const auto generation = ++m_watchGeneration;
    const auto folders = m_libraryFolders;
    // Register roots before scanning so changes during enumeration still trigger a rescan.
    for (const auto &folder : folders) {
        QString root = QDir::cleanPath(folder);
        if (folder.isEmpty()) continue;
        while (!QFileInfo::exists(root)) {
            const QString parent = QFileInfo(root).absolutePath();
            if (parent == root) break;
            root = parent;
        }
        if (QFileInfo(root).isDir() && !m_libWatcher->directories().contains(root)) m_libWatcher->addPath(root);
    }
    auto *watcher = new QFutureWatcher<QStringList>(this);
    connect(watcher, &QFutureWatcher<QStringList>::finished, this, [this, watcher, cancel, generation] {
        const auto fresh = watcher->result();
        watcher->deleteLater();
        if (cancel->load() || generation != m_watchGeneration) return;
        const auto stale = m_libWatcher->directories();
        const QSet<QString> previous(stale.cbegin(), stale.cend()), wanted(fresh.cbegin(), fresh.cend());
        const auto removed = (previous - wanted).values(), added = (wanted - previous).values();
        if (!removed.isEmpty()) m_libWatcher->removePaths(removed);
        if (!added.isEmpty()) m_libWatcher->addPaths(added);
    });
    watcher->setFuture(QtConcurrent::run([folders, cancel] {
        QSet<QString> fresh;
        for (const auto &folder : folders) {
            if (cancel->load()) break;
            if (folder.isEmpty()) continue;
            QString root = QDir::cleanPath(folder);
            while (!QFileInfo::exists(root)) {
                const QString parent = QFileInfo(root).absolutePath();
                if (parent == root) break;
                root = parent;
            }
            if (QFileInfo(root).isDir()) fresh.insert(root);
            QDirIterator it(folder, QDir::Dirs | QDir::NoDotAndDotDot, QDirIterator::Subdirectories);
            while (it.hasNext()) {
                if (cancel->load()) return QStringList{};
                fresh.insert(it.next());
            }
        }
        return fresh.values();
    }));
}

// 目录改动：重启单触定时器（连续多次变化只在最后一次后 700ms 重扫一次）。
void MainWindow::onLibraryChanged() {
    if (m_rescanTimer) m_rescanTimer->start();
}

void MainWindow::setLibraryWatchEnabled(bool on) {
    if (!m_libWatcher) return;
    if (on) {
        updateLibraryWatch();
    } else {
        if (m_watchCancel) m_watchCancel->store(true);
        ++m_watchGeneration;
        if (m_rescanTimer) m_rescanTimer->stop();
        QStringList stale = m_libWatcher->directories();
        if (!stale.isEmpty()) m_libWatcher->removePaths(stale);
    }
}

void MainWindow::closeEvent(QCloseEvent *e) {
    saveState();
    e->accept();
}

// 首次显示才装停靠组：那时 frameGeometry 才是真实的全局位置 / 尺寸。
void MainWindow::showEvent(QShowEvent *e) {
    QWidget::showEvent(e);
#ifdef Q_OS_WIN
    setWindowPinTop(this, m_pinTop);
#endif
    ensureDock();
}

void MainWindow::ensureDock() {
    if (m_dockReady) return;
    m_dockReady = true;
    m_dock = new SkinDock(this);
    m_dock->setSavedPanels(m_savedPanelFrames); // 先暂存面板几何，后续 registerPanel 逐个套用
    m_dock->registerPanel(SkinDock::Main, this);
    if (!m_savedFrame.isEmpty()) m_dock->restoreGeometry(m_savedFrame);
    // 兼容：若列表 / 均衡器 / 歌词在 dock 就绪前已建，补登记
    if (m_playlist) m_dock->registerPanel(SkinDock::Playlist, m_playlist);
    if (m_eqWindow) m_dock->registerPanel(SkinDock::Equalizer, m_eqWindow);
    if (m_lyricWindow) m_dock->registerPanel(SkinDock::Lyric, m_lyricWindow);
    if (m_listVisible && !m_playlist) togglePlaylistPanel();
    if (m_savedEQVisible && !m_eqWindow) toggleEqPanel();
}

void MainWindow::paintEvent(QPaintEvent *) {
    const qreal dpr = devicePixelRatioF();
    const QSize pixels(qCeil(width() * dpr), qCeil(height() * dpr));
    const float alpha = GlassStyle::enabled() ? GlassStyle::glassAlpha() : 1.0f;
    if (m_bodyCache.size() != pixels || m_bodyCache.devicePixelRatio() != dpr || m_bodyAlpha != alpha) {
        m_bodyCache = QPixmap(pixels);
        m_bodyCache.setDevicePixelRatio(dpr);
        m_bodyCache.fill(Qt::transparent);
        QPainter body(&m_bodyCache);
        Painter::drawBody(&body, QRectF(rect()), Theme::windowTop, Theme::windowBottom, alpha, kSkinRadius,
                          Theme::skinEdge, true);
        m_bodyAlpha = alpha;
    }
    QPainter p(this);
    p.drawPixmap(0, 0, m_bodyCache);
}

void MainWindow::dragEnterEvent(QDragEnterEvent *e) {
    if (e->mimeData()->hasUrls()) e->acceptProposedAction();
}

// 无边框窗没有原生缩放手柄：命中左/右/下三侧边缘带就交给系统缩放。
// 顶边让给标题条拖动（startSystemMove），不与缩放抢。阈值内为根布局留白，不抢控件。
namespace {
Qt::Edges frameResizeEdges(const QWidget *w, QPointF p) {
    constexpr int kBand = 6;
    const QRect r = w->rect();
    Qt::Edges e;
    if (p.x() < kBand) e |= Qt::LeftEdge;
    if (p.x() >= r.width() - kBand) e |= Qt::RightEdge;
    if (p.y() >= r.height() - kBand) e |= Qt::BottomEdge;
    return e;
}
} // namespace

void MainWindow::mousePressEvent(QMouseEvent *e) {
    if (e->button() == Qt::LeftButton) {
        const Qt::Edges edges = frameResizeEdges(this, e->position());
        if (edges != Qt::Edges()) {
            if (auto *wh = windowHandle(); wh && wh->startSystemResize(edges)) return;
        }
    }
    QWidget::mousePressEvent(e);
}

void MainWindow::mouseMoveEvent(QMouseEvent *e) {
    const Qt::Edges edges = frameResizeEdges(this, e->position());
    if ((edges & Qt::LeftEdge) && (edges & Qt::BottomEdge))
        setCursor(Qt::SizeBDiagCursor);
    else if ((edges & Qt::RightEdge) && (edges & Qt::BottomEdge))
        setCursor(Qt::SizeFDiagCursor);
    else if (edges & (Qt::LeftEdge | Qt::RightEdge))
        setCursor(Qt::SizeHorCursor);
    else if (edges & Qt::BottomEdge)
        setCursor(Qt::SizeVerCursor);
    else
        setCursor(Qt::ArrowCursor);
    QWidget::mouseMoveEvent(e);
}

void MainWindow::dropEvent(QDropEvent *e) {
    QStringList paths;
    for (const QUrl &u : e->mimeData()->urls())
        if (u.isLocalFile())
            paths << u.toLocalFile();
        else if (u.scheme() == QLatin1String("http") || u.scheme() == QLatin1String("https"))
            paths << u.toString(); // 拖入电台地址也直接进列
    loadDirOrFiles(paths);
}

void MainWindow::openFiles() {
    const QStringList files =
        QFileDialog::getOpenFileNames(this, QStringLiteral("打开音频"), QDir::homePath(), Importer::fileDialogFilter());
    if (!files.isEmpty()) loadDirOrFiles(files);
}

// 播放列表右键「添加文件夹…」：选一个目录走与拖放相同的载入通路（目录递归在 Importer 里）。
void MainWindow::openFolder() {
    const QString dir = QFileDialog::getExistingDirectory(this, QStringLiteral("打开文件夹"), QDir::homePath());
    if (!dir.isEmpty()) loadDirOrFiles({dir});
}

// 显示信息随本次导入结果提交，不提前写台名，避免取消或过期回调留下半成品。
void MainWindow::addRadioPrompt() {
    const auto radio = promptRadioInfo(this);
    if (!radio) return;
    QHash<QString, QJsonObject> edits;
    if (!radio->title().isEmpty() || !radio->artist().isEmpty() || !radio->album().isEmpty())
        edits.insert(radio->identityKey(),
                     QJsonObject{{"title", radio->title()}, {"artist", radio->artist()}, {"album", radio->album()}});
    loadDirOrFiles({radio->url().toString()}, edits);
}

void MainWindow::editRadioPrompt(const Track &track) {
    if (track.isNull() || !track.isRadio()) return;
    const auto radio = promptRadioInfo(this, track);
    if (!radio) return;
    m_collections.editTrack(track.identityKey(), radio->title(), radio->artist(), radio->album());
    m_controller->setTracks(m_collections.currentTracks());
    if (m_playlist) m_playlist->refreshGroups();
    syncNowPlaying();
    saveState();
}

void MainWindow::loadDirOrFiles(const QStringList &paths, const QHash<QString, QJsonObject> &radioEdits) {
    if (m_restoringLibrary) {
        m_deferredImports.append(paths);
        for (auto it = radioEdits.cbegin(); it != radioEdits.cend(); ++it)
            m_deferredRadioEdits.insert(it.key(), it.value());
        return;
    }
    m_sceneReady = true;
    if (m_importCancel) m_importCancel->store(true);
    const auto cancel = std::make_shared<std::atomic<bool>>(false);
    m_importCancel = cancel;
    const uint64_t generation = ++m_importGeneration;
    m_operationStatus = QStringLiteral("正在导入…");
    m_operationProblems.clear();
    const uint64_t operation = ++m_operationGeneration;
    m_status->setText(m_operationStatus);
    auto *watcher = new QFutureWatcher<Importer::Result>(this);
    connect(watcher, &QFutureWatcher<Importer::Result>::finished, this,
            [this, watcher, generation, radioEdits, operation] {
                const auto imported = watcher->result();
                watcher->deleteLater();
                if (generation != m_importGeneration || imported.cancelled) return;
                if (operation == m_operationGeneration) {
                    m_operationProblems = imported.problems.join(QLatin1Char('\n'));
                    m_operationStatus = QStringLiteral("已导入 %1 首；拒收 %2 项")
                                            .arg(imported.tracks.size())
                                            .arg(imported.problems.size());
                    if (!imported.problems.isEmpty()) m_operationStatus += QStringLiteral("；明细见设置 → 媒体库");
                    m_status->setText(m_operationStatus);
                }
                const QList<Track> tracks = imported.tracks;
                if (tracks.isEmpty()) {
                    return;
                }
                for (const Track &track : tracks) {
                    if (!track.isRadio()) continue;
                    const auto edit = radioEdits.constFind(track.identityKey());
                    if (edit != radioEdits.cend())
                        m_collections.editTrack(track.identityKey(), edit->value("title").toString(),
                                                edit->value("artist").toString(), edit->value("album").toString());
                    else if (track.title() != Track::fromRadio(track.url()).title())
                        m_collections.radios().setAlias(track.identityKey(), track.title());
                }
                m_collections.registerTracks(tracks);
                m_collections.setViewId(Collections::kAllViewId);
                if (m_playlist) m_playlist->refreshGroups();
                const auto list = m_collections.currentTracks();
                m_controller->setTracks(list);
                for (int i = 0; i < list.size(); ++i)
                    if (list[i].identityKey() == tracks.first().identityKey()) {
                        m_controller->playRowAt(i);
                        break;
                    }
                syncNowPlaying();
                saveState();
            });
    watcher->setFuture(QtConcurrent::run([paths, cancel] { return Importer::read(paths, true, cancel.get()); }));
}

void MainWindow::syncNowPlaying() {
    const Track t = m_controller->currentTrack();
    static_cast<CoverBox *>(m_cover)->setImage(t.isNull() ? QImage()
                                                          : CoverArt::imageForTrack(t, CoverArt::kWellPixel));
    if (t.isNull()) {
        m_marquee->setText(QStringLiteral("千千静听 复刻版"));
        m_channel->setText(QStringLiteral("立体声"));
        const int n = m_controller->tracks().size();
        m_codec->setText(n > 0 ? QStringLiteral("已载入 %1 首").arg(n) : QStringLiteral("拖入文件开始播放"));
        m_seek->setProgress(0.0);
        return;
    }
    const QString head = t.artist().isEmpty() ? t.title() : t.artist() + QStringLiteral(" - ") + t.title();
    m_marquee->setText(head);
    m_marquee->setToolTip(head);

    const int ch = t.channels();
    m_channel->setText(ch == 2 ? QStringLiteral("立体声")
                               : (ch == 1 ? QStringLiteral("单声道") : QStringLiteral("%1声道").arg(ch)));

    QString line = t.formatName();
    if (t.bitRateKbps() > 0)
        line += (line.isEmpty() ? QString() : QStringLiteral(" ")) + QStringLiteral("%1k").arg(t.bitRateKbps());
    if (t.sampleRate() > 0) line += QStringLiteral(" · %1k").arg(t.sampleRate() / 1000.0, 0, 'f', 1);
    m_codec->setText(line.isEmpty() ? t.fileName() : line);
}

void MainWindow::syncState() {
    if (!m_persistenceProblem.isEmpty()) {
        m_status->setText(m_persistenceProblem);
        return;
    }
    const Track track = m_controller->currentTrack();
    if (!track.isNull() && track.isRadio()) {
        m_status->setText(m_controller->radioStatusText());
        if (!m_controller->radioNowPlaying().isEmpty()) m_codec->setText(m_controller->radioNowPlaying());
        return;
    }
    const bool playing = m_controller->isPlaying();
    const QString s = playing
                          ? QStringLiteral("播放")
                          : (m_controller->currentTrack().isNull() ? QStringLiteral("停止") : QStringLiteral("暂停"));
    m_status->setText(QStringLiteral("状态: ") + s);
}
