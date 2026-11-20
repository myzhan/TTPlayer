#pragma once
#include <memory>
#include <QObject>
class PlayerController;
class MainWindow;
std::unique_ptr<QObject> createMediaSession(PlayerController *controller, MainWindow *window);
