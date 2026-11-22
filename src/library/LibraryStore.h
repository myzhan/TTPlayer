#pragma once

// 用户设置 / 歌曲列表 / 播放现场的持久化：SQLite（state.db，与旧 state.json 同目录）。
//
// 为什么换库：设置与列表是两类不同粒度、写频不同的数据（resume 每 5 秒一次、设置按需），
// JSON 时代的做法是每次整份重写 state.json，且「未知键透传」只能靠原样搬运。入库后：
//   - 设置是 settings 表里的键值行，列表是各自有序表（favorites / recent_plays / ...），
//     改一行就写一行，外部也能用 sqlite3 直接查；
//   - 写入走事务，崩溃只会回滚整个事务，没有「写了一半」的档；
//   - 旧 JSON 首次启动自动迁移一次（state.json → state.db），原档改名 .migrated-<时间戳> 留底；
//     JSON 里认不得的顶层键整段存进 meta 表，不丢用户数据。
// 读仍然逐字段宽容兑默认（旧库缺列/缺行都算默认），不因单个怪值把整库判死。
// playMode 落盘沿用既有枚举序（order/singleLoop/listLoop/random），与 Qt 枚举不同，需映射。

#include "models/PlayQueue.h"
#include "models/RadioStations.h"
#include "models/UserPlaylist.h"
#include "audio/EQ.h"

#include <QJsonObject>
#include <QList>
#include <QMap>
#include <QString>
#include <QStringList>
#include <array>

