//
//  haptics_fix.m —— 门①（GCController.playerIndex → 0）+ 数据源（sink 两路）
//
//  根因 = 系统给 `GCController.playerIndex` 报 **-1**（未分配），游戏据此匹配不上手柄
//  ⇒ 不建 Wwise motion sink ⇒ **手柄震动与普攻震动同时失效**。
//  修法 = 在 ObjC 层把 `-[GCController playerIndex]` **一律报 0**（游戏的目标槽位）：
//  所有读取点一起修好 ⇒ 游戏自己匹配上、自己建 sink、自己发数据 ⇒ 两项自愈。
//  （旧 P1/P2 补丁只修一处匹配、retrigger 兜底，均已删除 —— 详见 STATE §100。）
//
//  ⚠️ 不改游戏二进制。多手柄场景会把所有手柄都算成 1P（单手柄无影响）。
//  ⚠️ 输出侧（4 马达分发 / A1·A2·A3 钩子）在 haptics_out.m —— 不要混写。
//  ⚠️ 详见 haptics/STATE.md §100、haptics/memory/topics/11-haptics-rumble-root-cause-and-fix.md
//
#import "EndfieldHapticsFix.h"
#import "EndfieldHapticsLog.h"
#import "EndfieldHapticsOut.h"          // 数据源 = sink 两路 → hg_out_feed2
#import "../Endfield/EndfieldRuntime.h"

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <math.h>
#include <stdatomic.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>

#pragma mark - 门①：GCController.playerIndex → 0

static IMP g_origPlayerIndex = NULL;
static _Atomic int g_installed = 0;
static _Atomic int g_piLogged = 0;

static NSInteger hg_playerIndex(id self, SEL _cmd) {
    NSInteger real = g_origPlayerIndex ? ((NSInteger (*)(id, SEL))g_origPlayerIndex)(self, _cmd) : -1;
    if (atomic_fetch_add(&g_piLogged, 1) < 5)
        rlog("[门] GCController.playerIndex 真实值=%lld → 报给游戏 0", (long long)real);
    return 0;
}

// 安装（幂等；类还没加载时由 hg_fix_tick 重试）。
static void hg_gate_install(void) {
    if (atomic_load(&g_installed)) return;
    Class c = NSClassFromString(@"GCController");
    SEL sel = sel_registerName("playerIndex");
    Method m = c ? class_getInstanceMethod(c, sel) : NULL;
    if (m == NULL) return;                          // 还没加载 → 下个 tick 再试
    g_origPlayerIndex = method_getImplementation(m);
    method_setImplementation(m, (IMP)hg_playerIndex);
    atomic_store(&g_installed, 1);
    rlog("[门] 已拆：GCController.playerIndex → 恒 0（原 IMP=%p）", (void *)g_origPlayerIndex);
}

#pragma mark - 心跳辅助（控制器清单 + 手柄能力摘要）

static id hg_really_controllers(void) {
    Class c = NSClassFromString(@"GCController");
    if (!c) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(c, sel_registerName("controllers"));
}

// ★ 手柄能力摘要 —— 与 `haptics/tools/haptics_localities.swift` 同口径：
//   名称/类别 · localities 数 · 有无左右握把 / 扳机马达 → 最终输出模式。
static void hg_log_pad_status(id ct, id sup) {
    if (!ct) { rlog("[CTRL] 手柄状态: 无手柄"); return; }
    NSString *vn = ((id (*)(id, SEL))objc_msgSend)(ct, sel_registerName("vendorName"));
    NSString *pc = ((id (*)(id, SEL))objc_msgSend)(ct, sel_registerName("productCategory"));
    BOOL hasLH = NO, hasRH = NO, hasLT = NO, hasRT = NO;
    if ([sup isKindOfClass:[NSSet class]] || [sup isKindOfClass:[NSArray class]]) {
        hasLH = [sup containsObject:@"Left Handle"];
        hasRH = [sup containsObject:@"Right Handle"];
        hasLT = [sup containsObject:@"Left Trigger"];
        hasRT = [sup containsObject:@"Right Trigger"];
    }
    BOOL dual = hasLH && hasRH, trig = hasLT && hasRT;
    const char *mode = trig ? "4 马达（握把+扳机，split 生效）"
                            : (dual ? "2 马达（仅握把，自动回退纯路由）"
                                    : "1 路（Default）");
    rlog("[CTRL] 手柄状态: %s / %s · localities=%lu · 左右握把=%s · 扳机马达=%s → 输出=%s",
         vn ? [vn UTF8String] : "?", pc ? [pc UTF8String] : "?",
         (unsigned long)(sup ? [sup count] : 0),
         dual ? "有" : "无", trig ? "有" : "无", mode);
}

