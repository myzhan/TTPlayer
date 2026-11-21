#include "CoverWindow.h"
#include "models/CoverArt.h"
#include "Theme.h"
#include "Painter.h"

#include <QPainter>
#include <QPainterPath>

namespace {
QColor scaledAlpha(QColor c, float a) {
    c.setAlphaF(c.alphaF() * a);
    return c;
}
} // namespace

CoverWindow::CoverWindow(PlayerController *controller, QWidget *parent)
    : SkinWindow(QStringLiteral("专辑封面"), true, parent), m_controller(controller) {
    // 辅助窗不跟随半透明：压在播放列表/歌词上时，下层内容不透过封面窗。
    setGlassTransparencyFollows(false);
    resize(252, 340 + 30); // 高度补上自绘标题条（~30）
    setMinimumSize(200, 260);

    connect(m_controller, &PlayerController::trackChanged, this, &CoverWindow::reload);
    reload();
}

void CoverWindow::reload() {
    const Track t = m_controller->currentTrack();
    m_image = CoverArt::imageForTrack(t, CoverArt::kLargePixel);
    if (t.isNull()) {
        m_caption = QStringLiteral("还没有播放中的曲目");
        m_source.clear();
    } else {
        m_caption = t.artist().isEmpty() ? t.title() : QStringLiteral("%1 - %2").arg(t.artist(), t.title());
        const QSize px = CoverArt::pixelSizeForTrack(t);
        if (m_image.isNull())
            m_source = QStringLiteral("无（在同目录放一张 cover.jpg，或与音频同名的 .png）");
        else if (!CoverArt::externalImagePath(t).isEmpty())
            m_source = QStringLiteral("外部封面 %1×%2").arg(px.width()).arg(px.height());
        else
            m_source = QStringLiteral("内嵌封面 %1×%2").arg(px.width()).arg(px.height());
    }
    update();
}

void CoverWindow::paintBody(QPainter *p, const QRectF &r) {
    p->save();
    p->setRenderHint(QPainter::Antialiasing, true);
    p->translate(r.topLeft());
    const float wA = shellAlpha();
    const int W = int(r.width()), H = int(r.height());
    Painter::drawWell(p, QRectF(0, 0, W, H).adjusted(0.5, 0.5, -0.5, -0.5), Theme::windowTop, Theme::windowBottom, wA,
                      6);

    const int side = qMin(W - 24, H - 90);
    const QRect artRect((W - side) / 2, 12, side, side);

    if (m_image.isNull()) {
        // 占位光盘（浅底：走墨色层次，黑/白实底在浅玻璃上要么过重要么看不见）
        p->setPen(QPen(Theme::hairline, 1));
        p->setBrush(scaledAlpha(Theme::inkOnGlassSoft, 0.10f));
        p->drawRoundedRect(artRect, 6, 6);
        const QPointF c = artRect.center();
        const qreal rad = side * 0.32;
        p->setPen(Qt::NoPen);
        p->setBrush(scaledAlpha(Theme::inkOnGlassSoft, 0.28f));
        p->drawEllipse(c, rad, rad);
        p->setBrush(Theme::inkOnGlassAccent);
        p->drawEllipse(c, rad * 0.18, rad * 0.18);
        p->setPen(Theme::inkOnGlassSoft);
        p->setFont(Fonts::small);
        p->drawText(artRect, Qt::AlignCenter, QStringLiteral("无封面"));
    } else {
        const QImage scaled = m_image.scaled(artRect.size(), Qt::KeepAspectRatio, Qt::SmoothTransformation);
        QRectF imgRect(0, 0, scaled.width(), scaled.height());
        imgRect.moveCenter(artRect.center());
        QPainterPath clip;
        clip.addRoundedRect(imgRect, 6, 6);
        p->setClipPath(clip);
        p->drawImage(imgRect.topLeft(), scaled);
        p->setClipping(false);
    }

    // 两行字（浅底深字：标题用 inkOnGlass、来路用 inkOnGlassSoft）
    p->setFont(Fonts::title);
    p->setPen(Theme::inkOnGlass);
    const QRectF capRect(8, artRect.bottom() + 8, W - 16, 20);
    p->drawText(capRect, Qt::AlignCenter,
                p->fontMetrics().elidedText(m_caption, Qt::ElideMiddle, int(capRect.width())));
    p->setFont(Fonts::tiny);
    p->setPen(Theme::inkOnGlassSoft);
    p->drawText(QRectF(8, artRect.bottom() + 28, W - 16, 16), Qt::AlignCenter, m_source);
    p->restore();
}