namespace LibraryStore {

struct Loaded {
    bool valid = false;         // 库存在且能读（首启迁移成功也算）
    QStringList trackPaths;     // 上次列表（file:// URL，含 fragment）
    QStringList libraryFolders; // 曲库根目录
    QStringList libraryKeys;
    QStringList defaultKeys;
    bool hasDefaultKeys = false;
    QJsonObject trackEdits;
    double volume = 0.8;
    bool muted = false;
    PlayMode mode = PlayMode::ListLoop;
    bool eqEnabled = true;
    double eqPreGain = 0;
    std::array<double, Equalizer::kBands> eqGains{};
    double transparency = 0.15;
    bool glass = true;
    QString windowFrame; // "x,y,w,h"
    QString dockFrame;   // 停靠组锚点几何 "left,top,width"（SkinDock）
    QString panelFrames; // 各可停靠面板几何+吸附态 "pl=x,y,w,h,d;eq=..;ly=.."（旧档缺=空，全默认吸附）
    int skinLayout = 0; // 皮肤布局版本：与当前版本不符则丢弃旧几何（R20）
    bool autoResumePlay = false;
    bool listVisible = true;
    bool eqVisible = false;
    // 响度均衡（F02）：沿用旧档键名与枚举序（off=0/track=1/album=2），默认关
    int replayGainMode = 0;
    double replayGainPreamp = 0;
    bool replayGainPeakLimit = true;
    // 收藏 / 自建歌单 / 上次在看的歌单（F04/F05）：沿用旧档键名与写法（旧档缺这些 = 空）
    QStringList favoriteKeys;      // 收藏键，按加入顺序
    QList<UserPlaylist> userLists; // 自建歌单
    QString viewListID;            // 上次在看的页（沿用旧档写法：
                                   // "main"/"library"/"radio"/"recentRadio"/"recent"/"favorites"/
                                   // "playlist:<id>"；空或认不出 = 回 [默认]）
    // 最近播放 / 最近听的台（F06 派生页）：纯键档案，最近的在最前；旧档缺 = 空
    QStringList recentKeys;      // 最近播过的 identityKey（上限 50）
    QStringList recentRadioKeys; // 最近听过的台地址（上限 20）
    // 无缝播放（F01）：默认开，旧档缺这一项不能「升级一下又跳空白」
    bool gaplessPlay = true;
    // 睡眠定时器到期前淡出最后十秒（F09）：只有开关入库，定时器本身不入库
    bool sleepFade = true;
    // 输出设备（F07）：只存 SDL 设备名（mac 上即 CoreAudio UID），空串 = 跟随系统默认
    QString outputDeviceUID;
    QString outputDeviceName; // 可读名，只为「设备不在了还能说出它叫什么」
    // 歌词时间校准（F10）：键 = Track.identityKey，值 = 秒（正 = 延后），只进存档不回写 .lrc
    QMap<QString, double> lyricShifts;
    // 出厂电台黑名单（F11）：用户亲手删掉的内置电台身份键，种入只认这一份、以后启动不再塞回
    QStringList declinedRadioKeys;
    // 电台档案（R13）：台名 / 分类 / 归属，全以电台地址为键；旧档缺 = 空（谁也没起过名字）
    QHash<QString, QString> radioAliases;     // 地址 → 自定义台名
    QList<RadioCategory> radioCategories;     // 用户建的分类，按创建顺序
    QHash<QString, QString> radioAssignments; // 地址 → 分类 id（未分类不占位）
    // R03 播放现场恢复：旧档缺这些键 → 无现场（全默认）。
    // resumeQueue 是基础播放序列的 token；旧来源只在读档适配器中处理。
    bool resumeValid = false;        // 上次确实停在一个播放上下文上
    QString resumeTrackKey;          // 正在播那条的 token（冗余保存，便于诊断/兜底）
    double resumePosition = 0;       // 段内秒
    bool resumeWasPlaying = false;   // 关机瞬间是否在播（配合 autoResumePlay 才决定开不开声）
    int resumeCursor = -1;           // 游标下标（-1 = 无）
    QList<int> resumeHistoryIndexes; // 随机回退栈（指向 resumeQueue 的下标）
    QStringList resumeQueue;
};

/// 旧 JSON 存档路径（QStandardPaths::AppDataLocation / state.json）。
/// 现在只用于「首次迁移」与自检 / 打包隔离；TTPLAYER_QT_STATE 仍然指向这里。
QString stateFilePath();

/// SQLite 库路径：stateFilePath() 的 .json 换成 .db（同目录、同主名）。
/// 自检把 TTPLAYER_QT_STATE 落到临时目录时，库文件也跟着落在那里，天然不碰用户档。
QString dbFilePath();

/// schema 版本（PRAGMA user_version）。表名带同名世代前缀（v1_settings 等），二者必须一致；
/// 旧库低于它时按 LibraryStore.cpp 的 kMigrations 逐版搬数据，高于它则拒绝写入。
/// 改 schema：先改表名前缀，再追一条迁移，这里加一（cpp 里有 static_assert 对齐）。
constexpr int kSchemaVersion = 1;

/// 宽容读取（库缺失/坏 → valid=false 的默认值）
Loaded load();

/// 把 Loaded 写入库（settings / 列表 / 现场全量替换，事务内完成）
bool save(const Loaded &values);

/// 只写播放现场（基础序列+游标+历史+位置）：每 5 秒一次，不动设置与列表
bool saveResume(const Loaded &values);

/// 关闭当前线程的库连接。删库 / 换档 / 自检重建前必须先关，
/// 否则旧连接还指着已删 inode，读到的不是新库。
void closeDatabase();

/// 首启迁移时原 JSON 里认不出的顶层键（meta.legacy_unknown）——「未知字段不丢」的可验证出口
QJsonObject legacyUnknownFields();

/// 递归扫描这些目录里的可播文件（按 playableExtensions 过滤），返回 file:// URL 列表
QStringList scanFolders(const QStringList &folders);

/// Qt PlayMode ↔ 落盘整数（既有枚举序）互转
int modeToInt(PlayMode m);
PlayMode intToMode(int v);

/// 窗口几何 ↔ "x,y,w,h"
QString frameToString(int x, int y, int w, int h);
bool frameFromString(const QString &s, int &x, int &y, int &w, int &h);

} // namespace LibraryStore