// 心跳里看一眼控制器数组：状态变化或每 10 次心跳打一行。
void hg_fix_log_ctrl_heartbeat(void) {
    @try {
        id arr = hg_really_controllers();
        NSUInteger cnt = arr ? [arr count] : 0;
        static unsigned long hbLastCnt = 999; static void *hbLastHap = NULL;
        static unsigned long hbLastLoc = 999; static int hbCtrlTick = 0;
        id ct = cnt ? [arr objectAtIndex:0] : nil;
        id hap = ct ? ((id (*)(id, SEL))objc_msgSend)(ct, sel_registerName("haptics")) : nil;
        id sup = hap ? ((id (*)(id, SEL))objc_msgSend)(hap, sel_registerName("supportedLocalities")) : nil;
        unsigned long nl = (unsigned long)(sup ? [sup count] : 0);
        BOOL changed = (cnt != hbLastCnt || (void *)hap != hbLastHap || nl != hbLastLoc);
        if (changed || ++hbCtrlTick >= 10) {
            hbCtrlTick = 0;
            if (cnt == 0) {
                rlog("[CTRL] 心跳: controllers() 为空 !!");
            } else {
                char d[160]; hg_flat(d, sizeof d, [ct description]);
                rlog("[CTRL] 心跳%s: count=%lu [0] haptics=%p localities=%lu | %s",
                     changed ? "★变化" : "", cnt, hap, nl, d);
                if (changed) hg_log_pad_status(ct, sup);   // ★ 手柄能力摘要（状态变化时）
            }
            hbLastCnt = cnt; hbLastHap = (void *)hap; hbLastLoc = nl;
        }
    } @catch (NSException *ex) { /* 忽略 */ }
}

#pragma mark - 数据源：AkMotionSink::Consume 的两路

// ══════════════════════════════════════════════════════════════════════════
// 数据源 = Wwise motion 的两路（真·左右）：挂 `AkMotionSink` 的数据入口 **Consume**
//   Consume(this = sink, AkAudioBuffer* in, AkRamp gain)      // gain 走 s0/s1
//     · sink 侧：通道数 [sink+0x20] = 2、每通道采样数 [sink+0x24] = 256
//     · 缓冲侧：总采样数 [buf+0x10] = 512、数据指针 [buf]；**平面**排布
//               （前 256 = 通道 0 = 左，后 256 = 通道 1 = 右）
//   做法：每帧取**每通道峰值** → `hg_out_feed2` 驱动 4 马达（**不做定标**，官方值原样），
//         再**照常透传**原实现 ⇒ 游戏自己的链路不受影响（官方那一路由 A3 静音）。
//
// ★★ **不硬编码地址**（支持国服/国际服 + 后续更新）：
//   ① 在 `__text` 里按 Consume 的指令签名找函数（掩码见下方 HG_SINK_SIG*）；
//   ② 在 `__DATA_CONST` / `__DATA` 里找指向它的 8 字节指针 = vtable 槽；
//   ⇒ 换版本/换服都不用改常量；找不到就**静默不挂**（只打一行日志）。
//   ⚠️ 二进制是 **arm64（非 arm64e）** ⇒ 运行时 vtable 里是普通指针，可直接改写
//      （磁盘上的 chained fixup 由 dyld 装载时解掉）。
//   详见 haptics/STATE.md §101 §102、haptics/memory/topics/07-endfield-haptics-signal-sources.md §8
// ══════════════════════════════════════════════════════════════════════════

