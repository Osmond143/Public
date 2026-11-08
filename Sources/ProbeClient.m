// ProbeClient.m
#import "ProbeClient.h"

#import <mach/mach.h>
#import <mach/mach_error.h>
#include <dlfcn.h>

extern mach_port_t  bootstrap_port;
extern kern_return_t bootstrap_look_up(mach_port_t bp, const char *service_name, mach_port_t *sp);

// 私有符号：消费沙盒扩展令牌
extern int sandbox_extension_consume(const char *extension_token);
extern char *sandbox_extension_release(int64_t handle);

@interface ProbeClient ()
@property (nonatomic, readwrite) KRWStatus status;
@property (nonatomic, readwrite) uint32_t  servicePort;
@property (nonatomic, readwrite) int64_t   tokenHandle;
@property (nonatomic, readwrite, copy) NSString *lastError;
@end

@implementation ProbeClient

+ (instancetype)shared {
    static ProbeClient *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [[ProbeClient alloc] init];
        s.status = KRWStatusIdle;
        s.servicePort = MACH_PORT_NULL;
        s.tokenHandle = -1;
    });
    return s;
}

- (void)setErr:(NSString *)msg {
    self.lastError = msg;
    NSLog(@"[probe] %@", msg);
}

#pragma mark - 连接

- (BOOL)connectService:(NSString *)serviceName token:(NSString *)token {
    if (serviceName.length == 0) {
        [self setErr:@"服务名为空"];
        self.status = KRWStatusLookupFail;
        return NO;
    }

    // 1) 有 token 就先消费（这条不需要 mach-lookup entitlement）
    if (token.length > 0) {
        int64_t h = sandbox_extension_consume(token.UTF8String);
        if (h < 0) {
            [self setErr:[NSString stringWithFormat:@"sandbox_extension_consume 失败: %lld", h]];
            self.status = KRWStatusConsumeFail;
            return NO;
        }
        self.tokenHandle = h;
        [self setErr:[NSString stringWithFormat:@"token 消费成功 handle=%lld", h]];
    } else {
        [self setErr:@"没有 token，尝试直接 lookup（需要 mach-lookup entitlement）"];
    }

    // 2) lookup 服务
    mach_port_t port = MACH_PORT_NULL;
    kern_return_t kr = bootstrap_look_up(bootstrap_port, serviceName.UTF8String, &port);
    if (kr != KERN_SUCCESS) {
        [self setErr:[NSString stringWithFormat:@"bootstrap_look_up(%@) 失败: %s (0x%x)",
                      serviceName, mach_error_string(kr), kr]];
        self.status = KRWStatusLookupFail;
        return NO;
    }

    self.servicePort = port;
    self.status = KRWStatusReady;
    [self setErr:[NSString stringWithFormat:@"服务已连接 %@ port=%u", serviceName, port]];
    return YES;
}

#pragma mark - 读写

// TODO(M1): DarkSword 的 mach_msg 协议还没挖出来，这几步先留空。
// 挖到之后：
//   - 读请求：{ msg_id, addr, len, reply_port }
//   - 写请求：{ msg_id, addr, len, data... }
- (BOOL)read:(uint64_t)addr into:(void *)buf length:(size_t)len {
    if (self.status != KRWStatusReady) {
        [self setErr:@"read: 服务未连接"];
        return NO;
    }
    [self setErr:[NSString stringWithFormat:@"read(%#llx, %zu): 协议未实现（等 M1）",
                  (unsigned long long)addr, len]];
    self.status = KRWStatusMsgFail;
    return NO;
}

- (BOOL)write:(uint64_t)addr from:(const void *)buf length:(size_t)len {
    if (self.status != KRWStatusReady) {
        [self setErr:@"write: 服务未连接"];
        return NO;
    }
    [self setErr:@"write: 协议未实现（本方案也不写游戏内存）"];
    return NO;
}

#pragma mark - 调试：枚举候选

- (NSArray<NSDictionary *> *)enumerateCandidates {
    NSMutableArray *out = [NSMutableArray array];

    // 1. 已加载的镜像里有没有 okdemo 相关
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name) continue;
        NSString *n = [NSString stringWithUTF8String:name];
        if ([n containsString:@"okdemo"] || [n containsString:@"darksword"] ||
            [n containsString:@"Via"] || [n containsString:@"vesp"]) {
            [out addObject:@{ @"kind": @"image", @"name": n,
                              @"base": @((uint64_t)_dyld_get_image_header(i)) }];
        }
    }

    // 2. UserDefaults 里有没有 dskrw 相关的键
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    for (NSString *k in ud.dictionaryRepresentation.allKeys) {
        if ([k containsString:@"dskrw"] || [k containsString:@"okdemo"] ||
            [k containsString:@"darksword"]) {
            id v = [ud objectForKey:k];
            [out addObject:@{ @"kind": @"defaults", @"name": k,
                              @"value": [v description] ?: @"(nil)" }];
        }
    }

    // 3. 常见固定路径
    NSArray *paths = @[
        @"/var/mobile/Library/Preferences/com.okdemo.dskrw.rw.plist",
        @"/var/mobile/Library/Preferences/com.okdemo.dskrw.control.plist",
        @"/var/mobile/Library/Preferences/com.okdemo.darksword.keepalive-watchdog.plist",
        @"/var/mobile/Documents/dskrw.token",
        @"/var/mobile/tmp/dskrw.token",
    ];
    for (NSString *p in paths) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:p]) {
            [out addObject:@{ @"kind": @"file", @"name": p }];
        }
    }

    return out;
}

@end

#pragma mark - C 桥接（给 DumpOffsets.c 用）

int krw_read_bridge(uint64_t addr, void *buf, size_t len) {
    return [[ProbeClient shared] read:addr into:buf length:len] ? 1 : 0;
}
