#include "SkinDock.h"

#include <QWidget>
#include <QEvent>
#include <QTimer>
#include <QPointer>
#include <QGuiApplication>
#include <QScreen>

SkinDock::SkinDock(QObject *parent) : QObject(parent) {}

QWidget *SkinDock::panelWindow(Panel p) const {
    return m_win.value(p, nullptr);
}

bool SkinDock::isPanelDocked(Panel p) const {
    QWidget *w = m_win.value(p, nullptr);
    return w ? isDocked(w) : false;
}

int SkinDock::panelSide(Panel p) const {
    QWidget *w = m_win.value(p, nullptr);
    return w ? static_cast<int>(sideOf(w)) : -1;
}

void SkinDock::registerPanel(Panel panel, QWidget *w) {
    if (!w) return;
    m_win[panel] = w;
    m_panel[w] = panel;
    m_vis[w] = w->isVisible();
    m_lastTopLeft[w] = w->frameGeometry().topLeft();

    // 默认吸附态：全吸附、Bottom 主列（保持既有竖排外观）。
    bool docked = true;
    Side side = Bottom;
    // 套用存档（若有）：几何 + 吸附态 + 方位。浮动面板先按存档自由几何摆；吸附面板交给 layout 重排。
    if (m_saved.contains(panel)) {
        const Saved s = m_saved.take(panel);
        docked = s.docked;
        side = static_cast<Side>(s.side);
        w->resize(s.frame.size());
        if (!docked) w->move(s.frame.topLeft());
    }
    m_docked[w] = docked;
    m_side[w] = side;

    // Bottom 吸附成员一登记就先被「当前组宽」收编：否则它自带的大初始宽（如列表窗 600）
    // 会在首次显示时以 Resize 事件泄漏进 m_width，把主窗与整组一起撑大（实测：开列表 480→600）。
    // Left/Right 侧列宽度独立，不收编。
    if (panel != Main && docked && side == Bottom && m_width > 0 && w->width() != m_width)
        w->resize(m_width, w->height());

    w->installEventFilter(this);

    // 主窗是宽度与组锚点的基准
    if (panel == Main) {
        m_width = w->width();
        const QRect f = w->frameGeometry();
        m_originX = f.left();
        m_originTopY = f.top();
    }
    layout();
}

bool SkinDock::eventFilter(QObject *obj, QEvent *ev) {
    auto *w = qobject_cast<QWidget *>(obj);
    if (!w || !m_panel.contains(w)) return false;
    switch (ev->type()) {
        case QEvent::Move:
            if (panelOf(w) == Main) memberMovedMain(w);
            else memberMovedPanel(w);
            break;
        case QEvent::Resize: memberResized(w); break;
        case QEvent::Show:  m_vis[w] = true;  layout(); break;
        case QEvent::Hide:  m_vis[w] = false; layout(); break;
        default: break;
    }
    return false;   // 不吞事件，各窗照常处理
}

// 拖动主窗：更新锚点，已吸附成员按同一位移跟随（浮动成员不动）。
void SkinDock::memberMovedMain(QWidget *w) {
    if (m_layingOut) return;
    const QPoint now = w->frameGeometry().topLeft();
    const QPoint last = m_lastTopLeft.value(w, now);
    const QPoint d = now - last;
    if (d.isNull()) return;
    m_originX += d.x();
    m_originTopY += d.y();
    m_lastTopLeft[w] = now;
    layout();
}

// 拖动面板（列表 / 均衡器 / 歌词）：跟手自由移动，不实时重排；靠 settle 定时器在
// 停下后判磁吸。布局期的程序化 move 被 m_layingOut 挡掉，不会被误认成用户拖动。
void SkinDock::memberMovedPanel(QWidget *w) {
    if (m_layingOut) return;
    m_lastTopLeft[w] = w->frameGeometry().topLeft();
    QTimer *t = m_settle.value(w, nullptr);
    if (!t) {
        t = new QTimer(this);
        t->setSingleShot(true);
        t->setInterval(90);
        const QPointer<QWidget> guard = w;
        connect(t, &QTimer::timeout, this, [this, guard] {
            if (guard) evaluateSnap(guard);
        });
        m_settle[w] = t;
    }
    t->start();   // 每次 Move 重置，最后一次 Move 后 90ms 无动静即判定
}

// 拉宽：主窗或任一 Bottom 吸附成员改宽 → 主列同宽；Left/Right 侧列与浮动成员尺寸各自独立。
void SkinDock::memberResized(QWidget *w) {
    if (m_layingOut) return;
    if (panelOf(w) == Main) {
        if (w->width() != m_width) m_width = w->width();
        layout();
        return;
    }
    if (isDocked(w) && sideOf(w) == Bottom && w->width() != m_width) {
        m_width = w->width();
        layout();
    }
}

