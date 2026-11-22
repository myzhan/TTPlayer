#include "PropertyWindow.h"
#include "media/CoverArt.h"
#include "playback/PlayerController.h"
#include "Theme.h"
#include "SkinParts.h"

#include <QVBoxLayout>
#include <QHBoxLayout>
#include <QLabel>
#include <QFileInfo>
#include <QDir>

#include <cmath>

namespace {

QString clock(double sec) {
    const int s = int(std::lround(sec));
    return QStringLiteral("%1:%2").arg(s / 60).arg(s % 60, 2, 10, QLatin1Char('0'));
}

QString sizeLabel(qint64 bytes) {
    if (bytes <= 0) return QStringLiteral("0 B");
    static const char *units[] = {"B", "KB", "MB", "GB", "TB"};
    double v = double(bytes);
    int u = 0;
    while (v >= 1024 && u < 4) {
        v /= 1024;
        ++u;
    }
    return QStringLiteral("%1 %2").arg(v, 0, 'f', v < 10 && u > 0 ? 1 : 0).arg(units[u]);
}

} // namespace

QList<QPair<QString, QString>> PropertyWindow::linesFor(const Track &t) {
    QList<QPair<QString, QString>> lines;
    if (t.isNull()) return lines;
    if (!t.decodeProblem().isEmpty()) lines.append({QStringLiteral("问题"), t.decodeProblem()});

    if (t.isRadio()) {
        lines.append({QStringLiteral("电台"), t.title()});
        lines.append({QStringLiteral("地址"), t.url().toString()});
        if (t.sampleRate() > 0)
            lines.append({QStringLiteral("采样率"), QStringLiteral("%1 Hz").arg(int(t.sampleRate()))});
        if (!t.formatName().isEmpty()) lines.append({QStringLiteral("编码"), t.formatName()});
        return lines;
    }

    const QFileInfo fi(t.url().toLocalFile());
    lines.append({QStringLiteral("文件名"), fi.completeBaseName() + QLatin1Char('.') + fi.suffix().toLower()});
    lines.append({QStringLiteral("路径"), fi.absolutePath()});
    lines.append({QStringLiteral("类型"), t.formatName().isEmpty() ? QStringLiteral("未知") : t.formatName()});
    lines.append({QStringLiteral("大小"), sizeLabel(t.fileSize())});
    if (t.duration() > 0) lines.append({QStringLiteral("时长"), clock(t.duration())});
    if (t.sampleRate() > 0) lines.append({QStringLiteral("采样率"), QStringLiteral("%1 Hz").arg(int(t.sampleRate()))});
    if (t.channels() > 0)
        lines.append({QStringLiteral("声道"),
                      t.channels() == 2 ? QStringLiteral("立体声") : QStringLiteral("%1 声道").arg(t.channels())});
    if (t.bitRateKbps() > 0) lines.append({QStringLiteral("码率"), QStringLiteral("%1 kbps").arg(t.bitRateKbps())});

    const QSize px = CoverArt::pixelSizeForTrack(t);
    if (!CoverArt::imageForTrack(t, 1).isNull()) {
        const bool external = !CoverArt::externalImagePath(t).isEmpty();
        lines.append({QStringLiteral("封面"), QStringLiteral("%1 %2×%3")
                                                  .arg(external ? QStringLiteral("外部") : QStringLiteral("内嵌"))
                                                  .arg(px.width())
                                                  .arg(px.height())});
    } else {
        lines.append({QStringLiteral("封面"), QStringLiteral("无（在同目录放一张 cover.jpg，或与音频同名的 .png）")});
    }

    if (t.isCueSegment()) {
        lines.append({QStringLiteral("镜像内起点"), clock(t.playStart())});
        if (t.playEnd() >= 0) lines.append({QStringLiteral("镜像内终点"), clock(t.playEnd())});
    }
    return lines;
}

PropertyWindow::PropertyWindow(const Track &track, PlayerController *ctl, QWidget *parent)
    : SkinWindow(QStringLiteral("媒体文件信息"), TitleButtons::Close, parent) {
    setAttribute(Qt::WA_DeleteOnClose);

    auto *root = new QVBoxLayout(body());
    auto *top = new QHBoxLayout();

    // 左侧封面缩略图（≤64，取自带小档）
    auto *cover = new QLabel(this);
    cover->setFixedSize(72, 72);
    cover->setAlignment(Qt::AlignCenter);
    const QImage art = CoverArt::imageForTrack(track, CoverArt::kWellPixel);
    if (!art.isNull()) {
        cover->setPixmap(QPixmap::fromImage(art.scaled(64, 64, Qt::KeepAspectRatio, Qt::SmoothTransformation)));
    } else {
        cover->setText(QStringLiteral("无封面"));
        cover->setStyleSheet(QStringLiteral("color:%1;background:transparent;").arg(Theme::inkOnGlassSoft.name()));
    }
    top->addWidget(cover, 0, Qt::AlignTop);

    // 右侧标题 + 逐行信息
    auto *col = new QVBoxLayout();
    const QString head =
        track.artist().isEmpty() ? track.title() : QStringLiteral("%1 - %2").arg(track.artist(), track.title());
    auto *title = new QLabel(head.isEmpty() ? QStringLiteral("未知曲目") : head, this);
    title->setFont(Fonts::title);
    title->setStyleSheet(QStringLiteral("color:%1;background:transparent;").arg(Theme::inkOnGlass.name()));
    col->addWidget(title);

    QString body;
    QList<QPair<QString, QString>> lines = linesFor(track);
    // 响度均衡行：能回答「现在到底加了多少、为什么是这个数」（无控制器时不显）
    if (ctl && !track.isNull())
        lines.append({QStringLiteral("响度均衡"), ctl->replayGainStatusText(track, ctl->isPlaying())});
    if (ctl && track.isRadio()) lines.append({QStringLiteral("连接质量"), ctl->radioQualityText()});
    for (const auto &kv : lines)
        body += QStringLiteral("%1：%2\n").arg(kv.first, kv.second);
    auto *info = new QLabel(body.trimmed(), this);
    info->setFont(Fonts::small);
    info->setStyleSheet(QStringLiteral("color:%1;background:transparent;").arg(Theme::inkOnGlass.name()));
    info->setTextInteractionFlags(Qt::TextSelectableByMouse);
    col->addWidget(info, 1);
    top->addLayout(col, 1);

    root->addLayout(top);

    // 统一毛玻璃：按钮走自绘 hover-face（静止透明、hover 轻亮），不再用原生 QPushButton。
    auto *ok = new TTButton(this);
    ok->setTextLabel(QStringLiteral("好"));
    ok->setFace(TTButton::Face::Glass);
    ok->setPreferredSize({40, 22});
    connect(ok, &TTButton::clicked, this, &QWidget::close);
    auto *btnRow = new QHBoxLayout();
    btnRow->addStretch();
    btnRow->addWidget(ok);
    root->addLayout(btnRow);

    resize(360, qMax(200, 40 + lines.size() * 18) + 30); // 高度补上自绘标题条（~30）
}
