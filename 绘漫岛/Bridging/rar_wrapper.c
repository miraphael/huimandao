// rar_wrapper.c — 基于 unrar dll.hpp C API 的内存提取实现
#include "rar_wrapper.h"
#include "dll.hpp"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

static unsigned char* g_buf = NULL;
static size_t g_len = 0;
static size_t g_cap = 0;

static int PASCAL proc_data(unsigned char* Addr, int Size) {
    if (Size <= 0) return 1;
    if (g_len + (size_t)Size > g_cap) {
        size_t need = g_len + (size_t)Size;
        size_t newcap = g_cap ? g_cap * 2 : 1024 * 1024;
        while (newcap < need) newcap *= 2;
        unsigned char* nb = (unsigned char*)realloc(g_buf, newcap);
        if (!nb) return 0;
        g_buf = nb;
        g_cap = newcap;
    }
    memcpy(g_buf + g_len, Addr, (size_t)Size);
    g_len += (size_t)Size;
    return 1;
}

static HANDLE open_archive(const char* path, struct RAROpenArchiveDataEx* od) {
    memset(od, 0, sizeof(*od));
    od->ArcName = (char*)path;
    od->OpenMode = RAR_OM_EXTRACT;
    HANDLE h = RAROpenArchiveEx(od);
    return h;
}

int unrar_needs_password(const char* archivePath) {
    struct RAROpenArchiveDataEx od;
    HANDLE h = open_archive(archivePath, &od);
    if (!h) return 0;
    struct RARHeaderDataEx hd;
    memset(&hd, 0, sizeof(hd));
    int need = 0;
    if (RARReadHeaderEx(h, &hd) == 0 && (hd.Flags & RHDF_ENCRYPTED)) need = 1;
    RARCloseArchive(h);
    return need;
}

char** unrar_list(const char* archivePath, int* count, int* errCode) {
    *count = 0;
    *errCode = 0;
    struct RAROpenArchiveDataEx od;
    HANDLE h = open_archive(archivePath, &od);
    if (!h || od.OpenResult != 0) { *errCode = od.OpenResult ? -1 : -1; return NULL; }
    char** names = NULL;
    int n = 0, cap = 0;
    struct RARHeaderDataEx hd;
    while (1) {
        memset(&hd, 0, sizeof(hd));
        if (RARReadHeaderEx(h, &hd) != 0) break;
        if (!(hd.Flags & RHDF_DIRECTORY)) {
            if (n >= cap) {
                cap = cap ? cap * 2 : 64;
                names = (char**)realloc(names, sizeof(char*) * (size_t)cap);
            }
            names[n] = strdup(hd.FileName);
            n++;
        }
        RARProcessFile(h, RAR_SKIP, NULL, NULL);
    }
    RARCloseArchive(h);
    *count = n;
    return names;
}

unsigned char* unrar_extract(const char* archivePath, const char* entryName, int* outLen, int* errCode) {
    *outLen = 0;
    *errCode = 0;
    struct RAROpenArchiveDataEx od;
    HANDLE h = open_archive(archivePath, &od);
    if (!h || od.OpenResult != 0) { *errCode = -1; return NULL; }
    RARSetProcessDataProc(h, proc_data);
    g_len = 0;
    struct RARHeaderDataEx hd;
    int found = 0;
    while (1) {
        memset(&hd, 0, sizeof(hd));
        int r = RARReadHeaderEx(h, &hd);
        if (r != 0) { *errCode = -3; break; }
        if (strcmp(hd.FileName, entryName) == 0) {
            int pr = RARProcessFile(h, RAR_TEST, NULL, NULL);
            found = (pr == 0);
            if (pr == ERAR_MISSING_PASSWORD || pr == ERAR_BAD_PASSWORD) *errCode = -5;
            else if (pr != 0) *errCode = -4;
            break;
        }
        RARProcessFile(h, RAR_SKIP, NULL, NULL);
    }
    RARCloseArchive(h);
    if (!found) { if (*errCode == 0) *errCode = -2; return NULL; }
    *outLen = (int)g_len;
    return g_buf;
}

void unrar_free_list(char** names, int count) {
    if (!names) return;
    for (int i = 0; i < count; i++) free(names[i]);
    free(names);
}
