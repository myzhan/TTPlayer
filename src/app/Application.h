#pragma once
#include <QApplication>
#include <QFileOpenEvent>
#include <functional>

class PlayerApplication final : public QApplication {
public:
    using QApplication::QApplication;
    QStringList pendingFiles;
    std::function<void(const QStringList &)> openFiles;
    bool event(QEvent *event) override {
        if (event->type() == QEvent::FileOpen) {
            auto *file = static_cast<QFileOpenEvent *>(event);
            const QString value = file->url().isLocalFile() ? file->url().toLocalFile() : file->url().toString();
            if (openFiles)
                openFiles({value});
            else
                pendingFiles << value;
            return true;
        }
        return QApplication::event(event);
    }
};
