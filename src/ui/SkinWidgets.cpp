#include "SkinWidgets.h"

#include "Theme.h"
#include "Painter.h"
#include "SkinParts.h"

#include <QPainter>
#include <QPainterPath>
#include <QMouseEvent>
#include <QWheelEvent>
#include <QPaintEvent>
#include <QStackedWidget>
#include <QLineEdit>
#include <QVBoxLayout>
#include <QFontMetrics>

namespace {
QColor scaledAlpha(QColor c, float a) {
    c.setAlphaF(c.alphaF() * a);
    return c;
}

// 小下拉三角（combo / spinbox 复用）
void drawChevron(QPainter *p, const QRectF &box, bool up, const QColor &color) {
    p->save();
    p->setRenderHint(QPainter::Antialiasing, true);
    p->setPen(Qt::NoPen);
    p->setBrush(color);
    const qreal cx = box.center().x(), cy = box.center().y();
    const qreal w = qMin<qreal>(6.0, box.width() * 0.4), h = 3.5;
    QPainterPath t;
    if (up) {
        t.moveTo(cx - w, cy + h);
        t.lineTo(cx + w, cy + h);
        t.lineTo(cx, cy - h);
    } else {
        t.moveTo(cx - w, cy - h);
        t.lineTo(cx + w, cy - h);
        t.lineTo(cx, cy + h);
    }
    t.closeSubpath();
    p->drawPath(t);
    p->restore();
}
} // namespace

// ————————————————————————————————————————————————
// SkinSection
// ————————————————————————————————————————————————
SkinSection::SkinSection(const QString &title, QWidget *parent) : QWidget(parent), m_title(title) {
    auto *v = new QVBoxLayout(this);
    v->setContentsMargins(2, 22, 2, 4); // 顶部留 22 给标题 + 发丝
    v->setSpacing(0);
    m_content = new QWidget(this);
    v->addWidget(m_content);
    connect(&GlassNotifier::instance(), &GlassNotifier::changed, this, [this] { update(); });
}

void SkinSection::paintEvent(QPaintEvent *) {
    QPainter p(this);
    p.setRenderHint(QPainter::Antialiasing, false);
    // 标题（深字，浅底上）
    p.setFont(Fonts::small);
    p.setPen(Theme::inkOnGlassSoft);
    p.drawText(QRectF(2, 2, width() - 4, 18), Qt::AlignVCenter | Qt::AlignLeft, m_title);
    // 标题下方一条发丝线
    const float a = GlassStyle::enabled() ? GlassStyle::glassAlpha() : 1.0f;
    p.setPen(QPen(scaledAlpha(Theme::hairline, a), 1));
    const qreal y = 20.5;
    p.drawLine(QPointF(2, y), QPointF(width() - 2, y));
}

// ————————————————————————————————————————————————
// SkinCheckBox
// ————————————————————————————————————————————————
SkinCheckBox::SkinCheckBox(const QString &text, QWidget *parent) : QAbstractButton(parent), m_text(text) {
    setCheckable(true);
    setCursor(Qt::PointingHandCursor);
    setAttribute(Qt::WA_Hover, true);
    connect(&GlassNotifier::instance(), &GlassNotifier::changed, this, [this] { update(); });
}

QSize SkinCheckBox::sizeHint() const {
    QFontMetrics fm(Fonts::base);
    return {fm.horizontalAdvance(m_text) + 30, 26};
}

void SkinCheckBox::paintEvent(QPaintEvent *) {
    QPainter p(this);
    const bool hot = underMouse() && isEnabled();
    const QRectF frame = QRectF(rect()).adjusted(0.5, 0.5, -0.5, -0.5);
    // 整行 hover 轻亮（静止透明）
    Painter::drawHoverFace(&p, frame, hot, isDown(), 4, false);
    // 勾选方块
    const qreal bs = 15;
    const QRectF box(6, (height() - bs) / 2.0, bs, bs);
    const float a = GlassStyle::enabled() ? GlassStyle::glassAlpha() : 1.0f;
    QPainterPath bp;
    bp.addRoundedRect(box, 3, 3);
    if (isChecked()) {
        p.fillPath(bp, scaledAlpha(Theme::textAccent, 0.9f));
        p.setBrush(Qt::NoBrush);
        p.setPen(QPen(scaledAlpha(Theme::inkOnGlassAccent, 1.0f), 1));
        p.drawPath(bp);
        Skin::drawGlyph(&p, Skin::Glyph::Check, box, Theme::inkOnGlass, 0.7);
    } else {
        p.setBrush(Qt::NoBrush);
        p.setPen(QPen(scaledAlpha(Theme::hairline, 1.0f), 1));
        p.drawPath(bp);
    }
    // 文字
    p.setFont(Fonts::base);
    p.setPen(isChecked() ? Theme::inkOnGlass : scaledAlpha(Theme::inkOnGlass, 0.92f));
    p.drawText(QRectF(box.right() + 8, 0, width() - box.right() - 10, height()), Qt::AlignVCenter | Qt::AlignLeft,
               m_text);
    Q_UNUSED(a);
}

