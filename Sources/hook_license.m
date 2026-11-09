// hook_license.m
// 注入到 CodeV（无畏契约手游）进程，绕过「不死鸟 HUD」的卡密验证
//
// 原理：
//   1. 找到 江雪 / MenuInteraction 类，hook setOnConfirm: 把验证成功回调的 block 存下来
//   2. hook confirmButtonTapped：点确认时直接调用保存的 block，跳过网络验证
//   3. 兜底：hook stringForKey: 把读到的键名/值打印出来
//
// 全部用 method_setImplementation（改 __DATA 里的 method_t），
// 不改代码段，不需要 inline hook，也不需要内核读写。

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#include <mach-o/dyld.h>
#include <unistd.h>

// CodeV 是沙盒 app，写不了 /var/mobile，改写到自己的 tmp
static NSString *logPath(void) {
    return [NSTemporaryDirectory() stringByAppendingPathComponent:@"vesp_license.log"];
}

static NSMutableString *gLog = nil;

static void L(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    if (!gLog) gLog = [NSMutableString string];
    [gLog appendFormat:@"%@\n", s];
    NSLog(@"[license] %@", s);
    [gLog writeToFile:logPath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

// ---------------------------------------------------------------- 保存的 block
static id g_savedBlock = nil;
static int g_hookedSetOnConfirm = 0;

static void my_setOnConfirm(id self, SEL _cmd, id block) {
    L(@"[setOnConfirm:] self=%s block=%p", object_getClassName(self), block);
    if (block) {
        g_savedBlock = [block copy];
        L(@"  已保存 block");
    }
}

// ---------------------------------------------------------------- confirmButtonTapped
static void my_confirmButtonTapped(id self, SEL _cmd) {
    L(@"[confirmButtonTapped] self=%s", object_getClassName(self));
    if (g_savedBlock) {
        L(@"  跳过验证，直接调用 _onConfirm block");
        @try {
            void (^b)(void) = g_savedBlock;
            b();
        } @catch (NSException *e) {
            L(@"  block 调用异常: %@", e);
        }
    } else {
        L(@"  还没拿到 block，无法跳过");
    }
}

// ---------------------------------------------------------------- stringForKey:
static IMP g_origStringForKey = NULL;

static id my_stringForKey(id self, SEL _cmd, NSString *key) {
    id v = nil;
    if (g_origStringForKey) {
        v = ((id(*)(id,SEL,id))g_origStringForKey)(self, _cmd, key);
    }
    L(@"[stringForKey:] key=%@ -> %@", key, v);
    return v;
}

// ---------------------------------------------------------------- 主逻辑
static void hook_all(void) {
    int n = objc_getClassList(NULL, 0);
    if (n <= 0) { L(@"objc_getClassList 返回 0"); return; }
    Class *classes = (Class *)malloc(sizeof(Class) * n);
    n = objc_getClassList(classes, n);
    L(@"类总数: %d", n);

    SEL selSetOnConfirm = sel_registerName("setOnConfirm:");
    SEL selConfirm      = sel_registerName("confirmButtonTapped");
    SEL selStringForKey = sel_registerName("stringForKey:");

    int hookedA = 0, hookedB = 0, hookedC = 0;

    for (int i = 0; i < n; i++) {
        Class c = classes[i];
        const char *cn = class_getName(c);
        if (!cn) continue;

        // 只看挂自己的类（江雪 / MenuInteraction / MenuLoad）
        BOOL interesting = (strcmp(cn, "江雪") == 0 ||
                            strcmp(cn, "MenuInteraction") == 0 ||
                            strcmp(cn, "MenuLoad") == 0);
        if (!interesting) continue;

        L(@"发现类: %s", cn);

        Method mA = class_getInstanceMethod(c, selSetOnConfirm);
        if (mA) {
            method_setImplementation(mA, (IMP)my_setOnConfirm);
            L(@"  hook setOnConfirm:");
            hookedA++;
        }
        Method mB = class_getInstanceMethod(c, selConfirm);
        if (mB) {
            method_setImplementation(mB, (IMP)my_confirmButtonTapped);
            L(@"  hook confirmButtonTapped");
            hookedB++;
        }
        Method mC = class_getInstanceMethod(c, selStringForKey);
        if (mC) {
            if (!g_origStringForKey) g_origStringForKey = method_getImplementation(mC);
            method_setImplementation(mC, (IMP)my_stringForKey);
            L(@"  hook stringForKey:");
            hookedC++;
        }
    }

    // NSUserDefaults 的 stringForKey: 也 hook 一份（兜底打印键名）
    Class ud = objc_getClass("NSUserDefaults");
    if (ud) {
        Method mC = class_getInstanceMethod(ud, selStringForKey);
        if (mC) {
            if (!g_origStringForKey) g_origStringForKey = method_getImplementation(mC);
            method_setImplementation(mC, (IMP)my_stringForKey);
            L(@"  hook NSUserDefaults stringForKey:");
            hookedC++;
        }
    }

    g_hookedSetOnConfirm = hookedA;
    L(@"完成: setOnConfirm=%d confirm=%d stringForKey=%d", hookedA, hookedB, hookedC);
    free(classes);

    L(@"日志: %@", logPath());

    // 弹窗显示（方便直接截图）
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *w = UIApplication.sharedApplication.keyWindow;
        UIViewController *root = w.rootViewController;
        if (!root) return;
        UIAlertController *ac =
            [UIAlertController alertControllerWithTitle:@"license hook"
                                                message:[gLog copy]
                                         preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"OK"
                                               style:UIAlertActionStyleDefault handler:nil]];
        [root presentViewController:ac animated:YES completion:nil];
    });
}

__attribute__((constructor))
static void license_ctor(void) {
    NSLog(@"[license] dylib loaded, pid=%d", getpid());
    // 游戏加载 tgpa_wrapper 需要时间，等 12 秒
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(12 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(0, 0), ^{
        hook_all();
    });
}
