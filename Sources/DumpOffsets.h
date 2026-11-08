// DumpOffsets.h
// 纯 C 的偏移扫描逻辑，用函数指针解耦内核读
#pragma once
#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/// 内核读回调：成功返回 1
typedef int (*krw_read_fn)(uint64_t addr, void *buf, size_t len);

/// 桥接函数（由 ProbeClient 实现，供 C 侧调用）
int krw_read_bridge(uint64_t addr, void *buf, size_t len);

/// 跑一遍扫描，结果打到 stdout / NSLog
void dump_offsets_run(krw_read_fn rd);

#ifdef __cplusplus
}
#endif
