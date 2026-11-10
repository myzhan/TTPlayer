#ifndef TTPLAYER_CLIBARCHIVE_SHIM_H
#define TTPLAYER_CLIBARCHIVE_SHIM_H

// macOS SDK 只带 libarchive.dylib + libarchive.tbd，不装 archive.h。
// 这里手写一遍我们要用的 API 子集（结构体保持 opaque，返回值用 libarchive 的
// 整型常量）。tbd 里的符号集来自 libarchive 3.4/3.5 时代，本 shim 只用那时
// 就已存在的稳定接口，ABI 兼容。
//
// 参考：https://github.com/libarchive/libarchive/blob/master/libarchive/archive.h
// 上游采用 BSD-2-Clause 许可，与本 MIT 项目兼容；这里只声明签名，不复制实现。

#include <sys/types.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// 与 libarchive 一致的基本整型
typedef int64_t la_int64_t;
typedef ssize_t la_ssize_t;

// 状态码（负数是错误）
enum {
    CLARCHIVE_EOF = 1,
    CLARCHIVE_OK = 0,
    CLARCHIVE_RETRY = -10,
    CLARCHIVE_WARN = -20,
    CLARCHIVE_FAILED = -25,
    CLARCHIVE_FATAL = -30
};

// opaque 句柄（Swift ClangImporter 不接受 incomplete struct，
// 给个内部成员使它成为 complete struct；实际实现不会分配也不读取这里，
// 所有指针都从 libarchive 拿。ABI 层面只有一个 void*）
struct archive { char _opaque; };
struct archive_entry { char _opaque; };

// 生命周期
struct archive *archive_read_new(void);
int archive_read_free(struct archive *);
int archive_read_close(struct archive *);

// 启用容器与过滤器（一次全开；zip/tar/7z/rar/rar5 与 gzip/bzip2/xz/zstd 都能自动嗅探）
int archive_read_support_filter_all(struct archive *);
int archive_read_support_format_all(struct archive *);

// 打开具体文件
int archive_read_open_filename(struct archive *, const char *filename, size_t block_size);

// 迭代条目
int archive_read_next_header(struct archive *, struct archive_entry **);

// 读条目数据（一次一块，返回实际读到的字节数；到条目尾返回 0；EOF 情况见上层错误码）
la_ssize_t archive_read_data(struct archive *, void *buffer, size_t len);
int archive_read_data_skip(struct archive *);

// 错误串
const char *archive_error_string(struct archive *);

// 条目访问器
const char *archive_entry_pathname(struct archive_entry *);
la_int64_t archive_entry_size(struct archive_entry *);
int archive_entry_is_encrypted(struct archive_entry *);

// C 辅助（实现在 shim.c）：循环 archive_read_data 直到写完 cap 或条目结尾。
// 返回 实际写入字节数（>=0）或 libarchive 错误码（<0）。
ssize_t cff_archive_read_all(struct archive *a, void *out, size_t cap);

#ifdef __cplusplus
}
#endif

#endif
