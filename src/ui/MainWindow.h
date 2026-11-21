#pragma once

// 主面板：紧凑播放器外壳。
// 竖排 = 标题条(22) → 显示大槽 DisplayPanel(150：歌名/声道/状态/格式 四行文字 + 封面 +
// 频谱 + 底部条[音量·静音·传输带·列表/均衡器/歌词]) → 独立进度行 ControlBar(18)。
// 播放列表已挪到独立 PlaylistWindow（列表/均衡器/歌词是各自浮窗，SkinDock 三窗排布后续补）。

#include "core/PlayerController.h"
#include "core/Collections.h"
#include "audio/AudioEngine.h"

#include <QWidget>
#include <QPixmap>
#include <QSet>

class QLabel;
class SpectrumView;
class TransportBar;
class TimeSlider;
class VolumeSlider;
class TTButton;
class WellView;
class PlaylistWindow;
class EqWindow;
class LyricWindow;
class CoverWindow;
class QueueWindow;
class SkinDock;
class QFileSystemWatcher;
class QTimer;

class MainWindow : public QWidget {
    Q_OBJECT
public:
    explicit MainWindow(PlayerController *controller, AudioEnginePtr engine, QWidget *parent = nullptr);
    ~MainWindow() override;
    void cancelLibraryScan();
    void toggleMute();
    bool userMuted() const { return m_muted; }
    double userVolume() const { return m_vol; }
    void setUserVolume(double volume);

    bool isRestoringLibrary() const { return m_restoringLibrary; }
    void restoreLibrary(); // 无命令行输入时：从 state.db 恢复列表 / 扫曲库
    /// 出厂电台默认入表（F11）：不开庭、走同一 addRadio 通路、删过不回来。返回新种入台数
    int seedPresetRadios();
    void flushState() { saveState(); } // 退出前落盘（aboutToQuit 用）
    QString relocateLibraryRoot(const QString &oldRoot, const QString &newRoot);
    QString operationStatus() const { return m_operationStatus; }
    void loadPaths(const QStringList &paths) { loadDirOrFiles(paths); } // 含 CUE 展开

    Collections &collections() { return m_collections; } // 播放列表窗共享的集合层

    // 供设置对话框绑定：控制器 / 引擎 / 启动自动续播 / 曲库文件夹 / 落盘
    PlayerController *controller() { return m_controller; }
    AudioEnginePtr engine() { return m_engine; }
    bool autoResumePlay() const { return m_autoResumePlay; }
    void setAutoResumePlay(bool on) {
        m_autoResumePlay = on;
        saveState();
    }
    QStringList libraryFolders() const { return m_libraryFolders; }
    void addLibraryFolder(const QString &path);
    void removeLibraryFolder(const QString &path);
    void rescanLibrary();                 // 重扫全部曲库目录并刷新展示
    void setLibraryWatchEnabled(bool on); // 关闭时不响应文件系统改动（无头探针用）
    void requestSave() { saveState(); }

    // R19 后台驻留（对齐 AGENTS.md：— 隐藏整组到菜单栏后台继续播、× 直退进程）：
    // hideGroupToBackground 记住整组当前可见窗再全隐；restoreGroupFromBackground 只恢复那些。
    // 无托盘平台 hideGroupToBackground 退化为 showMinimized（否则藏起来没入口恢复）。
    void hideGroupToBackground();
    void restoreGroupFromBackground();
    void toggleGroupVisibility();                                        // 托盘点击 / 双击走这里
    void setGroupHideBypassTray(bool on) { m_groupHideBypassTray = on; } // 无头探针：跳过「无托盘退化最小化」门
    bool isGroupHidden() const { return m_groupHidden; }                 // 探针：当前是否处于整组隐藏态

