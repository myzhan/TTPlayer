#include "AppIcon.h"

#include <QPainter>
#include <QPainterPath>
#include <QLinearGradient>
#include <QRectF>

// “蓝玻璃底 + 白色耳机”的应用图标画法。
// 坐标系差异：原画法原点在左下（y 向上），Qt 在左上（y 向下）。下面所有 y 相关
// 的偏移都按 s - y_origin 折过一遍；渐变 angle -90（自上而下）在 Qt 里
// 直接用 QLinearGradient(top→bottom) 表达。

namespace {

// 图标六色
const QColor kShellTop(0x6F, 0xB1, 0xEA);
const QColor kShellBottom(0x1A, 0x4A, 0x84);
const QColor kShellEdge(0x0E, 0x31, 0x59);
const QColor kGlyphFace(0xFD, 0xFE, 0xFF);
const QColor kGlyphShade(0xA9, 0xC6, 0xE2);
const QColor kGlyphShadow(0x0A, 0x27, 0x43);

// 耳机轮廓（Qt 坐标）：头梁是上半「月牙环」，两侧各一只胶囊耳罩压在梁端。
// bandY 是环心的 y（从顶算），返回可填充路径数组，本体与投影各按同组参数画一遍。
QList<QPainterPath> headphone(qreal cx, qreal bandY, qreal bandR, qreal thick, qreal cupW, qreal cupH) {
    const qreal outerR = bandR + thick / 2;
    const qreal innerR = bandR - thick / 2;
    const QRectF outerRect(cx - outerR, bandY - outerR, outerR * 2, outerR * 2);
    const QRectF innerRect(cx - innerR, bandY - innerR, innerR * 2, innerR * 2);

    // 上半环：外弧从 3 点逆时针（Qt 正角方向=屏幕向上）扫到 9 点，再沿内弧折回封口
    QPainterPath ring;
    ring.arcMoveTo(outerRect, 0);
    ring.arcTo(outerRect, 0, 180);
    ring.arcTo(innerRect, 180, -180);
    ring.closeSubpath();

    QList<QPainterPath> parts;
    parts.append(ring);
    // 耳罩：cup 底边在 bandY - cupH*0.82（从底算），折到 Qt 顶坐标
    // = bandY - cupH*0.18 为顶边，向下延伸 cupH。左右各一只，圆心 cx∓bandR。
    const qreal cupTop = bandY - cupH * 0.18;
    for (qreal dx : {-bandR, bandR}) {
        QRectF cup(cx + dx - cupW / 2, cupTop, cupW, cupH);
        QPainterPath c;
        c.addRoundedRect(cup, cupW / 2, cupW / 2);
        parts.append(c);
    }
    return parts;
}

} // namespace

namespace AppIcon {

QPixmap pixmap(int side) {
    const qreal s = side;
    QPixmap pm(side, side);
    pm.fill(Qt::transparent);

    QPainter p(&pm);
    p.setRenderHint(QPainter::Antialiasing, true);

    const QRectF body(s * 0.05, s * 0.05, s * 0.90, s * 0.90);
    const qreal radius = s * 0.20;
    const qreal hair = qMax<qreal>(1.0, std::round(s * 0.006));

    // 底：上浅下深的蓝玻璃 + 深描边
    {
        QPainterPath path;
        path.addRoundedRect(body, radius, radius);
        QLinearGradient g(body.topLeft(), body.bottomLeft());
        g.setColorAt(0.0, kShellTop);
        g.setColorAt(1.0, kShellBottom);
        p.fillPath(path, g);
        if (hair >= 1.0) {
            p.setPen(QPen(kShellEdge, hair));
            p.setBrush(Qt::NoBrush);
            p.drawPath(path);
        }
    }

    // 16px 单独收一版：反光 / 内沿亮线 / 投影在这个画布上只会变成噪点，
    // 梁与耳罩反过来要加粗（tiny 比例），否则缩进菜单栏/列表就散架
    const bool tiny = s < 24;

    if (!tiny) {
        p.save();
        QPainterPath clip;
        clip.addRoundedRect(body, radius, radius);
        p.setClipPath(clip);
        // 上半段玻璃反光：下半留深色，图标才有厚度，不会读成一块塑料片
        QLinearGradient sheen(QPointF(body.left(), body.top()), QPointF(body.left(), body.center().y()));
        sheen.setColorAt(0.0, QColor(255, 255, 255, 77)); // 0.30
        sheen.setColorAt(1.0, QColor(255, 255, 255, 0));
        p.fillRect(QRectF(body.left(), body.top(), body.width(), body.height() * 0.5), sheen);
        // 内沿亮线：玻璃边缘的一圈高光
        const qreal inset = hair * 1.5;
        QPainterPath rim;
        rim.addRoundedRect(body.adjusted(inset, inset, -inset, -inset), radius - inset, radius - inset);
        p.setPen(QPen(QColor(255, 255, 255, 77), hair)); // 0.30
        p.setBrush(Qt::NoBrush);
        p.drawPath(rim);
        p.restore();
    }

    const qreal cx = s * 0.5;
    const qreal bandY = s * 0.5; // body.minY + 0.45s 对称折到 Qt，即 0.5s
    const qreal bandR = s * 0.21;
    const qreal thick = s * (tiny ? 0.105 : 0.085);
    const qreal cupW = s * (tiny ? 0.23 : 0.20);
    const qreal cupH = s * (tiny ? 0.28 : 0.25);

    // 先垫一层深色投影（整体下压 0.012s）：蓝底上不加投影，白色耳机像贴纸浮在表面
    if (!tiny) {
        for (const QPainterPath &path : headphone(cx, bandY + s * 0.012, bandR, thick, cupW, cupH)) {
            p.fillPath(path, QColor(kGlyphShadow.red(), kGlyphShadow.green(), kGlyphShadow.blue(), 89)); // 0.35
        }
    }

    // 本体：近白填充 + 下沿压一层浅蓝灰渐变（纯白压蓝底会“发飘”，带渐变才有体积）
    for (const QPainterPath &path : headphone(cx, bandY, bandR, thick, cupW, cupH)) {
        p.save();
        p.setClipPath(path);
        p.fillPath(path, kGlyphFace);
        QLinearGradient g(body.topLeft(), body.bottomLeft());
        g.setColorAt(0.0, QColor(kGlyphShade.red(), kGlyphShade.green(), kGlyphShade.blue(), 0));
        g.setColorAt(1.0, QColor(kGlyphShade.red(), kGlyphShade.green(), kGlyphShade.blue(), 140)); // 0.55
        p.fillRect(body, g);
        p.restore();
    }

    p.end();
    return pm;
}

QIcon icon() {
    QIcon ic;
    // 覆盖 Dock / 任务栏 / 窗口标题栏 / Cmd-Tab 常见档位
    for (int side : {16, 24, 32, 48, 64, 128, 256, 512, 1024}) {
        ic.addPixmap(pixmap(side));
    }
    return ic;
}

} // namespace AppIcon