// Consume 入口的三条指令（掩码匹配；word1 只锁 opcode = cbz w8）
#define HG_SINK_SIG0_MASK  0xFFFFFFFFu
#define HG_SINK_SIG0_VAL   0x39402028u   // ldrb w8, [x1, #8]
#define HG_SINK_SIG1_MASK  0xFF000000u
#define HG_SINK_SIG1_VAL   0x34000000u   // cbz  w8, …
#define HG_SINK_SIG2_MASK  0xFFFFFFFFu
#define HG_SINK_SIG2_VAL   0x7940202Bu   // ldrh w11, [x1, #0x10]

static void (*g_sinkConsumeOrig)(void *, void *, float, float) = NULL;
static _Atomic int      g_sinkInstalled = 0;
static _Atomic int      g_sinkCalls = 0;
static _Atomic uint64_t g_sinkLastLogUs = 0;

// 数据源本体：每帧取两路峰值 → hg_out_feed2，然后透传原实现（见上方数据源块）。
static void hg_sink_consume(void *self, void *buf, float g0, float g1) {
    int n = atomic_fetch_add(&g_sinkCalls, 1) + 1;

    // sink 侧：[+0x20] = 通道数(2)，[+0x24] = 每通道采样数(256)
    int nch = 0, stride = 0;
    if (self) { nch = *(int *)((char *)self + 0x20); stride = *(int *)((char *)self + 0x24); }
    // 缓冲侧：**平面**排布（前 stride 个 = 通道 0 = 左，接着 stride 个 = 通道 1 = 右）
    int bsmp = 0; float *pd = NULL;
    if (buf) {
        bsmp = (int)(*(unsigned short *)((char *)buf + 0x10));
        pd   = *(float **)((char *)buf);
    }

    float pk[2] = {0.0f, 0.0f};
    if (pd && nch >= 1 && nch <= 2 && stride > 0 && stride <= 4096 &&
        (size_t)stride * nch <= (size_t)bsmp) {
        for (int ch = 0; ch < nch; ch++) {
            const float *base = pd + (size_t)ch * stride;
            float m = 0.0f;
            for (int i = 0; i < stride; i++) { float a = fabsf(base[i]); if (a > m) m = a; }
            pk[ch] = m;
        }
    }

    // 原始峰值直接交给输出侧（无定标）
    float vL = pk[0], vR = pk[1];

    uint64_t t = now_us();
    int doLog = (n <= 20 || (t - atomic_load(&g_sinkLastLogUs)) > 1000000ull);
    if (doLog) atomic_store(&g_sinkLastLogUs, t);

    float motor[4] = {0.0f, 0.0f, 0.0f, 0.0f};
    hg_out_feed2(vL, vR, t, motor);             // ★ 交给输出侧（双通道 → 4 马达）

    if (doLog)
        rlog("[SINK] #%d 通道=%d 每通道采样=%d | 原始峰值=%.4f %.4f"
             " | 马达 左握=%.3f 右握=%.3f 左扳=%.3f 右扳=%.3f",
             n, nch, stride, pk[0], pk[1],
             motor[0], motor[1], motor[2], motor[3]);

    if (g_sinkConsumeOrig) g_sinkConsumeOrig(self, buf, g0, g1);
}

