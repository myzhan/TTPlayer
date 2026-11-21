#pragma once

// 统一毛玻璃自绘控件集：替换设置/列表/属性窗里的原生 Fusion 控件（QTabWidget/QComboBox/
// QCheckBox/QSpinBox/QSlider/QLineEdit/QListWidget/QGroupBox）。全部走同一玻璃语言：
//   静止透明、仅 hover/pressed 轻亮（Painter::drawHoverFace）、区域靠 1px 发丝线、
//   浅底深字（Theme::inkOnGlass*）、alpha 单一（GlassStyle::glassAlpha）、监听 GlassNotifier 重绘。
// API 刻意贴近对应原生控件，Phase 2 多为类型替换。

#include <QWidget>
#include <QAbstractButton>
#include <QString>
#include <QStringList>
#include <QColor>
#include <QVector>
#include <QVariant>

class QPainter;
class QMouseEvent;
class QPaintEvent;
class QStackedWidget;
class QLineEdit;

// —— 分节容器（替 QGroupBox）：小标题 + 右侧发丝线，内容装进 contentLayout ——
class SkinSection : public QWidget {
    Q_OBJECT
public:
    explicit SkinSection(const QString &title, QWidget *parent = nullptr);
    QWidget *content() const { return m_content; }

protected:
    void paintEvent(QPaintEvent *) override;

private:
    QString m_title;
    QWidget *m_content = nullptr;
};

// —— 勾选行（替 QCheckBox）：方块 + 文字，静止透明、hover 轻亮、选中画 accent 勾。
// 直接用 QAbstractButton 内建 checkable/toggled，不再自写 checked 存取（避免遮蔽基类）。
class SkinCheckBox : public QAbstractButton {
    Q_OBJECT
public:
    explicit SkinCheckBox(const QString &text, QWidget *parent = nullptr);
    QSize sizeHint() const override;

protected:
    void paintEvent(QPaintEvent *) override;

private:
    QString m_text;
};

// —— 分段标签 + 堆叠页（替 QTabWidget）——
class SkinTabWidget : public QWidget {
    Q_OBJECT
public:
    explicit SkinTabWidget(QWidget *parent = nullptr);
    int addTab(QWidget *page, const QString &label);
    void setCurrentIndex(int i);
    int currentIndex() const { return m_current; }
    const QStringList &labels() const { return m_labels; }
signals:
    void currentChanged(int index);

protected:
    void paintEvent(QPaintEvent *) override;
    void mousePressEvent(QMouseEvent *) override;
    void mouseMoveEvent(QMouseEvent *) override;
    void leaveEvent(QEvent *) override;

private:
    QRectF tabRect(int i) const;
    QStackedWidget *m_stack = nullptr;
    QStringList m_labels;
    int m_current = 0;
    int m_hot = -1;
    static constexpr int kTabH = 28;
};

// —— 下拉框（替 QComboBox）：按钮显示当前项 + 弹出 SkinListView ——
class SkinComboBox : public QWidget {
    Q_OBJECT
public:
    explicit SkinComboBox(QWidget *parent = nullptr);
    void addItem(const QString &text, const QVariant &itemData = QVariant());
    int count() const { return m_texts.size(); }
    int currentIndex() const { return m_current; }
    void setCurrentIndex(int i);
    QString itemText(int i) const { return m_texts.value(i); }
    QVariant itemData(int i) const { return m_datas.value(i); }
    QSize sizeHint() const override { return {120, 26}; }
signals:
    void activated(int index);
    void currentIndexChanged(int index);

protected:
    void paintEvent(QPaintEvent *) override;
    void mousePressEvent(QMouseEvent *) override;
    void enterEvent(QEnterEvent *) override;
    void leaveEvent(QEvent *) override;

private:
    void openPopup();
    QStringList m_texts;
    QVector<QVariant> m_datas;
    int m_current = -1;
    bool m_hot = false;
};

// —— 数值框（替 QSpinBox）：值 + 上下箭头（hover-face）——
class SkinSpinBox : public QWidget {
    Q_OBJECT
public:
    explicit SkinSpinBox(QWidget *parent = nullptr);
    void setRange(int lo, int hi);
    void setValue(int v);
    int value() const { return m_value; }
    void setSuffix(const QString &s) {
        m_suffix = s;
        update();
    }
    QSize sizeHint() const override { return {110, 26}; }
signals:
    void valueChanged(int v);

protected:
    void paintEvent(QPaintEvent *) override;
    void mousePressEvent(QMouseEvent *) override;
    void mouseMoveEvent(QMouseEvent *) override;
    void enterEvent(QEnterEvent *) override;
    void leaveEvent(QEvent *) override;

private:
    QRectF upRect() const;
    QRectF downRect() const;
    void step(int dir);
    int m_lo = 0, m_hi = 100, m_value = 0;
    QString m_suffix;
    int m_hotBtn = 0; // 0 无 / +1 上 / -1 下
};

