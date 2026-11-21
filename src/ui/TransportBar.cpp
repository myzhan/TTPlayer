#include "TransportBar.h"
#include "Painter.h"
#include "Theme.h"

#include <QHBoxLayout>
#include <QPainter>

namespace {
TTButton *makeBtn(Skin::Glyph g, QWidget *parent) {
    auto *b = new TTButton(parent);
    b->setGlyph(g);
    b->setFace(TTButton::Face::Glass);
    b->setPreferredSize({g == Skin::Glyph::Play ? 38 : 30, 20});
    return b;
}
}

TransportBar::TransportBar(PlayerController *controller, QWidget *parent) : QWidget(parent), m_controller(controller) {
    auto *lay = new QHBoxLayout(this);
    lay->setContentsMargins(3, 2, 3, 2);
    lay->setSpacing(3);

    auto *prev = makeBtn(Skin::Glyph::Prev, this);
    m_play = makeBtn(Skin::Glyph::Play, this);
    auto *stop = makeBtn(Skin::Glyph::Stop, this);
    auto *next = makeBtn(Skin::Glyph::Next, this);
    m_mode = makeBtn(Skin::Glyph::ListLoop, this);
    m_mode->setPreferredSize({34, 20}); // 模式图标细节多，比传输键略宽
    m_mode->setGlyphScale(0.82);        // 默认 0.62 太小，循环/单曲难辨

    lay->addWidget(stop);
    lay->addWidget(prev);
    lay->addWidget(m_play);
    lay->addWidget(next);
    lay->addWidget(m_mode);

    connect(prev, &QAbstractButton::clicked, controller, &PlayerController::prev);
    connect(next, &QAbstractButton::clicked, controller, &PlayerController::next);
    connect(stop, &QAbstractButton::clicked, controller, &PlayerController::stop);
    connect(m_play, &QAbstractButton::clicked, controller, &PlayerController::togglePlay);
    connect(m_mode, &QAbstractButton::clicked, this, [controller] {
        // 四模式轮转：顺序→列表循环→单曲循环→随机
        static const PlayMode order[] = {PlayMode::Order, PlayMode::ListLoop, PlayMode::SingleLoop, PlayMode::Random};
        const PlayMode cur = controller->mode();
        int i = 0;
        for (int k = 0; k < 4; ++k)
            if (order[k] == cur) i = k;
        controller->setMode(order[(i + 1) % 4]);
    });

    auto syncPlay = [this] { m_play->setGlyph(m_controller->isPlaying() ? Skin::Glyph::Pause : Skin::Glyph::Play); };
    auto syncMode = [this] {
        using G = Skin::Glyph;
        G g = G::ListLoop;
        switch (m_controller->mode()) {
        case PlayMode::Order:
            g = G::Sequential;
            break; // 顺序：向右箭头（播完到底）
        case PlayMode::ListLoop:
            g = G::ListLoop;
            break;
        case PlayMode::SingleLoop:
            g = G::RepeatOne;
            break;
        case PlayMode::Random:
            g = G::Shuffle;
            break;
        }
        m_mode->setGlyph(g);
        m_mode->setLit(m_controller->mode() != PlayMode::Order);
    };
    connect(controller, &PlayerController::playbackStateChanged, this, syncPlay);
    connect(controller, &PlayerController::modeChanged, this, syncMode);
    syncPlay();
    syncMode();
}

void TransportBar::paintEvent(QPaintEvent *) {
    QPainter p(this);
    Painter::drawBody(&p, QRectF(rect()), Theme::windowTop, Theme::windowBottom, GlassStyle::glassAlpha(), 0,
                      Theme::skinEdge, false);
}
