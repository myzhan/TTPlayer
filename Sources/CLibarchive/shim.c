// CLibarchive 编译单元与 C 辅助。
//
// Swift ClangImporter 处理 `la_ssize_t` + `void *` 的组合签名时，会把它 import
// 成返回 `Int` 但参数是 `UnsafeMutableRawPointer!` — 可用但每次调用要在 Swift
// 侧手写循环把条目读完。这里包一个"整条读完"的辅助，Swift 侧一行搞定；
// 剩下的 API 直接映射，Swift 完全可用。

#include "shim.h"
#include <string.h>

// 一直读，直到条目结束或调用方给的缓冲写满。
// 返回：>=0 实际写入 out 的字节数；<0 libarchive 报错（out 里可能已部分写）。
// 注意：调用方需要按 entry_size 预留 out 长度；若条目实际更大，会截断（不 OOM）。
ssize_t cff_archive_read_all(struct archive *a, void *out, size_t cap) {
    unsigned char *p = (unsigned char *)out;
    size_t written = 0;
    while (written < cap) {
        la_ssize_t r = archive_read_data(a, p + written, cap - written);
        if (r == 0) break;                 // 当前条目结束
        if (r < 0) return (ssize_t)r;      // 失败，把 libarchive 错误码原样回传
        written += (size_t)r;
    }
    return (ssize_t)written;
}