// ————————————————————————————————————————————————
// SkinTabWidget
// ————————————————————————————————————————————————
SkinTabWidget::SkinTabWidget(QWidget *parent) : QWidget(parent) {
    m_stack = new QStackedWidget(this);
    auto *v = new QVBoxLayout(this);
    v->setContentsMargins(0, kTabH + 6, 0, 0);
    v->setSpacing(0);
    v->addWidget(m_stack);
    connect(&GlassNotifier::instance(), &GlassNotifier::changed, this, [this] { update(); });
}

int SkinTabWidget::addTab(QWidget *page, const QString &label) {
    const int i = m_stack->addWidget(page);
    m_labels << label;
    if (m_labels.size() == 1) {
        m_current = 0;
        m_stack->setCurrentIndex(0);
    }
    update();
    return i;
}

void SkinTabWidget::setCurrentIndex(int i) {
    if (i < 0 || i >= m_labels.size() || i == m_current) return;
    m_current = i;
    m_stack->setCurrentIndex(i);
    emit currentChanged(i);
    update();
}

QRectF SkinTabWidget::tabRect(int i) const {
    QFontMetrics fm(Fonts::base);
    qreal x = 4;
    for (int k = 0; k < i; ++k)
        x += fm.horizontalAdvance(m_labels[k]) + 24;
    const qreal w = fm.horizontalAdvance(m_labels[i]) + 24;
    return QRectF(x, 4, w, kTabH - 4);
}

void SkinTabWidget::paintEvent(QPaintEvent *) {
    QPainter p(this);
    QFontMetrics fm(Fonts::base);
    for (int i = 0; i < m_labels.size(); ++i) {
        const QRectF r = tabRect(i);
        const bool sel = (i == m_current);
        const bool hot = (i == m_hot) && !sel;
        Painter::drawHoverFace(&p, r, hot, false, 5, false);
        if (sel) {
            // 选中：一层极淡 accent + 底部 accent 下划线
            p.fillPath(
                [&] {
                    QPainterPath q;
                    q.addRoundedRect(r, 5, 5);
                    return q;
                }(),
                scaledAlpha(Theme::textAccent, 0.16f));
            p.setPen(Qt::NoPen);
            p.setBrush(scaledAlpha(Theme::inkOnGlassAccent, 0.9f));
            p.drawRect(QRectF(r.left() + 6, r.bottom() - 1, r.width() - 12, 2));
        }
        p.setFont(Fonts::small);
        p.setPen(sel ? Theme::inkOnGlass : scaledAlpha(Theme::inkOnGlass, 0.7f));
        p.drawText(r, Qt::AlignCenter, m_labels[i]);
    }
    Q_UNUSED(fm);
}

void SkinTabWidget::mousePressEvent(QMouseEvent *e) {
    for (int i = 0; i < m_labels.size(); ++i)
        if (tabRect(i).contains(e->position())) {
            setCurrentIndex(i);
            return;
        }
    QWidget::mousePressEvent(e);
}

void SkinTabWidget::mouseMoveEvent(QMouseEvent *e) {
    int h = -1;
    for (int i = 0; i < m_labels.size(); ++i)
        if (tabRect(i).contains(e->position())) {
            h = i;
            break;
        }
    if (h != m_hot) {
        m_hot = h;
        update();
    }
}

void SkinTabWidget::leaveEvent(QEvent *) {
    if (m_hot != -1) {
        m_hot = -1;
        update();
    }
}

