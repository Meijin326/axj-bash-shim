// verorder.m —— 把 AXJ(YOY)「版本选择」页的分组顺序整体反转
//
// 背景（2026-10-03）
//   版本页 = IFIOSVersionSelector，分组数组是它的 ivar（offset 表项 VA 0x1004007cc）。
//   我们（-64/-66/-67）把 8 个槽改成了 iOS 13~18/26/27 并让 8 段全出，
//   但**显示顺序始终是升序**（IOS 13 在顶、IOS 27 在底），与期望（新机在前）相反。
//
//   实测结论：显示顺序**与每行 code 的数值无关**——-66 与 -67 的 code 分配完全相反，
//   顺序一字未变。所以继续在 code 上做文章是死路。
//
// 本文件的做法（最小、可逆、不碰签名）
//   不去猜「哪个槽排第几」，而是**在 App 运行期把最终的 _groups 数组整体反转**：
//   当前顺序 [13,14,15,16,17,18,26,27] 的精确逆序就是期望的 [27,26,18,17,16,15,14,13]。
//   反转动作放在 -numberOfSectionsInTableView: 的第一次调用（此时 _groups 已构建完、
//   表格尚未取分组标题），因此不需要额外 reloadData。
//
//   幂等：只在「首元素标签 < 末元素标签」（= 仍是升序）时反转。
//   若两个标签取不到，则不动作（只记日志），绝不盲翻。
//
// 诊断日志（多路径回退）：
//   /var/mobile/Documents/axjverorder.log  ->  /var/mobile/axjverorder.log
//   ->  $HOME/axjverorder.log  ->  /tmp/axjverorder.log
//   每次都把反转前/后的完整标签序列写进去，顺序问题一眼可查。

#import <substrate.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <stdarg.h>
#import <time.h>
#import <sys/stat.h>
#import <unistd.h>

#define VO_LOG_MAX (256 * 1024)

// 32 位 ivar 偏移表项所在的 VA，以及主可执行文件的 preference VA 基址（都是链接期常量）
#define VO_OFFSET_SLOT_VA 0x1004007ccULL
#define VO_IMAGE_BASE_VA  0x100000000ULL

// ---- 分组标签 / 键的取值选择子（AXJ 的混淆命名，来自逆向）----
#define VO_SEL_LABEL "bKUzXkYeElqHVKDUDRazsjKaJnIPwNyvQIkwBwlW"
#define VO_SEL_KEY   "TheojRJwVaYVRPhRvLprwmNQJsVDUlZRTPzBPjNv"

// ---------------------------------------------------------------- log

