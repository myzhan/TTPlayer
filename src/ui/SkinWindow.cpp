#include "SkinWindow.h"

#include "Theme.h"
#include "SkinParts.h"
#include "Painter.h"
#include "app/Application.h"
#ifdef Q_OS_WIN
#include "MainWindow.h"
#endif
#include <QDragEnterEvent>
#include <QDropEvent>
#include <QMimeData>

#include <QVBoxLayout>
#include <QHBoxLayout>
#include <QLabel>
#include <QPainter>
#include <QMouseEvent>
#include <QPaintEvent>
#include <QShowEvent>
#include <QWindow>

// 圆角半径与主窗一致：壳、mask（不再需要）、描边都对齐。
static constexpr qreal kSkinRadius = 10.0;

namespace {

// 标题条：浅玻璃渐变，按下空白处交给系统移动整窗（无边框窗唯一可拖的地方）。
class SkinTitleBar : public QWidget {
public:
    explicit SkinTitleBar(QWidget *parent = nullptr) : QWidget(parent) {
        setFixedHeight(22);
        connect(&GlassNotifier::instance(), &GlassNotifier::changed, this, [this] { update(); });
    }

protected:
    void paintEvent(QPaintEvent *) override {
        QPainter p(this);
        // 标题条跟随所属窗；转换等不跟随的窗口仍使用不透明背景。
        const auto *shell = qobject_cast<SkinWindow *>(window());
        const float a = shell ? shell->shellAlpha() : (GlassStyle::enabled() ? GlassStyle::glassAlpha() : 1.0f);
        Painter::drawBody(&p, QRectF(rect()), Theme::titleTop, Theme::titleBottom, a, 0, Theme::skinEdge, true);
    }
    void mousePressEvent(QMouseEvent *e) override {
        if (e->button() == Qt::LeftButton) {
            if (auto *wh = window()->windowHandle(); wh && wh->startSystemMove()) {
                QWidget::mousePressEvent(e);
                return;
            }
        }
        QWidget::mousePressEvent(e);
    }
};

// 无边框窗没有原生缩放手柄：命中左/右/下三侧边缘带交给系统缩放。顶边让给标题条拖动，
// 不与缩放抢（与主窗同一口径）。
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

SkinWindow::SkinWindow(const QString &title, TitleButtons buttons, QWidget *parent) : QWidget(parent) {
#ifdef Q_OS_WIN
    // 副面板是工具窗，不占独立任务栏/Alt-Tab 入口；主窗仍是普通 Window。
    setWindowFlags(Qt::Tool | Qt::FramelessWindowHint);
#else
    setWindowFlags(Qt::Window | Qt::FramelessWindowHint);
#endif
    setAttribute(Qt::WA_TranslucentBackground, true);
    connect(&GlassNotifier::instance(), &GlassNotifier::changed, this, [this] { update(); });
    setMouseTracking(true); // 未按键也收 move，边缘光标才能提前变缩放形状
    setWindowTitle(title);
    setAcceptDrops(true);

    auto *root = new QVBoxLayout(this);
    root->setContentsMargins(4, 4, 4, 6);
    root->setSpacing(3);

    auto *bar = new SkinTitleBar(this);
    m_titleBar = bar;
    auto *bl = new QHBoxLayout(bar);
    bl->setContentsMargins(8, 1, 4, 1);
    bl->setSpacing(3);

    auto *cap = new QLabel(title, bar);
    cap->setFont(Fonts::panelTitle);
    cap->setStyleSheet(QStringLiteral("color:%1;background:transparent;").arg(Theme::titleText.name()));

    bl->addWidget(cap);
    bl->addStretch();
    if (buttons == TitleButtons::MinimizeAndClose) {
        auto *minBtn = new TTButton(bar);
        minBtn->setObjectName(QStringLiteral("panelMinimize"));
        minBtn->setGlyph(Skin::Glyph::Minus);
        minBtn->setFace(TTButton::Face::Glass);
        minBtn->setPreferredSize({22, 18});
        minBtn->setToolTip(QStringLiteral("最小化"));
        bl->addWidget(minBtn);
        connect(minBtn, &TTButton::clicked, this, [this] { onMinimize(); });
    }
    if (buttons != TitleButtons::None) {
        auto *closeBtn = new TTButton(bar);
        closeBtn->setObjectName(QStringLiteral("panelClose"));
        closeBtn->setGlyph(Skin::Glyph::Close);
        closeBtn->setFace(TTButton::Face::Glass);
        closeBtn->setPreferredSize({22, 18});
        closeBtn->setToolTip(QStringLiteral("关闭"));
        bl->addWidget(closeBtn);
        connect(closeBtn, &TTButton::clicked, this, [this] { onClose(); });
    }

    m_body = new QWidget(this);
    root->addWidget(bar);
    root->addWidget(m_body, 1);
}

void SkinWindow::paintEvent(QPaintEvent *) {
    QPainter p(this);
    Painter::drawBody(&p, QRectF(rect()), Theme::windowTop, Theme::windowBottom, shellAlpha(), kSkinRadius,
                      Theme::skinEdge, true);
    if (m_body) paintBody(&p, QRectF(m_body->geometry()));
}

void SkinWindow::setGlassTransparencyFollows(bool on) {
    if (m_followGlass == on) return;
    m_followGlass = on;
    update();
    if (m_titleBar) m_titleBar->update();
}

float SkinWindow::shellAlpha() const {
    return (m_followGlass && GlassStyle::enabled()) ? GlassStyle::glassAlpha() : 1.0f;
}

void SkinWindow::showEvent(QShowEvent *e) {
    QWidget::showEvent(e);
    if (m_body) m_body->update(); // body 透明，靠父窗 paintBody 铺底，尺寸落定后补一次
}

void SkinWindow::setTitleBarVisible(bool visible) {
    m_titleBar->setVisible(visible);
}
void SkinWindow::dragEnterEvent(QDragEnterEvent *event) {
    if (event->mimeData()->hasUrls()) event->acceptProposedAction();
}
void SkinWindow::dropEvent(QDropEvent *event) {
    QStringList paths;
    for (const QUrl &url : event->mimeData()->urls())
        paths << (url.isLocalFile() ? url.toLocalFile() : url.toString());
    if (paths.isEmpty()) return;
    emit filesDropped(paths);
    if (auto *app = dynamic_cast<PlayerApplication *>(qApp); app && app->openFiles) app->openFiles(paths);
    event->acceptProposedAction();
}

void SkinWindow::onClose() {
    close();
}
void SkinWindow::onMinimize() {
#ifdef Q_OS_WIN
    // 工具窗没有任务栏恢复入口，最小化键统一交给主窗收起整组。
    if (auto *main = qobject_cast<MainWindow *>(parentWidget())) {
        main->hideGroupToBackground();
        return;
    }
#endif
    showMinimized();
}

void SkinWindow::mousePressEvent(QMouseEvent *e) {
    if (e->button() == Qt::LeftButton) {
        const Qt::Edges edges = frameResizeEdges(this, e->position());
        if (edges != Qt::Edges()) {
            if (auto *wh = windowHandle(); wh && wh->startSystemResize(edges)) return;
        }
        if (!m_titleBar->isVisible())
            if (auto *wh = windowHandle(); wh && wh->startSystemMove()) return;
    }
    QWidget::mousePressEvent(e);
}

void SkinWindow::mouseMoveEvent(QMouseEvent *e) {
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
