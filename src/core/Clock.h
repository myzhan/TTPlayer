#pragma once
#include <QtGlobal>
#ifdef __APPLE__
#include <mach/mach_time.h>
#elif defined(_WIN32)
#include <windows.h>
#else
#include <time.h>
#endif
// Includes system sleep; changing the wall clock does not extend a sleep plan.
inline qint64 continuousMilliseconds() {
#ifdef __APPLE__
    static const mach_timebase_info_data_t scale=[] {mach_timebase_info_data_t value;mach_timebase_info(&value);return value;}();
    return qint64(static_cast<long double>(mach_continuous_time())*scale.numer/scale.denom/1000000);
#elif defined(_WIN32)
    return qint64(GetTickCount64());
#else
    timespec value{};clock_gettime(CLOCK_BOOTTIME,&value);
    return qint64(value.tv_sec)*1000+value.tv_nsec/1000000;
#endif
}
