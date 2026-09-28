// AXJBashShim —— 在 AXJ(YOY) 的进程内，把「需要花括号展开的命令」交给 bash 执行
//
// 背景
//   AXJ 清 App 数据容器时执行形如下面的命令：
//       rm -rf  <容器路径>/{Documents,Library,tmp,StoreKit}
//       mkdir -p <容器路径>/{Documents,Library,tmp,StoreKit}
//   这串路径要靠 shell 做 brace expansion。而 procursus(Taurine) 的 /bin/sh 指向 dash，
//   dash 不做花括号展开 → 命令打在一个字面名字 "{Documents,Library,tmp,StoreKit}" 上，
//   rm -rf 带 -f 静默返回成功、mkdir 则真建出那个怪名字的目录 → 表现为
//   「点一键新机/换备份没反应、账号不变」。
//   （unc0ver 环境下 /bin/sh 是 bash 系，所以以前一直好用。）
//
// 本 shim 做的事（只在这几个进程内，进程外 /bin/sh 一律不动）
//   拦截该进程发起 shell 的四个入口：system / posix_spawn / posix_spawnp / execve / popen*
//   仅当「路径是 sh 且命令同时含 { 和 }」时，把要执行的 shell 换成 /usr/bin/bash；
//   其余 100% 走原实现 —— 保证非花括号命令的行为与装本 shim 之前逐字节一致。
//
// 同时写诊断日志到 /var/mobile/Documents/axjshim.log（失败退到 /tmp/axjshim.log）：
//   记录谁加载了、谁执行了什么命令、结果如何。排查靠它，不靠猜。
//
// 注意
//   iOS SDK 把 system() 标成 __attribute__((unavailable))，直接写 &system 编不过，
//   故一律用 dlsym 在运行期取真实入口。

#import <substrate.h>
#import <dlfcn.h>
#import <string.h>
#import <stdio.h>
#import <stdlib.h>
#import <stdarg.h>
#import <time.h>
#import <spawn.h>
#import <errno.h>
#import <unistd.h>
#import <fcntl.h>
#import <sys/stat.h>
#import <sys/wait.h>
#import <mach-o/dyld.h>

extern char **environ;

#define SHIM_LOG "/var/mobile/Documents/axjshim.log"
#define SHIM_LOG_MAX (256 * 1024)

// ---------------------------------------------------------------- log

// 依次尝试多个落地位置，取第一个可写的：
//   1) /var/mobile/Documents/axjshim.log  （root 进程、无沙箱 App 都写得进）
//   2) $HOME/axjshim.log                  （若 App 被沙箱限制，就落在它自己的容器里）
//   3) /tmp/axjshim.log
// 这样无论注入到 root 守护进程还是 App，都能留下证据。
static const char *shim_log_path(void) {
    static char chosen[1024];
    if (chosen[0] != '\0') return chosen;

    char homep[900];
    homep[0] = '\0';
    const char *home = getenv("HOME");
    if (home != NULL && home[0] != '\0') {
        snprintf(homep, sizeof(homep), "%s/axjshim.log", home);
    }

    const char *cands[3];
    cands[0] = SHIM_LOG;
    cands[1] = (homep[0] != '\0') ? homep : NULL;
    cands[2] = "/tmp/axjshim.log";

    for (int i = 0; i < 3; i++) {
        if (cands[i] == NULL) continue;
        FILE *f = fopen(cands[i], "a");
        if (f != NULL) {
            fclose(f);
            strncpy(chosen, cands[i], sizeof(chosen) - 1);
            chosen[sizeof(chosen) - 1] = '\0';
            return chosen;
        }
    }
    chosen[0] = '\0';
    return NULL;
}

static void shim_log(const char *fmt, ...) {
    const char *path = shim_log_path();
    if (path == NULL) return;

    struct stat st;
    if (stat(path, &st) == 0 && st.st_size > SHIM_LOG_MAX) {
        unlink(path);
    }
    FILE *f = fopen(path, "a");
    if (f == NULL) return;

    time_t t = time(NULL);
    struct tm tmv;
    localtime_r(&t, &tmv);
    fprintf(f, "[%02d:%02d:%02d] ", tmv.tm_hour, tmv.tm_min, tmv.tm_sec);

    va_list ap;
    va_start(ap, fmt);
    vfprintf(f, fmt, ap);
    va_end(ap);
    fputc('\n', f);
    fclose(f);
}

// ---------------------------------------------------------------- helpers

static int shim_has_braces(const char *s) {
    return s != NULL && strchr(s, '{') != NULL && strchr(s, '}') != NULL;
}

static int shim_mentioned(const char *s) {
    return s != NULL && strstr(s, "Containers/Data/Application") != NULL;
}

