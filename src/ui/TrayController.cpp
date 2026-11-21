#include "TrayController.h"
#include "MainWindow.h"
#include "AppIcon.h"

#include <QSystemTrayIcon>
#include <QMenu>
#include <QAction>
#include <QApplication>

TrayController::TrayController(MainWindow *window, PlayerController *controller, QObject *parent)
    : QObject(parent), m_window(window), m_controller(controller) {
    if (!QSystemTrayIcon::isSystemTrayAvailable()) return;

    auto *menu = new QMenu();
    QAction *toggleVis = menu->addAction(QStringLiteral("显示 / 隐藏主界面"));
    menu->addSeparator();
    QAction *playPause = menu->addAction(QStringLiteral("播放 / 暂停"));
    QAction *prev = menu->addAction(QStringLiteral("上一首"));
    QAction *next = menu->addAction(QStringLiteral("下一首"));
    QAction *stop = menu->addAction(QStringLiteral("停止"));
    menu->addSeparator();
    QAction *quit = menu->addAction(QStringLiteral("退出"));

    connect(toggleVis, &QAction::triggered, this, [this] {
        if (!m_window) return;
        m_window->toggleGroupVisibility(); // R19：作用于整组并恢复原可见性，不只主窗
    });
    connect(playPause, &QAction::triggered, m_controller, &PlayerController::togglePlay);
    connect(prev, &QAction::triggered, m_controller, &PlayerController::prev);
    connect(next, &QAction::triggered, m_controller, &PlayerController::next);
    connect(stop, &QAction::triggered, m_controller, &PlayerController::stop);
    connect(quit, &QAction::triggered, qApp, &QCoreApplication::quit);

    m_tray = new QSystemTrayIcon(this);
    m_tray->setIcon(AppIcon::icon());
    m_tray->setToolTip(QStringLiteral("千千静听"));
    m_tray->setContextMenu(menu);
    // 双击托盘图标 = 显示 / 隐藏
    connect(m_tray, &QSystemTrayIcon::activated, this, [this](QSystemTrayIcon::ActivationReason r) {
        if (r != QSystemTrayIcon::Trigger && r != QSystemTrayIcon::DoubleClick) return;
        if (!m_window) return;
        m_window->toggleGroupVisibility(); // R19：整组隐藏 / 恢复
    });
    m_tray->show();
}

bool TrayController::available() const {
    return m_tray != nullptr;
}
