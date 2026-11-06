/*
 * libshim.so — compatibility shim for running Alpine v3.24 Neovim
 * on top of iSH's Alpine v3.14 userland (musl 1.2.2).
 *
 * Loaded into nvim via DT_NEEDED (added by install.sh with patchelf).
 *
 * 1. pthread_getname_np
 *    libuv from Alpine v3.24 calls pthread_getname_np(), which only
 *    appeared in musl 1.2.3+. iSH ships musl 1.2.2, so libuv fails to
 *    relocate. libuv only uses it to report thread names, so returning
 *    an empty name is harmless.
 *
 * 2. readdir / scandir
 *    iSH's filesystem returns d_type == DT_UNKNOWN for every directory
 *    entry. POSIX allows this, but libuv/luv then report the entry type
 *    as nil, and vim.pack (plus many plugins) treat such entries as
 *    "not a directory". Result: vim.pack reinstalls every plugin on
 *    every start. We fill in d_type with an lstat() when it is unknown.
 *
 * Build: gcc -shared -fPIC -O2 -o libshim.so shim.c
 */
#define _GNU_SOURCE
#include <pthread.h>
#include <stddef.h>
#include <dirent.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>

/* ---- 1. pthread_getname_np ------------------------------------------ */

int pthread_getname_np(pthread_t t, char *buf, size_t len) {
    (void)t;
    if (len) buf[0] = 0;
    return 0;
}

/* ---- 2. d_type fix-up ----------------------------------------------- */

static unsigned char mode_to_dt(mode_t m) {
    if (S_ISDIR(m))  return DT_DIR;
    if (S_ISREG(m))  return DT_REG;
    if (S_ISLNK(m))  return DT_LNK;
    if (S_ISFIFO(m)) return DT_FIFO;
    if (S_ISSOCK(m)) return DT_SOCK;
    if (S_ISCHR(m))  return DT_CHR;
    if (S_ISBLK(m))  return DT_BLK;
    return DT_UNKNOWN;
}

struct dirent *readdir(DIR *dir) {
    static struct dirent *(*real)(DIR *);
    if (!real) real = (struct dirent *(*)(DIR *))dlsym(RTLD_NEXT, "readdir");
    struct dirent *d = real(dir);
    if (d && d->d_type == DT_UNKNOWN) {
        struct stat st;
        if (fstatat(dirfd(dir), d->d_name, &st, AT_SYMLINK_NOFOLLOW) == 0)
            d->d_type = mode_to_dt(st.st_mode);
    }
    return d;
}

typedef int (*sel_fn)(const struct dirent *);
typedef int (*cmp_fn)(const struct dirent **, const struct dirent **);

int scandir(const char *path, struct dirent ***res, sel_fn sel, cmp_fn cmp) {
    static int (*real)(const char *, struct dirent ***, sel_fn, cmp_fn);
    if (!real) real = (int (*)(const char *, struct dirent ***, sel_fn, cmp_fn))
                      dlsym(RTLD_NEXT, "scandir");
    int n = real(path, res, sel, cmp);
    for (int i = 0; i < n; i++) {
        struct dirent *d = (*res)[i];
        if (d->d_type != DT_UNKNOWN) continue;
        char buf[4096];
        struct stat st;
        if (snprintf(buf, sizeof buf, "%s/%s", path, d->d_name) < (int)sizeof buf
            && lstat(buf, &st) == 0)
            d->d_type = mode_to_dt(st.st_mode);
    }
    return n;
}