    // 置顶（整组）：面板开合抽成可复用方法（标题/底部按钮走同一条通路），并暴露整组覆盖计数供无头探针。
    void togglePlaylistPanel();
    void toggleEqPanel();
    void toggleLyricPanel();
    void toggleCoverPanel();
    void toggleQueuePanel();
    void applyPinTop(bool on) { togglePinTop(on); } // 探针：驱动真实「置顶整组」逻辑
    int probeGroupVisible() const;                  // 当前可见的整组窗数（含主窗）
    int probeGroupPinned() const;                   // 其中带 stays-on-top 的数

protected:
    void paintEvent(QPaintEvent *) override;
    void dropEvent(QDropEvent *) override;
    void dragEnterEvent(QDragEnterEvent *) override;
    void closeEvent(QCloseEvent *) override;
    void showEvent(QShowEvent *) override; // 首次显示后装停靠组（那时才有真实 frameGeometry）
    // 无边框窗：靠边缘 startSystemResize 缩放，并随位置切换缩放光标
    void mousePressEvent(QMouseEvent *) override;
    void mouseMoveEvent(QMouseEvent *) override;

private:
    QPixmap m_bodyCache;
    float m_bodyAlpha = -1;
    void captureResume(LibraryStore::Loaded &scene) const;
    void writeResume();
    bool m_restoringLibrary = false, m_rescanAfterRestore = false, m_seedAfterRestore = false,
         m_saveAfterRestore = false;
    uint64_t m_restoreGeneration = 0;
    QStringList m_deferredImports;
    std::shared_ptr<std::atomic<bool>> m_restoreCancel;
    std::shared_ptr<std::atomic<bool>> m_watchCancel;
    uint64_t m_watchGeneration = 0;
    QString m_persistenceProblem, m_operationStatus;
    std::shared_ptr<std::atomic<bool>> m_importCancel;
    uint64_t m_importGeneration = 0;
    bool m_sceneReady = false, m_savedEQVisible = false;
    friend class RegressionTests;
    void openFiles();
    void openFolder(); // 播放列表右键「添加文件夹…」：选目录后整棵导入
    void addRadioPrompt(); // 右键「添加网络电台…」：问地址→走同一条 loadPaths 通路建成 radio Track
    void loadDirOrFiles(const QStringList &paths);
    void syncNowPlaying();
    void syncState();
    void applyVolume();
    void toggleFavoriteCurrent();              // Cmd+D：当前曲加入 / 移出收藏
    void placeFloating(QWidget *w, int slot);  // SkinDock 式：主窗下方错开摆
    void loadState();                          // 从 state.db 应用设置
    void saveState();                          // 当前运行时写回 state.db
    void updateModeBadge();                    // 标题条播放方式徽章（[列表循环] 等）
    void togglePinTop(bool on);                // 置顶：整组可见窗一起切 WindowStaysOnTopHint
    void setWindowPinTop(QWidget *w, bool on); // 对单窗切 stays-on-top（改 flags 后按需重显保位）
    void updateLibraryWatch();                 // R09：把曲库文件夹(含子目录)挂上 QFileSystemWatcher
    void onLibraryChanged();                   // 目录改动→重启防抖重扫定时器

    PlayerController *m_controller;
    AudioEnginePtr m_engine;
    Collections m_collections; // 收藏 / 自建歌单 / 当前视图（F04/F05）

    // 显示区文字
    QLabel *m_marquee = nullptr;
    QLabel *m_channel = nullptr;
    QLabel *m_status = nullptr;
    QLabel *m_codec = nullptr;
    QWidget *m_cover = nullptr;
    SpectrumView *m_spectrum = nullptr;

    // 标题条：播放方式徽章 + 置顶键
    QLabel *m_modeBadge = nullptr;
    TTButton *m_pin = nullptr;

    // 底部条控件
    VolumeSlider *m_volume = nullptr;
    TTButton *m_mute = nullptr;
    TransportBar *m_transport = nullptr;
    TTButton *m_list = nullptr;
    TTButton *m_eq = nullptr;
    TTButton *m_lyric = nullptr;

    // 进度行
    TimeSlider *m_seek = nullptr;

    PlaylistWindow *m_playlist = nullptr; // 懒建
    EqWindow *m_eqWindow = nullptr;       // 懒建
    LyricWindow *m_lyricWindow = nullptr; // 懒建
    CoverWindow *m_coverWindow = nullptr; // 懒建（点封面格开合）
    QueueWindow *m_queueWindow = nullptr; // 懒建（待播队列面板，F03）

    SkinDock *m_dock = nullptr; // 主窗锚点 + 列表/均衡器/歌词自由拖动、靠近才磁吸
    bool m_dockReady = false;
    QString m_savedFrame;       // 存档里的停靠组锚点几何 "left,top,width"
    QString m_savedPanelFrames; // 存档里各面板几何+吸附态（交给 SkinDock::setSavedPanels）

    double m_vol = 0.8;
    bool m_muted = false;
    bool m_pinTop = false; // 置顶权威态（与 m_pin 按钮同步）：整组置顶 + 新开窗继承都读它，不绑按钮 widget

    // 本模块不驱动、但需原样回写的字段（避免丢用户数据）
    bool m_autoResumePlay = false;
    bool m_listVisible = true;
    QFileSystemWatcher *m_libWatcher = nullptr; // R09：曲库目录监听（文件系统事件的 Qt 等价）
    QTimer *m_rescanTimer = nullptr;            // 防抖：多次改动合一次重扫
    QStringList m_libraryFolders;
    QStringList m_declinedRadioKeys; // 用户删过的内置电台身份键（F11 黑名单）
    QSet<QString> m_scannedKeys; // 上一次由「曲库文件夹扫描」贡献的 @all 身份键（R02：重扫只换这批，不动手工项/电台）

    // R19：隐藏到后台前整组哪些窗可见，恢复时只弹回这些
    QList<QWidget *> m_groupBeforeHide;
    std::shared_ptr<std::atomic<bool>> m_scanCancel;
    uint64_t m_scanGeneration = 0;
    bool m_groupHidden = false;
    bool m_groupHideBypassTray = false; // 探针置真：offscreen 无托盘也走整组隐藏路径
};
