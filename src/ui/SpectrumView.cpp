#include "SpectrumView.h"
#include "Theme.h"

#include <QLinearGradient>
#include <QPainter>
#include <QPainterPath>
#include <QWindow>
#include <QGuiApplication>
#include <cmath>

SpectrumView::SpectrumView(AudioEnginePtr engine, QWidget *parent)
    : QWidget(parent), m_engine(std::move(engine)) {
    setAttribute(Qt::WA_OpaquePaintEvent, false);
    // 24 fps：常数提到构造，回调里不再拼任何字符串/重算不变量（AGENTS.md 热路径）
    m_timer.setInterval(1000 / 24);
    connect(&m_timer, &QTimer::timeout, this, [this] {
        const auto handle=window()->windowHandle();
        const bool visible=isVisible() && !window()->isMinimized() && handle && handle->isExposed()
                           && QGuiApplication::applicationState()!=Qt::ApplicationSuspended;
        m_engine->setSpectrumEnabled(visible);
        if (visible) {
            const QRect dirty = advanceFrame();
            if (!dirty.isEmpty()) update(dirty);
            emit frameRequested();
        }
    });
    connect(&GlassNotifier::instance(), &GlassNotifier::changed, this, [this] { update(); });
}

void SpectrumView::hideEvent(QHideEvent *e) { m_timer.stop(); m_engine->setSpectrumEnabled(false); QWidget::hideEvent(e); }
void SpectrumView::showEvent(QShowEvent *e) { m_timer.start(); QWidget::showEvent(e); }

QRect SpectrumView::advanceFrame() {
    std::array<float, SpectrumAnalyzer::kBands> next{};
    m_engine->spectrumBands(next.data());
    const qreal dpr = devicePixelRatioF();
    const qreal barWidth = (width() + 1.0) / next.size() - 1.0;
    QRect dirty;
    // The base of each bar and its gradient are fixed. Only the moving upper
    // edge and peak cap need their old and new pixels repainted.
    auto mark = [&](int band, qreal from, qreal to, qreal thickness) {
        if (from == to) return;
        const qreal low = std::min(from, to);
        const qreal high = std::max(from, to);
        // On integer-scale screens aliased edges cannot cross a pixel centre
        // in this interval. Leave a margin for the rasterizer's fixed point rounding.
        auto sameRow = [dpr](qreal lo, qreal hi) {
            return std::floor(lo * dpr + 0.46) == std::floor(hi * dpr + 0.54);
        };
        if (dpr == std::floor(dpr) && sameRow(low, high) &&
            sameRow(low + thickness, high + thickness)) return;
        dirty |= QRectF(band * (barWidth + 1), low - 1, barWidth + 2,
                        high - low + thickness + 2).toAlignedRect();
    };
    for (size_t i = 0; i < next.size(); ++i) {
        const float peak = std::max(next[i], m_peaks[i] - 0.018f);
        mark(int(i), height() - height() * m_bands[i], height() - height() * next[i], 0);
        mark(int(i), height() - height() * m_peaks[i], height() - height() * peak, 1.5);
        m_peaks[i] = peak;
    }
    m_bands = next;
    return dirty;
}

void SpectrumView::paintEvent(QPaintEvent *) {
    QPainter p(this);
    p.setRenderHint(QPainter::Antialiasing, false);
    const QRectF r = rect();
    if (r.width() < 2 || r.height() < 2) return;


    constexpr int n = SpectrumAnalyzer::kBands;
    const qreal gap = 1.0;
    const qreal barW = (r.width() - gap * (n - 1)) / n;

    // 统一毛玻璃：深玻璃上先铺几条水平发丝网格（淡墨，不抢橙柱）。
    p.setPen(QPen(Theme::spectrumGrid, 1));
    for (int g = 1; g <= 3; ++g) {
        const qreal y = r.bottom() - r.height() * g / 4.0;
        p.drawLine(QPointF(r.left(), y), QPointF(r.right(), y));
    }

    // 整块竖向渐变一次建好（不逐柱各画渐变——那会让 CPU 退化 8 个百分点）
    QLinearGradient grad(r.bottomLeft(), r.topLeft());
    grad.setColorAt(0.0, Theme::spectrumBottom);
    grad.setColorAt(1.0, Theme::spectrumTop);

    // 所有柱子合成一条路径裁一次
    QPainterPath bars;
    for (int i = 0; i < n; ++i) {
        const float v = m_bands[i];
        const qreal h = std::max<qreal>(0.0, v * r.height());
        const qreal x = i * (barW + gap);
        bars.addRect(QRectF(x, r.bottom() - h, barW, h));
    }
    p.fillPath(bars, grad);

    // 柱尖高光一次填充
    p.setPen(Qt::NoPen);
    p.setBrush(Theme::spectrumPeak);
    QPainterPath caps;
    for (int i = 0; i < n; ++i) {
        const qreal y = r.bottom() - m_peaks[i] * r.height();
        caps.addRect(QRectF(i * (barW + gap), y, barW, 1.5));
    }
    p.drawPath(caps);
}
