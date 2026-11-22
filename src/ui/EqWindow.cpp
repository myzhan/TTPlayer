#include "EqWindow.h"
#include "SkinParts.h"
#include "Theme.h"
#include "Painter.h"

#include <QVBoxLayout>
#include <QHBoxLayout>
#include <QLabel>
#include "SkinWidgets.h"
#include <QPainter>
#include <cmath>

namespace {

// dB 刻度尺：+12/+6/0/-6/-12 横线 + 文字，行程与推子对齐（顶部留 6、底部让给读数）
class EQScale : public QWidget {
public:
    explicit EQScale(QWidget *parent = nullptr) : QWidget(parent) {
        connect(&GlassNotifier::instance(), &GlassNotifier::changed, this, [this] { update(); });
    }
    QSize sizeHint() const override { return {34, 90}; }

protected:
    void paintEvent(QPaintEvent *) override {
        QPainter p(this);
        const qreal top = 6, bottom = height() - 26;
        if (bottom - top < 10) return;
        const qreal travel = bottom - top;
        p.setFont(Fonts::numericTiny);
        for (double db : {12.0, 6.0, 0.0, -6.0, -12.0}) {
            const qreal ratio = (12 - db) / 24;
            const qreal y = top + travel * ratio;
            // 统一毛玻璃：浅玻璃上网格线走发丝墨线（取代旧深槽亮边）。
            p.fillRect(QRectF(1, y - 0.5, width() - 3, db == 0 ? 1.5 : 1),
                       QColor(Theme::hairline.red(), Theme::hairline.green(), Theme::hairline.blue(),
                              int((db == 0 ? 0.75 : 0.35) * 255)));
            const QString label = db > 0 ? QStringLiteral("+%1").arg(int(db)) : QStringLiteral("%1").arg(int(db));
            p.setPen(Theme::inkOnGlassSoft);
            p.drawText(QRectF(0, y - 6, width() - 2, 12), Qt::AlignRight | Qt::AlignVCenter, label);
        }
    }
};

QString freqLabel(double hz) {
    return hz >= 1000 ? QStringLiteral("%1K").arg(int(hz / 1000)) : QStringLiteral("%1").arg(int(hz));
}

} // namespace

EqWindow::EqWindow(AudioEnginePtr engine, QWidget *parent)
    : SkinWindow(QStringLiteral("均衡器"), TitleButtons::None, parent), m_engine(std::move(engine)) {
    resize(460, 178 + 30); // 高度补上自绘标题条（~30）；与主窗/列表同紧凑默认宽
    setMinimumSize(360, 178);

    auto *root = new QVBoxLayout(body());
    root->setContentsMargins(6, 6, 6, 6);

    auto *row = new QHBoxLayout();
    row->setSpacing(4);

    // 左栏：音量旋钮 + 开关/重置/预设
    auto *leftCol = new QVBoxLayout();
    m_volume = new KnobView(this);
    m_volume->setRange(0, 1);
    m_volume->setCaption(QStringLiteral("音量"));
    m_volume->setValue(0.8);
    m_volume->setFixedSize(44, 46);
    leftCol->addWidget(m_volume);
    m_preamp = new KnobView(this);
    m_preamp->setRange(-12, 12);
    m_preamp->setCaption(QStringLiteral("前置"));
    m_preamp->setFixedSize(44, 46);
    leftCol->addWidget(m_preamp);
    connect(m_preamp, &KnobView::valueChanged, this, [this](double db) { m_engine->setEQPreamp(db); });
    auto *ctrlRow = new QHBoxLayout();
    ctrlRow->setSpacing(3);
    auto mkBtn = [this](Skin::Glyph g, const QString &tip) {
        auto *b = new TTButton(this);
        b->setGlyph(g);
        b->setFace(TTButton::Face::Glass);
        b->setPreferredSize({22, 18});
        b->setToolTip(tip);
        return b;
    };
    m_enable = mkBtn(Skin::Glyph::Power, QStringLiteral("开启/关闭均衡器"));
    m_reset = mkBtn(Skin::Glyph::Reset, QStringLiteral("全部归零"));
    m_preset = mkBtn(Skin::Glyph::List, QStringLiteral("预设"));
    ctrlRow->addWidget(m_enable);
    ctrlRow->addWidget(m_reset);
    ctrlRow->addWidget(m_preset);
    leftCol->addLayout(ctrlRow);
    leftCol->addStretch();
    row->addLayout(leftCol);

    // dB 刻度
    row->addWidget(new EQScale(this));

    // 10 段推子 + 增益/频率读数
    const auto &freqs = Equalizer::frequencies();
    auto *faderRow = new QHBoxLayout();
    faderRow->setSpacing(2);
    for (int i = 0; i < 10; ++i) {
        auto *col = new QVBoxLayout();
        col->setSpacing(1);
        auto *f = new FaderView(this);
        f->setRange(-12, 12);
        m_faders[i] = f;
        auto *gain = new QLabel(QStringLiteral("0"), this);
        gain->setFont(Fonts::numericTiny);
        gain->setAlignment(Qt::AlignCenter);
        gain->setStyleSheet(QStringLiteral("color:%1;background:transparent;").arg(Theme::inkOnGlassAccent.name()));
        m_gainLabels[i] = gain;
        auto *name = new QLabel(freqLabel(freqs[i]), this);
        name->setFont(Fonts::numericTiny);
        name->setAlignment(Qt::AlignCenter);
        name->setStyleSheet(QStringLiteral("color:%1;background:transparent;").arg(Theme::inkOnGlassSoft.name()));
        col->addWidget(f, 1);
        col->addWidget(gain);
        col->addWidget(name);
        faderRow->addLayout(col);
        connect(f, &FaderView::gainChanged, this, [this] {
            applyGains();
            refreshReadout();
        });
    }
    row->addLayout(faderRow, 1);

    root->addLayout(row);

    connect(m_enable, &TTButton::clicked, this, [this] {
        m_engine->setEQEnabled(!m_engine->eqEnabled());
        syncFromEngine();
    });
    connect(m_reset, &TTButton::clicked, this, [this] {
        for (auto *f : m_faders)
            f->setGain(0);
        m_preamp->setValue(0);
        m_engine->setEQPreamp(0);
        applyGains();
        refreshReadout();
    });
    connect(m_preset, &TTButton::clicked, this, &EqWindow::showPresetMenu);
    connect(m_volume, &KnobView::valueChanged, this, [this](double v) { emit volumeRequested(v); });

    syncFromEngine();
}

