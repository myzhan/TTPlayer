#pragma once
#include "models/Track.h"
#include <atomic>
namespace Importer {
struct Result {
    QList<Track> tracks;
    QStringList problems;
    bool cancelled = false;
};
// 文件选择器与目录、归档导入共用运行时格式白名单。
QString fileDialogFilter();
Result read(const QStringList &paths, bool metadata = true, const std::atomic<bool> *cancel = nullptr);
void probe(Track &track, std::shared_ptr<const std::atomic<bool>> cancel = {});
}
