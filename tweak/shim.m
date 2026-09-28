// AXJBashShim —— 只注入 DHPDaemon，把「需要花括号展开的命令」交给 bash 执行
//
// 背景
//    AXJ(爱思助手/YOY) 的 root 守护进程 DHPDaemon 用 system() 执行清容器命令，
//    命令形如:  rm -rf <容器路径>/{Documents,Library,tmp,StoreKit}
//    这里的 {} 需要 shell 做 brace expansion。而 procursus 的 /bin/sh 指向 dash，
//    dash 不做花括号展开 → rm -rf 打在字面路径 "{Documents,Library,tmp,StoreKit}" 上
//    → 带 -f 静默返回成功、一个目录都没删 → 表现为「点一键新机没反应 / 账号不变」。
//    （unc0ver 环境下 /bin/sh 是 bash 系，所以以前一直好用。）
//
// 本 shim 做的事
//    只在这一个进程内，把「同时含 { 和 } 的命令」转交 /usr/bin/bash 执行；
//    其余所有命令 100% 走原来的 system()，行为与改动前完全一致。
//    进程外（系统 /bin/sh）不作任何改动 —— 这就是「只对 AXJ 生效」。
//
// 注意
//    iOS SDK 把 system() 标成了 __attribute__((unavailable))，直接写 &system 编不过。
//    DHPDaemon 是 2020 年用老 SDK 编的，它照样导入了 _system —— 所以运行时有这个符号。
//    这里用 dlsym 在运行期取它的真实入口，既绕开编译期限制，又拿到真实函数地址。

#import <substrate.h>
#import <dlfcn.h>
#import <string.h>
#import <spawn.h>
#import <errno.h>
#import <unistd.h>
#import <sys/wait.h>

extern char **environ;

typedef int (*axj_system_fn)(const char *);
static axj_system_fn orig_system = NULL;

static int axj_system(const char *cmd) {
    if (cmd == NULL) {
        return orig_system ? orig_system(cmd) : -1;
    }

    // 只有同时含 { 和 } 的命令才需要 bash 的花括号展开；其余原样走原实现。
    // 这个判断让「非花括号命令」的行为与装本 shim 之前逐字节一致，是刻意的保守设计。
    if (orig_system == NULL ||
        strchr(cmd, '{') == NULL || strchr(cmd, '}') == NULL) {
        return orig_system(cmd);
    }

    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    char *argv[] = { (char *)"sh", (char *)"-c", (char *)cmd, NULL };
    pid_t pid = 0;
    int rc = posix_spawn(&pid, "/usr/bin/bash", &fa, NULL, argv, environ);
    posix_spawn_file_actions_destroy(&fa);
    if (rc != 0) {
        return orig_system(cmd);          // 保底：bash 起不来就退回原实现
    }

    int status = 0;
    while (waitpid(pid, &status, 0) < 0) {
        if (errno != EINTR) break;
    }
    return status;
}

// 用 constructor 而不是 logos 的 %ctor：本工程没有任何 %hook，
// 这样能完全绕开 logos 展开带来的一堆坑。
__attribute__((constructor)) static void axj_bash_shim_init(void) {
    void *sym = dlsym(RTLD_DEFAULT, "system");
    if (sym == NULL) {
        void *h = dlopen("/usr/lib/libsystem_c.dylib", RTLD_LAZY);
        if (h) sym = dlsym(h, "system");
    }
    if (sym != NULL) {
        MSHookFunction(sym, (void *)axj_system, (void **)&orig_system);
    }
}
