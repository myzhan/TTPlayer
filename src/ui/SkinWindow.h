#pragma once

// 无边框自绘皮肤窗基类：与主窗同一套观感（圆角玻璃壳 + 顶部浅色标题条 +
// 最小化/关闭按钮 + 边缘缩放），三平台一致——不挂各 OS 原生标题栏，避免 mac/win/linux
// 标题栏外观、位置、配色各异。二级窗（播放列表/均衡器/歌词/封面/属性/设置/队列 ）都继承它。
// 默认跟随「半透明玻璃」设置；设置/属性/队列/封面这类辅助窗在构造里关掉，
// 壳与标题条画成完全不透明，叠在主面板上时文字不会被下层透上来干扰。
//
// 用法：
//   - 布局型面板：把内容控件装进 body()（QLayout::addWidget 会自动把这些控件
//     reparent 到 body），不需要覆写 paintBody（透出浅色玻璃壳即可）。
//   - 深色槽型面板（均衡器/歌词/封面）：覆写 paintBody 往 body 区域铺深蓝灰 well，
//     子控件仍在其上绘制。

#include <QWidget>
#include <QRectF>
#include <QString>

class QPainter;
class QMouseEvent;
class QPaintEvent;
class QShowEvent;
class QVBoxLayout;

class SkinWindow : public QWidget {
    Q_OBJECT
public:
    // allowMinimize：是否显示「最小化」键（属性/设置这类瞬时窗只留关闭）。
    explicit SkinWindow(const QString &title, bool allowMinimize, QWidget *parent = nullptr);

    // 是否跟随「半透明玻璃」设置。默认 true：主窗、播放列表、均衡器、歌词四个主面板
    // 与桌面合成；辅助窗设为 false 后壳/标题条/槽一律按 alpha=1 绘制。
    void setGlassTransparencyFollows(bool on);
    bool glassTransparencyFollows() const { return m_followGlass; }
    // 本窗壳与槽当前使用的 alpha：跟随时取全局玻璃值，否则恒为 1.0。
    float shellAlpha() const;
signals:
    void filesDropped(const QStringList &paths);

protected:
    QWidget *body() const { return m_body; }
    void setTitleBarVisible(bool visible);
    void dragEnterEvent(QDragEnterEvent *) override;
    void dropEvent(QDropEvent *) override;

    // 子类给内容区铺自定义背景（如深蓝灰 well）时覆写；默认不画，透出外壳玻璃。
    // rect 为 body 在窗口坐标系内的几何。
    virtual void paintBody(QPainter *, const QRectF &) {}

    void paintEvent(QPaintEvent *) override;
    void showEvent(QShowEvent *) override;
    void mousePressEvent(QMouseEvent *) override;
    void mouseMoveEvent(QMouseEvent *) override;

    // 标题条关闭键动作：默认 close()（顶层窗无 WA_DeleteOnClose 即隐藏，有则销毁）。
    virtual void onClose();
    // 标题条最小化键动作：Windows 工具窗交给主窗收起整组，其他情况 showMinimized()。
    virtual void onMinimize();

private:
    QWidget *m_body = nullptr;
    QWidget *m_titleBar = nullptr;
    bool m_followGlass = true;
};
