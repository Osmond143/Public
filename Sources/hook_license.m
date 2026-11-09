// hook_license.m
// 注入到 CodeV（无畏契约手游）进程，分析「不死鸟 HUD」的卡密验证
//
// v4：观察网络，不动原流程
//   ✗ 不再 hook confirmButtonTapped（避免破坏 UI 状态导致闪退）
//   ✗ 不再 hook UserDefaults（v3 已证明它不写 UserDefaults）
//   ✓ hook +[NSURL URLWithString:]           打印请求地址
//   ✓ hook +[NSJSONSerialization JSONObject...] 打印解析的原始数据
//   ✓ hook -setOnConfirm:                    保存回调 block
//   ✓ 弹窗可刷新/复制

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#include <mach-o/dyld.h>
#include <unistd.h>

static NSMutableString *gLog = nil;

static NSString *logPath(void) {
    return [NSTemporaryDirectory() stringByAppendingPathComponent:@"vesp_license.log"];
}

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

static id g_savedBlock = nil;

// ---------------------------------------------------------------- setOnConfirm:
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
    if (s.length) {
        L(@"[URLWithString:] %@", s);
    }
    return u;
}

// ---------------------------------------------------------------- NSJSONSerialization
static IMP g_origJSONParse = NULL;

static id my_JSONParse(id self, SEL _cmd, NSData *data, NSUInteger opt, NSError **err) {
    if (data.length) {
        NSString *raw = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (!raw) raw = [data description];
        if (raw.length > 1500) raw = [[raw substringToIndex:1500] stringByAppendingString:@"..."];
        L(@"[JSONObjectWithData:] 原始数据(%lu bytes):\n%@", (unsigned long)data.length, raw);
    }
    id r = nil;
    if (g_origJSONParse) {
        r = ((id(*)(id,SEL,id,NSUInteger,NSError**))g_origJSONParse)(self, _cmd, data, opt, err);
    }
    L(@"[JSONObjectWithData:] 解析结果: %@", r);
    return r;
}

// ---------------------------------------------------------------- 日志弹窗
static void show_log_window(void);

static void show_log_window(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *root = nil;
        for (UIWindow *win in UIApplication.sharedApplication.windows) {
            if (win.rootViewController) { root = win.rootViewController; break; }
        }
        if (!root) { NSLog(@"[license] 无 root, 日志 %@", logPath()); return; }

        if (root.presentedViewController &&
            [root.presentedViewController isKindOfClass:[UIAlertController class]]) {
            [root dismissViewControllerAnimated:NO completion:nil];
        }

        NSString *text = gLog.length ? gLog : @"(空)";
        if (text.length > 2600) {
            text = [NSString stringWithFormat:@"...(前略)...\n%@",
                    [text substringFromIndex:text.length - 2600]];
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

// ---------------------------------------------------------------- 主逻辑
static void hook_all(void) {
    int n = objc_getClassList(NULL, 0);
    Class *classes = (Class *)malloc(sizeof(Class) * n);
    n = objc_getClassList(classes, n);
    L(@"类总数: %d", n);

    int hookedA = 0;

    // 1) 江雪 的 setOnConfirm:
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

    // 2) NSURL URLWithString:  （类方法）
    Method mURL = class_getClassMethod(objc_getClass("NSURL"),
                                       sel_registerName("URLWithString:"));
    if (mURL) {
        g_origURLWithString = method_getImplementation(mURL);
        method_setImplementation(mURL, (IMP)my_URLWithString);
        L(@"  hook +[NSURL URLWithString:]");
    } else {
        L(@"  !! 没找到 +[NSURL URLWithString:]");
    }

    // 3) NSJSONSerialization JSONObjectWithData:options:error:  （类方法）
    Method mJSON = class_getClassMethod(objc_getClass("NSJSONSerialization"),
                                        sel_registerName("JSONObjectWithData:options:error:"));
    if (mJSON) {
        g_origJSONParse = method_getImplementation(mJSON);
        method_setImplementation(mJSON, (IMP)my_JSONParse);
        L(@"  hook +[NSJSONSerialization JSONObjectWithData:options:error:]");
    } else {
        L(@"  !! 没找到 JSONObjectWithData:options:error:");
    }

    L(@"完成: setOnConfirm=%d", hookedA);
    L(@"日志: %@", logPath());
    show_log_window();
}

__attribute__((constructor))
static void license_ctor(void) {
    NSLog(@"[license] dylib loaded, pid=%d", getpid());
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(12 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(0, 0), ^{
        hook_all();
    });
}
