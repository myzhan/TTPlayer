#pragma once

// 封面大图窗（对应 Swift CoverWindow）：跟随当前曲目换图，居中画封面，
// 下方两行「艺术家 - 标题」与「来路 / 无封面提示」。独立顶层窗，深色底衬。

#include "core/PlayerController.h"
#include "SkinWindow.h"

#include <QWidget>

class CoverWindow : public SkinWindow {
    Q_OBJECT
public:
    explicit CoverWindow(PlayerController *controller, QWidget *parent = nullptr);

    void reload();

protected:
    void paintBody(QPainter *p, const QRectF &rect) override;

private:
    PlayerController *m_controller;
    QImage m_image;
    QString m_caption;
    QString m_source;
};
