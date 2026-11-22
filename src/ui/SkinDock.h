#pragma once

// 皮肤停靠（Qt 版 SkinDock）：主面板是锚点，播放列表 / 均衡器 / 歌词三窗**可自由拖动**，
// 只有拖到某个「停靠槽」附近（磁吸阈值 kSnapDist 内）才吸附，拖离则脱离浮动。
// 停靠槽有三个方位（每面板记一个 Side）：
//   · Bottom：主窗下方同宽竖排（主列，默认）；
//   · Left  / Right：主列左右并排成侧列，顶边与主窗对齐、按 Panel 序沿侧竖排，宽度各自独立。
//   · 拖主窗 → 已吸附成员按同一位移跟随，浮动成员原地不动；
//   · 拉宽主窗或任一 Bottom 吸附成员 → 主列同宽；侧列 / 浮动成员宽度独立；
//   · 任一窗显示 / 隐藏 → 吸附成员重排补位，浮动成员不受影响。
//
// 实现靠给每个成员装 eventFilter（Move/Resize/Show/Hide），不改各窗事件：
//   · 面板被用户拖动时不实时重排（跟手自由移动），靠一个 settle 定时器在「停下」后判磁吸；
//     evaluateSnap 在 Bottom/Left/Right 三个候选槽里挑「左上角最近且 ≤ 阈值」的那个吸附；
//   · 布局期间用 m_layingOut 抑制自激（程序化 move/resize 会再发事件），避免把布局位移
//     误认成用户拖动。设置 / 属性 / 封面作为瞬态辅助成员入组，不写面板存档。

#include <QObject>
#include <QHash>
#include <QPoint>
#include <QString>
#include <QRect>
#include <QPointer>
#include <QSet>

class QWidget;
class QTimer;

class SkinDock : public QObject {
    Q_OBJECT
public:
    enum Panel { Main = 0, Playlist = 1, Equalizer = 2, Lyric = 3 };
    enum Side { Bottom = 0, Left = 1, Right = 2 };
    static constexpr int kGap = 6;
    static constexpr int kSnapDist = 44; // 磁吸阈值（px）：候选槽左上角 ± 此范围内才吸附

    explicit SkinDock(QObject *parent = nullptr);

    /// 登记成员窗（Main 提供初始宽度与组左上角）。装 eventFilter，不接管其事件。
    /// 若此前 setSavedPanels 存过该面板的几何 / 吸附态，这里套用（消费掉一条）。
    void registerPanel(Panel panel, QWidget *w);
    /// 瞬态辅助窗：首次预摆并在 Show 校准，所有方位保持自身宽度，不写存档。
    void registerAuxiliary(QWidget *w);
    bool isWindowDocked(QWidget *w) const { return m_vis.contains(w) && isDocked(w); }
    int windowSide(QWidget *w) const { return m_vis.contains(w) ? int(sideOf(w)) : -1; }

    int width() const { return m_width; }

    /// 测试接缝：某面板当前是否吸附 / 吸附在哪个方位（供 DOCK_PROBE 验磁吸，不改对外行为）
    bool isPanelDocked(Panel p) const;
    int panelSide(Panel p) const; // 返回 Side；未登记返回 -1

    /// 组锚点几何 "left,top,width"（top 是主窗顶边全局 y），用于持久化
    QString geometryString() const;
    /// 还原组锚点；返回是否用上了存档
    bool restoreGeometry(const QString &s);

    /// 各可停靠面板的几何 + 吸附态 + 方位 "pl=x,y,w,h,d,s;eq=...;ly=..."
    /// （d=1 吸附 / 0 浮动；s=0 Bottom / 1 Left / 2 Right）
    QString panelFramesString() const;
    /// 解析并暂存面板存档，供后续 registerPanel 套用（须在登记任何面板之前调用）
    void setSavedPanels(const QString &s);

    /// 把还原的窗口几何夹回可用屏幕：完全落在所有屏幕之外时（如换到更小的屏 / 拔掉
    /// 副屏后旧坐标在屏幕外），保持尺寸居中到主屏可用区；否则原样返回。
    static QRect clampToScreens(const QRect &want);

signals:
    void geometryChanged();

protected:
    bool eventFilter(QObject *obj, QEvent *ev) override;

private:
    struct Saved {
        QRect frame;
        bool docked;
        int side;
    };

    void memberMovedMain(QWidget *w);
    void memberMovedPanel(QWidget *w);
    void memberResized(QWidget *w);
    void evaluateSnap(QWidget *w);
    void layout();
    QWidget *panelWindow(Panel p) const;
    QList<QWidget *> members() const;
    void unregisterWindow(QWidget *w);
    void placeAuxiliary(QWidget *w);
    bool sharesWidth(QWidget *w) const { return m_panel.contains(w); }
    bool isDocked(QWidget *w) const { return m_docked.value(w, true); }
    Side sideOf(QWidget *w) const { return m_side.value(w, Bottom); }
    /// w 若此刻吸附到 side 方位应落在的框：Bottom 用组宽、Left/Right 用 w 自身宽；
    /// 位置按同方位已吸附的前序成员（Panel 序）沿该方向排布。
    QRect computeSlot(QWidget *w, Side side) const;

    QHash<Panel, QWidget *> m_win;
    QList<QPointer<QWidget>> m_auxiliary;
    QSet<QWidget *> m_firstShow;
    QHash<QWidget *, Panel> m_panel;
    QHash<QWidget *, bool> m_vis;
    QHash<QWidget *, QPoint> m_lastTopLeft; // 上次记录的框左上角，用来求拖动位移
    QHash<QWidget *, bool> m_docked;        // 每面板吸附 / 浮动
    QHash<QWidget *, Side> m_side;          // 每面板吸附方位（Bottom/Left/Right）
    QHash<QWidget *, QTimer *> m_settle;    // 拖动停止判定（单发定时器）
    QHash<Panel, Saved> m_saved;            // 待套用的面板存档（registerPanel 消费）
    int m_width = 480;
    int m_originX = 0;
    int m_originTopY = 0;
    bool m_layingOut = false;
};
