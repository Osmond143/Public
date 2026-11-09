// hook_license.m
// 注入到 CodeV（无畏契约手游）进程，分析「不死鸟 HUD」的卡密验证
//
// 第 2 版：只观察，不动原流程（避免闪退）
//   1. hook setOnConfirm:     保存验证成功回调的 block
//   2. hook confirmButtonTapped 只打日志（不调 block，不发网络请求）
//   3. hook stringForKey: / objectForKey: / setObject:forKey:  打印所有 UserDefaults 读写
//
// 目标是拿到卡密状态的「键名」和「期望值」，下一版再针对性注入。

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

// ---------------------------------------------------------------- 保存的 block
static id g_savedBlock = nil;

static void my_setOnConfirm(id self, SEL _cmd, id block) {
    // 用 %@ 打印，避免 %s 乱码
    Class c = object_getClass(self);
    L(@"[setOnConfirm:] class=%@ block=%p", NSStringFromClass(c), block);
    if (block) {
        g_savedBlock = [block copy];
        L(@"  已保存 block");
    }
}

// ---------------------------------------------------------------- confirmButtonTapped
static void my_confirmButtonTapped(id self, SEL _cmd) {
    Class c = object_getClass(self);
    L(@"[confirmButtonTapped] class=%@  (不调 block，避免崩溃)", NSStringFromClass(c));
    L(@"  已保存的 block: %p", g_savedBlock);
}

// ---------------------------------------------------------------- UserDefaults 读写
static IMP g_origStringForKey = NULL;
static IMP g_origObjectForKey = NULL;
static IMP g_origSetObject = NULL;

static id my_stringForKey(id self, SEL _cmd, NSString *key) {
    id v = nil;
    if (g_origStringForKey) {
        v = ((id(*)(id,SEL,id))g_origStringForKey)(self, _cmd, key);
    }
    L(@"[stringForKey:] class=%@ key=%@ -> %@",
      NSStringFromClass(object_getClass(self)), key, v);
    return v;
}

static id my_objectForKey(id self, SEL _cmd, NSString *key) {
    id v = nil;
    if (g_origObjectForKey) {
        v = ((id(*)(id,SEL,id))g_origObjectForKey)(self, _cmd, key);
    }
    L(@"[objectForKey:] class=%@ key=%@ -> %@ (%@)",
      NSStringFromClass(object_getClass(self)), key, v,
      v ? NSStringFromClass(object_getClass(v)) : @"nil");
    return v;
}

static void my_setObject(id self, SEL _cmd, id value, NSString *key) {
    Class vc = value ? object_getClass(value) : nil;
    L(@"[setObject:forKey:] class=%@ key=%@ value=%@ (%@)",
      NSStringFromClass(object_getClass(self)), key, value,
      vc ? NSStringFromClass(vc) : @"nil");
    if (g_origSetObject) {
        ((void(*)(id,SEL,id,id))g_origSetObject)(self, _cmd, value, key);
    }
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
    SEL selObjectForKey = sel_registerName("objectForKey:");
    SEL selSetObject    = sel_registerName("setObject:forKey:");

    int hookedA = 0, hookedB = 0, hookedC = 0, hookedD = 0, hookedE = 0;

    for (int i = 0; i < n; i++) {
        Class c = classes[i];
        const char *cn = class_getName(c);
        if (!cn) continue;

        BOOL interesting = (strcmp(cn, "江雪") == 0 ||
                            strcmp(cn, "MenuInteraction") == 0 ||
                            strcmp(cn, "MenuLoad") == 0);
        if (!interesting) continue;

        L(@"发现类: %@", NSStringFromClass(c));

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

    // NSUserDefaults 的读写（全局，兜底）
    Class ud = objc_getClass("NSUserDefaults");
    if (ud) {
        Method mC = class_getInstanceMethod(ud, selStringForKey);
        if (mC) {
            if (!g_origStringForKey) g_origStringForKey = method_getImplementation(mC);
            method_setImplementation(mC, (IMP)my_stringForKey);
            L(@"  hook NSUserDefaults stringForKey:");
            hookedC++;
        }
        Method mD = class_getInstanceMethod(ud, selObjectForKey);
        if (mD) {
            g_origObjectForKey = method_getImplementation(mD);
            method_setImplementation(mD, (IMP)my_objectForKey);
            L(@"  hook NSUserDefaults objectForKey:");
            hookedD++;
        }
        Method mE = class_getInstanceMethod(ud, selSetObject);
        if (mE) {
            g_origSetObject = method_getImplementation(mE);
            method_setImplementation(mE, (IMP)my_setObject);
            L(@"  hook NSUserDefaults setObject:forKey:");
            hookedE++;
        }
    }

    L(@"完成: setOnConfirm=%d confirm=%d stringForKey=%d objectForKey=%d setObject=%d",
      hookedA, hookedB, hookedC, hookedD, hookedE);
    L(@"日志: %@", logPath());
    free(classes);
}

__attribute__((constructor))
static void license_ctor(void) {
    NSLog(@"[license] dylib loaded, pid=%d", getpid());
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(12 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(0, 0), ^{
        hook_all();
    });
}
