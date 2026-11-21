#pragma once

#include <QString>

// 崩溃捕获：进程收到致命信号（SIGSEGV/SIGABRT/SIGBUS/SIGFPE/SIGILL/SIGTRAP）、
// C++ std::terminate、或 Windows 未处理异常时，把「信号/异常码 + 出错地址 + 调用栈」
// 以 async-signal-safe 的方式追加写进崩溃日志，然后恢复默认处置重新触发，让进程
// 仍以正确退出码死亡（保留系统自带的崩溃报告 / core dump）。
//
// 崩溃日志默认落在存档同目录下的 crash.log（复用 LibraryStore::stateFilePath() 的目录，
// 因此 TTPLAYER_QT_STATE 隔离档也会把崩溃日志写到隔离目录，不串用户数据）。
//
// install() 需在 QApplication 建好、应用名已设（存档目录可解析）之后尽早调用一次。
namespace CrashHandler {

/// 注册所有崩溃处理器；重复调用无副作用。
void install();

/// 崩溃日志绝对路径（install() 时确定；未 install 时返回空）。
QString logFilePath();

} // namespace CrashHandler
