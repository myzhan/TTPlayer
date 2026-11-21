#include "CrashHandler.h"
#include "library/LibraryStore.h"

#include <cstring>
#include <ctime>
#include <csignal>
#include <cstdint>

// 崩溃日志绝对路径在 install() 时算好、拷进这块静态缓冲；信号处理函数里只用它，
// 绝不调用任何可能 malloc / 加锁的 Qt/std 函数（否则在崩溃现场二次死锁）。
static char g_path[1024];
static int g_path_len = 0;
static QString g_path_str;                  // 仅供 install 后外部读取，不在 handler 里用
static volatile sig_atomic_t g_entered = 0; // 防重入：一次崩溃只写一份记录

#ifdef _WIN32
#include <windows.h>
#include <io.h>
#include <fcntl.h>
#include <dbghelp.h>
#include <sys/stat.h>
#include <share.h>
#include <cstdio>
#define CRASH_WRITE(fd, buf, n) _write((fd), (buf), static_cast<unsigned>(n))
#else
#include <unistd.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <execinfo.h>
#include <errno.h>
#define CRASH_WRITE(fd, buf, n) write((fd), (buf), (n))
#endif

// ————————————————————————————————————————————————
// async-signal-safe 的小工具：定长写 + 手写十进制 / 十六进制
// ————————————————————————————————————————————————
namespace {

void writeAll(int fd, const char *s, size_t n) {
    while (n > 0) {
        const auto w = CRASH_WRITE(fd, s, n);
        if (w <= 0) {
#ifndef _WIN32
            if (errno == EINTR) continue;
#endif
            break;
        }
        s += w;
        n -= static_cast<size_t>(w);
    }
}

void writeStr(int fd, const char *s) {
    writeAll(fd, s, std::strlen(s));
}

size_t fmtUint(unsigned long long v, char *buf) {
    char tmp[24];
    int i = 0;
    if (v == 0) {
        buf[0] = '0';
        buf[1] = '\0';
        return 1;
    }
    while (v > 0) {
        tmp[i++] = static_cast<char>('0' + (v % 10));
        v /= 10;
    }
    int n = 0;
    while (i > 0)
        buf[n++] = tmp[--i];
    buf[n] = '\0';
    return static_cast<size_t>(n);
}

size_t fmtHex(unsigned long long v, char *buf) {
    static const char *digits = "0123456789abcdef";
    buf[0] = '0';
    buf[1] = 'x';
    char tmp[17];
    int i = 0;
    if (v == 0) {
        tmp[i++] = '0';
    } else {
        while (v > 0) {
            tmp[i++] = digits[v & 0xF];
            v >>= 4;
        }
    }
    int n = 2;
    while (i > 0)
        buf[n++] = tmp[--i];
    buf[n] = '\0';
    return static_cast<size_t>(n);
}

// 崩溃记录头（种类 / 码 / 出错地址 / 时间戳），POSIX 与 Windows、terminate 共用
void writeHeader(int fd, const char *kind, unsigned long long code, const char *codeName, unsigned long long addr) {
    char num[32];
    writeStr(fd, "\n==== TTPlayer crash @ ");
    writeAll(fd, num, fmtUint(static_cast<unsigned long long>(std::time(nullptr)), num));
    writeStr(fd, " (unix) ====\n");
    writeStr(fd, kind);
    writeStr(fd, " ");
    writeAll(fd, num, fmtUint(code, num));
    writeStr(fd, " (");
    writeStr(fd, codeName);
    writeStr(fd, ")\n");
    writeStr(fd, "fault addr ");
    writeAll(fd, num, fmtHex(addr, num));
    writeStr(fd, "\n");
}

// 打开崩溃日志（追加）；失败返回 -1
int openLog() {
#ifdef _WIN32
#ifdef _MSC_VER
    int descriptor = -1;
    return _sopen_s(&descriptor, g_path, _O_CREAT | _O_WRONLY | _O_APPEND | _O_BINARY, _SH_DENYNO,
                    _S_IREAD | _S_IWRITE) == 0
               ? descriptor
               : -1;
#else
    return ::_open(g_path, _O_CREAT | _O_WRONLY | _O_APPEND | _O_BINARY, _S_IREAD | _S_IWRITE);
#endif
#else
    return ::open(g_path, O_CREAT | O_WRONLY | O_APPEND, 0644);
#endif
}

void closeLog(int fd) {
#ifdef _WIN32
    ::_commit(fd);
    ::_close(fd);
#else
    ::fsync(fd);
    ::close(fd);
#endif
}

} // namespace

