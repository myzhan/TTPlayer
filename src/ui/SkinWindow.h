#pragma once

// 无边框自绘皮肤窗基类：与主窗同一套观感（圆角玻璃壳 + 顶部浅色标题条 +
// 最小化/关闭按钮 + 边缘缩放），三平台一致——不挂各 OS 原生标题栏，避免 mac/win/linux
// 标题栏外观、位置、配色各异。列表/均衡器/歌词保留标题拖动，窗控统一由主面板负责。
// 主面板与设置/属性/封面跟随「半透明玻璃」设置；只调整壳与标题背景，前景不透明。
// 转换等其余辅助窗在构造里关闭跟随，壳与标题条保持完全不透明。
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
    enum class TitleButtons { None, Close, MinimizeAndClose };
    explicit SkinWindow(const QString &title, TitleButtons buttons, QWidget *parent = nullptr);

    // 是否跟随「半透明玻璃」设置。默认 true：主面板和设置/属性/封面与桌面合成；
    // 转换等辅助窗设为 false 后壳/标题条/槽一律按 alpha=1 绘制。
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
#ifdef Q_OS_MACOS
    // 面板进 App Exposé 网格的抑制：show 后平台窗可能尚未 expose，有界重试直到施加成功。
    void scheduleMacTransient(int attempt);
#endif
};
