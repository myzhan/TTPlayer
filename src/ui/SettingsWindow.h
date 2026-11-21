#pragma once

// 独立设置对话框：把设置项归并成分组的模态面板
// （播放 / 音效 / 输出设备 / 歌词 / 外观 / 媒体库），全部直连已有后端。
// 改一处即落盘（走 MainWindow::requestSave / 各自 setter），不憋到关闭才写。

#include "SkinWindow.h"

class MainWindow;
class QLabel;
class SkinListView;
class SkinComboBox;
class SkinSlider;

class SettingsWindow : public SkinWindow {
    Q_OBJECT
public:
    explicit SettingsWindow(MainWindow *main, QWidget *parent = nullptr);

private:
    QWidget *buildPlayback();
    QWidget *buildAudioFx();
    QWidget *buildOutput();
    QWidget *buildLyric();
    QWidget *buildAppearance();
    QWidget *buildLibrary();

    void refreshLyricStatus();

    MainWindow *m_main;

    // 播放
    SkinComboBox *m_mode = nullptr;
    SkinComboBox *m_sleepPreset = nullptr;
    // 音效
    SkinComboBox *m_rgMode = nullptr;
    SkinSlider *m_preamp = nullptr;
    QLabel *m_preampLabel = nullptr;
    // 输出设备
    SkinComboBox *m_device = nullptr;
    // 歌词
    QLabel *m_lyricStatus = nullptr;
    // 外观
    SkinSlider *m_transparency = nullptr;
    QLabel *m_transparencyLabel = nullptr;
    // 媒体库
    SkinListView *m_folders = nullptr;
};