// ————————————————————————————————————————————————
// POSIX（macOS / Linux）：sigaction + backtrace
// ————————————————————————————————————————————————
#ifndef _WIN32

#include <exception>
#include <cstdlib>

namespace {

const char *sigName(int sig) {
    switch (sig) {
    case SIGSEGV:
        return "SIGSEGV";
    case SIGABRT:
        return "SIGABRT";
    case SIGBUS:
        return "SIGBUS";
    case SIGFPE:
        return "SIGFPE";
    case SIGILL:
        return "SIGILL";
    case SIGTRAP:
        return "SIGTRAP";
    default:
        return "UNKNOWN";
    }
}

void dumpBacktrace(int fd) {
    void *frames[128];
    const int n = ::backtrace(frames, 128);
    if (n > 0) {
        writeStr(fd, "backtrace:\n");
        ::backtrace_symbols_fd(frames, n, fd); // 直接写 fd，避开 backtrace_symbols 的 malloc
    } else {
        writeStr(fd, "backtrace: <unavailable>\n");
    }
}

void crashHandler(int sig, siginfo_t *info, void * /*ucontext*/) {
    if (g_entered) { // 写日志途中又崩：落默认处置，避免无限递归
        ::signal(sig, SIG_DFL);
        ::raise(sig);
        return;
    }
    g_entered = 1;

    const int fd = openLog();
    if (fd >= 0) {
        const unsigned long long addr = info ? reinterpret_cast<unsigned long long>(info->si_addr) : 0;
        writeHeader(fd, "signal", static_cast<unsigned long long>(sig), sigName(sig), addr);
        dumpBacktrace(fd);
        closeLog(fd);
    }

    ::signal(sig, SIG_DFL); // 恢复默认并重新触发：进程以 128+sig 退出、系统照常出崩溃报告
    ::raise(sig);
}

void terminateHandler() {
    if (!g_entered) {
        g_entered = 1;
        const int fd = openLog();
        if (fd >= 0) {
            writeHeader(fd, "terminate", 0, "std::terminate", 0);
            dumpBacktrace(fd);
            closeLog(fd);
        }
    }
    ::signal(SIGABRT, SIG_DFL); // 摘掉 SIGABRT 处理器，避免 abort 再写第二份
    ::abort();
}

void *g_altStack = nullptr; // 备用信号栈：栈溢出型 SIGSEGV 也能跑处理器

} // namespace

void CrashHandler::install() {
    static bool done = false;
    if (done) return;
    done = true;

    const QString state = LibraryStore::stateFilePath();
    const int slash = state.lastIndexOf(QLatin1Char('/'));
    g_path_str = (slash >= 0 ? state.left(slash + 1) : QString()) + QStringLiteral("crash.log");
    const QByteArray utf8 = g_path_str.toUtf8();
    g_path_len = static_cast<int>(qMin(utf8.size(), static_cast<qsizetype>(sizeof(g_path) - 1)));
    std::memcpy(g_path, utf8.constData(), g_path_len);
    g_path[g_path_len] = '\0';

    const size_t altSize = size_t{64} * 1024;
    g_altStack = std::malloc(altSize);
    if (g_altStack) {
        stack_t ss;
        ss.ss_sp = g_altStack;
        ss.ss_size = altSize;
        ss.ss_flags = 0;
        ::sigaltstack(&ss, nullptr);
    }

    struct sigaction sa;
    std::memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = crashHandler;
    sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
    sigemptyset(&sa.sa_mask); // macOS/BSD 上是宏，不能加 ::

    const int sigs[] = {SIGSEGV, SIGABRT, SIGBUS, SIGFPE, SIGILL, SIGTRAP};
    for (int s : sigs)
        ::sigaction(s, &sa, nullptr);

    std::set_terminate(terminateHandler);
}

QString CrashHandler::logFilePath() {
    return g_path_str;
}

// ————————————————————————————————————————————————
// Windows：SetUnhandledExceptionFilter + CaptureStackBackTrace + dbghelp 符号化
// ————————————————————————————————————————————————
#else // _WIN32

#include <exception>