static int shim_argv_has_braces(char *const argv[]) {
    if (argv == NULL) return 0;
    for (int i = 0; argv[i] != NULL; i++) {
        if (shim_has_braces(argv[i])) return 1;
    }
    return 0;
}

static const char *shim_argv_joined(char *const argv[]) {
    static char buf[2048];
    buf[0] = '\0';
    if (argv == NULL) return buf;
    size_t used = 0;
    for (int i = 0; argv[i] != NULL && used + 2 < sizeof(buf); i++) {
        size_t n = strlen(argv[i]);
        if (n > sizeof(buf) - used - 2) n = sizeof(buf) - used - 2;
        memcpy(buf + used, argv[i], n);
        used += n;
        buf[used++] = ' ';
        buf[used] = '\0';
    }
    return buf;
}

// 只有 basename 恰为 "sh" 的路径才替换（/bin/sh、/usr/bin/sh、sh ...）
static int shim_is_sh(const char *path) {
    if (path == NULL) return 0;
    const char *b = strrchr(path, '/');
    b = (b != NULL) ? b + 1 : path;
    return strcmp(b, "sh") == 0;
}

static int shim_is_read_mode(const char *mode) {
    return mode != NULL && mode[0] == 'r';
}

// 用 bash 跑一段命令字符串，返回 wait 状态（对齐 system() 的语义）
static int shim_run_with_bash(const char *cmd, const char *who) {
    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    char *argv[] = { (char *)"sh", (char *)"-c", (char *)cmd, NULL };
    pid_t pid = 0;
    int rc = posix_spawn(&pid, "/usr/bin/bash", &fa, NULL, argv, environ);
    posix_spawn_file_actions_destroy(&fa);
    if (rc != 0) {
        shim_log("    !! %s: posix_spawn(bash) failed rc=%d errno=%d", who, rc, errno);
        return -1;
    }
    int status = 0;
    while (waitpid(pid, &status, 0) < 0) {
        if (errno != EINTR) break;
    }
    return status;
}

// ---------------------------------------------------------------- system()

typedef int (*shim_system_fn)(const char *);
static shim_system_fn orig_system = NULL;

static int shim_system(const char *cmd) {
    if (orig_system == NULL) return -1;
    if (cmd == NULL) return orig_system(cmd);

    if (!shim_has_braces(cmd)) {
        if (shim_mentioned(cmd)) {
            shim_log("system  (plain) uid=%d cmd=%s", getuid(), cmd);
        }
        return orig_system(cmd);
    }

    shim_log("system  (BRACE) uid=%d cmd=%s", getuid(), cmd);
    int status = shim_run_with_bash(cmd, "system");
    if (status < 0) return orig_system(cmd);
    shim_log("    -> bash done status=%d", status);
    return status;
}

// ---------------------------------------------------------------- posix_spawn()

typedef int (*shim_spawn_fn)(pid_t *, const char *,
                             const posix_spawn_file_actions_t *,
                             const posix_spawnattr_t *,
                             char *const[], char *const[]);
static shim_spawn_fn orig_posix_spawn = NULL;
static shim_spawn_fn orig_posix_spawnp = NULL;

static int shim_spawn_common(shim_spawn_fn orig, const char *tag,
                             pid_t *pid, const char *path,
                             const posix_spawn_file_actions_t *fa,
                             const posix_spawnattr_t *attr,
                             char *const argv[], char *const envp[]) {
    if (orig == NULL) {
        errno = ENOSYS;
        return -1;
    }
    const char *newpath = path;

    if (shim_is_sh(path) && shim_argv_has_braces(argv)) {
        newpath = "/usr/bin/bash";
        shim_log("%s (BRACE) uid=%d %s -> /usr/bin/bash  argv=[%s]",
                 tag, getuid(), path ? path : "(null)", shim_argv_joined(argv));
    } else if (shim_argv_has_braces(argv)) {
        shim_log("%s (brace-nonsh) uid=%d path=%s argv=[%s]",
                 tag, getuid(), path ? path : "(null)", shim_argv_joined(argv));
    } else if (shim_mentioned(shim_argv_joined(argv))) {
        shim_log("%s (plain) uid=%d path=%s argv=[%s]",
                 tag, getuid(), path ? path : "(null)", shim_argv_joined(argv));
    }

    return orig(pid, newpath, fa, attr, argv, envp);
}

static int shim_posix_spawn(pid_t *pid, const char *path,
                            const posix_spawn_file_actions_t *fa,
                            const posix_spawnattr_t *attr,
                            char *const argv[], char *const envp[]) {
    return shim_spawn_common(orig_posix_spawn, "spawn  ",
                             pid, path, fa, attr, argv, envp);
}