// ————————————————————————————————————————————————
// SkinComboBox
// ————————————————————————————————————————————————
SkinComboBox::SkinComboBox(QWidget *parent) : QWidget(parent) {
    setCursor(Qt::PointingHandCursor);
    setAttribute(Qt::WA_Hover, true);
    setSizePolicy(QSizePolicy::Expanding, QSizePolicy::Fixed);
    connect(&GlassNotifier::instance(), &GlassNotifier::changed, this, [this] { update(); });
}

void SkinComboBox::addItem(const QString &text, const QVariant &data) {
    m_texts << text;
    m_datas << data;
    if (m_current < 0)
        setCurrentIndex(0);
    else
        update();
}

void SkinComboBox::setCurrentIndex(int i) {
    if (i < 0 || i >= m_texts.size()) return;
    const bool changed = (i != m_current);
    m_current = i;
    update();
    if (changed) emit currentIndexChanged(i);
}

void SkinComboBox::paintEvent(QPaintEvent *) {
    QPainter p(this);
    const QRectF frame = QRectF(rect()).adjusted(0.5, 0.5, -0.5, -0.5);
    const bool pressed = underMouse() && (m_hot || rect().contains(mapFromGlobal(QCursor::pos())));
    // 静止留一圈发丝轮廓（下拉框需要可见边界），hover 轻亮
    Painter::drawHoverFace(&p, frame, m_hot, false, 5, /*hairlineRest=*/true);
    Q_UNUSED(pressed);
    p.setFont(Fonts::base);
    p.setPen(Theme::inkOnGlass);
    const QString cur = m_current >= 0 ? m_texts.value(m_current) : QString();
    p.drawText(QRectF(8, 0, width() - 26, height()), Qt::AlignVCenter | Qt::AlignLeft, cur);
    drawChevron(&p, QRectF(width() - 20, 0, 16, height()), false, scaledAlpha(Theme::inkOnGlass, 0.8f));
}

void SkinComboBox::mousePressEvent(QMouseEvent *) {
    if (!m_texts.isEmpty()) openPopup();
}

void SkinComboBox::enterEvent(QEnterEvent *) {
    m_hot = true;
    update();
}
void SkinComboBox::leaveEvent(QEvent *) {
    m_hot = false;
    update();
}

void SkinComboBox::openPopup() {
    auto *pop = new QWidget(nullptr, Qt::Popup);
    pop->setAttribute(Qt::WA_DeleteOnClose);
    auto *v = new QVBoxLayout(pop);
    v->setContentsMargins(1, 1, 1, 1);
    auto *list = new SkinListView(pop);
    list->setOpaqueBg(true);
    list->setItems(m_texts);
    list->setCurrentRow(m_current);
    v->addWidget(list);
    const int want = qMax(width(), 160);
    list->setMinimumWidth(want);
    pop->resize(want, qMin(280, m_texts.size() * 26 + 4));
    connect(list, &SkinListView::itemClicked, pop, [pop](int) { pop->close(); });
    connect(list, &SkinListView::currentRowChanged, this, [this](int row) {
        if (row >= 0 && row < m_texts.size()) {
            setCurrentIndex(row);
            emit activated(row);
        }
    });
    pop->show();
    pop->move(mapToGlobal(QPoint(0, height())));
}

// ————————————————————————————————————————————————
// SkinSpinBox
// ————————————————————————————————————————————————
SkinSpinBox::SkinSpinBox(QWidget *parent) : QWidget(parent) {
    setAttribute(Qt::WA_Hover, true);
    setSizePolicy(QSizePolicy::Fixed, QSizePolicy::Fixed);
    connect(&GlassNotifier::instance(), &GlassNotifier::changed, this, [this] { update(); });
}

void SkinSpinBox::setRange(int lo, int hi) {
    m_lo = lo;
    m_hi = hi;
    setValue(m_value);
}

void SkinSpinBox::setValue(int v) {
    const int c = qBound(m_lo, v, m_hi);
    if (c == m_value) return;
    m_value = c;
    emit valueChanged(m_value);
    update();
}

QRectF SkinSpinBox::upRect() const {
    return QRectF(width() - 18, 1, 17, height() / 2.0 - 1);
}
QRectF SkinSpinBox::downRect() const {
    return QRectF(width() - 18, height() / 2.0, 17, height() / 2.0 - 1);
}

void SkinSpinBox::step(int dir) {
    setValue(m_value + dir);
}

