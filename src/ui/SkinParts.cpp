#include "SkinParts.h"
#include "Theme.h"
#include "Painter.h"

#include <QPainter>
#include <QFontMetricsF>
#include <QPainterPath>
#include <QLinearGradient>
#include <QPaintEvent>
#include <QMouseEvent>
#include <QEnterEvent>
#include <QWheelEvent>
#include <QtMath>

namespace {

// 0~1 alpha 缩放
QColor scaledAlpha(QColor c, float a) {
    c.setAlphaF(c.alphaF() * a);
    return c;
}

QColor hexc(uint v) {
    return QColor((v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF);
}

} // namespace

namespace Skin {

void drawGlyph(QPainter *p, Glyph g, const QRectF &rect, const QColor &color, qreal scale) {
    if (g == Glyph::None) return;
    const qreal s = qMin(rect.width(), rect.height()) * scale;
    QRectF box(rect.center().x() - s / 2, rect.center().y() - s / 2, s, s);
    p->save();
    p->setRenderHint(QPainter::Antialiasing, true);
    p->setPen(Qt::NoPen);
    p->setBrush(color);

    QPainterPath path;
    switch (g) {
    case Glyph::Play:
        path.moveTo(box.left() + s * 0.18, box.top());
        path.lineTo(box.right(), box.center().y());
        path.lineTo(box.left() + s * 0.18, box.bottom());
        path.closeSubpath();
        p->drawPath(path);
        break;
    case Glyph::Pause:
        p->drawRect(QRectF(box.left() + s * 0.18, box.top(), s * 0.22, s));
        p->drawRect(QRectF(box.right() - s * 0.40, box.top(), s * 0.22, s));
        break;
    case Glyph::Stop:
        p->drawRect(box.adjusted(s * 0.12, s * 0.12, -s * 0.12, -s * 0.12));
        break;
    case Glyph::Prev:
    case Glyph::Next: {
        const bool next = (g == Glyph::Next);
        const qreal barW = s * 0.14;
        QPainterPath tri;
        if (next) {
            tri.moveTo(box.left(), box.top());
            tri.lineTo(box.left() + s * 0.62, box.center().y());
            tri.lineTo(box.left(), box.bottom());
        } else {
            tri.moveTo(box.right(), box.top());
            tri.lineTo(box.right() - s * 0.62, box.center().y());
            tri.lineTo(box.right(), box.bottom());
        }
        tri.closeSubpath();
        p->drawPath(tri);
        if (next)
            p->drawRect(QRectF(box.right() - barW, box.top(), barW, s));
        else
            p->drawRect(QRectF(box.left(), box.top(), barW, s));
        break;
    }
    case Glyph::Sequential: {
        // 顺序播放：一条向右箭头（顺次播完到底即停）
        p->setBrush(Qt::NoBrush);
        QPen pen(color, qMax(1.3, s * 0.12));
        pen.setCapStyle(Qt::RoundCap);
        pen.setJoinStyle(Qt::RoundJoin);
        p->setPen(pen);
        const qreal y = box.center().y();
        const qreal x0 = box.left() + s * 0.14, x1 = box.right() - s * 0.14;
        p->drawLine(QPointF(x0, y), QPointF(x1, y));
        p->drawLine(QPointF(x1, y), QPointF(x1 - s * 0.20, y - s * 0.16));
        p->drawLine(QPointF(x1, y), QPointF(x1 - s * 0.20, y + s * 0.16));
        break;
    }
    case Glyph::Repeat:
    case Glyph::RepeatOne:
    case Glyph::ListLoop: {
        // 循环轨道（宽扁圆角矩形）+ 上边右指向箭头；单曲循环在中心画一条粗竖「1」。
        p->setBrush(Qt::NoBrush);
        QPen pen(color, qMax(1.5, s * 0.12));
        pen.setCapStyle(Qt::RoundCap);
        pen.setJoinStyle(Qt::RoundJoin);
        p->setPen(pen);
        QRectF r = box.adjusted(s * 0.04, s * 0.22, -s * 0.04, -s * 0.22);
        p->drawRoundedRect(r, r.height() / 2, r.height() / 2);
        // 轨道上边右指向箭头（循环方向）
        p->setPen(Qt::NoPen);
        p->setBrush(color);
        const qreal ay = r.top();
        const qreal ax = r.center().x() + s * 0.02;
        QPainterPath arrow;
        arrow.moveTo(ax + s * 0.18, ay);
        arrow.lineTo(ax - s * 0.02, ay - s * 0.15);
        arrow.lineTo(ax - s * 0.02, ay + s * 0.15);
        arrow.closeSubpath();
        p->drawPath(arrow);
        if (g == Glyph::RepeatOne) {
            // 矢量粗竖「1」（不用字体，小尺寸下也清），与 ListLoop 的空心轨道拉开差异
            p->setPen(QPen(color, qMax(1.8, s * 0.16), Qt::SolidLine, Qt::RoundCap));
            p->setBrush(Qt::NoBrush);
            const qreal cx = r.center().x();
            const qreal cy = r.center().y();
            p->drawLine(QPointF(cx, cy - s * 0.10), QPointF(cx, cy + s * 0.10));
            p->drawLine(QPointF(cx, cy - s * 0.10), QPointF(cx - s * 0.09, cy - s * 0.01));
        }
        break;
    }
    case Glyph::Shuffle: {
        // 随机：两条交叉线 + 右端两个箭头（洗牌交叉）
        p->setBrush(Qt::NoBrush);
        QPen pen(color, qMax(1.3, s * 0.11));
        pen.setCapStyle(Qt::RoundCap);
        pen.setJoinStyle(Qt::RoundJoin);
        p->setPen(pen);
        const qreal l = box.left() + s * 0.12, rt = box.right() - s * 0.12;
        const qreal t = box.top() + s * 0.20, b = box.bottom() - s * 0.20;
        p->drawLine(QPointF(l, t), QPointF(rt, b));
        p->drawLine(QPointF(l, b), QPointF(rt, t));
        auto head = [&](qreal x, qreal y, qreal ux, qreal uy) {
            const qreal a = s * 0.20, w = s * 0.10;
            const qreal px = -uy, py = ux; // 垂直单位
            p->drawLine(QPointF(x, y), QPointF(x - ux * a + px * w, y - uy * a + py * w));
            p->drawLine(QPointF(x, y), QPointF(x - ux * a - px * w, y - uy * a - py * w));
        };
        {
            const qreal dx = rt - l, dy = b - t;
            const qreal m = qSqrt(dx * dx + dy * dy);
            head(rt, b, dx / m, dy / m);
        }
        {
            const qreal dx = rt - l, dy = t - b;
            const qreal m = qSqrt(dx * dx + dy * dy);
            head(rt, t, dx / m, dy / m);
        }
        break;
    }
    case Glyph::Eject:
        path.moveTo(box.center().x(), box.top());
        path.lineTo(box.right(), box.center().y());
        path.lineTo(box.left(), box.center().y());
        path.closeSubpath();
        p->drawPath(path);
        p->drawRect(QRectF(box.left(), box.bottom() - s * 0.22, s, s * 0.18));
        break;
    case Glyph::Menu:
        for (int i = 0; i < 3; ++i)
            p->drawRect(QRectF(box.left(), box.top() + i * s * 0.34, s, s * 0.14));
        break;
    case Glyph::Pin: {
        // 图钉：上部椭圆帽 + 下尖针（置顶）
        QRectF cap(box.center().x() - s * 0.30, box.top() + s * 0.06, s * 0.60, s * 0.42);
        p->drawEllipse(cap);
        p->drawRect(QRectF(box.center().x() - s * 0.10, cap.bottom() - s * 0.02, s * 0.20, s * 0.16));
        QPen pen(color, qMax(1.2, s * 0.12));
        pen.setCapStyle(Qt::RoundCap);
        p->setPen(pen);
        p->setBrush(Qt::NoBrush);
        p->drawLine(QPointF(box.center().x(), cap.bottom() + s * 0.12), QPointF(box.center().x(), box.bottom()));
        p->setPen(Qt::NoPen);
        p->setBrush(color);
        break;
    }
    case Glyph::Minus:
        p->drawRect(QRectF(box.left() + s * 0.12, box.center().y() - s * 0.08, s * 0.76, s * 0.16));
        break;
    case Glyph::Close: {
        p->setBrush(Qt::NoBrush);
        QPen pen(color, qMax(1.4, s * 0.12));
        pen.setCapStyle(Qt::RoundCap);
        p->setPen(pen);
        QRectF x = box.adjusted(s * 0.18, s * 0.18, -s * 0.18, -s * 0.18);
        p->drawLine(x.topLeft(), x.bottomRight());
        p->drawLine(x.topRight(), x.bottomLeft());
        break;
    }
    case Glyph::List:
        for (int i = 0; i < 3; ++i) {
            p->drawRect(QRectF(box.left(), box.top() + i * s * 0.36, s * 0.18, s * 0.18));
            p->drawRect(QRectF(box.left() + s * 0.28, box.top() + i * s * 0.36 + s * 0.02, s * 0.72, s * 0.12));
        }
        break;
    case Glyph::EQ: {
        for (int i = 0; i < 3; ++i) {
            const qreal cx = box.left() + s * (0.18 + i * 0.32);
            p->drawRect(QRectF(cx - s * 0.05, box.top(), s * 0.10, s));
            const qreal ky = box.top() + s * (0.2 + i * 0.25);
            p->drawEllipse(QRectF(cx - s * 0.13, ky, s * 0.26, s * 0.26));
        }
        break;
    }
    case Glyph::Lyric: {
        p->setBrush(Qt::NoBrush);
        QPen pen(color, qMax(1.2, s * 0.09));
        p->setPen(pen);
        QRectF r = box.adjusted(s * 0.08, s * 0.1, -s * 0.08, -s * 0.1);
        QPainterPath bubble;
        bubble.addRoundedRect(r, s * 0.12, s * 0.12);
        p->drawPath(bubble);
        p->setPen(QPen(color, qMax(1.0, s * 0.07)));
        p->drawLine(r.left() + s * 0.1, r.center().y(), r.right() - s * 0.1, r.center().y());
        break;
    }
    case Glyph::Search: {
        p->setBrush(Qt::NoBrush);
        QPen pen(color, qMax(1.4, s * 0.11));
        p->setPen(pen);
        QRectF circ = box.adjusted(0, 0, -s * 0.28, -s * 0.28);
        p->drawEllipse(circ);
        QPointF a(circ.right() - s * 0.02, circ.bottom() - s * 0.02);
        p->drawLine(a, QPointF(box.right(), box.bottom()));
        break;
    }
    case Glyph::Add: {
        p->setBrush(Qt::NoBrush);
        QPen pen(color, qMax(1.4, s * 0.12));
        pen.setCapStyle(Qt::RoundCap);
        p->setPen(pen);
        p->drawLine(box.center(), QPointF(box.center().x(), box.top()));
        p->drawLine(box.center(), QPointF(box.center().x(), box.bottom()));
        p->drawLine(box.center(), QPointF(box.left(), box.center().y()));
        p->drawLine(box.center(), QPointF(box.right(), box.center().y()));
        break;
    }
    case Glyph::Check: {
        p->setBrush(Qt::NoBrush);
        QPen pen(color, qMax(1.4, s * 0.14));
        pen.setCapStyle(Qt::RoundCap);
        pen.setJoinStyle(Qt::RoundJoin);
        p->setPen(pen);
        p->drawPolyline(QPolygonF() << QPointF(box.left() + s * 0.1, box.center().y())
                                    << QPointF(box.center().x() - s * 0.05, box.bottom() - s * 0.15)
                                    << QPointF(box.right() - s * 0.05, box.top() + s * 0.15));
        break;
    }
    case Glyph::Volume:
    case Glyph::Mute: {
        // 喇叭体（梯形 + 方块）
        QPainterPath sp;
        sp.moveTo(box.left() + s * 0.06, box.top() + s * 0.36);
        sp.lineTo(box.left() + s * 0.26, box.top() + s * 0.36);
        sp.lineTo(box.left() + s * 0.50, box.top() + s * 0.14);
        sp.lineTo(box.left() + s * 0.50, box.bottom() - s * 0.14);
        sp.lineTo(box.left() + s * 0.26, box.bottom() - s * 0.36);
        sp.lineTo(box.left() + s * 0.06, box.bottom() - s * 0.36);
        sp.closeSubpath();
        p->drawPath(sp);
        if (g == Glyph::Volume) {
            p->setBrush(Qt::NoBrush);
            QPen pen(color, qMax(1.1, s * 0.09));
            pen.setCapStyle(Qt::RoundCap);
            p->setPen(pen);
            QRectF arc(box.left() + s * 0.42, box.top() + s * 0.22, s * 0.42, s * 0.56);
            p->drawArc(arc, -55 * 16, 110 * 16);
        } else {
            p->setBrush(Qt::NoBrush);
            QPen pen(color, qMax(1.3, s * 0.11));
            pen.setCapStyle(Qt::RoundCap);
            p->setPen(pen);
            QRectF x(box.left() + s * 0.56, box.top() + s * 0.28, s * 0.36, s * 0.44);
            p->drawLine(x.topLeft(), x.bottomRight());
            p->drawLine(x.topRight(), x.bottomLeft());
        }
        break;
    }
    case Glyph::Power: {
        p->setBrush(Qt::NoBrush);
        QPen pen(color, qMax(1.2, s * 0.11));
        pen.setCapStyle(Qt::RoundCap);
        p->setPen(pen);
        QRectF c = box.adjusted(s * 0.14, s * 0.14, -s * 0.14, -s * 0.14);
        p->drawArc(c, 60 * 16, 300 * 16); // 顶部开口的环
        p->drawLine(QPointF(c.center().x(), c.top() - s * 0.04), QPointF(c.center().x(), c.center().y()));
        break;
    }
    case Glyph::Reset: {
        p->setBrush(Qt::NoBrush);
        QPen pen(color, qMax(1.2, s * 0.10));
        pen.setCapStyle(Qt::RoundCap);
        p->setPen(pen);
        QRectF c = box.adjusted(s * 0.16, s * 0.16, -s * 0.16, -s * 0.16);
        p->drawArc(c, 40 * 16, 280 * 16); // 回旋箭头
        p->setPen(Qt::NoPen);
        p->setBrush(color);
        QPainterPath ah;
        const QPointF tip = c.center() + QPointF(0, -c.height() / 2);
        ah.moveTo(tip.x() - s * 0.14, tip.y() - s * 0.02);
        ah.lineTo(tip.x() + s * 0.12, tip.y() - s * 0.02);
        ah.lineTo(tip.x(), tip.y() + s * 0.20);
        ah.closeSubpath();
        p->drawPath(ah);
        break;
    }
    default:
        break;
    }
    p->restore();
}

} // namespace Skin

// ————————————————————————————————————————————————
// WellView
// ————————————————————————————————————————————————
WellView::WellView(QWidget *parent) : QWidget(parent) {
    setAttribute(Qt::WA_StyledBackground, false);
    connect(&GlassNotifier::instance(), &GlassNotifier::changed, this, [this] { update(); });
}

void WellView::setDark(bool dark) {
    m_dark = dark;
    update();
}
void WellView::setShowGrid(bool on, int columns) {
    m_showGrid = on;
    m_gridColumns = columns;
    update();
}

void WellView::paintEvent(QPaintEvent *) {
    if (width() < 4 || height() < 4) return;
    QPainter p(this);
    p.setRenderHint(QPainter::Antialiasing, true);
    const QRectF area = QRectF(rect()).adjusted(0.5, 0.5, -0.5, -0.5);
    QPainterPath path;
    path.addRoundedRect(area, m_radius, m_radius);

    // 统一毛玻璃：显示区/列表与外壳同一层浅蓝玻璃，不再铺深蓝槽、不再画凹陷压边。
    const float a = GlassStyle::enabled() ? GlassStyle::glassAlpha() : 1.0f;
    QLinearGradient g(area.topLeft(), area.bottomLeft());
    g.setColorAt(0.0, scaledAlpha(Theme::windowTop, a));
    g.setColorAt(1.0, scaledAlpha(Theme::windowBottom, a));
    p.fillPath(path, g);

    // 区域之间靠 1px 发丝边区分（取代旧深蓝压边）
    p.setBrush(Qt::NoBrush);
    p.setPen(QPen(scaledAlpha(Theme::hairline, a), 1));
    p.drawPath(path);

    if (m_showGrid) {
        p.setPen(Qt::NoPen);
        p.setBrush(scaledAlpha(Theme::hairline, 0.8f));
        for (int i = 1; i < 5; ++i)
            p.drawRect(QRectF(2, area.height() * i / 5.0, area.width() - 4, 1));
        const int cols = qMax(2, m_gridColumns);
        for (int i = 1; i < cols; ++i)
            p.drawRect(QRectF(area.width() * i / double(cols), 2, 1, area.height() - 4));
    }
}

// ————————————————————————————————————————————————
// TTButton
// ————————————————————————————————————————————————
TTButton::TTButton(QWidget *parent) : QAbstractButton(parent) {
    setAttribute(Qt::WA_Hover, true);
    setCursor(Qt::PointingHandCursor);
    connect(&GlassNotifier::instance(), &GlassNotifier::changed, this, [this] { update(); });
}

void TTButton::paintEvent(QPaintEvent *) {
    if (width() < 4 || height() < 4) return;
    QPainter p(this);
    p.setRenderHint(QPainter::Antialiasing, true);
    const bool hot = underMouse() && isEnabled();
    const bool pressed = isDown();
    const QRectF frame = QRectF(rect()).adjusted(0.5, 0.5, -0.5, -0.5);
    const qreal radius = qMin(m_radius, frame.height() / 2);
    QPainterPath path;
    path.addRoundedRect(frame, radius, radius);

    auto drawContent = [&](const QColor &fg) {
        switch (m_kind) {
        case Kind::Glyph:
            Skin::drawGlyph(&p, m_glyph, rect(), fg, m_glyphScale);
            break;
        case Kind::Text: {
            p.setFont(Fonts::tiny);
            p.setPen(fg);
            p.drawText(rect(), Qt::AlignCenter, m_text);
            break;
        }
        case Kind::Badge: {
            const qreal d = qMax(1.0, qMin(width(), height()) - 5.0);
            QRectF circ(rect().center().x() - d / 2, rect().center().y() - d / 2, d, d);
            p.setBrush(m_lit ? Theme::textAccent : Theme::buttonHot);
            p.setPen(QPen(scaledAlpha(Theme::buttonEdge, 0.8f), 1));
            p.drawEllipse(circ);
            QFont f = Fonts::tiny;
            f.setPixelSize(int(d * 0.60));
            f.setBold(true);
            p.setFont(f);
            p.setPen(m_lit ? hexc(0x1A1206) : Theme::titleText);
            p.drawText(circ, Qt::AlignCenter, m_badge);
            break;
        }
        }
    };

    switch (m_face) {
    case Face::Glass: {
        if (m_lit) {
            p.fillPath(path, scaledAlpha(Theme::textAccent, 0.22f));
            p.setBrush(Qt::NoBrush);
            p.setPen(QPen(scaledAlpha(Theme::inkOnGlassAccent, 0.9f), 1));
            p.drawPath(path);
        }
        Painter::drawHoverFace(&p, frame, hot, pressed, radius, false);
        break;
    }
    case Face::Flat:
    case Face::FlatOnLight: {
        if (!(hot || pressed || m_lit)) break;
        const bool onLight = (m_face == Face::FlatOnLight);
        const QColor bg = pressed ? Theme::buttonPressed : (onLight ? Theme::flatHotOnLightBG : Theme::flatHotBG);
        p.fillPath(path, bg);
        p.setBrush(Qt::NoBrush);
        p.setPen(QPen(onLight ? Theme::buttonEdge : Theme::flatEdgeHot, 1));
        p.drawPath(path);
        break;
    }
    case Face::None: {
        if (!(hot || pressed)) break;
        const QColor bg = (pressed ? Theme::buttonPressed : Theme::flatHotBG);
        p.fillPath(path, scaledAlpha(bg, pressed ? 0.75f : 0.45f));
        break;
    }
    }

    // 前景色（内容）
    QColor fg;
    if (m_face == Face::Glass || m_face == Face::None) {
        if (m_lit)
            fg = Theme::textAccent; // 激活：橙黄 accent
        else if (hot)
            fg = Theme::textHighlight; // hover：亮白
        else
            fg = Theme::inkOnGlass; // 静止：深底亮字
    } else if (m_face == Face::Flat) {
        fg = m_lit ? Theme::textAccent : (hot ? Theme::flatTextHot : Theme::flatText);
    } else { // FlatOnLight
        fg = m_lit ? Theme::textAccent : (hot ? Theme::flatTextOnLightHot : Theme::flatTextOnLight);
    }
    drawContent(fg);
}

// ————————————————————————————————————————————————
// TimeSlider
// ————————————————————————————————————————————————
TimeSlider::TimeSlider(QWidget *parent) : QWidget(parent) {
    setAttribute(Qt::WA_Hover, true);
    setCursor(Qt::PointingHandCursor);
    connect(&GlassNotifier::instance(), &GlassNotifier::changed, this, [this] { update(); });
}

double TimeSlider::ratioAt(qreal x) const {
    if (width() <= 1) return 0;
    return qBound(0.0, double(x) / width(), 1.0);
}

void TimeSlider::setProgress(double v) {
    if (m_dragging) return;
    const double next = qBound(0.0, v, 1.0);
    if (next == m_progress) return;
    m_progress = next;
    update();
}
void TimeSlider::enterEvent(QEnterEvent *) {
    m_hot = true;
    update();
}
void TimeSlider::leaveEvent(QEvent *) {
    m_hot = false;
    update();
}
void TimeSlider::mousePressEvent(QMouseEvent *e) {
    m_dragging = true;
    m_dragValue = ratioAt(e->position().x());
    update();
}
void TimeSlider::mouseMoveEvent(QMouseEvent *e) {
    if (m_dragging) {
        m_dragValue = ratioAt(e->position().x());
        update();
    }
}
void TimeSlider::mouseReleaseEvent(QMouseEvent *e) {
    if (!m_dragging) return;
    m_dragging = false;
    m_progress = ratioAt(e->position().x());
    emit seekRatio(m_progress);
    update();
}

void TimeSlider::paintEvent(QPaintEvent *) {
    constexpr int H = 7;
    if (width() <= 1 || height() <= H) return;
    QPainter p(this);
    p.setRenderHint(QPainter::Antialiasing, true);
    const double v = m_dragging ? m_dragValue : m_progress;
    const QRectF groove(0, (height() - H) / 2.0, width(), H);
    QPainterPath gp;
    gp.addRoundedRect(groove, 2.5, 2.5);
    p.fillPath(gp, Theme::groove);
    p.setBrush(Qt::NoBrush);
    p.setPen(QPen(Theme::hairline, 1));
    p.drawPath(gp);

    const double fillW = qBound(0.0, width() * v, double(width()));
    if (fillW > 1) {
        const QRectF fr(0, groove.y(), fillW, H);
        QPainterPath fp;
        fp.addRoundedRect(fr, 2.5, 2.5);
        QLinearGradient g(fr.topLeft(), fr.bottomLeft());
        g.setColorAt(0.0, Theme::spectrumBottom);
        g.setColorAt(1.0, Theme::spectrumTop);
        p.fillPath(fp, g);
    }

    // 四分刻度
    p.setPen(Qt::NoPen);
    p.setBrush(scaledAlpha(Theme::hairline, 0.9f));
    for (int i = 1; i < 4; ++i)
        p.drawRect(QRectF(groove.width() * i / 4.0, groove.y() + 1, 1, groove.height() - 2));

    // 游标：竖细条（浅底上走深 accent，白游标会消失）
    constexpr double knobW = 4;
    const double kx = qBound(0.0, fillW - knobW / 2.0, double(width()) - knobW);
    const QRectF knob(kx, 1, knobW, height() - 2);
    p.setBrush(m_hot ? Theme::inkOnGlassAccent : scaledAlpha(Theme::inkOnGlassAccent, 0.85f));
    p.setPen(Qt::NoPen);
    p.drawRect(knob);
    p.setBrush(Qt::NoBrush);
    p.setPen(QPen(scaledAlpha(Theme::border, 0.7f), 1));
    p.drawRect(knob.adjusted(-0.5, -0.5, 0.5, 0.5));
}

// ————————————————————————————————————————————————
// VolumeSlider
// ————————————————————————————————————————————————
VolumeSlider::VolumeSlider(QWidget *parent) : QWidget(parent) {
    setAttribute(Qt::WA_Hover, true);
    setCursor(Qt::PointingHandCursor);
    connect(&GlassNotifier::instance(), &GlassNotifier::changed, this, [this] { update(); });
}

double VolumeSlider::knobDiameter() const {
    return qMin(double(height()) - 4.0, 16.0);
}

QRectF VolumeSlider::readoutRect() const {
    const QFontMetricsF textMetrics(Fonts::tiny);
    const QFontMetricsF numberMetrics(Fonts::numericTiny);
    // 留足最长读数的字形宽度，不随当前数值改变槽长，避免拖动时跳动。
    const double textWidth = qCeil(qMax(numberMetrics.horizontalAdvance(QStringLiteral("100%")),
                                        textMetrics.horizontalAdvance(QStringLiteral("静音")))) +
                             2.0;
    return QRectF(width() - textWidth - 2.0, 0, textWidth, height());
}

QRectF VolumeSlider::grooveRect() const {
    const double radius = knobDiameter() / 2.0;
    const double left = radius + 1.0;
    const double right = readoutRect().left() - radius - 3.0;
    return QRectF(left, (height() - 5) / 2.0, qMax(1.0, right - left), 5);
}

void VolumeSlider::setValue(double v) {
    m_value = qBound(0.0, v, 1.0);
    update();
}
void VolumeSlider::setMuted(bool m) {
    m_muted = m;
    update();
}
void VolumeSlider::enterEvent(QEnterEvent *) {
    m_hot = true;
    update();
}
void VolumeSlider::leaveEvent(QEvent *) {
    m_hot = false;
    update();
}
void VolumeSlider::mousePressEvent(QMouseEvent *e) {
    const QRectF gr = grooveRect();
    if (gr.width() <= 0) return;
    m_value = qBound(0.0, (e->position().x() - gr.left()) / gr.width(), 1.0);
    emit valueChanged(m_value);
    update();
}
void VolumeSlider::mouseMoveEvent(QMouseEvent *e) {
    if (e->buttons().testFlag(Qt::LeftButton)) mousePressEvent(e);
}

void VolumeSlider::paintEvent(QPaintEvent *) {
    const QRectF gr = grooveRect();
    if (gr.width() <= 1 || height() <= 6) return;
    QPainter p(this);
    p.setRenderHint(QPainter::Antialiasing, true);
    QPainterPath path;
    path.addRoundedRect(gr, 2.5, 2.5);
    p.fillPath(path, Theme::groove);
    p.setBrush(Qt::NoBrush);
    p.setPen(QPen(scaledAlpha(m_hot ? Theme::inkOnGlassAccent : Theme::hairline, 0.9f), 1));
    p.drawPath(path);

    const double ratio = m_muted ? 0 : qBound(0.0, m_value, 1.0);
    const double fillW = gr.width() * ratio;
    if (fillW > 1) {
        const QRectF fr(gr.x(), gr.y(), fillW, gr.height());
        QPainterPath fp;
        fp.addRoundedRect(fr, 2.5, 2.5);
        QLinearGradient g(fr.topLeft(), fr.bottomLeft());
        g.setColorAt(0.0, Theme::spectrumBottom);
        g.setColorAt(1.0, Theme::spectrumTop);
        p.fillPath(fp, g);
    }

    // 玻璃圆推子
    const double knobD = knobDiameter();
    if (knobD > 2) {
        const double cx = gr.x() + fillW;
        const QRectF knob(cx - knobD / 2.0, height() / 2.0 - knobD / 2.0, knobD, knobD);
        QPainterPath kp;
        kp.addEllipse(knob);
        QLinearGradient kg(knob.topLeft(), knob.bottomLeft());
        kg.setColorAt(0.0, m_hot ? Theme::buttonHotTop : Theme::buttonTop);
        kg.setColorAt(1.0, m_hot ? Theme::buttonHotBottom : Theme::buttonBottom);
        p.fillPath(kp, kg);
        p.setBrush(Qt::NoBrush);
        p.setPen(QPen(Theme::buttonEdge, 1));
        p.drawPath(kp);
        p.setBrush(QColor(255, 255, 255, 180));
        p.setPen(Qt::NoPen);
        p.drawRect(QRectF(knob.x() + 3, knob.y() + 2, qMax(1.0, knob.width() - 6), 2));
    }

    // 右侧读数
    const QString pct = m_muted ? QStringLiteral("静音") : QStringLiteral("%1%").arg(int(m_value * 100));
    p.setFont(m_muted ? Fonts::tiny : Fonts::numericTiny);
    p.setPen((m_muted || m_value == 0) ? Theme::meterRed : Theme::inkOnGlassSoft);
    p.drawText(readoutRect(), Qt::AlignVCenter | Qt::AlignRight, pct);
}

// ————————————————————————————————————————————————
// FaderView
// ————————————————————————————————————————————————
FaderView::FaderView(QWidget *parent) : QWidget(parent) {
    setAttribute(Qt::WA_Hover, true);
    setCursor(Qt::PointingHandCursor);
    connect(&GlassNotifier::instance(), &GlassNotifier::changed, this, [this] { update(); });
}

void FaderView::setGain(double g) {
    m_gain = qBound(m_min, g, m_max);
    update();
}

void FaderView::setFromY(qreal y) {
    const qreal top = 6, bottom = height() - 6;
    if (bottom <= top) return;
    const qreal t = qBound(0.0, double(y - top) / (bottom - top), 1.0); // 0=顶(max)
    m_gain = m_max - t * (m_max - m_min);
    emit gainChanged(m_gain);
    update();
}

void FaderView::enterEvent(QEnterEvent *) {
    m_hot = true;
    update();
}
void FaderView::leaveEvent(QEvent *) {
    m_hot = false;
    update();
}
void FaderView::mousePressEvent(QMouseEvent *e) {
    m_dragging = true;
    setFromY(e->position().y());
}
void FaderView::mouseMoveEvent(QMouseEvent *e) {
    if (m_dragging) setFromY(e->position().y());
}

void FaderView::paintEvent(QPaintEvent *) {
    if (width() < 4 || height() < 12) return;
    QPainter p(this);
    p.setRenderHint(QPainter::Antialiasing, true);
    const qreal top = 6, bottom = height() - 6;
    const qreal travel = qMax(1.0, bottom - top);
    const auto yOf = [&](double g) { return top + (m_max - g) / (m_max - m_min) * travel; };

    const qreal gw = qMin(6.0, width() * 0.4);
    const qreal cx = width() / 2.0;
    const QRectF groove(cx - gw / 2, top, gw, travel);
    QPainterPath gp;
    gp.addRoundedRect(groove, gw / 2, gw / 2);
    p.fillPath(gp, Theme::groove);
    p.setBrush(Qt::NoBrush);
    p.setPen(QPen(Theme::hairline, 1));
    p.drawPath(gp);

    // 0dB 基准线
    const qreal y0 = yOf(0);
    const qreal yv = yOf(m_gain);
    p.setPen(QPen(scaledAlpha(Theme::hairline, 0.9f), 1));
    p.drawLine(QPointF(2, y0), QPointF(width() - 2, y0));

    // 已填段（从 0 到当前值）
    if (qAbs(yv - y0) > 0.5) {
        const QRectF fr(cx - gw / 2, qMin(y0, yv), gw, qAbs(yv - y0));
        QLinearGradient g(fr.topLeft(), fr.bottomLeft());
        g.setColorAt(0.0, Theme::spectrumTop);
        g.setColorAt(1.0, Theme::spectrumBottom);
        p.fillRect(fr, g);
    }

    // 横向把手
    const qreal hw = qMin(20.0, width() - 2.0);
    const QRectF handle(cx - hw / 2, yv - 4, hw, 8);
    QPainterPath hp;
    hp.addRoundedRect(handle, 2, 2);
    QLinearGradient hg(handle.topLeft(), handle.bottomLeft());
    hg.setColorAt(0.0, m_hot ? Theme::buttonHotTop : Theme::buttonTop);
    hg.setColorAt(1.0, m_hot ? Theme::buttonHotBottom : Theme::buttonBottom);
    p.fillPath(hp, hg);
    p.setBrush(Qt::NoBrush);
    p.setPen(QPen(Theme::buttonEdge, 1));
    p.drawPath(hp);
}

// ————————————————————————————————————————————————
// KnobView
// ————————————————————————————————————————————————
KnobView::KnobView(QWidget *parent) : QWidget(parent) {
    setAttribute(Qt::WA_Hover, true);
    setCursor(Qt::PointingHandCursor);
    connect(&GlassNotifier::instance(), &GlassNotifier::changed, this, [this] { update(); });
}

void KnobView::setValue(double v) {
    m_value = qBound(m_min, v, m_max);
    update();
}

void KnobView::mousePressEvent(QMouseEvent *e) {
    m_lastPos = e->pos();
}
void KnobView::mouseMoveEvent(QMouseEvent *e) {
    if (!(e->buttons().testFlag(Qt::LeftButton))) return;
    const int dy = m_lastPos.y() - e->pos().y(); // 上拖增大
    m_lastPos = e->pos();
    if (dy == 0) return;
    m_value = qBound(m_min, m_value + dy * (m_max - m_min) / 150.0, m_max);
    emit valueChanged(m_value);
    update();
}
void KnobView::wheelEvent(QWheelEvent *e) {
    const double step = (m_max - m_min) / 40.0;
    m_value = qBound(m_min, m_value + (e->angleDelta().y() > 0 ? step : -step), m_max);
    emit valueChanged(m_value);
    update();
}

void KnobView::paintEvent(QPaintEvent *) {
    QPainter p(this);
    p.setRenderHint(QPainter::Antialiasing, true);
    const qreal capH = 12;
    const qreal d = qMin(double(width()), double(height()) - capH - 2);
    if (d < 6) return;
    const QPointF c(width() / 2.0, (height() - capH) / 2.0);
    const QRectF circ(c.x() - d / 2, c.y() - d / 2, d, d);
    QPainterPath kp;
    kp.addEllipse(circ);
    QLinearGradient kg(circ.topLeft(), circ.bottomLeft());
    kg.setColorAt(0.0, Theme::buttonTop);
    kg.setColorAt(1.0, Theme::buttonBottom);
    p.fillPath(kp, kg);
    p.setBrush(Qt::NoBrush);
    p.setPen(QPen(Theme::buttonEdge, 1));
    p.drawPath(kp);

    // 指示线：-135°..+135°（0 在正上）
    const double f = (m_value - m_min) / (m_max - m_min);
    const double ang = (-135 + f * 270) * 3.14159265358979323846 / 180.0;
    const QPointF dir(std::sin(ang), -std::cos(ang));
    p.setPen(QPen(Theme::inkOnGlassAccent, qMax(1.5, d * 0.09), Qt::SolidLine, Qt::RoundCap));
    p.drawLine(c, c + dir * (d / 2 - 3));

    if (!m_caption.isEmpty()) {
        p.setFont(Fonts::tiny);
        p.setPen(Theme::inkOnGlassSoft);
        p.drawText(QRectF(0, height() - capH, width(), capH), Qt::AlignCenter, m_caption);
    }
}