// 在 __DATA_CONST / __DATA 里找指向 `target` 的 8 字节指针，返回该槽地址（找不到 NULL）。
static void *hg_find_pointer_slot(void *base, uintptr_t target) {
    const struct mach_header_64 *h = (const struct mach_header_64 *)base;
    if (h->magic != MH_MAGIC_64) return NULL;
    const unsigned char *p = (const unsigned char *)base + sizeof(struct mach_header_64);
    const unsigned char *end = p + h->sizeofcmds;
    for (uint32_t i = 0; i < h->ncmds && p + sizeof(struct load_command) <= end; i++) {
        const struct load_command *lc = (const struct load_command *)p;
        if (lc->cmdsize < sizeof(struct load_command) || p + lc->cmdsize > end) break;
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *sg = (const struct segment_command_64 *)lc;
            if (strncmp(sg->segname, "__DATA_CONST", sizeof(sg->segname)) == 0 ||
                strncmp(sg->segname, "__DATA",       sizeof(sg->segname)) == 0) {
                uintptr_t *w = (uintptr_t *)((uintptr_t)base + sg->vmaddr);
                size_t n = (size_t)(sg->vmsize / sizeof(uintptr_t));
                for (size_t k = 0; k < n; k++)
                    if (w[k] == target) return &w[k];
            }
        }
        p += lc->cmdsize;
    }
    return NULL;
}

static void hg_sink_probe_install(void) {
    if (atomic_load(&g_sinkInstalled)) return;
    void *base = EndfieldRuntimeImageBase();
    if (base == NULL) return;                       // UnityFramework 还没加载 → 下个 tick 再试

    // ① 按指令签名在 __text 里找 Consume（不硬编码 ⇒ 双版本 / 更新都不用改常量）
    static const uint32_t masks[3]  = { HG_SINK_SIG0_MASK, HG_SINK_SIG1_MASK, HG_SINK_SIG2_MASK };
    static const uint32_t values[3] = { HG_SINK_SIG0_VAL,  HG_SINK_SIG1_VAL,  HG_SINK_SIG2_VAL  };
    void *consume = EndfieldRuntimeScanText(masks, values, 3);
    if (consume == NULL) {
        rlog("[SINK] !! 没找到 Consume 签名（版本变了？）—— 不挂，静默");
        atomic_store(&g_sinkInstalled, 1);          // 图像已加载，找不到就是不匹配 → 不重试
        return;
    }

    // ② 在数据段里找指向它的 8 字节指针 = vtable 槽
    void **slot = (void **)hg_find_pointer_slot(base, (uintptr_t)consume);
    if (slot == NULL) {
        rlog("[SINK] !! 找到 Consume %p 但没有指向它的 vtable 槽 —— 不挂", consume);
        atomic_store(&g_sinkInstalled, 1);
        return;
    }

    g_sinkConsumeOrig = (void (*)(void *, void *, float, float))consume;
    void *repl = (void *)hg_sink_consume;
    if (!EndfieldRuntimeWriteMemory(slot, &repl, sizeof(repl))) {
        rlog("[SINK] !! 改写 vtable 槽 %p 失败", (void *)slot);
        return;
    }
    atomic_store(&g_sinkInstalled, 1);
    rlog("[SINK] ★ 已挂 sink Consume（函数 %p，槽 %p）—— 数据源：两路 → 4 马达",
         consume, (void *)slot);
}

#pragma mark - 对外接口（签名保持不变：haptics_out.m / haptics_main.m 依赖）

void hg_fix_tick(void) {
    hg_gate_install();                          // 门①（幂等；类晚加载时补装）
    hg_sink_probe_install();                    // ★ 数据源：sink Consume（幂等）
    // 调参走代码接口 hg_haptics_set(key, value)，无控制文件（STATE §103）。
}

// A1 钩子内调用（haptics_out.m）：现场记录 controllers() 数量。
void hg_fix_on_a1(id engine, int idx) {
    (void)engine;
    @try {
        id arr = hg_really_controllers();
        rlog("[CTRL] A1 #%d 时 controllers().count=%lu", idx,
             (unsigned long)(arr ? [arr count] : 0));
    } @catch (NSException *ex) { (void)ex; }
}

void hg_fix_install(void) {
    rlog("[门] 安装：门①（GCController.playerIndex → 0）+ 数据源（AkMotionSink::Consume 两路）"
         "—— 旧的 P1/P2 内存补丁、retrigger、Rewired 接管 均已删除；sink 钩子在 tick 里懒装");
    hg_gate_install();
}
