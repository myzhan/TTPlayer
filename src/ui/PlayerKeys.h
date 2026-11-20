#pragma once
#include "MainWindow.h"
#include "SkinWidgets.h"
#include <QApplication>
#include <QKeyEvent>
#include <QLineEdit>
#include <QTextEdit>
#include <QAbstractSpinBox>
#include <QFileDialog>

class PlayerKeys final : public QObject {
    MainWindow *window;
public:
    explicit PlayerKeys(MainWindow *w):QObject(w),window(w){qApp->installEventFilter(this);}
    bool eventFilter(QObject *target,QEvent *event)override {
        if(event->type()!=QEvent::KeyPress)return false;
        auto *key=static_cast<QKeyEvent *>(event);
        QWidget *focus=qobject_cast<QWidget *>(target);
        if(!focus)focus=QApplication::focusWidget();
        const bool editing=qobject_cast<QLineEdit *>(focus)||qobject_cast<QTextEdit *>(focus)||qobject_cast<QAbstractSpinBox *>(focus)
                           ||qobject_cast<SkinLineEdit *>(focus)||qobject_cast<SkinSpinBox *>(focus);
        auto *ctl=window->controller();const auto modifiers=key->modifiers();
        if(modifiers==Qt::NoModifier&&(key->key()>=Qt::Key_F1&&key->key()<=Qt::Key_F4)) {
            static const PlayMode modes[]={PlayMode::Order,PlayMode::SingleLoop,PlayMode::ListLoop,PlayMode::Random};
            ctl->setMode(modes[key->key()-Qt::Key_F1]);return true;
        }
        if(modifiers==Qt::NoModifier&&!editing) {
            switch(key->key()) {
            case Qt::Key_M:window->toggleMute();return true;
            case Qt::Key_Space:ctl->togglePlay();return true;
            case Qt::Key_Left:ctl->prev();return true;
            case Qt::Key_Right:ctl->next();return true;
            case Qt::Key_F1:ctl->setMode(PlayMode::Order);return true;
            case Qt::Key_F2:ctl->setMode(PlayMode::SingleLoop);return true;
            case Qt::Key_F3:ctl->setMode(PlayMode::ListLoop);return true;
            case Qt::Key_F4:ctl->setMode(PlayMode::Random);return true;
            }
        }
        if(modifiers==Qt::AltModifier&&!editing) {
            if(key->key()==Qt::Key_Left){ctl->nudgeLyricShift(-0.5);return true;}
            if(key->key()==Qt::Key_Right){ctl->nudgeLyricShift(0.5);return true;}
            if(key->key()==Qt::Key_0){ctl->resetLyricShift();return true;}
        }
        if(key->matches(QKeySequence::Quit)){qApp->quit();return true;}
        if(key->key()==Qt::Key_O&&modifiers==(Qt::ControlModifier|Qt::ShiftModifier)) {
            const QString path=QFileDialog::getExistingDirectory(window,QStringLiteral("添加音乐目录"));
            if(!path.isEmpty())window->loadPaths({path});return true;
        }
        return false;
    }
};
