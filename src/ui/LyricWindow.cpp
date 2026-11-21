#include "LyricWindow.h"
#include "Theme.h"
#include "Painter.h"

#include <QPainter>
#include <QPainterPath>

LyricWindow::LyricWindow(PlayerController *controller, QWidget *parent)
    : SkinWindow(QStringLiteral("歌词"), true, parent), m_controller(controller) {
    resize(480, 260 + 30); // 高度补上自绘标题条（~30）
    setMinimumSize(320, 160);

    connect(m_controller, &PlayerController::trackChanged, this, &LyricWindow::reload);
    connect(m_controller, &PlayerController::lyricShiftChanged, this, &LyricWindow::reload);
    connect(m_controller, &PlayerController::positionTicked, this, [this](double pos, double) {
        m_pos = pos;
        // 查行只认控制器对齐后的歌词时间轴（整盘词加段起点、用户校准减掉）
        const int idx = m_lyric.lineIndexAt(m_controller->alignedLyricTime(pos));
        if (idx != m_index) {
            m_index = idx;
            update();
        }
    });
    reload();
}

void LyricWindow::reload() {
    m_lyric = m_controller->currentLyric(); // 控制器统一持有当前歌词
    m_pos = m_controller->position();
    m_index = m_lyric.lineIndexAt(m_controller->alignedLyricTime(m_pos));
    update();
}

void LyricWindow::paintBody(QPainter *p, const QRectF &r) {
    p->save();
    p->setRenderHint(QPainter::Antialiasing, true);
    p->translate(r.topLeft());
    const QRectF box(0, 0, r.width(), r.height());
    // 统一毛玻璃：与主窗/列表窗同一层浅玻璃（不再铺深蓝 well），单一 alpha。
    const float wA = GlassStyle::enabled() ? GlassStyle::wellAlpha() : 1.0f;
    Painter::drawWell(p, box.adjusted(0.5, 0.5, -0.5, -0.5), Theme::windowTop, Theme::windowBottom, wA, 5);

    const QRectF area = box.adjusted(14, 10, -14, -10);
    if (m_lyric.isEmpty()) {
        p->setFont(Fonts::title);
        p->setPen(Theme::inkOnGlassSoft);
        p->drawText(area, Qt::AlignCenter, QStringLiteral("纯音乐 / 无歌词"));
        p->restore();
        return;
    }

    const auto &lines = m_lyric.lines();
    const qreal lineH = 30;
    const qreal center = area.center().y();
    for (int i = 0; i < int(lines.size()); ++i) {
        const qreal dy = (i - m_index) * lineH;
        const qreal y = center + dy;
        if (y < area.top() - lineH || y > area.bottom() + lineH) continue;
        const int dist = qAbs(i - m_index);
        QFont f = Fonts::base;
        QColor color = Theme::inkOnGlassSoft;
        if (dist == 0) {
            f = Fonts::title;
            f.setPixelSize(17);
            f.setBold(true);
            color = Theme::inkOnGlassAccent;
        } else if (dist == 1) {
            color = Theme::inkOnGlass;
        }
        // 越远越淡
        float alpha = dist == 0 ? 1.0f : (dist == 1 ? 0.7f : 0.35f);
        color.setAlphaF(color.alphaF() * alpha);
        p->setFont(f);
        p->setPen(color);
        const QRectF rr(area.left(), y - lineH / 2, area.width(), lineH);
        p->drawText(rr, Qt::AlignCenter, lines[i].text);
    }
    p->restore();
}
