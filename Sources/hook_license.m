// hook_license.m
// 注入到 CodeV（无畏契约手游）进程，分析与绕过「不死鸟 HUD」的卡密验证
//
// v6：
//   ✓ 用 dyld __interpose 拦截 exit / _exit / abort / kill
//     —— 原包输假卡密直接退出、无提示，先确认它是怎么退的，并尝试阻止
//   ✓ 三指长按 1.2 秒弹日志（不挡输入）
//   ✓ signal handler 记录崩溃
//   ✓ 保留网络观察
//
// 注意：__interpose 只对「通过 dyld 绑定的符号」生效，
//       如果挂用 syscall 直接杀进程，这里抓不到。

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#include <mach-o/dyld.h>
#include <unistd.h>
#include <signal.h>
#include <fcntl.h>
#include <string.h>
#include <stdlib.h>

static NSMutableString *gLog = nil;
static char gLogPathC[512] = {0};
static char gCrashPathC[512] = {0};

static void L(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    if (!gLog) gLog = [NSMutableString string];
    [gLog appendFormat:@"%@\n", s];
    NSLog(@"[license] %@", s);
    if (gLogPathC[0]) {
        [gLog writeToFile:[NSString stringWithUTF8String:gLogPathC]
               atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
}

// ---------------------------------------------------------------- 崩溃记录
static void crash_handler(int sig, siginfo_t *info, void *ctx) {
    char buf[256];
    int n = snprintf(buf, sizeof(buf),
                     "\n[CRASH] signal=%d (%s) addr=%p\n",
                     sig,
                     sig == SIGSEGV ? "SIGSEGV" :
                     sig == SIGABRT ? "SIGABRT" :
                     sig == SIGILL  ? "SIGILL"  :
                     sig == SIGBUS  ? "SIGBUS"  :
                     sig == SIGFPE  ? "SIGFPE"  : "?",
                     (void *)(info ? info->si_addr : NULL));
    if (gCrashPathC[0] && n > 0) {
        int fd = open(gCrashPathC, O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (fd >= 0) {
            write(fd, buf, n);
            if (gLog) {
                const char *p = gLog.UTF8String;
                size_t len = p ? strlen(p) : 0;
                if (len > 8192) { p += (len - 8192); len = 8192; }
                if (len) write(fd, p, len);
            }
            close(fd);
        }
    }
    signal(sig, SIG_DFL);
    raise(sig);
}

static void install_crash_handler(void) {
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = crash_handler;
    sa.sa_flags = SA_SIGINFO;
    sigaction(SIGSEGV, &sa, NULL);
    sigaction(SIGABRT, &sa, NULL);
    sigaction(SIGILL,  &sa, NULL);
    sigaction(SIGBUS,  &sa, NULL);
    sigaction(SIGFPE,  &sa, NULL);
}

// ---------------------------------------------------------------- exit 拦截
// 记住调用栈（用 backtrace 不安全，只记录「谁调用」的粗略信息）
static volatile int g_blockExit = 1;   // 1 = 拦截（不真的退出）

static void vesp_exit(int code) {
    char buf[256];
    int n = snprintf(buf, sizeof(buf),
                     "\n[EXIT] exit(%d) 被调用，已拦截\n", code);
    if (gCrashPathC[0] && n > 0) {
        int fd = open(gCrashPathC, O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (fd >= 0) {
            write(fd, buf, n);
            if (gLog) {
                const char *p = gLog.UTF8String;
                size_t len = p ? strlen(p) : 0;
                if (len > 8192) { p += (len - 8192); len = 8192; }
                if (len) write(fd, p, len);
            }
            close(fd);
        }
    }
    NSLog(@"[license] exit(%d) intercepted", code);
    if (!g_blockExit) {
        _exit(code);
    }
    // 不退出，让进程继续（卡密界面会僵住，但至少活着）
    for (;;) {
        sleep(1);
    }
}

static void vesp_abort(void) {
    if (gCrashPathC[0]) {
        const char *msg = "\n[ABORT] abort() 被调用，已拦截\n";
        int fd = open(gCrashPathC, O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (fd >= 0) {
            write(fd, msg, strlen(msg));
            if (gLog) {
                const char *p = gLog.UTF8String;
                size_t len = p ? strlen(p) : 0;
                if (len > 8192) { p += (len - 8192); len = 8192; }
                if (len) write(fd, p, len);
            }
            close(fd);
        }
    }
    NSLog(@"[license] abort() intercepted");
    if (!g_blockExit) abort();
    for (;;) sleep(1);
}

#define DYLD_INTERPOSE(_replacement, _replacee) \
    __attribute__((used)) static struct { const void *replacement; const void *replacee; } \
    _interpose_##_replacee __attribute__((section("__DATA,__interpose"))) = \
    { (const void *)(unsigned long)&_replacement, (const void *)(unsigned long)&_replacee };

DYLD_INTERPOSE(vesp_exit, exit)
DYLD_INTERPOSE(vesp_exit, _exit)
DYLD_INTERPOSE(vesp_abort, abort)

// ---------------------------------------------------------------- setOnConfirm:
static id g_savedBlock = nil;

static void my_setOnConfirm(id self, SEL _cmd, id block) {
    L(@"[setOnConfirm:] class=%@ block=%p",
      NSStringFromClass(object_getClass(self)), block);
    if (block) {
        g_savedBlock = [block copy];
        L(@"  已保存 block");
    }
}

// ---------------------------------------------------------------- NSURL URLWithString:
static IMP g_origURLWithString = NULL;

static id my_URLWithString(id self, SEL _cmd, NSString *s) {
    id u = nil;
    if (g_origURLWithString) {
        u = ((id(*)(id,SEL,id))g_origURLWithString)(self, _cmd, s);
    }
    if (s.length && s.length < 300) L(@"[URL] %@", s);
    return u;
}

// ---------------------------------------------------------------- JSON 解析
static IMP g_origJSONParse = NULL;

static id my_JSONParse(id self, SEL _cmd, NSData *data, NSUInteger opt, NSError **err) {
    if (data.length && data.length < 6000) {
        NSString *raw = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (raw && raw.length < 3000) L(@"[JSON in] %@", raw);
    }
    id r = nil;
    if (g_origJSONParse) {
        r = ((id(*)(id,SEL,id,NSUInteger,NSError**))g_origJSONParse)(self, _cmd, data, opt, err);
    }
    return r;
}

// ---------------------------------------------------------------- 日志弹窗
static void show_log_window(void);

static void show_log_window(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *root = nil;
        for (UIWindow *win in UIApplication.sharedApplication.windows) {
            if (win.isKeyWindow && win.rootViewController) { root = win.rootViewController; break; }
        }
        if (!root) {
            for (UIWindow *win in UIApplication.sharedApplication.windows) {
                if (win.rootViewController) { root = win.rootViewController; break; }
            }
        }
        if (!root) { NSLog(@"[license] 无 root"); return; }

        NSString *text = gLog.length ? gLog : @"(空)";
        if (text.length > 1800) {
            text = [NSString stringWithFormat:@"...(前略)...\n%@",
                    [text substringFromIndex:text.length - 1800]];
        }
        if (gCrashPathC[0]) {
            NSString *crash = [NSString stringWithContentsOfFile:[NSString stringWithUTF8String:gCrashPathC]
                                                        encoding:NSUTF8StringEncoding error:nil];
            if (crash.length) {
                if (crash.length > 900) crash = [crash substringFromIndex:crash.length - 900];
                text = [NSString stringWithFormat:@"%@\n\n== 退出/崩溃记录 ==\n%@", text, crash];
            }
        }

        UIAlertController *ac =
            [UIAlertController alertControllerWithTitle:@"license log"
                                                message:text
                                         preferredStyle:UIAlertControllerStyleAlert];
        __weak typeof(root) wroot = root;
        [ac addAction:[UIAlertAction actionWithTitle:@"刷新"
                                               style:UIAlertActionStyleDefault
                                             handler:^(UIAlertAction *a) { show_log_window(); }]];
        [ac addAction:[UIAlertAction actionWithTitle:@"复制"
                                               style:UIAlertActionStyleDefault
                                             handler:^(UIAlertAction *a) {
            UIPasteboard.generalPasteboard.string = gLog ?: @"";
        }]];
        [ac addAction:[UIAlertAction actionWithTitle:@"关闭"
                                               style:UIAlertActionStyleCancel
                                             handler:nil]];
        [wroot presentViewController:ac animated:YES completion:nil];
    });
}

// ---------------------------------------------------------------- 三指长按
@interface VespGestureTarget : NSObject
- (void)onLongPress:(UILongPressGestureRecognizer *)g;
@end

@implementation VespGestureTarget
- (void)onLongPress:(UILongPressGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateBegan) show_log_window();
}
@end

static VespGestureTarget *g_gestureTarget = nil;

static void install_gesture(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!g_gestureTarget) g_gestureTarget = [VespGestureTarget new];
        UIWindow *key = nil;
        for (UIWindow *w in UIApplication.sharedApplication.windows) {
            if (w.isKeyWindow) { key = w; break; }
        }
        if (!key) {
            for (UIWindow *w in UIApplication.sharedApplication.windows) {
                if (w.rootViewController) { key = w; break; }
            }
        }
        if (!key) { NSLog(@"[license] 无 window"); return; }
        UILongPressGestureRecognizer *g =
            [[UILongPressGestureRecognizer alloc] initWithTarget:g_gestureTarget
                                                          action:@selector(onLongPress:)];
        g.numberOfTouchesRequired = 3;
        g.minimumPressDuration = 1.2;
        g.cancelsTouchesInView = NO;
        [key addGestureRecognizer:g];
        NSLog(@"[license] 三指长按已挂上");
    });
}

