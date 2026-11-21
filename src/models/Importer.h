#pragma once
#include "Track.h"
#include <atomic>
namespace Importer {
struct Result {
    QList<Track> tracks;
    QStringList problems;
    bool cancelled = false;
};
Result read(const QStringList &paths, bool metadata = true, const std::atomic<bool> *cancel = nullptr);
void probe(Track &track, std::shared_ptr<std::atomic<bool>> cancel = {});
}
