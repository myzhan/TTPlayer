#pragma once

// 皮肤控件原件：GradientView / WellView / TTButton。
// Qt 没有系统矢量符号集，传输键/窗控键一律用 QPainterPath 矢量自绘（Glyph 枚举）。
// 玻璃分层约束（AGENTS.md）：TTButton(.glass) 与 WellView 不走 Painter::drawBody，
// 各自直接读 GlassStyle::buttonAlpha / wellAlpha，并监听 GlassNotifier::changed 重绘。

#include <QWidget>
#include <QAbstractButton>
#include <QColor>
#include <QString>

class QPainter;

namespace Skin {

/// 矢量图标（按名称取用的自绘图形）
enum class Glyph {
    None,
    Play,
    Pause,
    Stop, // 传输
    Prev,
    Next, // 上一首 / 下一首
    Repeat,
    RepeatOne,
    Shuffle,    // 循环模式
    ListLoop,   // 列表循环
    Sequential, // 顺序播放（一个向右箭头，播完到底即停）
    Eject,      // 弹出
    Menu,
    Minus,
    Close, // 标题条窗控
    Pin,   // 置顶（标题条）
    List,
    EQ,
    Lyric,
    Search,
    HeartOutline,
    HeartFilled,
    Add, // 面板入口
    Check,
    Volume,
    Mute, // 音量 / 静音
    Power,
    Reset, // 均衡器开关 / 重置
};

/// 在 rect 内居中绘制一个矢量图标；size 取 rect 短边 * scale
void drawGlyph(QPainter *p, Glyph g, const QRectF &rect, const QColor &color, qreal scale = 0.5);

} // namespace Skin

/// 内嵌凹陷槽：显示区 / 列表 / 均衡器 / 歌词共用的深蓝灰玻璃底（对应 WellView）
class WellView : public QWidget {
    Q_OBJECT
public:
    explicit WellView(QWidget *parent = nullptr);

    void setDark(bool dark);                    // 列表区用略深色调
    void setShowGrid(bool on, int columns = 0); // 频谱区顶部刻度网格
    void setCornerRadius(qreal r) {
        m_radius = r;
        update();
    }

    QSize sizeHint() const override { return {200, 80}; }

protected:
    void paintEvent(QPaintEvent *) override;

private:
    qreal m_radius = 3.0;
    bool m_dark = false;
    bool m_showGrid = false;
    int m_gridColumns = 0;
};

/// 皮肤按钮：浅玻璃贴片 / 扁平文字（深底、浅底）/ 无底 四种面（对应 TTButton）
class TTButton : public QAbstractButton {
    Q_OBJECT
public:
    enum class Face { Glass, Flat, FlatOnLight, None };

    explicit TTButton(QWidget *parent = nullptr);

    void setGlyph(Skin::Glyph g) {
        m_glyph = g;
        m_kind = Kind::Glyph;
        update();
    }
    void setTextLabel(const QString &t) {
        m_text = t;
        m_kind = Kind::Text;
        update();
    }
    void setBadge(const QString &t) {
        m_badge = t;
        m_kind = Kind::Badge;
        update();
    }

    void setFace(Face f) {
        m_face = f;
        update();
    }
    void setLit(bool lit) {
        m_lit = lit;
        update();
    }
    void setGlyphScale(qreal s) {
        m_glyphScale = s;
        update();
    }
    void setCornerRadius(qreal r) {
        m_radius = r;
        update();
    }
    void setPreferredSize(QSize s) {
        m_prefSize = s;
        updateGeometry();
        update();
    }

    QSize sizeHint() const override { return m_prefSize; }

protected:
    void paintEvent(QPaintEvent *) override;

private:
    enum class Kind { Glyph, Text, Badge };
    Kind m_kind = Kind::Glyph;
    Skin::Glyph m_glyph = Skin::Glyph::None;
    QString m_text, m_badge;
    Face m_face = Face::Glass;
    bool m_lit = false;
    qreal m_glyphScale = 0.62;
    qreal m_radius = 3.0;
    QSize m_prefSize{32, 24};
};