namespace {

void dumpBacktraceWin(int fd) {
    void *frames[128];
    const USHORT n = static_cast<USHORT>(::CaptureStackBackTrace(0, 128, frames, nullptr));
    if (n == 0) {
        writeStr(fd, "backtrace: <unavailable>\n");
        return;
    }
    writeStr(fd, "backtrace:\n");
    HANDLE proc = ::GetCurrentProcess();
    ::SymInitialize(proc, nullptr, TRUE); // 同目录有 .pdb 就能符号化，否则退化成裸地址
    char line[512];
    for (USHORT i = 0; i < n; ++i) {
        const DWORD64 addr = reinterpret_cast<DWORD64>(frames[i]);
        char hex[32];
        int off = snprintf(line, sizeof(line), "  #%u ", i);
        const size_t hl = fmtHex(addr, hex);
        memcpy(line + off, hex, hl);
        off += static_cast<int>(hl);
        char symBuf[sizeof(SYMBOL_INFO) + 256];
        SYMBOL_INFO *sym = reinterpret_cast<SYMBOL_INFO *>(symBuf);
        sym->SizeOfStruct = sizeof(SYMBOL_INFO);
        sym->MaxNameLen = 255;
        DWORD64 disp = 0;
        if (::SymFromAddr(proc, addr, &disp, sym))
            off += snprintf(line + off, sizeof(line) - off, "  %s+0x%llx", sym->Name,
                            static_cast<unsigned long long>(disp));
        IMAGEHLP_LINE64 lp;
        lp.SizeOfStruct = sizeof(lp);
        DWORD ldisp = 0;
        if (::SymGetLineFromAddr64(proc, addr, &ldisp, &lp))
            off += snprintf(line + off, sizeof(line) - off, "  (%s:%lu)", lp.FileName, lp.LineNumber);
        if (off > 0 && static_cast<size_t>(off) < sizeof(line)) {
            line[off++] = '\n';
            writeAll(fd, line, static_cast<size_t>(off));
        }
    }
    ::SymCleanup(proc);
}

const char *exceptionName(DWORD code) {
    switch (code) {
    case EXCEPTION_ACCESS_VIOLATION:
        return "ACCESS_VIOLATION";
    case EXCEPTION_STACK_OVERFLOW:
        return "STACK_OVERFLOW";
    case EXCEPTION_INT_DIVIDE_BY_ZERO:
        return "INT_DIVIDE_BY_ZERO";
    case EXCEPTION_FLT_DIVIDE_BY_ZERO:
        return "FLT_DIVIDE_BY_ZERO";
    case EXCEPTION_ILLEGAL_INSTRUCTION:
        return "ILLEGAL_INSTRUCTION";
    case EXCEPTION_PRIV_INSTRUCTION:
        return "PRIV_INSTRUCTION";
    case EXCEPTION_IN_PAGE_ERROR:
        return "IN_PAGE_ERROR";
    case EXCEPTION_DATATYPE_MISALIGNMENT:
        return "DATATYPE_MISALIGNMENT";
    default:
        return "UNKNOWN";
    }
}

LONG WINAPI unhandledFilter(EXCEPTION_POINTERS *ep) {
    if (!g_entered) {
        g_entered = 1;
        const int fd = openLog();
        if (fd >= 0) {
            DWORD code = 0;
            unsigned long long addr = 0;
            if (ep && ep->ExceptionRecord) {
                code = ep->ExceptionRecord->ExceptionCode;
                addr = reinterpret_cast<unsigned long long>(ep->ExceptionRecord->ExceptionAddress);
            }
            writeHeader(fd, "exception", code, exceptionName(code), addr);
            dumpBacktraceWin(fd);
            closeLog(fd);
        }
    }
    return EXCEPTION_EXECUTE_HANDLER;
}

void terminateHandlerWin() {
    if (!g_entered) {
        g_entered = 1;
        const int fd = openLog();
        if (fd >= 0) {
            writeHeader(fd, "terminate", 0, "std::terminate", 0);
            dumpBacktraceWin(fd);
            closeLog(fd);
        }
    }
    ::TerminateProcess(::GetCurrentProcess(), 0xDEAD);
}

} // namespace

void CrashHandler::install() {
    static bool done = false;
    if (done) return;
    done = true;

    const QString state = LibraryStore::stateFilePath();
    const int slash = state.lastIndexOf(QLatin1Char('/'));
    g_path_str = (slash >= 0 ? state.left(slash + 1) : QString()) + QStringLiteral("crash.log");
    const QByteArray utf8 = g_path_str.toUtf8();
    g_path_len = static_cast<int>(qMin(utf8.size(), static_cast<qsizetype>(sizeof(g_path) - 1)));
    std::memcpy(g_path, utf8.constData(), g_path_len);
    g_path[g_path_len] = '\0';

    ::SetUnhandledExceptionFilter(unhandledFilter);
    ::SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX);
    std::set_terminate(terminateHandlerWin);
}

QString CrashHandler::logFilePath() {
    return g_path_str;
}

#endif