// —— 横向滑槽（替 QSlider）——
class SkinSlider : public QWidget {
    Q_OBJECT
public:
    explicit SkinSlider(QWidget *parent = nullptr);
    void setRange(int lo, int hi);
    void setValue(int v);
    int value() const { return m_value; }
    QSize sizeHint() const override { return {140, 20}; }
signals:
    void valueChanged(int v);
    void sliderReleased();

protected:
    void paintEvent(QPaintEvent *) override;
    void mousePressEvent(QMouseEvent *) override;
    void mouseMoveEvent(QMouseEvent *) override;
    void mouseReleaseEvent(QMouseEvent *) override;
    void enterEvent(QEnterEvent *) override;
    void leaveEvent(QEvent *) override;

private:
    void setFromX(qreal x);
    QRectF grooveRect() const;
    int m_lo = 0, m_hi = 100, m_value = 0;
    bool m_hot = false, m_dragging = false;
};

// —— 皮肤列表（替 QListWidget / 组合框弹出）：单列文本行，选中 accent 条、hover 行轻亮。
// 支持每行携带 QVariant 数据（左栏 viewId）、滚轮滚动 + 细指示条、右键定位行（自定义菜单）。
class SkinListView : public QWidget {
    Q_OBJECT
public:
    explicit SkinListView(QWidget *parent = nullptr);
    void setItems(const QStringList &items);
    void addItem(const QString &text);
    void addItem(const QString &text, const QVariant &itemData);
    void removeRow(int row);
    void clear();
    int count() const { return m_items.size(); }
    QString rowText(int i) const { return m_items.value(i); }
    QVariant rowData(int i) const { return m_datas.value(i); }
    int currentRow() const { return m_current; }
    void setCurrentRow(int row);
    int rowAt(const QPointF &pos) const; // 视口坐标→行（含滚动偏移），越界 -1
    void setRowHeight(int h) {
        m_rowH = h;
        update();
    }
    void setOpaqueBg(bool on) {
        m_opaqueBg = on;
        update();
    } // 弹出层用：铺不透明面板
    QSize sizeHint() const override { return {160, 200}; }
signals:
    void currentRowChanged(int row);
    void itemClicked(int row);
    void itemDoubleClicked(int row);

protected:
    void paintEvent(QPaintEvent *) override;
    void mousePressEvent(QMouseEvent *) override;
    void mouseDoubleClickEvent(QMouseEvent *) override;
    void mouseMoveEvent(QMouseEvent *) override;
    void wheelEvent(QWheelEvent *) override;
    void leaveEvent(QEvent *) override;

private:
    int contentHeight() const { return m_items.size() * m_rowH; }
    int maxScroll() const { return qMax(0, contentHeight() - height()); }
    void clampScroll();
    QStringList m_items;
    QVector<QVariant> m_datas;
    int m_current = -1;
    int m_hot = -1;
    int m_rowH = 26;
    int m_scroll = 0;
    bool m_opaqueBg = false;
};

// —— 搜索/输入框（替 QLineEdit）：透明玻璃底 + 底部发丝线 + focus 轻亮 ——
// 仍继承 QLineEdit 以复用光标/选区/编辑，只重画外壳（去 Fusion 白灰方块）。
class SkinLineEdit : public QWidget {
    Q_OBJECT
public:
    explicit SkinLineEdit(QWidget *parent = nullptr);
    QString text() const;
    void setText(const QString &t);
    void clear();
    void selectAll();
    void setPlaceholderText(const QString &t);
    void setClearButtonEnabled(bool on);
    QLineEdit *edit() const { return m_edit; }
    QSize sizeHint() const override;
signals:
    void textChanged(const QString &t);
    void returnPressed();

protected:
    void paintEvent(QPaintEvent *) override;

private:
    QLineEdit *m_edit = nullptr;
};

// —— 进度条（替 QProgressBar）：凹陷细槽 + 蓝→青渐变已转段 + 居中读数 ——
class SkinProgress : public QWidget {
    Q_OBJECT
public:
    explicit SkinProgress(QWidget *parent = nullptr);
    /// 0..1；负数 = 不确定进度（只画槽，不画已转段）
    void setRatio(double r);
    double ratio() const { return m_ratio; }
    void setCaption(const QString &t);
    QSize sizeHint() const override { return {220, 16}; }

protected:
    void paintEvent(QPaintEvent *) override;

private:
    double m_ratio = 0;
    QString m_caption;
};