/// 自绘进度条：凹陷细槽 + 蓝→青渐变已播段 + 四分刻度 + 竖细游标。
/// 只发「比值」，秒数换算交给外层（时长在控制器手里）。
class TimeSlider : public QWidget {
    Q_OBJECT
public:
    explicit TimeSlider(QWidget *parent = nullptr);
    void setProgress(double v); // 0..1；拖动中忽略（不让 tick 抢游标）
    double ratio() const { return m_dragging ? m_dragValue : m_progress; }
    QSize sizeHint() const override { return {200, 16}; }
signals:
    void seekRatio(double ratio); // 松手时发
protected:
    void paintEvent(QPaintEvent *) override;
    void mousePressEvent(QMouseEvent *) override;
    void mouseMoveEvent(QMouseEvent *) override;
    void mouseReleaseEvent(QMouseEvent *) override;
    void enterEvent(QEnterEvent *) override;
    void leaveEvent(QEvent *) override;

private:
    double ratioAt(qreal x) const;
    double m_progress = 0, m_dragValue = 0;
    bool m_dragging = false, m_hot = false;
};

/// 音量槽：凹陷细槽 + 渐变已填 + 玻璃圆推子 + 右侧 "xx%"/"静音"（对应 VolumeWellView）
class VolumeSlider : public QWidget {
    Q_OBJECT
public:
    explicit VolumeSlider(QWidget *parent = nullptr);
    void setValue(double v);
    void setMuted(bool m);
    double value() const { return m_value; }
    bool muted() const { return m_muted; }
    QSize sizeHint() const override { return {132, 20}; }
signals:
    void valueChanged(double v);

protected:
    void paintEvent(QPaintEvent *) override;
    void mousePressEvent(QMouseEvent *) override;
    void mouseMoveEvent(QMouseEvent *) override;
    void enterEvent(QEnterEvent *) override;
    void leaveEvent(QEvent *) override;

private:
    friend class RegressionTests;
    double knobDiameter() const;
    QRectF readoutRect() const;
    QRectF grooveRect() const;
    double m_value = 0.8;
    bool m_muted = false, m_hot = false;
};

/// 竖推子：凹陷细槽 + 中心 0dB 基准 + 从中往上下填 + 横向把手。
/// 量程 min..max（默认 -12..12），拖动改值。
class FaderView : public QWidget {
    Q_OBJECT
public:
    explicit FaderView(QWidget *parent = nullptr);
    void setRange(double lo, double hi) {
        m_min = lo;
        m_max = hi;
        update();
    }
    void setGain(double g);
    double gain() const { return m_gain; }
    QSize sizeHint() const override { return {24, 90}; }
signals:
    void gainChanged(double gain);

protected:
    void paintEvent(QPaintEvent *) override;
    void mousePressEvent(QMouseEvent *) override;
    void mouseMoveEvent(QMouseEvent *) override;
    void enterEvent(QEnterEvent *) override;
    void leaveEvent(QEvent *) override;

private:
    void setFromY(qreal y);
    double m_min = -12, m_max = 12, m_gain = 0;
    bool m_hot = false, m_dragging = false;
};

/// 旋钮：玻璃圆 + 指示线 + 下方题注；竖拖改值。
class KnobView : public QWidget {
    Q_OBJECT
public:
    explicit KnobView(QWidget *parent = nullptr);
    void setRange(double lo, double hi) {
        m_min = lo;
        m_max = hi;
        update();
    }
    void setCaption(const QString &c) {
        m_caption = c;
        update();
    }
    void setValue(double v);
    double value() const { return m_value; }
    QSize sizeHint() const override { return {44, 46}; }
signals:
    void valueChanged(double v);

protected:
    void paintEvent(QPaintEvent *) override;
    void mousePressEvent(QMouseEvent *) override;
    void mouseMoveEvent(QMouseEvent *) override;
    void wheelEvent(QWheelEvent *) override;

private:
    double m_min = 0, m_max = 1, m_value = 0.8;
    QString m_caption;
    QPoint m_lastPos;
};