// ---------------------------------------------------------------- 主逻辑
static void hook_all(void) {
    int n = objc_getClassList(NULL, 0);
    Class *classes = (Class *)malloc(sizeof(Class) * n);
    n = objc_getClassList(classes, n);
    L(@"类总数: %d", n);

    int hookedA = 0;
    SEL selSetOnConfirm = sel_registerName("setOnConfirm:");
    for (int i = 0; i < n; i++) {
        Class c = classes[i];
        const char *cn = class_getName(c);
        if (!cn) continue;
        if (strcmp(cn, "江雪") != 0) continue;
        L(@"发现类: %@", NSStringFromClass(c));
        Method m = class_getInstanceMethod(c, selSetOnConfirm);
        if (m) {
            method_setImplementation(m, (IMP)my_setOnConfirm);
            L(@"  hook setOnConfirm:");
            hookedA++;
        }
    }
    free(classes);

    Method mURL = class_getClassMethod(objc_getClass("NSURL"),
                                       sel_registerName("URLWithString:"));
    if (mURL) {
        g_origURLWithString = method_getImplementation(mURL);
        method_setImplementation(mURL, (IMP)my_URLWithString);
        L(@"  hook +[NSURL URLWithString:]");
    }
    Method mJSON = class_getClassMethod(objc_getClass("NSJSONSerialization"),
                                        sel_registerName("JSONObjectWithData:options:error:"));
    if (mJSON) {
        g_origJSONParse = method_getImplementation(mJSON);
        method_setImplementation(mJSON, (IMP)my_JSONParse);
        L(@"  hook +[NSJSONSerialization JSONObjectWithData:options:error:]");
    }

    L(@"完成: setOnConfirm=%d", hookedA);
    L(@"exit/abort 已拦截（不会真的退出）");
    L(@"日志: %s", gLogPathC);
    L(@"记录: %s", gCrashPathC);
    L(@"  看日志: 三指长按屏幕 1.2 秒");
}

__attribute__((constructor))
static void license_ctor(void) {
    NSString *tmp = NSTemporaryDirectory();
    strncpy(gLogPathC, [[tmp stringByAppendingPathComponent:@"vesp_license.log"] UTF8String], 511);
    strncpy(gCrashPathC, [[tmp stringByAppendingPathComponent:@"vesp_crash.txt"] UTF8String], 511);

    NSLog(@"[license] dylib loaded, pid=%d", getpid());
    install_crash_handler();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(12 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(0, 0), ^{
        hook_all();
        install_gesture();
    });
}