void EqWindow::paintBody(QPainter *p, const QRectF &rect) {
    // 统一毛玻璃：与主窗/列表窗同一层浅玻璃（不再铺深蓝 well），单一 alpha。
    const float wA = GlassStyle::enabled() ? GlassStyle::wellAlpha() : 1.0f;
    Painter::drawWell(p, rect.adjusted(0.5, 0.5, -0.5, -0.5), Theme::windowTop, Theme::windowBottom, wA, 5);
}

void EqWindow::syncFromEngine() {
    const auto g = m_engine->eqGains();
    for (int i = 0; i < 10; ++i)
        m_faders[i]->setGain(g[i]);
    m_enable->setLit(m_engine->eqEnabled());
    m_volume->setValue(m_engine->volume());
    m_preamp->setValue(m_engine->eqPreamp());
    refreshReadout();
}

void EqWindow::applyGains() {
    std::array<double, Equalizer::kBands> arr{};
    for (int i = 0; i < 10; ++i)
        arr[i] = m_faders[i]->gain();
    m_engine->setEQGains(arr);
}

void EqWindow::refreshReadout() {
    for (int i = 0; i < 10; ++i) {
        const double g = m_faders[i]->gain();
        m_gainLabels[i]->setText(g >= 0 ? QStringLiteral("+%1").arg(int(g)) : QStringLiteral("%1").arg(int(g)));
    }
    // 命中预设则高亮名字
    struct P {
        const char *name;
        std::array<double, 10> g;
    };
    static const P presets[] = {
        {"默认", {0, 0, 0, 0, 0, 0, 0, 0, 0, 0}},
        {"摇滚", {5, 4, 3, -1, -2, -1, 2, 4.5, 5, 4.5}},
        {"流行", {-1.5, 0, 2, 3.5, 3.5, 3, 1.5, 0, -1, -1.5}},
        {"古典", {4.5, 3.5, 0.5, 0, 0, -1, -2, -3, -4, -4.5}},
        {"爵士", {4, 3, 1.5, 1, 0, 1, 2, 3, 4, 3.5}},
        {"低音增强", {7, 6, 4.5, 2, 0, -0.5, -1, -1.5, -2, -2}},
        {"高音增强", {-2, -1.5, -1, 0, 0.5, 1.5, 3, 4.5, 6, 7}},
        {"人声", {-2.5, -1, 0, 2.5, 4, 4, 3, 1, -0.5, -1.5}},
    };
    m_currentPreset = QStringLiteral("自定义");
    for (const auto &pr : presets) {
        bool hit = true;
        for (int i = 0; i < 10; ++i)
            if (std::abs(pr.g[i] - m_faders[i]->gain()) > 0.05) {
                hit = false;
                break;
            }
        if (hit) {
            m_currentPreset = QString::fromUtf8(pr.name);
            break;
        }
    }
    m_preset->setToolTip(QStringLiteral("预设（%1）").arg(m_currentPreset));
}

void EqWindow::showPresetMenu() {
    SkinMenu menu(this);
    struct Item {
        QString name;
        std::array<double, 10> g;
    };
    const QList<Item> items = {
        {QStringLiteral("默认"), {0, 0, 0, 0, 0, 0, 0, 0, 0, 0}},
        {QStringLiteral("摇滚"), {5, 4, 3, -1, -2, -1, 2, 4.5, 5, 4.5}},
        {QStringLiteral("流行"), {-1.5, 0, 2, 3.5, 3.5, 3, 1.5, 0, -1, -1.5}},
        {QStringLiteral("古典"), {4.5, 3.5, 0.5, 0, 0, -1, -2, -3, -4, -4.5}},
        {QStringLiteral("爵士"), {4, 3, 1.5, 1, 0, 1, 2, 3, 4, 3.5}},
        {QStringLiteral("低音增强"), {7, 6, 4.5, 2, 0, -0.5, -1, -1.5, -2, -2}},
        {QStringLiteral("高音增强"), {-2, -1.5, -1, 0, 0.5, 1.5, 3, 4.5, 6, 7}},
        {QStringLiteral("人声"), {-2.5, -1, 0, 2.5, 4, 4, 3, 1, -0.5, -1.5}},
    };
    for (const auto &it : items) {
        QAction *act = menu.addAction(it.name);
        act->setCheckable(true);
        act->setChecked(it.name == m_currentPreset);
        const auto gains = it.g;
        connect(act, &QAction::triggered, this, [this, gains] {
            for (int i = 0; i < 10; ++i)
                m_faders[i]->setGain(gains[i]);
            applyGains();
            refreshReadout();
        });
    }
    menu.exec(m_preset->mapToGlobal(QPoint(0, m_preset->height())));
}
