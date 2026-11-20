#pragma once

// 曲目「属性」对话框（复刻千千静听媒体文件信息窗）：左侧封面缩略图，
// 右侧「艺术家 - 标题」+ 逐行 key：value（文件名/路径/类型/大小/时长/采样率/
// 声道/码率/封面来路，以及 CUE 分轨位置）。数据源统一走 Track getter + CoverArt。

#include "models/Track.h"
#include "SkinWindow.h"

class PlayerController;

class PropertyWindow : public SkinWindow {
    Q_OBJECT
public:
    explicit PropertyWindow(const Track &track, PlayerController *ctl = nullptr, QWidget *parent = nullptr);

    static QList<QPair<QString, QString>> linesFor(const Track &track);
};