static const char *vo_log_path(void) {
    static char chosen[1024];
    if (chosen[0] != '\0') return chosen;

    char homep[900];
    homep[0] = '\0';
    const char *home = getenv("HOME");
    if (home != NULL && home[0] != '\0') {
        snprintf(homep, sizeof(homep), "%s/axjverorder.log", home);
    }

    const char *cands[4];
    cands[0] = "/var/mobile/Documents/axjverorder.log";
    cands[1] = "/var/mobile/axjverorder.log";
    cands[2] = (homep[0] != '\0') ? homep : NULL;
    cands[3] = "/tmp/axjverorder.log";

    for (int i = 0; i < 4; i++) {
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

static void vo_log(const char *fmt, ...) {
    const char *path = vo_log_path();
    if (path == NULL) return;

    struct stat st;
    if (stat(path, &st) == 0 && st.st_size > VO_LOG_MAX) unlink(path);

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

// 读运行期真实 ivar 偏移：dyld 已把 0x1004007cc 处的表项填好
static int32_t vo_groups_offset(void) {
    uintptr_t base = (uintptr_t)_dyld_get_image_header(0);
    return *(int32_t *)(base + (VO_OFFSET_SLOT_VA - VO_IMAGE_BASE_VA));
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"

static NSString *vo_str_of(id obj, const char *selName) {
    if (obj == nil) return nil;
    SEL s = sel_registerName(selName);
    if (![obj respondsToSelector:s]) return nil;

    // 只认「返回对象」的方法：否则若该 getter 返回的是 long long（大版本号），
    // performSelector 会把整数当指针，isKindOfClass 直接崩。
    NSMethodSignature *sig = [obj methodSignatureForSelector:s];
    if (sig == nil) return nil;
    const char *rt = [sig methodReturnType];
    if (rt == NULL || rt[0] != '@') return nil;

    id v = [obj performSelector:s];
    if ([v isKindOfClass:[NSString class]]) return v;
    return nil;
}

static NSString *vo_label_of(id group) {
    NSString *s = vo_str_of(group, VO_SEL_LABEL);
    if (s != nil) return s;
    return vo_str_of(group, VO_SEL_KEY);   // 兜底：用 major 键
}

#pragma clang diagnostic pop

static void vo_join(NSArray *arr, char *buf, size_t cap) {
    buf[0] = '\0';
    NSUInteger n = [arr count];
    for (NSUInteger i = 0; i < n; i++) {
        NSString *l = vo_label_of([arr objectAtIndex:i]);
        const char *p = l ? [l UTF8String] : "(nil)";
        size_t used = strlen(buf);
        if (used + 2 >= cap) break;
        strncat(buf, p, cap - used - 2);
        if (i + 1 < n) strncat(buf, " ", cap - strlen(buf) - 1);
    }
}

// 幂等反转：仅当首元素 < 末元素（仍是升序）时才翻
static void vo_maybe_reverse(id vc) {
    int32_t off = vo_groups_offset();
    if (off <= 0) { vo_log("bad ivar offset %d", (int)off); return; }

    // ARC 下不能直接 cast 成 id* / void*，一律走 __bridge
    void *slot = (char *)(__bridge void *)vc + off;
    id arr = (__bridge id)(*(void **)slot);
    if (arr == NULL) { vo_log("_groups is nil (off=%d)", (int)off); return; }
    if (![arr isKindOfClass:[NSMutableArray class]]) {
        vo_log("_groups NOT mutable (%s) -> skip", object_getClassName(arr));
        return;
    }

    NSUInteger n = [arr count];
    if (n < 2) return;   // 还没构建完，下次再说

    char before[2048];
    vo_join(arr, before, sizeof(before));

    NSString *first = vo_label_of([arr objectAtIndex:0]);
    NSString *last  = vo_label_of([arr objectAtIndex:n - 1]);
    if (first == nil || last == nil) {
        vo_log("n=%lu order: %s  (label unavailable -> skip)",
               (unsigned long)n, before);
        return;
    }

    if ([first compare:last] != NSOrderedAscending) {
        vo_log("n=%lu already ordered: %s  (first=%s last=%s)",
               (unsigned long)n, before,
               first ? [first UTF8String] : "(nil)",
               last ? [last UTF8String] : "(nil)");
        return;
    }

    for (NSUInteger i = 0; i + 1 < n - i; i++) {
        [(NSMutableArray *)arr exchangeObjectAtIndex:i withObjectAtIndex:(n - 1 - i)];
    }

    char after[2048];
    vo_join(arr, after, sizeof(after));
    vo_log("n=%lu BEFORE: %s", (unsigned long)n, before);
    vo_log("n=%lu AFTER : %s", (unsigned long)n, after);
}

// ---------------------------------------------------------------- hooks

static void (*vo_orig_viewDidLoad)(id, SEL);
static NSInteger (*vo_orig_numSections)(id, SEL, id);
static void (*vo_orig_viewWillAppear)(id, SEL, BOOL);

static void vo_viewDidLoad(id self, SEL _cmd) {
    vo_orig_viewDidLoad(self, _cmd);
}

// 两个触发点都调 vo_maybe_reverse（内部幂等：只在顺序仍是升序时翻一次）。
// 无论 _groups 是 viewDidLoad 同步建好、还是异步才填上，都能被覆盖到。
static void vo_viewWillAppear(id self, SEL _cmd, BOOL animated) {
    @try {
        vo_maybe_reverse(self);
    } @catch (NSException *e) {
        vo_log("exception(willAppear): %s", [[e description] UTF8String]);
    }
    vo_orig_viewWillAppear(self, _cmd, animated);
}

static NSInteger vo_numSections(id self, SEL _cmd, id tv) {
    @try {
        vo_maybe_reverse(self);
    } @catch (NSException *e) {
        vo_log("exception: %s", [[e description] UTF8String]);
    }
    return vo_orig_numSections(self, _cmd, tv);
}

__attribute__((constructor)) static void vo_init(void) {
    @autoreleasepool {
        Class c = objc_getClass("IFIOSVersionSelector");
        if (c == NULL) return;   // 本进程没有这个页面（例如 DHPDaemon）

        Method m1 = class_getInstanceMethod(c, sel_registerName("viewDidLoad"));
        if (m1 != NULL) {
            vo_orig_viewDidLoad = (void *)method_getImplementation(m1);
            method_setImplementation(m1, (IMP)vo_viewDidLoad);
        }

        Method m2 = class_getInstanceMethod(c, sel_registerName("numberOfSectionsInTableView:"));
        if (m2 != NULL) {
            vo_orig_numSections = (void *)method_getImplementation(m2);
            method_setImplementation(m2, (IMP)vo_numSections);
        }

        Method m3 = class_getInstanceMethod(c, sel_registerName("viewWillAppear:"));
        if (m3 != NULL) {
            vo_orig_viewWillAppear = (void *)method_getImplementation(m3);
            method_setImplementation(m3, (IMP)vo_viewWillAppear);
        }

        vo_log("verorder installed (viewDidLoad=%p numSections=%p viewWillAppear=%p)",
               (void *)m1, (void *)m2, (void *)m3);
    }
}
