#pragma once

// 电台档案（F11 / review R13）：自定义台名 + 分类 + 台的分类归属。
//
// 三份档案全部以「电台地址」（Track::identityKey 那套写法里电台就是完整 URL 串）为键，所以：
// - 同一个地址无论从哪儿进来（手输、m3u、上次存档）都共用这一个台名与这一个归属；
// - 改了地址就是换了身份，得由 replaceKeys 显式把设置搬过去，不能靠「名字看着像」偷偷认领。
//
// 台名与流里 ICY StreamTitle 的「正在播放」是两回事：这里存的才是用户起的名字。
// 对齐 Swift Models/RadioStations.swift。

#include <QHash>
#include <QList>
#include <QSet>
#include <QString>
#include <QStringList>
#include <QUrl>

/// 一个电台分类。`id` 是稳定身份：改名、台的进出都不动它（与 UserPlaylist 同一套规矩）。
struct RadioCategory {
    QString id;
    QString name;
};

class RadioStations {
public:
    static constexpr int nameLimit = 40;     // 分类名长度上限（左栏那一列只有 110pt 宽）
    static constexpr int aliasLimit = 60;    // 自定义台名上限（够写「FM97.4 古典音乐」）
    /// 未分类的稳定 id：不是用户建出来的分类，删不掉，左栏永远有这一行（默认入口）
    static inline const QString uncategorizedID = QStringLiteral("__uncategorized__");

    // MARK: 查
    const QList<RadioCategory> &categories() const { return m_categories; }
    QStringList ids() const;
    int count() const { return m_categories.size(); }
    bool isEmpty() const { return m_categories.isEmpty(); }
    bool contains(const QString &id) const { return indexOf(id) >= 0; }
    /// 未分类 → 「未分类电台」；不存在的分类 → 空串
    QString nameOf(const QString &id) const;
    /// 这个台现在归哪一类（空串 = 未分类）。指向已删分类的归属一律按未分类算。
    QString categoryIDOf(const QString &key) const;
    /// 这一类里有哪些台（未分类 = 没有归属的那些）；调用处负责再与「列表里实际有什么」求交
    QStringList keysIn(const QString &id) const;
    int unassignedCount() const;

    QString aliasFor(const QString &key) const { return m_aliases.value(key); }

    /// 台名来源：用户自定义 > 出厂内置 > 按地址（属性面板与自检要说清这一层）
    enum class NameSource { Custom, Builtin, Address };

    /// 列表与标题该显示什么：自定义台名优先，其次内置台名，都没才按地址认出那段
    QString displayName(const QUrl &url) const;
    NameSource nameSource(const QUrl &url) const;
    /// 取消自定义之后落回哪儿：出厂台落回内置名，其余落回地址
    QString fallbackText(const QUrl &url) const;
    bool hasCustomName(const QUrl &url) const;

    // MARK: 台名
    /// 起/改自定义台名。空名字不是错误，是「取消自定义」：落回内置台名或地址并摘掉这一条。
    void setAlias(const QString &key, const QString &raw);

    // MARK: 分类建 / 改名 / 删 / 移动
    /// 新建分类。名字空（或只有空白）时不建返回 false；同名自动区分并把实际用的名写进 note。
    bool createCategory(const QString &raw, QString *outId, QString *outNote);
    /// 重命名分类：只改显示名不动 id。返回错误原因（空串 = 改好了）。
    QString renameCategory(const QString &id, const QString &raw);
    /// 删除分类：只丢壳，台一条地址都不删——落回未分类。未分类本身删不掉。
    /// 返回 false = 未分类 / 不存在；否则 *moved 带回落到未分类的台数。
    bool deleteCategory(const QString &id, int *moved);
    /// 把若干台移进某个分类。`id` 空或「未分类」= 把归属摘掉（不是删台）。
    /// 返回动了几台；目标分类不存在时一个都不动并写 *problem。
    int moveRadios(const QStringList &keys, const QString &id, QString *problem);

    // MARK: 身份迁移
    /// 地址换了（编辑地址）：台名与归属跟着搬新家。目标已有设置时以新地址那份为准。返回搬动项数。
    int replaceKeys(const QHash<QString, QString> &map);

    // MARK: 存档
    /// 还原存档（旧档没这几项 = 谁都没起过名字）。宽容：丢空名字、重复 id、指向不存在分类的归属。
    void restore(const QHash<QString, QString> &aliases, const QList<RadioCategory> &cats,
                 const QHash<QString, QString> &assigned);
    QHash<QString, QString> snapshotAliases() const { return m_aliases; }
    QList<RadioCategory> snapshotCategories() const { return m_categories; }
    QHash<QString, QString> snapshotAssigned() const { return m_assigned; }

private:
    int indexOf(const QString &id) const;
    QSet<QString> takenNames() const;

    QList<RadioCategory> m_categories;
    QHash<QString, QString> m_aliases;    // 地址 → 自定义台名（没起过名的台不占位）
    QHash<QString, QString> m_assigned;   // 地址 → 分类 id（未分类不占位）
};