static int shim_posix_spawnp(pid_t *pid, const char *path,
                             const posix_spawn_file_actions_t *fa,
                             const posix_spawnattr_t *attr,
                             char *const argv[], char *const envp[]) {
    return shim_spawn_common(orig_posix_spawnp, "spawnp ",
                             pid, path, fa, attr, argv, envp);
}

// ---------------------------------------------------------------- execve()

typedef int (*shim_execve_fn)(const char *, char *const[], char *const[]);
static shim_execve_fn orig_execve = NULL;

static int shim_execve(const char *path, char *const argv[], char *const envp[]) {
    if (orig_execve == NULL) {
        errno = ENOSYS;
        return -1;
    }
    if (shim_is_sh(path) && shim_argv_has_braces(argv)) {
        shim_log("execve  (BRACE) uid=%d %s -> /usr/bin/bash argv=[%s]",
                 getuid(), path, shim_argv_joined(argv));
        return orig_execve("/usr/bin/bash", argv, envp);
    }
    if (shim_mentioned(shim_argv_joined(argv))) {
        shim_log("execve  (plain) uid=%d path=%s argv=[%s]",
                 getuid(), path ? path : "(null)", shim_argv_joined(argv));
    }
    return orig_execve(path, argv, envp);
}

// ---------------------------------------------------------------- popen()

typedef FILE *(*shim_popen_fn)(const char *, const char *);
static shim_popen_fn orig_popen = NULL;

// 把 cmd 安全地嵌进单引号里："'" -> "'\\''"
static char *shim_sq_escape(const char *cmd) {
    size_t n = strlen(cmd);
    char *out = malloc(n * 4 + 32);
    if (out == NULL) return NULL;
    size_t o = 0;
    for (size_t i = 0; i < n; i++) {
        if (cmd[i] == '\'') {
            memcpy(out + o, "'\\''", 4);
            o += 4;
        } else {
            out[o++] = cmd[i];
        }
    }
    out[o] = '\0';
    return out;
}

static FILE *shim_popen(const char *cmd, const char *mode) {
    if (orig_popen == NULL) return NULL;
    if (cmd == NULL) return orig_popen(cmd, mode);

    if (shim_has_braces(cmd) && shim_is_read_mode(mode)) {
        char *esc = shim_sq_escape(cmd);
        if (esc != NULL) {
            size_t need = strlen(esc) + 64;
            char *wrapped = malloc(need);
            if (wrapped != NULL) {
                snprintf(wrapped, need, "exec /usr/bin/bash -c '%s'", esc);
                shim_log("popen   (BRACE->bash) uid=%d cmd=%s", getuid(), cmd);
                FILE *fp = orig_popen(wrapped, mode);
                free(wrapped);
                free(esc);
                return fp;
            }
            free(esc);
        }
    }

    if (shim_mentioned(cmd)) {
        shim_log("popen   (plain) uid=%d cmd=%s", getuid(), cmd);
    }
    return orig_popen(cmd, mode);
}

// ---------------------------------------------------------------- init

static void shim_hook(const char *name, void *replace, void **orig, const char *tag) {
    void *sym = dlsym(RTLD_DEFAULT, name);
    if (sym == NULL) {
        shim_log("=== hook %-12s MISSING (symbol not found)", name);
        return;
    }
    MSHookFunction(sym, replace, orig);
    shim_log("=== hook %-12s ok  sym=%p orig=%p  (%s)", name, sym, *orig, tag);
}

__attribute__((constructor)) static void axj_bash_shim_init(void) {
    char exe[1024];
    uint32_t sz = sizeof(exe);
    if (_NSGetExecutablePath(exe, &sz) != 0) {
        strncpy(exe, "?", sizeof(exe) - 1);
        exe[sizeof(exe) - 1] = '\0';
    }

    shim_log("=== LOADED pid=%d uid=%d euid=%d exe=%s log=%s",
             getpid(), getuid(), geteuid(), exe, shim_log_path() ?: "(nowhere)");

    shim_hook("system", (void *)shim_system, (void **)&orig_system, "libsystem_c");
    shim_hook("posix_spawn", (void *)shim_posix_spawn, (void **)&orig_posix_spawn, "libsystem_kernel");
    shim_hook("posix_spawnp", (void *)shim_posix_spawnp, (void **)&orig_posix_spawnp, "libsystem_kernel");
    shim_hook("execve", (void *)shim_execve, (void **)&orig_execve, "libsystem_kernel");
    shim_hook("popen", (void *)shim_popen, (void **)&orig_popen, "libsystem_c");

    shim_log("=== READY  pid=%d", getpid());
}