void SkinSpinBox::paintEvent(QPaintEvent *) {
    QPainter p(this);
    const QRectF frame = QRectF(rect()).adjusted(0.5, 0.5, -0.5, -0.5);
    // 值区静止发丝轮廓
    p.setBrush(Qt::NoBrush);
    const float a = GlassStyle::enabled() ? GlassStyle::glassAlpha() : 1.0f;
    QPainterPath body;
    body.addRoundedRect(frame, 5, 5);
    p.setPen(QPen(scaledAlpha(Theme::hairline, a), 1));
    p.drawPath(body);
    p.setFont(Fonts::base);
    p.setPen(Theme::inkOnGlass);
    p.drawText(QRectF(8, 0, width() - 30, height()), Qt::AlignVCenter | Qt::AlignLeft,
               QString::number(m_value) + m_suffix);
    // 上下按钮 hover-face
    Painter::drawHoverFace(&p, upRect(), m_hotBtn == 1, false, 3, false);
    Painter::drawHoverFace(&p, downRect(), m_hotBtn == -1, false, 3, false);
    drawChevron(&p, upRect(), true, scaledAlpha(Theme::inkOnGlass, 0.85f));
    drawChevron(&p, downRect(), false, scaledAlpha(Theme::inkOnGlass, 0.85f));
}

void SkinSpinBox::mousePressEvent(QMouseEvent *e) {
    if (upRect().contains(e->position()))
        step(+1);
    else if (downRect().contains(e->position()))
        step(-1);
}

void SkinSpinBox::enterEvent(QEnterEvent *) {
    setMouseTracking(true);
}
void SkinSpinBox::leaveEvent(QEvent *) {
    if (m_hotBtn) {
        m_hotBtn = 0;
        update();
    }
}

void SkinSpinBox::mouseMoveEvent(QMouseEvent *e) {
    int h = 0;
    if (upRect().contains(e->position()))
        h = 1;
    else if (downRect().contains(e->position()))
        h = -1;
    if (h != m_hotBtn) {
        m_hotBtn = h;
        update();
    }
}

// ————————————————————————————————————————————————
// SkinSlider
// ————————————————————————————————————————————————
SkinSlider::SkinSlider(QWidget *parent) : QWidget(parent) {
    setCursor(Qt::PointingHandCursor);
    setAttribute(Qt::WA_Hover, true);
    setSizePolicy(QSizePolicy::Expanding, QSizePolicy::Fixed);
    connect(&GlassNotifier::instance(), &GlassNotifier::changed, this, [this] { update(); });
}

void SkinSlider::setRange(int lo, int hi) {
    m_lo = lo;
    m_hi = hi;
    update();
}

void SkinSlider::setValue(int v) {
    const int c = qBound(m_lo, v, m_hi);
    if (c == m_value) return;
    m_value = c;
    emit valueChanged(m_value);
    update();
}

QRectF SkinSlider::grooveRect() const {
    const qreal h = 4;
    return QRectF(2, (height() - h) / 2.0, width() - 4, h);
}

void SkinSlider::setFromX(qreal x) {
    const QRectF g = grooveRect();
    if (g.width() <= 0) return;
    const double t = qBound(0.0, (x - g.left()) / g.width(), 1.0);
    setValue(m_lo + int(std::lround(t * (m_hi - m_lo))));
}

void SkinSlider::paintEvent(QPaintEvent *) {
    QPainter p(this);
    p.setRenderHint(QPainter::Antialiasing, true);
    const QRectF g = grooveRect();
    const float a = GlassStyle::enabled() ? GlassStyle::glassAlpha() : 1.0f;
    // 槽：发丝底
    QPainterPath gp;
    gp.addRoundedRect(g, 2, 2);
    p.fillPath(gp, scaledAlpha(Theme::hairline, 0.9f));
    // 已填段：accent
    const double t = m_hi > m_lo ? double(m_value - m_lo) / (m_hi - m_lo) : 0.0;
    QRectF fill(g.left(), g.top(), g.width() * t, g.height());
    QPainterPath fp;
    fp.addRoundedRect(fill, 2, 2);
    p.fillPath(fp, scaledAlpha(Theme::inkOnGlassAccent, 0.85f));
    // 把手：玻璃圆，hover 轻亮
    const qreal hr = (m_hot || m_dragging) ? 7.0 : 6.0;
    const QPointF hc(g.left() + g.width() * t, g.center().y());
    QRectF handle(hc.x() - hr, hc.y() - hr, hr * 2, hr * 2);
    p.setPen(QPen(scaledAlpha(Theme::hairline, 1.0f), 1));
    p.setBrush(scaledAlpha(Theme::windowTop, m_hot || m_dragging ? 1.0f : 0.9f));
    p.drawEllipse(handle);
    Q_UNUSED(a);
}