// w 若此刻吸附到 side 方位应落在的框。Bottom：主列，宽度取组宽，落在同方位前序成员下方；
// Left/Right：侧列，宽度取 w 自身，顶边与主窗对齐、沿侧按 Panel 序往下堆。
QRect SkinDock::computeSlot(QWidget *w, Side side) const {
    QWidget *mainW = panelWindow(Main);
    const QRect mf = mainW ? mainW->frameGeometry()
                           : QRect(m_originX, m_originTopY, m_width, 200);
    const Panel target = panelOf(w);

    if (side == Bottom) {
        QWidget *prev = mainW;
        for (Panel p : {Playlist, Equalizer, Lyric}) {
            if (p == target) break;
            QWidget *pw = panelWindow(p);
            if (!pw || !m_vis.value(pw, false) || !isDocked(pw) || sideOf(pw) != Bottom) continue;
            prev = pw;
        }
        const QRect pr = prev ? prev->frameGeometry()
                              : QRect(m_originX, m_originTopY, m_width, 0);
        return QRect(pr.left(), pr.bottom() + kGap + 1, m_width, w->height());
    }

    // Left / Right 侧列：先算同方位、排在 w 之前的成员把游标往下推多少
    int cursorY = mf.top();
    for (Panel p : {Playlist, Equalizer, Lyric}) {
        if (p == target) break;
        QWidget *pw = panelWindow(p);
        if (!pw || !m_vis.value(pw, false) || !isDocked(pw) || sideOf(pw) != side) continue;
        cursorY += pw->frameGeometry().height() + kGap + 1;
    }
    const int ww = w->width();
    if (side == Right)
        return QRect(mf.right() + 1 + kGap, cursorY, ww, w->height());
    return QRect(mf.left() - kGap - ww, cursorY, ww, w->height());   // Left：右边缘贴主窗左侧留缝
}

// 拖动停下后：在 Bottom/Left/Right 三个候选槽里挑「左上角最近且 ≤ 阈值」的吸附；
// 都不够近则脱离浮动，让其余吸附成员补位。
void SkinDock::evaluateSnap(QWidget *w) {
    if (m_layingOut || !m_panel.contains(w)) return;
    const QRect f = w->frameGeometry();
    Side best = Bottom;
    int bestDist = kSnapDist + 1;
    bool found = false;
    for (Side s : {Bottom, Left, Right}) {
        const QRect slot = computeSlot(w, s);
        const int d = qMax(qAbs(f.left() - slot.left()), qAbs(f.top() - slot.top()));
        if (d < bestDist) { bestDist = d; best = s; found = true; }
    }
    if (found) {
        m_side[w] = best;
        if (!isDocked(w)) m_docked[w] = true;
        layout();   // 吸附：落回该方位槽位（Bottom 会顺带对齐组宽）
    } else if (isDocked(w)) {
        m_docked[w] = false;   // 拖离：保留当前几何与宽度，转为浮动
        layout();              // 其余吸附成员重排补位
    }
}

void SkinDock::layout() {
    if (m_layingOut) return;
    m_layingOut = true;

    // 主窗：锚点 + 组宽基准（永远排在主列最上）。
    QWidget *mainW = panelWindow(Main);
    if (mainW && m_vis.value(mainW, true)) {
        if (mainW->width() != m_width) mainW->resize(m_width, mainW->height());
        mainW->move(m_originX, m_originTopY);
        m_lastTopLeft[mainW] = mainW->frameGeometry().topLeft();
    }
    const QRect mf = mainW ? mainW->frameGeometry()
                           : QRect(m_originX, m_originTopY, m_width, 0);

    // Bottom 主列：只堆叠「可见 + 吸附 + Bottom」成员，同宽；浮动 / 侧列成员不碰。
    QWidget *prev = mainW;
    for (Panel p : {Playlist, Equalizer, Lyric}) {
        QWidget *w = panelWindow(p);
        if (!w || !m_vis.value(w, false) || !isDocked(w) || sideOf(w) != Bottom) continue;
        if (w->width() != m_width) w->resize(m_width, w->height());
        const QRect pr = prev ? prev->frameGeometry()
                             : QRect(m_originX, m_originTopY, m_width, 0);
        w->move(pr.left(), pr.bottom() + kGap + 1);
        m_lastTopLeft[w] = w->frameGeometry().topLeft();
        prev = w;
    }

    // Right 侧列：顶边与主窗对齐，沿侧往下堆，宽度各自独立。
    {
        const int x = mf.right() + 1 + kGap;
        int cursorY = mf.top();
        for (Panel p : {Playlist, Equalizer, Lyric}) {
            QWidget *w = panelWindow(p);
            if (!w || !m_vis.value(w, false) || !isDocked(w) || sideOf(w) != Right) continue;
            w->move(x, cursorY);
            cursorY += w->frameGeometry().height() + kGap + 1;
            m_lastTopLeft[w] = w->frameGeometry().topLeft();
        }
    }
    // Left 侧列：右边缘贴主窗左侧留缝，顶边对齐，沿侧往下堆。
    {
        const int rightEdge = mf.left() - 1 - kGap;
        int cursorY = mf.top();
        for (Panel p : {Playlist, Equalizer, Lyric}) {
            QWidget *w = panelWindow(p);
            if (!w || !m_vis.value(w, false) || !isDocked(w) || sideOf(w) != Left) continue;
            w->move(rightEdge - w->width() + 1, cursorY);
            cursorY += w->frameGeometry().height() + kGap + 1;
            m_lastTopLeft[w] = w->frameGeometry().topLeft();
        }
    }

    m_layingOut = false;
    emit geometryChanged();
}

