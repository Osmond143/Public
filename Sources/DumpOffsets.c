// DumpOffsets.c
// 在设备上扫 UE4 结构偏移（纯 C，读写通过回调）
//
// 逻辑跟 PC 侧的 dump_offsets.cpp 一样：
//   候选全局 -> 是不是 UObject -> 扫字段找 TArray<UObject*> -> 再往下扫一级

#include "DumpOffsets.h"
#include <stdio.h>
#include <string.h>
#include <mach-o/dyld.h>

static uint64_t g_textLo = 0;
static uint64_t g_textHi = 0;

#define LOG(fmt, ...) fprintf(stderr, "[dump] " fmt "\n", ##__VA_ARGS__)

static int is_text_ptr(uint64_t p) {
    return p >= g_textLo && p < g_textHi && (p & 3) == 0;
}

static int rd64(krw_read_fn rd, uint64_t a, uint64_t *v) {
    return rd(a, v, 8) && *v != 0;
}

static int rd32(krw_read_fn rd, uint64_t a, uint32_t *v) {
    return rd(a, v, 4);
}

// UObject: vtable 在 __TEXT，Class 指针可读且 Class 的 vtable 也合法
static int is_uobject(krw_read_fn rd, uint64_t p, uint64_t *cls) {
    if (!p || (p & 7)) return 0;
    uint64_t vt = 0;
    if (!rd64(rd, p, &vt)) return 0;
    if (!is_text_ptr(vt)) return 0;
    uint64_t c = 0;
    if (!rd(p + 0x10, &c, 8) || !c) return 0;
    uint64_t cvt = 0;
    if (!rd64(rd, c, &cvt)) return 0;
    if (!is_text_ptr(cvt)) return 0;
    *cls = c;
    return 1;
}

// TArray 探测：Data/Num 合理，抽样元素都是 UObject
static int probe_tarray(krw_read_fn rd, uint64_t base, uint32_t off, uint32_t *numOut) {
    uint64_t data = 0;
    uint32_t num = 0;
    if (!rd64(rd, base + off, &data)) return 0;
    if (!rd32(rd, base + off + 8, &num)) return 0;
    if (!data || num == 0 || num > 20000 || (data & 7)) return 0;

    uint32_t step = num / 4 ? num / 4 : 1;
    uint32_t ok = 0, checked = 0, i;
    for (i = 0; i < num && checked < 4; i += step, checked++) {
        uint64_t e = 0;
        uint64_t c = 0;
        if (!rd(data + (uint64_t)i * 8, &e, 8)) return 0;
        if (!e) continue;
        if (is_uobject(rd, e, &c)) ok++;
    }
    if (!ok) return 0;
    *numOut = num;
    return 1;
}

static void scan_object(krw_read_fn rd, uint64_t obj, const char *label, uint32_t maxOff) {
    LOG("---- scan %s @ %#llx ----", label, (unsigned long long)obj);

    uint32_t off;
    uint32_t found = 0;
    for (off = 0; off < maxOff; off += 8) {
        uint32_t num = 0;
        if (!probe_tarray(rd, obj, off, &num)) continue;

        uint64_t data = 0;
        uint64_t e0 = 0, c0 = 0;
        rd(obj + off, &data, 8);
        if (!rd64(rd, data, &e0)) continue;
        if (!is_uobject(rd, e0, &c0)) continue;

        LOG("  [+%#05x] TArray<UObject*>  num=%u  data=%#llx",
            off, num, (unsigned long long)data);
        found++;

        // 二级：这个对象内部再找 TArray（Level->Actors）
        uint64_t p = 0;
        if (!rd64(rd, obj + off, &p)) continue;
        uint32_t off2;
        for (off2 = 0; off2 < 0x800; off2 += 8) {
            uint32_t n2 = 0;
            if (!probe_tarray(rd, p, off2, &n2)) continue;
            LOG("    -> 二级 [+%#05x] 内 [+%#05x] num=%u", off, off2, n2);
        }
    }
    if (!found) LOG("  (没有命中)");
}

void dump_offsets_run(krw_read_fn rd) {
    // 主模块 __TEXT 范围（用于判断"像不像代码指针"）
    uint32_t cnt = _dyld_image_count();
    uint32_t i;
    for (i = 0; i < cnt; i++) {
        const char *n = _dyld_get_image_name(i);
        if (!n) continue;
        // 取第一个非系统镜像当"目标模块"
        if (strstr(n, "/usr/lib/") || strstr(n, "/System/")) continue;
        const struct mach_header_64 *h = (const struct mach_header_64 *)_dyld_get_image_header(i);
        if (!h || h->magic != MH_MAGIC_64) continue;
        g_textLo = (uint64_t)h;
        g_textHi = g_textLo + 0x20000000ULL;   // 粗一点的区间
        LOG("模块: %s  base=%#llx", n, (unsigned long long)g_textLo);
        break;
    }

    if (!g_textLo) {
        LOG("找不到目标模块，放弃");
        return;
    }

    // 候选全局（PC 侧静态分析得到的）
    static const uint64_t cands[] = {
        0x10A1549F8ULL,
        0x10A023800ULL,
        0x109BB3DD8ULL,
        0x109F95B30ULL,
    };

    int k;
    for (k = 0; k < (int)(sizeof(cands) / sizeof(cands[0])); k++) {
        uint64_t g = cands[k];
        uint64_t obj = 0;
        if (!rd64(rd, g, &obj)) {
            LOG("[cand %#llx] 读不到", (unsigned long long)g);
            continue;
        }
        uint64_t cls = 0;
        if (!is_uobject(rd, obj, &cls)) {
            LOG("[cand %#llx] -> %#llx 不是 UObject",
                (unsigned long long)g, (unsigned long long)obj);
            continue;
        }
        char label[64];
        snprintf(label, sizeof(label), "cand_%llx", (unsigned long long)g);
        scan_object(rd, obj, label, 0x2000);
    }
}
