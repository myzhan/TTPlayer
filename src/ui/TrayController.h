#pragma once

// 系统托盘后台（菜单栏后台继续播）：最小化/隐藏到托盘后
// 音频继续，托盘菜单提供 显示/隐藏 · 播放/暂停 · 上一首/下一首 · 停止 · 退出。
// 平台没有托盘（部分 Linux 桌面）时静默降级，不影响主界面。

#include "playback/PlayerController.h"

#include <QObject>
#include <QPointer>

class MainWindow;
class QSystemTrayIcon;
class QMenu;

class TrayController : public QObject {
    Q_OBJECT
public:
    TrayController(MainWindow *window, PlayerController *controller, QObject *parent = nullptr);
    ~TrayController() override;

    bool available() const;

private:
    friend class RegressionTests;
    QMenu *buildMenu(bool themed);
    void showContextMenu(const QPoint &position);
    QMenu *m_menu = nullptr; // 析构时先解除托盘关联，再销毁菜单。
    QPointer<MainWindow> m_window;
    PlayerController *m_controller;
    QSystemTrayIcon *m_tray = nullptr;
};