QString SkinDock::geometryString() const {
    return QStringLiteral("%1,%2,%3").arg(m_originX).arg(m_originTopY).arg(m_width);
}

QString SkinDock::panelFramesString() const {
    QStringList out;
    auto add = [&out, this](Panel p, const char *tag) {
        QWidget *w = panelWindow(p);
        if (!w) return;
        const QRect f = w->frameGeometry();
        out << QStringLiteral("%1=%2,%3,%4,%5,%6,%7")
                   .arg(QLatin1String(tag)).arg(f.x()).arg(f.y())
                   .arg(f.width()).arg(f.height())
                   .arg(isDocked(w) ? 1 : 0).arg(static_cast<int>(sideOf(w)));
    };
    add(Playlist, "pl");
    add(Equalizer, "eq");
    add(Lyric, "ly");
    return out.join(QLatin1Char(';'));
}

void SkinDock::setSavedPanels(const QString &s) {
    m_saved.clear();
    for (const QString &item : s.split(QLatin1Char(';'), Qt::SkipEmptyParts)) {
        const int sep = item.indexOf(QLatin1Char('='));
        if (sep < 0) continue;
        const QString tag = item.left(sep);
        Panel p = Playlist;
        if (tag == QLatin1String("eq")) p = Equalizer;
        else if (tag == QLatin1String("ly")) p = Lyric;
        else if (tag != QLatin1String("pl")) continue;   // 只认这三类，主窗走 dockFrame
        const QStringList v = item.mid(sep + 1).split(QLatin1Char(','));
        if (v.size() < 5 || v.size() > 6) continue;      // 5=旧档（无 side，默认 Bottom）
        bool ok = false;
        const int x = v[0].toInt(&ok), y = v[1].toInt(&ok);
        const int w = v[2].toInt(&ok), h = v[3].toInt(&ok), d = v[4].toInt(&ok);
        if (!ok || w < 100 || h < 40) continue;
        int side = (v.size() == 6) ? v[5].toInt() : 0;
        if (side < 0 || side > 2) side = 0;
        m_saved[p] = Saved{clampToScreens(QRect(x, y, w, h)), d != 0, side};
    }
}

QRect SkinDock::clampToScreens(const QRect &want) {
    const auto screens = QGuiApplication::screens();
    for (const QScreen *s : screens)
        if (s->geometry().intersects(want))
            return want;   // 已与某块屏相交，不动用户几何
    // 完全在所有屏幕之外：保持尺寸，居中到主屏可用区（无主屏兜底给一个保守默认）
    QScreen *primary = QGuiApplication::primaryScreen();
    const QRect avail = primary ? primary->availableGeometry()
                               : QRect(0, 0, 1280, 800);
    int nx = avail.x() + (avail.width()  - want.width())  / 2;
    int ny = avail.y() + (avail.height() - want.height())  / 2;
    nx = qBound(avail.x(), nx, avail.x() + avail.width()  - want.width());
    ny = qBound(avail.y(), ny, avail.y() + avail.height() - want.height());
    return QRect(nx, ny, want.width(), want.height());
}

bool SkinDock::restoreGeometry(const QString &s) {
    const QStringList parts = s.split(QLatin1Char(','));
    if (parts.size() != 3) return false;
    bool ok = false;
    const int x = parts[0].toInt(&ok);       if (!ok) return false;
    const int y = parts[1].toInt(&ok);       if (!ok) return false;
    const int w = parts[2].toInt(&ok);       if (!ok || w < 320) return false;
    // 组锚点（= 主窗左上角）可能在旧多屏布局里落在屏幕外，夹回可用屏幕；
    // 高度取一个代表值只为让相交/居中判断成立，真正决定落点的是左上角。
    const QRect c = clampToScreens(QRect(x, y, w, 221));
    m_originX = c.x();
    m_originTopY = c.y();
    m_width = w;
    layout();
    return true;
}
