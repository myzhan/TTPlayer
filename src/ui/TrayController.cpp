#include "TrayController.h"
#include "MainWindow.h"
#include "AppIcon.h"
#include "SkinWidgets.h"

#include <QSystemTrayIcon>
#include <QMenu>
#include <QAction>
#include <QApplication>
#include <QCursor>
#include <QWindow>

TrayController::TrayController(MainWindow *window, PlayerController *controller, QObject *parent)
    : QObject(parent), m_window(window), m_controller(controller) {
    if (!QSystemTrayIcon::isSystemTrayAvailable()) return;

#ifdef Q_OS_WIN
    m_menu = buildMenu(true);
#else
    m_menu = buildMenu(false);
#endif
    m_tray = new QSystemTrayIcon(this);
    m_tray->setIcon(AppIcon::icon());
    m_tray->setToolTip(QStringLiteral("千千静听"));
#ifndef Q_OS_WIN
    m_tray->setContextMenu(m_menu);
#endif
    connect(m_tray, &QSystemTrayIcon::activated, this, [this](QSystemTrayIcon::ActivationReason reason) {
#ifdef Q_OS_WIN
        if (reason == QSystemTrayIcon::Context) {
            showContextMenu(QCursor::pos());
            return;
        }
#endif
        if (reason != QSystemTrayIcon::Trigger && reason != QSystemTrayIcon::DoubleClick) return;
        if (m_window) m_window->toggleGroupVisibility();
    });
    m_tray->show();
}

TrayController::~TrayController() {
    if (m_tray) {
        m_tray->hide();
        m_tray->setContextMenu(nullptr);
    }
    delete m_menu;
}

QMenu *TrayController::buildMenu(bool themed) {
    QMenu *menu = nullptr;
    if (themed) {
        auto *skin = new SkinMenu();
        skin->setCornerRadius(6);
        skin->setStyleSheet(skin->styleSheet() + QStringLiteral("QMenu{padding:4px;}"));
        menu = skin;
    } else {
        menu = new QMenu();
    }
    menu->setObjectName(QStringLiteral("trayMenu"));
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

    return menu;
}

void TrayController::showContextMenu(const QPoint &position) {
    if (!m_menu || !m_window) return;
    // QMenu::popup 负责屏幕边界、键盘与点外关闭；不恢复已隐藏的主窗。
    m_menu->popup(position);
    if (auto *handle = m_menu->windowHandle()) handle->requestActivate();
}

bool TrayController::available() const {
    return m_tray != nullptr;
}