void SkinSlider::mousePressEvent(QMouseEvent *e) {
    m_dragging = true;
    setFromX(e->position().x());
}
void SkinSlider::mouseMoveEvent(QMouseEvent *e) {
    if (m_dragging) setFromX(e->position().x());
}
void SkinSlider::mouseReleaseEvent(QMouseEvent *) {
    if (m_dragging) {
        m_dragging = false;
        emit sliderReleased();
    }
}
void SkinSlider::enterEvent(QEnterEvent *) {
    m_hot = true;
    update();
}
void SkinSlider::leaveEvent(QEvent *) {
    m_hot = false;
    update();
}

// ————————————————————————————————————————————————
// SkinListView
// ————————————————————————————————————————————————
SkinListView::SkinListView(QWidget *parent) : QWidget(parent) {
    setAttribute(Qt::WA_Hover, true);
    setSizePolicy(QSizePolicy::Expanding, QSizePolicy::Expanding);
    connect(&GlassNotifier::instance(), &GlassNotifier::changed, this, [this] { update(); });
}

void SkinListView::setItems(const QStringList &items) {
    m_items = items;
    m_datas.clear();
    for (int i = 0; i < m_items.size(); ++i)
        m_datas << QVariant();
    if (m_current >= m_items.size()) m_current = m_items.isEmpty() ? -1 : 0;
    clampScroll();
    update();
}
void SkinListView::addItem(const QString &text) {
    m_items << text;
    m_datas << QVariant();
    update();
}
void SkinListView::addItem(const QString &text, const QVariant &data) {
    m_items << text;
    m_datas << data;
    update();
}
void SkinListView::removeRow(int row) {
    if (row < 0 || row >= m_items.size()) return;
    m_items.removeAt(row);
    m_datas.removeAt(row);
    if (m_current == row)
        m_current = m_items.isEmpty() ? -1 : qBound(0, row, m_items.size() - 1);
    else if (m_current > row)
        --m_current;
    clampScroll();
    update();
}
void SkinListView::clear() {
    m_items.clear();
    m_datas.clear();
    m_current = -1;
    m_scroll = 0;
    update();
}

void SkinListView::setCurrentRow(int row) {
    if (row == m_current) return;
    m_current = row;
    emit currentRowChanged(row);
    update();
}

void SkinListView::clampScroll() {
    m_scroll = qBound(0, m_scroll, maxScroll());
}

int SkinListView::rowAt(const QPointF &pos) const {
    const int r = int((pos.y() + m_scroll) / m_rowH);
    return (r >= 0 && r < m_items.size()) ? r : -1;
}

void SkinListView::paintEvent(QPaintEvent *) {
    QPainter p(this);
    if (m_opaqueBg) {
        // 弹出层：铺一层不透明玻璃面板，浮在桌面上要能读
        p.fillRect(rect(), scaledAlpha(Theme::panel, 0.98f));
        p.setPen(QPen(scaledAlpha(Theme::hairline, 1.0f), 1));
        p.drawRect(QRectF(rect()).adjusted(0.5, 0.5, -0.5, -0.5));
    }
    p.setFont(Fonts::base);
    p.setClipRect(rect());
    for (int i = 0; i < m_items.size(); ++i) {
        const QRectF row(0, i * m_rowH - m_scroll, width(), m_rowH);
        if (row.bottom() < 0 || row.top() > height()) continue; // 滚出视口不画
        if (i == m_current) {
            p.fillRect(row.adjusted(1, 1, -1, -1), scaledAlpha(Theme::textAccent, 0.22f));
            p.setPen(Qt::NoPen);
            p.setBrush(scaledAlpha(Theme::inkOnGlassAccent, 0.9f));
            p.drawRect(QRectF(row.left() + 1, row.top() + 2, 2, row.height() - 4));
        } else if (i == m_hot) {
            Painter::drawHoverFace(&p, row.adjusted(1, 1, -1, -1), true, false, 3, false);
        }
        p.setPen(i == m_current ? Theme::inkOnGlass : scaledAlpha(Theme::inkOnGlass, 0.9f));
        p.drawText(row.adjusted(10, 0, -6, 0), Qt::AlignVCenter | Qt::AlignLeft, m_items[i]);
    }
    // 内容超出视口时画一条细指示条（仅示意，不可拖拽）
    if (maxScroll() > 0) {
        const qreal trackH = height();
        const qreal barH = qMax<qreal>(20.0, trackH * trackH / contentHeight());
        const qreal barY = qBound<qreal>(0.0, (trackH - barH) * qreal(m_scroll) / maxScroll(), trackH - barH);
        p.fillRect(QRectF(width() - 4, barY, 2, barH), scaledAlpha(Theme::inkOnGlassSoft, 0.5f));
    }
}

