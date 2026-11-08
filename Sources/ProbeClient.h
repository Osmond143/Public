// ProbeClient.h
// 连接 DarkSword 的 KRW Mach 服务的客户端
#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, KRWStatus) {
    KRWStatusIdle = 0,
    KRWStatusReady,
    KRWStatusNoToken,        // 没拿到 sandbox token
    KRWStatusConsumeFail,    // token 无效
    KRWStatusLookupFail,     // bootstrap_look_up 失败（服务没注册 / 名字不对）
    KRWStatusMsgFail,        // mach_msg 收发失败
};

@interface ProbeClient : NSObject

+ (instancetype)shared;

/// 从磁盘/UserDefaults 里找 token，再连服务
/// @param serviceName 完整服务名（例如 com.okdemo.dskrw.rw.deadbeefcafebabe）
- (BOOL)connectService:(NSString *)serviceName token:(nullable NSString *)token;

/// 内核读
- (BOOL)read:(uint64_t)addr into:(void *)buf length:(size_t)len;

/// 内核写（本方案不用，留着备用）
- (BOOL)write:(uint64_t)addr from:(const void *)buf length:(size_t)len;

/// 直接把疑似 token / 服务名的候选列出来（调试用）
- (NSArray<NSDictionary *> *)enumerateCandidates;

@property (nonatomic, readonly) KRWStatus   status;
@property (nonatomic, readonly) NSString   *lastError;
@property (nonatomic, readonly) uint32_t    servicePort;
@property (nonatomic, readonly) int64_t     tokenHandle;

@end

NS_ASSUME_NONNULL_END
