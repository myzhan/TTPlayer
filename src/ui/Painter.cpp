#include "Painter.h"
#include "Theme.h"

#include <QLinearGradient>
#include <QPainter>
#include <QPainterPath>

namespace Painter {

static QColor scaledAlpha(QColor c, float alpha) {
    c.setAlphaF(c.alphaF() * alpha);
    return c;
}

// 两色线性混合（含 alpha 通道），用于插渐变中间色，不依赖 QColor::lerp 的版本差异。
static QColor blend(const QColor &a, const QColor &b, qreal t) {
    return QColor(qRound(a.red()   + (b.red()   - a.red())   * t),
                  qRound(a.green() + (b.green() - a.green()) * t),
                  qRound(a.blue()  + (b.blue()  - a.blue())  * t),
                  qRound(a.alpha() + (b.alpha() - a.alpha()) * t));
}

// 玻璃暗部基调（底部内阴影 / well 凹陷投影共用）——深色皮肤下取近黑中性调。
static const QColor kShade(0x05, 0x06, 0x07);

void drawBody(QPainter *p, const QRectF &rect, const QColor &top, const QColor &bottom,
              float alpha, qreal radius, const QColor &edge, bool gloss) {
    if (rect.width() < 1 || rect.height() < 1) return;
    p->setRenderHint(QPainter::Antialiasing, true);
    QPainterPath path;
    path.addRoundedRect(rect, radius, radius);
    p->save();
    p->setClipPath(path);

    const float a = GlassStyle::enabled() ? alpha : 1.0f;
    const qreal h = rect.height();

    // 主渐变：顶部最亮 -> 上 1/7 处留一段高光余晖 -> 底部偏暗，比纯线性更有厚度。
    QLinearGradient g(rect.topLeft(), rect.bottomLeft());
    g.setColorAt(0.0, scaledAlpha(top, a));
    g.setColorAt(0.14, scaledAlpha(blend(top, bottom, 0.22), a));
    g.setColorAt(1.0, scaledAlpha(blend(bottom, top, 0.06), a));
    p->fillRect(rect, g);

    if (gloss) {
        // 上半白色渐隐反光（深玻璃上的大面积光泽，比浅皮肤收弱）
        const qreal band = h * 0.5;
        QLinearGradient sheen(rect.topLeft(), QPointF(rect.left(), rect.top() + band));
        sheen.setColorAt(0.0, QColor(255, 255, 255, int(0.14 * a * 255)));
        sheen.setColorAt(1.0, QColor(255, 255, 255, 0));
        p->fillRect(QRectF(rect.topLeft(), QSizeF(rect.width(), band)), sheen);
    }

    // 顶部内高光斜面：紧贴顶边一条亮线快速渐隐，是玻璃「鼓起来」的关键。
    const qreal hlBand = qMax<qreal>(1.5, h * 0.05);
    QLinearGradient hl(rect.topLeft(), QPointF(rect.left(), rect.top() + hlBand));
    hl.setColorAt(0.0, scaledAlpha(Theme::innerHighlight, a));
    hl.setColorAt(1.0, QColor(255, 255, 255, 0));
    p->fillRect(QRectF(rect.topLeft(), QSizeF(rect.width(), hlBand)), hl);

    // 底部内阴影：贴底边的暗渐变，制造下沉/厚度感。
    const qreal shBand = qMax<qreal>(2.0, h * 0.10);
    QLinearGradient sh(QPointF(rect.left(), rect.bottom()), QPointF(rect.left(), rect.bottom() - shBand));
    sh.setColorAt(0.0, scaledAlpha(kShade, a * 0.55f));
    sh.setColorAt(1.0, QColor(0x05, 0x06, 0x07, 0));
    p->fillRect(QRectF(QPointF(rect.left(), rect.bottom() - shBand), QSizeF(rect.width(), shBand)), sh);

    p->restore();

    if (edge.isValid()) {
        p->setBrush(Qt::NoBrush);
        p->setPen(QPen(scaledAlpha(edge, a), 1));
        p->drawPath(path);
    }
}

void drawWell(QPainter *p, const QRectF &rect, const QColor &top, const QColor &bottom,
              float alpha, qreal radius) {
    // 统一毛玻璃：与外壳同一层玻璃底，但通过「顶部内阴影 + 底部内高光」把内容区读作
    // 轻微凹陷的槽（参考 Winamp 皮肤那种内凹质感），外加 1px 发丝边。
    if (rect.width() < 1 || rect.height() < 1) return;
    p->setRenderHint(QPainter::Antialiasing, true);
    QPainterPath path;
    path.addRoundedRect(rect, radius, radius);
    p->save();
    p->setClipPath(path);

    const float a = GlassStyle::enabled() ? alpha : 1.0f;
    const qreal h = rect.height();
    QLinearGradient g(rect.topLeft(), rect.bottomLeft());
    g.setColorAt(0.0, scaledAlpha(top, a));
    g.setColorAt(1.0, scaledAlpha(bottom, a));
    p->fillRect(rect, g);

    // 顶部内阴影：从上边往下的暗渐变，读作「凹陷」。
    const qreal inBand = qMax<qreal>(3.0, h * 0.12);
    QLinearGradient ins(QPointF(rect.left(), rect.top()), QPointF(rect.left(), rect.top() + inBand));
    ins.setColorAt(0.0, scaledAlpha(kShade, a * 0.62f));
    ins.setColorAt(1.0, QColor(0x05, 0x06, 0x07, 0));
    p->fillRect(QRectF(rect.topLeft(), QSizeF(rect.width(), inBand)), ins);

    // 底部内高光：下边一条微亮反衬，强化凹槽立体。
    const qreal upBand = qMax<qreal>(1.5, h * 0.06);
    QLinearGradient up(QPointF(rect.left(), rect.bottom()), QPointF(rect.left(), rect.bottom() - upBand));
    up.setColorAt(0.0, scaledAlpha(Theme::wellBevelLight, a * 0.30f));
    up.setColorAt(1.0, QColor(Theme::wellBevelLight.red(), Theme::wellBevelLight.green(),
                              Theme::wellBevelLight.blue(), 0));
    p->fillRect(QRectF(QPointF(rect.left(), rect.bottom() - upBand), QSizeF(rect.width(), upBand)), up);

    p->restore();

    // 发丝边
    p->setBrush(Qt::NoBrush);
    p->setPen(QPen(scaledAlpha(Theme::hairline, a), 1));
    p->drawPath(path);
}

void drawHoverFace(QPainter *p, const QRectF &rect, bool hot, bool pressed,
                   qreal radius, bool hairlineRest) {
    if (rect.width() < 1 || rect.height() < 1) return;
    p->setRenderHint(QPainter::Antialiasing, true);
    QPainterPath path;
    path.addRoundedRect(rect, radius, radius);

    // 静止：完全透明（可选极淡发丝轮廓），控件融进背景。
    if (!hot && !pressed) {
        if (hairlineRest) {
            p->setBrush(Qt::NoBrush);
            p->setPen(QPen(Theme::hairline, 1));
            p->drawPath(path);
        }
        return;
    }
    // hover / pressed：上浅下深的柔灰渐变面（比纯色更立体），pressed 再深一档。
    const QColor light(0x6A, 0x70, 0x76);
    const QColor deep(0x40, 0x44, 0x48);
    const float amp = pressed ? 0.60f : 0.42f;
    QLinearGradient g(rect.topLeft(), rect.bottomLeft());
    g.setColorAt(0.0, scaledAlpha(light, amp));
    g.setColorAt(1.0, scaledAlpha(deep, amp));
    p->fillPath(path, g);
    // 面顶部一条内高光，让按钮/hover 行有轻微凸起。
    const qreal hlBand = qMax<qreal>(1.0, rect.height() * 0.45);
    QLinearGradient hl(rect.topLeft(), QPointF(rect.left(), rect.top() + hlBand));
    hl.setColorAt(0.0, QColor(255, 255, 255, int(0.28 * amp * 255)));
    hl.setColorAt(1.0, QColor(255, 255, 255, 0));
    p->save();
    p->setClipPath(path);
    p->fillRect(QRectF(rect.topLeft(), QSizeF(rect.width(), hlBand)), hl);
    p->restore();
    p->setBrush(Qt::NoBrush);
    p->setPen(QPen(scaledAlpha(Theme::hairline, pressed ? 1.0f : 0.8f), 1));
    p->drawPath(path);
}

void drawHairline(QPainter *p, const QRectF &rect, bool horizontal) {
    p->setRenderHint(QPainter::Antialiasing, false);
    p->setPen(Qt::NoPen);
    p->setBrush(Theme::hairline);
    if (horizontal)
        p->drawRect(QRectF(rect.left(), rect.center().y(), rect.width(), 1));
    else
        p->drawRect(QRectF(rect.center().x(), rect.top(), 1, rect.height()));
}

} // namespace Painter