void SkinListView::mousePressEvent(QMouseEvent *e) {
    const int r = rowAt(e->position());
    if (r >= 0) {
        setCurrentRow(r);
        emit itemClicked(r);
    }
}
void SkinListView::mouseDoubleClickEvent(QMouseEvent *e) {
    const int r = rowAt(e->position());
    if (r >= 0) emit itemDoubleClicked(r);
}
void SkinListView::mouseMoveEvent(QMouseEvent *e) {
    const int r = rowAt(e->position());
    if (r != m_hot) {
        m_hot = r;
        update();
    }
}
void SkinListView::wheelEvent(QWheelEvent *e) {
    if (maxScroll() <= 0) {
        e->ignore();
        return;
    }
    const int step = e->angleDelta().y() / 120 * m_rowH * 2;
    m_scroll = qBound(0, m_scroll - step, maxScroll());
    update();
    e->accept();
}
void SkinListView::leaveEvent(QEvent *) {
    if (m_hot != -1) {
        m_hot = -1;
        update();
    }
}

// ————————————————————————————————————————————————
// SkinLineEdit
// ————————————————————————————————————————————————
SkinLineEdit::SkinLineEdit(QWidget *parent) : QWidget(parent) {
    auto *v = new QVBoxLayout(this);
    v->setContentsMargins(6, 2, 6, 2);
    m_edit = new QLineEdit(this);
    setFocusProxy(m_edit); // 包装器 setFocus 直达内部编辑框（搜索框展开即聚焦）
    // 去 Fusion 白灰方块：透明底、无边框、深字、accent 光标
    m_edit->setStyleSheet(QStringLiteral("QLineEdit{background:transparent;border:none;color:%1;}"
                                         "QLineEdit:focus{border:none;}")
                              .arg(Theme::inkOnGlass.name()));
    v->addWidget(m_edit);
    connect(m_edit, &QLineEdit::textChanged, this, &SkinLineEdit::textChanged);
    connect(m_edit, &QLineEdit::returnPressed, this, &SkinLineEdit::returnPressed);
    connect(&GlassNotifier::instance(), &GlassNotifier::changed, this, [this] { update(); });
}

QString SkinLineEdit::text() const {
    return m_edit->text();
}
void SkinLineEdit::setText(const QString &t) {
    m_edit->setText(t);
}
void SkinLineEdit::clear() {
    m_edit->clear();
}
void SkinLineEdit::selectAll() {
    m_edit->selectAll();
}
void SkinLineEdit::setPlaceholderText(const QString &t) {
    m_edit->setPlaceholderText(t);
}
void SkinLineEdit::setClearButtonEnabled(bool on) {
    m_edit->setClearButtonEnabled(on);
}
QSize SkinLineEdit::sizeHint() const {
    return {160, 28};
}

void SkinLineEdit::paintEvent(QPaintEvent *) {
    QPainter p(this);
    const float a = GlassStyle::enabled() ? GlassStyle::glassAlpha() : 1.0f;
    // 底部一条发丝线；聚焦时变 accent（轻亮）
    const bool focused = m_edit && m_edit->hasFocus();
    p.setPen(QPen(scaledAlpha(focused ? Theme::inkOnGlassAccent : Theme::hairline, focused ? 0.9f : a), 1));
    const qreal y = height() - 1.5;
    p.drawLine(QPointF(2, y), QPointF(width() - 2, y));
}
