// rar_wrapper.h — unrar C API 的极简内存提取封装（供 Swift 桥接调用）
#ifndef RAR_WRAPPER_H
#define RAR_WRAPPER_H

#include <stddef.h>   // C 编译单元里 wchar_t 需要（C++ 内建，C 不是）

#ifdef __cplusplus
extern "C" {
#endif

// 列出压缩包内文件名（不含目录项）。返回 malloc 的 char* 数组，count 输出条数。
// 释放方式：unrar_free_list(names, count)
char** unrar_list(const char* archivePath, int* count, int* errCode);

// 提取单个文件到内存。返回内部缓冲区指针（下次调用前有效，Swift 侧必须立刻拷贝）。
// 返回 NULL 表示失败，errCode: -1 打不开 -2 未找到 -3 头错误 -4 解码错误 -5 需要密码
unsigned char* unrar_extract(const char* archivePath, const char* entryName, int* outLen, int* errCode);

// 是否需要密码（打开时探测）
int unrar_needs_password(const char* archivePath);

void unrar_free_list(char** names, int count);

#ifdef __cplusplus
}
#endif

#endif
