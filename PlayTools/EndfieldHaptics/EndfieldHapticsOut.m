//
//  haptics_out.m —— 【③ 震动输出】4 马达分发 + 分配/强度调整（macOS CoreHaptics × Xbox 布局）
//
//  ══════════════════════════════════════════════════════════════════════════
//  震动输出那一块（数据源在 haptics_fix.m 的「数据源」一节）。
//
//    【③ 输出·分配 + 强度】（本文件 + hg_map.h）
//       分配：**sink 的两路**（左/右）→ 4 个 locality（各自慢变→握把 / 瞬态→扳机）
//       强度：最低强度线性拉伸 out = minPct + v*(1-minPct)（只抬非零）
//       调整：全部参数运行时可控（代码接口 `hg_haptics_set(key, value)`），立即生效
//  ══════════════════════════════════════════════════════════════════════════
//
//  管线：
//    A1  swizzle -[GCDeviceHaptics createEngineWithLocality:] → 为 4 个 locality 各建引擎
//    A2  swizzle -[CHHapticEngine createPlayerWithPattern:error:]（+Advanced）→ 拿到 player 具体类
//    A3  在该具体类上挂 -[sendParameters:atTime:error:] → 清零后调原实现（**官方那一路静音**）
//    数据源：`AkMotionSink::Consume` 的两路（haptics_fix.m）→ hg_out_feed2 → 我们的 4 个马达
//
//  分配映射（★ 实现 = `hg_map.h` 的纯函数 `hg_map_step2`，与离线工具共用同一份源码）：
//    ch0 低频/strong → LeftHandle、ch1 高频/weak → RightHandle（业界共识）；
//    每路各自慢变(8Hz LP) → 握把、瞬态(残差≥0.15、去抖150ms) → 该侧扳机脉冲。
//    ★ 参数（split / minPct / lphz / trigth / trigcd / pulsedecay / gripbleed）
//      由 `hg_haptics_set(<键>, <值>)` 运行时改（双缓冲原子发布，音频线程零锁读）；
//      默认值 = `hg_map_defaults()`。**没有控制文件、没有脚本。**
//
//  线程约束：A3 与 sink 的 Consume 都在音频线程 → 日志走环形缓冲（haptics_log.h），本文件不分配/不阻塞。
//  ⚠️ 门①（playerIndex→0）与数据源都在 haptics_fix.m —— 不要与本文件的"输出/分配"混写。
//
#import "EndfieldHapticsOut.h"
#import "EndfieldHapticsFix.h"      // A1 时通知修复侧（记录 controllers()）
#import "EndfieldHapticsLog.h"
#include "EndfieldHapticsMap.h"          // ★ 分配映射【纯函数】—— 与离线工具共用同一份源码（防漂移）

#import <objc/runtime.h>
#import <objc/message.h>
#import <dispatch/dispatch.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <time.h>
#include <sys/time.h>

#import <CoreHaptics/CoreHaptics.h>
#import <CoreHaptics/CHHapticEvent.h>
#import <CoreHaptics/CHHapticPattern.h>
#import <CoreHaptics/CHHapticParameter.h>
// 注意：不 import GameController —— 它的 GCEventViewController 在 macCatalyst 下
// 会拉进不可用的 NSViewController。我们只需要 GCDeviceHaptics 的选择器，
// 用 NSClassFromString + 字符串字面量即可，不需要头文件。

#pragma mark - 输出侧状态与参数

// ★ 默认阶段 1（4 马达分发）；阶段 0（只记录）已完成。默认值写在代码里，构造期由主控传入。
//   （launchctl setenv 传环境变量需要 GUI 会话，设不上 —— 见 STATE §10.3。）
static int g_stage = 1;
// ★ 隔离开关（Bool）：1=官方静音+我们 4 马达接管（默认）；0=官方直通（A/B 对比基线）
//   运行时可切：`hg_haptics_set("isolate", 0)` = 官方直通
static _Atomic int g_isolate = 1;
// 官方直通时"我们的 player 已释放"标志（避免音频线程每帧都去 release）
static _Atomic int g_releasedForOfficial = 0;
// ★ 心跳用：新数据源（sink Consume 两路）累计帧数 —— `hg_out_batches()` 返回它
//   （A3 只做"官方静音"，不再是数据源，因此不计数。）
static _Atomic int g_feedBatches = 0;
// ★ 最后一批到达时刻（微秒）—— 供心跳判断"上游已静默多久"，用于强制结算未闭合的段
static _Atomic uint64_t g_lastBatchUs = 0;
// ★ 我们当前给马达发的是不是非零值 —— 供"上游停发 ⇒ 排空"判断用
//   （4 个 player 是**无限时长**事件：只要不发新值，马达就一直保持上一个值。
//    而 sink 的 Consume 在 motion 总线空闲时**根本不会被调用** ⇒ 不处理就会一直震。）
static _Atomic int g_motorsLive = 0;
// ★ 最后一次**真帧**（来自 sink 的 Consume）的时刻 —— 排空器据此判断"事件是不是又回来了"。
//   ⚠️ 排空器自己喂的 0 **不算**真帧（所以它走 hg_feed_frame 而不是 hg_out_feed2）。
static _Atomic uint64_t g_lastRealFeedUs = 0;
// ★ 分配映射参数（split / minPct / lp_hz / trig_th / trig_cd / pulse_decay / grip_bleed）
//   → 在 hg_map.h 的 hg_map_params 里；由 `hg_haptics_set(key, value)` 改，双缓冲【原子发布】
//     （见下方 g_pbuf/g_pidx）—— **没有控制文件**。

// ── [EVT] 段统计：hg_out_feed2（音频线程）写、主控（drain）结算 ──
//   用原子标志互斥，双方忙则跳过；宁可少一行也不抢锁。
static double evStart = 0, evLast = 0, evSum = 0;
static float  evPeak = 0, evPeakH = 0, evPeakT = 0;
static int    evBatches = 0, evEndRun = 0;
static _Atomic int evBusy = 0;

// ★ 最低输出强度：线性拉伸 out = minPct + v*(1-minPct)，v 取【官方原始值】
//   （把有效区间 [0,1] 压缩映射到 [minPct,1] ⇒ 弱事件也能被感知）
//   ⚠️ 只对【非零】信号生效；v=0 仍输出 0，否则马达会一直嗡（"进游戏常震"旧 bug）。
// ★★ 已去掉归一化，只保留「分配 + 最低强度拉伸」；minPct 定档 0.30（STATE §94）。
//
// ★★★ 参数**不再硬编码**：由 `hg_haptics_set(key, value)` 运行时改，立即生效。
//   例：`hg_haptics_set("minpct", 0.35)` → 同一局里连切 N 个值对比，无需重编/重启。
//
//   ── 无锁发布（音频线程读取只花一次原子 load）──
//   双缓冲 + 原子索引：写者（主控线程）填【非当前】那块，填完再原子发布索引；
//   读者（音频线程）只做 `load acquire` + 取指针，无锁、无分配、无重试循环。
//   ⚠️ 不用 `_Atomic hg_map_params`：C11 对大结构体的原子访问可能落到 libatomic 的
//      内部锁上 —— 那正是音频线程绝对不能碰的东西。
static hg_map_params          g_pbuf[2];
static _Atomic(uintptr_t)     g_pidx = 0;      // 当前生效的是 g_pbuf[g_pidx]
static hg_map_state           g_mstate;        // ★ 只被音频线程读写（与改造前 hg_fanout 同一假设）

// 取当前生效参数（音频线程用；一次 acquire load + 一次取地址）
static inline const hg_map_params *hg_params_now(void) {
    return &g_pbuf[atomic_load_explicit(&g_pidx, memory_order_acquire)];
}

#pragma mark - 4 个 locality 引擎 / player

static id g_ourEng[4];   // Left/Right Handle + Left/Right Trigger
static id g_ourPl[4];
static NSString *g_locName[4];
static int g_ourCount = 0;

// ★★ 2 马达回退：本手柄是否【没有】扳机 locality（只有握把）。
//   由 hg_rebuild_engines（每次 A1，主线程）检测并原子发布；为 1 时 hg_out_feed2（音频线程）
//   把输出强制为【纯路由】—— 两握把拿完整包络。
//   原因：split 下「瞬态→扳机」那两路会被丢弃（只发 g_ourCount 路），握把只剩慢变 ⇒ 更弱。
//   详见 topics/03-输出-分配与强度.md §4.9。
static _Atomic int g_noTriggers = 0;

static id    g_paramPool[4];         // 预分配的动态参数（value 可变，零音频线程分配）
static id    g_paramArr[4];          // 预包装的单参数数组

static double g_durInf = INFINITY; // 事件时长 +Inf：窗口 [0,∞) 永不失效（不 start 则 sendParameters 静默 no-op）

#pragma mark - 停引擎（游戏旧引擎 / 我们的引擎通用）

// 停掉一个引擎。【静默】—— 调用方汇总成一行（原来每个引擎打一行，日志太吵）
static BOOL hg_stop_engine(id eng) {
    if (!eng) return NO;
    @try {
        SEL s1 = sel_registerName("stopWithCompletionHandler:");
        SEL s2 = sel_registerName("stopAtTime:error:");
        if (((BOOL (*)(id, SEL, SEL))objc_msgSend)(eng, sel_registerName("respondsToSelector:"), s1)) {
            ((void (*)(id, SEL, void *))objc_msgSend)(eng, s1, NULL);
            return YES;
        }
        if (((BOOL (*)(id, SEL, SEL))objc_msgSend)(eng, sel_registerName("respondsToSelector:"), s2)) {
            NSError *e = nil;
            return ((BOOL (*)(id, SEL, double, NSError **))objc_msgSend)(eng, s2, 0.0, &e);
        }
    } @catch (NSException *ex) { (void)ex; }
    return NO;
}

#pragma mark - A1: -[GCDeviceHaptics createEngineWithLocality:]

static void hg_rebuild_engines(id haptics);   // 前向声明（本区块之后定义）

// ★ 三个被 swizzle 方法的【原实现】—— 内部调用必须走它们，绝不能再走 objc_msgSend
//   （否则重新进入我们自己的钩子 → 无限递归）
static IMP g_origCreateEngine = NULL;   // -[GCDeviceHaptics createEngineWithLocality:]
static IMP g_origCreatePlayer = NULL;   // -[CHHapticEngine createPlayerWithPattern:error:]
// ★ 每个被 swizzle 的类各存一份原 IMP —— 不能共用一个全局！
//   （若同时挂 PatternPlayer 与 AdvancedPatternPlayer，共用会互相覆盖 → 调错实现/爆栈）
#define SWMAX 8
static Class g_swCls[SWMAX];
static IMP   g_swOrig[SWMAX];
static int   g_swN = 0;
static IMP   g_origSendParams = NULL;   // 兜底：最后一次挂的原 IMP
static IMP orig_send_for(id obj) {
    Class c = object_getClass(obj);
    for (int i = 0; i < g_swN; i++) if (g_swCls[i] == c) return g_swOrig[i];
    return g_origSendParams;
}
// 重入保护
static _Atomic int g_in_a2 = 0;
static _Atomic int g_in_a3 = 0;

static _Atomic int g_a1n = 0;   // A1 累计计数（日志序号；修复侧台账也用它）

static id hg_createEngineWithLocality(id self, SEL _cmd, NSString *locality) {
    id engine = ((id (*)(id, SEL, id))g_origCreateEngine)(self, _cmd, locality);
    int idx = atomic_fetch_add(&g_a1n, 1) + 1;

    // ⚠️ 不要在这里"每个 A1 后都 re-arm 开窗"（历史方案 A′，已回退）——
    //    会让游戏在加载期连续处于"没有手柄"状态 → 【登录界面手柄失效】。
    //    注意区分：被否掉的是「每个 A1 都开窗」，不是「启动后开一次窗」。
    //    详见 topics/05-错误记忆.md §2.2。

    rlog("[A1 #%d] createEngineWithLocality: %s  -> engine=%p",
         idx, locality ? [locality UTF8String] : "(nil)", engine);

    // ★★ 修复侧在 A1 时的动作（A1 计时 / 消费"停旧引擎"请求 / 引擎台账与诊断日志）
    hg_fix_on_a1(engine, idx);

    hg_rebuild_engines(self);   // ★ 输出侧：顺手建 4 个 locality 引擎
    return engine;
}

#pragma mark - 阶段 1：把同一包络分发给 4 个 locality 的引擎

// ── 4 路分发（上游 Wwise 已整形 → 直读直发，不加门控/滤波）──
// ★★ 【不设任何增益】：输出 = 线性拉伸后的 pct，四马达同值。
//    （旧的 master/握把/扳机增益与"扳机行程调制"已删 —— 会钳平包络层次、与纯路由冲突。）

// 在 A1 里调用：**重建**我们的 4 个 locality 引擎（跟随游戏生命周期，不搞"建一次用到底"）
static void hg_rebuild_engines(id haptics) {
    if (g_stage < 1) return;
    // 先放掉旧的（player 依赖引擎，一并放）
    // ★ 必须【stop 之后再 release】—— 否则引擎会一直占着设备（以前只 release 不 stop）。
    {
        uint64_t t0 = now_us();
        int n = g_ourCount;
        for (int i = 0; i < g_ourCount; i++) {
            if (g_ourPl[i])  { [g_ourPl[i]  release]; g_ourPl[i]  = nil; }
            if (g_ourEng[i]) { hg_stop_engine(g_ourEng[i]); [g_ourEng[i] release]; g_ourEng[i] = nil; }
        }
        if (n) rlog("[B] 停我们的 %d 个引擎耗时 %.1f ms", n, (now_us() - t0) / 1000.0);
    }
    g_ourCount = 0;

    // ★ 诊断：本手柄实际支持的 locality（Apple 文档要求据此判断）
    //   只在【内容变化时】打 —— 避免每次 A1 都刷一整行超长列表
    id sup = ((id (*)(id, SEL))objc_msgSend)(haptics, sel_registerName("supportedLocalities"));
    char flat[160];
    hg_flat(flat, sizeof flat, sup ? [sup description] : nil);
    {
        static char lastLoc[160] = {0};
        if (strcmp(lastLoc, flat) != 0) {
            rlog("[S1] localities: %s", flat);
            snprintf(lastLoc, sizeof lastLoc, "%s", flat);
        }
    }

    NSString *want[4] = { @"Left Handle", @"Right Handle", @"Left Trigger", @"Right Trigger" };
    // ★ 自适应：独立 Left/Right Handle 不在支持列表 → 回退合并 "Handles"
    //   （两握把通道同值时合并无损；参考 Ebiten 先查 supportedLocalities 的做法）
    if ([sup isKindOfClass:[NSSet class]] || [sup isKindOfClass:[NSArray class]]) {
        BOOL hasLH = [sup containsObject: @"Left Handle"];
        BOOL hasRH = [sup containsObject: @"Right Handle"];
        BOOL hasH  = [sup containsObject: @"Handles"];
        if (!hasLH && !hasRH && hasH) {
            want[0] = @"Handles"; want[1] = @"Handles";
            rlog("[S1] 独立握把 locality 不支持 → 两握把通道回退 Handles");
        }
    }
    BOOL gotTrig[2] = { NO, NO };            // i=2/3 → 左/右扳机是否建成
    for (int i = 0; i < 4; i++) {
        // ★ 走原实现（createEngineWithLocality: 已被 swizzle）
        id e = ((id (*)(id, SEL, id))g_origCreateEngine)(haptics, sel_registerName("createEngineWithLocality:"), want[i]);
        if (e) {
            g_ourEng[g_ourCount] = [e retain];
            g_locName[g_ourCount] = [want[i] retain];
            if (i >= 2) gotTrig[i - 2] = YES;
            g_ourCount++;
        } else {
            rlog("[S1] 引擎创建失败: %s", [want[i] UTF8String]);
        }
    }
    rlog("[S1] 重建 %d 个 locality 引擎", g_ourCount);

    // ★★ 2 马达回退：扳机 locality 缺任一 ⇒ 强制纯路由，让两握把拿完整包络
    //   （split 的瞬态两路会白丢 ⇒ 反而更弱；详见 g_noTriggers 处说明）。
    //   只在【状态变化时】打日志（否则每次 A1 都刷屏）。
    {
        int noTrig = !(gotTrig[0] && gotTrig[1]);
        static int lastNoTrig = -1;
        if (noTrig != lastNoTrig) {
            rlog("[S1] 扳机 locality %s → 输出%s",
                 noTrig ? "缺失（2 马达手柄）" : "齐备（4 马达）",
                 noTrig ? "自动回退【纯路由】：两握把同值、拿完整包络（split 参数被忽略）"
                        : "按 split 参数分配（慢变→握把 / 瞬态→扳机）");
            lastNoTrig = noTrig;
        }
        atomic_store(&g_noTriggers, noTrig);
    }
}

// 惰性创建第 i 个 player（创建后立即 start —— 不 start 则 sendParameters 静默无效）
static bool hg_create_player(int i) {
    if (g_ourPl[i] || !g_ourEng[i]) return true;
    @try {
        NSError *err = nil;
        // 引擎必须先 start（idempotent）
        BOOL sok = ((BOOL (*)(id, SEL, NSError **))objc_msgSend)
                    (g_ourEng[i], sel_registerName("startAndReturnError:"), &err);
        if (!sok) { rlog("[S2] 引擎启动失败 %d: %s", i, err ? [[err description] UTF8String] : "-"); return false; }
        // ★ 对齐演示器（尽力而为：旗标失败只跳过，绝不阻断 player 创建）
        //   注意：isAutoShutdownEnabled 的 ObjC setter 是 setAutoShutdownEnabled:（getter 才带 is-）
        @try {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(g_ourEng[i], sel_registerName("setPlaysHapticsOnly:"), YES);
            ((void (*)(id, SEL, BOOL))objc_msgSend)(g_ourEng[i], sel_registerName("setAutoShutdownEnabled:"), NO);
        } @catch (NSException *ex) {
            rlog("[S2] 旗标跳过 %d: %s", i, [[ex name] UTF8String]);
        }

        CHHapticEventParameter *ep =
            [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticIntensity
                                                          value:1.0];
        CHHapticEventParameter *sp =
            [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticSharpness
                                                          value:0.3];
        CHHapticEvent *ev =
            [[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticContinuous
                                          parameters:@[ep, sp]
                                        relativeTime:0
                                            duration:(double)g_durInf];
        CHHapticPattern *pat = [[CHHapticPattern alloc] initWithEvents:@[ev]
                                                            parameters:@[]
                                                                error:&err];
        // ★ 走原实现（该方法已被 swizzle）
        id pl = ((id (*)(id, SEL, id, NSError **))g_origCreatePlayer)
                    (g_ourEng[i], sel_registerName("createPlayerWithPattern:error:"), pat, &err);
        if (!pl) { rlog("[S2] player 创建失败 %d: %s", i, err ? [[err description] UTF8String] : "-"); return false; }
        g_ourPl[i] = [pl retain];
        // ★ 必须 start：CoreHaptics 的 player 不 start 就不播（sendParameters 静默 no-op）
        //   0.0 = CHHapticTimeImmediate（与游戏 sendParameters 的 t=0 同语义，立即生效）
        BOOL stok = ((BOOL (*)(id, SEL, double, NSError **))objc_msgSend)
                    (pl, sel_registerName("startAtTime:error:"), 0.0, &err);
        rlog("[S2] %s player 创建%s", [g_locName[i] UTF8String], stok ? "+start ✓" : "+start ✗");
        return true;
    } @catch (NSException *ex) {
        rlog("[S2] 例外 %d: %s", i, [[ex reason] UTF8String]);
        return false;
    }
}

static void hg_release_players(void);   // 前置声明（定义在本区块之后）

// ── ★★ 分配映射（双通道）：sink 两路 → 4 个 locality（Xbox 布局）──────────
//    ch0 低频/strong → LeftHandle、ch1 高频/weak → RightHandle；瞬态 → 各自扳机。
//    映射实现在 `hg_map.h` 的 `hg_map_step2`（纯函数，与离线工具共用同一份源码）；
//    参数由 `hg_haptics_set(key, value)` 运行时驱动。
//    ⚠️ A3 不再是数据源 —— 只做"官方那一路静音"（见 hg_sendParameters）。
//    数据源与业界依据见 topics/07-...signal-sources.md §8、topics/08-...prior-art.md §五。

// ── 核心：跑一次映射 + 发给 4 个马达（sink 帧与"排空器"共用）────────────────
//   ⚠️ **不碰任何"上游状态"**（g_lastBatchUs / g_lastRealFeedUs / 心跳计数）——
//      这样排空器也能按帧率复用它喂 0，而不会被误判成"上游又来数据了"。
//   vL / vR = 左/右通道的原始值（**不定标**）；t_us = 本帧时刻（微秒墙钟）
static void hg_feed_frame(float vL, float vR, uint64_t t_us, float motorOut[4]) {
    // ★ 参数快照：一次 acquire load 拿指针（主控线程每 150ms 可能换另一块缓冲）
    const hg_map_params *prm = hg_params_now();

    // ★★ 2 马达回退：无扳机 locality 时强制【纯路由】（split=0），
    //   否则瞬态那两路（motor[2]/[3]）算出来却发不出去（只发 g_ourCount 路）→ 白丢。
    hg_map_params eff = *prm;
    if (atomic_load_explicit(&g_noTriggers, memory_order_relaxed)) eff.split = 0;

    float motor[4];
    hg_map_step2(&g_mstate, &eff, vL, vR, t_us, motor);
    if (motorOut) { for (int i = 0; i < 4; i++) motorOut[i] = motor[i]; }   // 诊断回填

    // ── [EVT] 段统计：左右输入峰值 + 四马达峰值 ──
    //   结算三条路径（与旧一致）：① 连续 12 批静音 ② 稀疏流隔 >1s ③ 心跳强结（静默 >1.2s）
    float vpk = vL > vR ? vL : vR;
    if (!atomic_exchange(&evBusy, 1)) {
        struct timeval tv; gettimeofday(&tv, NULL);
        double now = tv.tv_sec + tv.tv_usec / 1e6;
        if (vpk >= 0.02f) {
            if (evBatches > 0 && now - evLast >= 1.0) {   // 稀疏流：隔 >1s 先切段
                char tbuf[16]; time_t sec = (time_t)evStart;
                struct tm tmr; localtime_r(&sec, &tmr);
                strftime(tbuf, sizeof tbuf, "%H:%M:%S", &tmr);
                rlog("[EVT] 起点%s len=%.2fs 输入峰=%.2f 均=%.2f 批数=%d 握把峰=%.2f 扳机峰=%.2f [gap切段]",
                     tbuf, evLast - evStart, evPeak, evSum / evBatches, evBatches, evPeakH, evPeakT);
                evBatches = 0; evEndRun = 0;
            }
            if (evBatches == 0) { evStart = now; evPeak = 0; evSum = 0; evPeakH = 0; evPeakT = 0; }
            if (vpk > evPeak) evPeak = vpk;
            if (motor[0] > evPeakH) evPeakH = motor[0];
            if (motor[1] > evPeakH) evPeakH = motor[1];
            // 无扳机 locality 时 motor[2]/[3] 是纯路由复制值、并非真的发给了扳机 → 不记扳机峰
            if (!atomic_load_explicit(&g_noTriggers, memory_order_relaxed)) {
                if (motor[2] > evPeakT) evPeakT = motor[2];
                if (motor[3] > evPeakT) evPeakT = motor[3];
            }
            evSum += vpk; evBatches++;
            evEndRun = 0;
            evLast = now;
        } else if (evBatches > 0) {
            if (++evEndRun >= 12) {   // 连续 ~128ms 静音 → 段结算
                char tbuf[16]; time_t sec = (time_t)evStart;
                struct tm tmr; localtime_r(&sec, &tmr);
                strftime(tbuf, sizeof tbuf, "%H:%M:%S", &tmr);
                rlog("[EVT] 起点%s len=%.2fs 输入峰=%.2f 均=%.2f 批数=%d 握把峰=%.2f 扳机峰=%.2f",
                     tbuf, now - evStart, evPeak, evSum / evBatches, evBatches, evPeakH, evPeakT);
                evBatches = 0;
            }
        }
        atomic_store(&evBusy, 0);
    }

    // 惰性建 player（无限时长事件，永不过期）→ 直发（t=0 = 立即）
    int anyLive = 0;
    for (int i = 0; i < g_ourCount; i++) {
        if (motor[i] > 0.0f) anyLive = 1;
        if (!g_ourPl[i] && !hg_create_player(i)) continue;
        ((void (*)(id, SEL, float))objc_msgSend)(g_paramPool[i], sel_registerName("setValue:"), motor[i]);
        ((BOOL (*)(id, SEL, NSArray *, NSTimeInterval, NSError **))orig_send_for(g_ourPl[i]))
            (g_ourPl[i], sel_registerName("sendParameters:atTime:error:"), g_paramArr[i], 0.0, NULL);
    }
    atomic_store(&g_motorsLive, anyLive);
}

// ── hg_feed_frame 的互斥：音频线程（真帧）与排空线程都可能进来 ──────────────
//   · 真帧**一定要发**：抢不到就自旋等（本函数本来就在做 ObjC/CoreHaptics，
//     不是实时安全的；这里给它足量自旋，宁可等一下也不丢帧）。
//   · 排空帧**可以让**：抢不到就跳过本 tick，下一 tick 再来（真帧优先）。
static _Atomic int g_feedBusy = 0;

static inline int hg_feed_trylock(void) {
    int expect = 0;
    return atomic_compare_exchange_strong_explicit(&g_feedBusy, &expect, 1,
                                                   memory_order_acquire, memory_order_relaxed);
}
static inline void hg_feed_lock_wait(void) {
    for (int i = 0; i < 200000; i++) { if (hg_feed_trylock()) return; }
    // 极端超时：仍然发（宁可轻微竞态，也不丢一帧真数据）
}
static inline void hg_feed_unlock(void) { atomic_store_explicit(&g_feedBusy, 0, memory_order_release); }

// ── 新数据源入口：sink 的两路 → 我们的 4 马达 ────────────────────────────
//   ⚠️ 音频线程调用：无分配、无锁（参数走双缓冲 acquire load）。
void hg_out_feed2(float vL, float vR, uint64_t t_us, float motorOut[4]) {
    if (g_stage < 1) return;
    if (!g_isolate) {                                   // 官方直通模式：我们的马达静默
        // 只在【切入官方直通那一刻】释放一次 player，别每帧都动 ObjC（音频线程）
        static _Atomic int released = 0;
        if (!atomic_exchange(&released, 1)) hg_release_players();
        return;
    }
    atomic_store(&g_releasedForOfficial, 0);      // 切回我们接管 → 下次切入时再释放

    atomic_fetch_add(&g_feedBatches, 1);          // 心跳计数（新数据源）
    atomic_store(&g_lastBatchUs, t_us);
    atomic_store(&g_lastRealFeedUs, t_us);        // ★ 真帧标记（排空器据此判断"事件回来了"）

    hg_feed_lock_wait();
    hg_feed_frame(vL, vR, t_us, motorOut);
    hg_feed_unlock();
}

#pragma mark - 排空器（drain）：上游停发后按 map 帧率继续喂 0，让脉冲自然收尾

//   ★ 修「震动不停」的做法：player 是**无限时长**事件 ⇒ 不发新值就保持上一个值；而 sink 的
//     Consume 在 motion 总线空闲时**根本不会被调用** ⇒ 上游一停，脉冲衰减就"冻住"。
//     直接发一个 0 是**硬砍**；这里改为排空器以 HG_MAP_DT_SEC 为周期持续喂 0，直到 map 状态
//     自然归零 —— 与"上游一直喂 0"等价，收尾形状一致。
//
//   ★★ "上游静默多久算结束" = **对齐官方**：官方 AkMotionSink 自己就是 0.1s（有数据就续期，
//     静默满 0.1s 就 stop）。⇒ 我们也用 0.1s。
//     详见 haptics/STATE.md §104、haptics/memory/topics/07-endfield-haptics-signal-sources.md §9。
//   ⚠️ 实际生效时刻 = 本阈值 + 主控 tick 粒度（150ms）⇒ 落在 100~250ms。
//   ⚠️ 启动只在主控线程（hg_out_idle_tick），停止只在排空线程（handler）；
//      原子标志 g_draining 保证 resume/suspend 严格配对。
#define HG_IDLE_END_US  100000ull        // 0.1s（官方同值）

static dispatch_source_t g_drainTimer = nil;
static _Atomic int       g_draining   = 0;

static void hg_drain_stop(void);

static dispatch_source_t hg_drain_timer(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dispatch_queue_t q = dispatch_queue_create("playcover.endfield.haptics.drain", DISPATCH_QUEUE_SERIAL);
        g_drainTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
        uint64_t interval = (uint64_t)(HG_MAP_DT_SEC * 1000000000.0f);   // 与 map 帧率一致（≈10.67ms）
        dispatch_source_set_timer(g_drainTimer, DISPATCH_TIME_NOW, interval, 0);
        dispatch_source_set_event_handler(g_drainTimer, ^{
            if (!atomic_load(&g_draining)) return;                       // 已停（可能还有一次排队的回调）
            if (!g_isolate) { hg_drain_stop(); return; }                 // 切到官方直通 ⇒ 收工
            uint64_t now = now_us();
            if (now - atomic_load(&g_lastRealFeedUs) < 30000ull) {       // 真帧又来了 ⇒ 交回 sink
                hg_drain_stop(); return;
            }
            if (!hg_feed_trylock()) return;                              // 真帧正在发 ⇒ 本 tick 让路
            hg_feed_frame(0.0f, 0.0f, now, NULL);                        // 喂一帧 0 ⇒ 脉冲继续衰减
            hg_feed_unlock();
            if (!atomic_load(&g_motorsLive)) hg_drain_stop();            // 4 马达已全 0 ⇒ 收工
        });
        // 注意：dispatch_source_create 返回的是**已挂起**的 source，
        //       首次 dispatch_resume 由 hg_drain_start 负责。
    });
    return g_drainTimer;
}

static void hg_drain_start(void) {
    if (atomic_exchange(&g_draining, 1)) return;          // 已在排空
    dispatch_resume(hg_drain_timer());
    rlog("[OUT] 上游停发 → 按帧率排空（脉冲自然收尾）");
}

static void hg_drain_stop(void) {
    if (!atomic_exchange(&g_draining, 0)) return;         // 没在排空
    dispatch_suspend(hg_drain_timer());
    rlog("[OUT] 排空结束（脉冲已自然归零）");
}

// ★ 主控线程每 tick 调用：上游静默 ≥ HG_IDLE_END_US（0.1s，对齐官方）且马达还亮着 ⇒ 启动排空器。
//   （0.1s ≫ 帧间隔 ~10.7ms ≈ 9 帧 ⇒ 只有"事件真的结束"才会触发。）
void hg_out_idle_tick(void) {
    if (g_stage < 1 || !g_isolate) return;
    uint64_t lb = atomic_load(&g_lastBatchUs);
    if (!lb || (now_us() - lb) < HG_IDLE_END_US) return;  // 还在流（帧间隔约 10.7ms）
    if (!atomic_load(&g_motorsLive)) return;              // 已经静了
    hg_drain_start();
}

// offset/官方直通：停止并释放全部 player
static void hg_release_players(void) {
    for (int i = 0; i < g_ourCount; i++) {
        if (!g_ourPl[i]) continue;
        NSError *err = nil;
        ((BOOL (*)(id, SEL, double, NSError **))objc_msgSend)
            (g_ourPl[i], sel_registerName("stopAtTime:error:"), 0.0, &err);
        [g_ourPl[i] release]; g_ourPl[i] = nil;
    }
}

// LT/RT 实时行程读取与扳机行程调制已随增益一并删除。

#pragma mark - A3: -[sendParameters:atTime:error:]（在具体类上 swizzle）

static BOOL hg_sendParameters(id self, SEL _cmd, NSArray *params,
                              NSTimeInterval t, NSError **err) {
    // ★ 重入保护：我们自己的 player 走原实现，不会进到这里；万一重入直接透传。
    if (atomic_load(&g_in_a3))
        return ((BOOL (*)(id, SEL, NSArray *, NSTimeInterval, NSError **))orig_send_for(self))
                   (self, _cmd, params, t, err);
    atomic_store(&g_in_a3, 1);
    NSUInteger n = [params count];
    // ★★ 全量记录官方送来的每一批震动数据：逐批、逐个参数（parameterID / value /
    //    relativeTime）连同 atTime: 一起记。
    static _Atomic int cnt = 0;
    int idx = atomic_fetch_add(&cnt, 1) + 1;
    {
        NSUInteger k = n < 8 ? n : 8;            // 上限 8（与静音分支一致）
        char lbuf[512];
        int off = snprintf(lbuf, sizeof lbuf, "[A3 #%d] atTime=%.6f n=%lu",
                           idx, t, (unsigned long)n);
        for (NSUInteger i = 0; i < k; i++) {
            id p = [params objectAtIndex:i];
            float pv  = ((float (*)(id, SEL))objc_msgSend)(p, sel_registerName("value"));
            double pr = ((double (*)(id, SEL))objc_msgSend)(p, sel_registerName("relativeTime"));
            // ★ 参数 ID：CoreHaptics 的 locality 在【建引擎时】就绑定了，
            //   动态参数只有 HapticIntensityControl 一个维度 —— 若全是它，
            //   则官方在这条通路上【无法表达】左右/分马达差异化。
            id pid = ((id (*)(id, SEL))objc_msgSend)(p, sel_registerName("parameterID"));
            const char *ps = (pid && [(NSString *)pid length]) ? [(NSString *)pid UTF8String] : "?";
            if (off < (int)sizeof lbuf)
                off += snprintf(lbuf + off, sizeof lbuf - off,
                                " | %lu:%s v=%.4f rt=%.6f",
                                (unsigned long)i, ps, pv, pr);
        }
        if (n > k && off < (int)sizeof lbuf)
            off += snprintf(lbuf + off, sizeof lbuf - off,
                            " | ...另有 %lu 个未记", (unsigned long)(n - k));
        rlog("%s", lbuf);
    }
    // ── ★ 屏蔽官方震动（受隔离开关控制）──
    //   隔离=1：官方引擎清零静音，我们的 4 马达接管
    //   隔离=0：官方直通（A/B 对比官方手感）；我们的马达静默
    BOOL r = YES;
    if (g_isolate && n > 0 && n <= 8) {
        float saved[8] = {0};
        id objs[8] = {0};
        for (NSUInteger i = 0; i < n; i++) {
            id p = [params objectAtIndex:i];
            objs[i] = p;
            saved[i] = ((float (*)(id, SEL))objc_msgSend)(p, sel_registerName("value"));
            ((void (*)(id, SEL, float))objc_msgSend)(p, sel_registerName("setValue:"), 0.0f);
        }
        r = ((BOOL (*)(id, SEL, NSArray *, NSTimeInterval, NSError **))orig_send_for(self))
                (self, _cmd, params, t, err);
        for (NSUInteger i = 0; i < n; i++)
            ((void (*)(id, SEL, float))objc_msgSend)(objs[i], sel_registerName("setValue:"), saved[i]);
    } else {
        // 超过 8 个参数：原样透传，不屏蔽
        r = ((BOOL (*)(id, SEL, NSArray *, NSTimeInterval, NSError **))orig_send_for(self))
                (self, _cmd, params, t, err);
    }

    // ★ A3 **不再是数据源** —— 数据从 `AkMotionSink::Consume` 两路进来（见 hg_out_feed2）。
    //   这里只负责把官方那一路清零静音（上面 g_isolate 块已清零并调过原实现）。
    atomic_store(&g_in_a3, 0);
    return r;
}

// 对某个具体类做一次 sendParameters: 的 swizzle（只做一次）
static void swizzle_send_parameters_on(Class cls) {
    static _Atomic(uintptr_t) done[64];
    static _Atomic int dn = 0;
    int cnt = atomic_load(&dn);
    for (int i = 0; i < cnt; i++)
        if (atomic_load(&done[i]) == (uintptr_t)cls) return;   // 已处理

    SEL sel = sel_registerName("sendParameters:atTime:error:");
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) {
        rlog("[A3] 类 %s 没有 sendParameters: → 跳过", class_getName(cls));
        return;
    }
    g_origSendParams = method_getImplementation(m);
    method_setImplementation(m, (IMP)hg_sendParameters);
    if (g_swN < SWMAX) { g_swCls[g_swN] = cls; g_swOrig[g_swN] = g_origSendParams; g_swN++; }
    else rlog("[A3] !! 类表已满，%s 的原 IMP 未登记", class_getName(cls));
    int slot = atomic_fetch_add(&dn, 1);
    if (slot < 64) atomic_store(&done[slot], (uintptr_t)cls);   // ★ 必须登记，防重复 swizzle
    rlog("[A3] 已在类 %s 上挂 sendParameters:（原 IMP=%p）",
         class_getName(cls), (void *)g_origSendParams);
}

#pragma mark - 用 player 的具体类去挂 A3

static id hg_createPlayerWithPattern(id self, SEL _cmd, id pattern, NSError **err) {
    // ★ 重入保护：hg_rebuild_players 内部用原实现建 player，不会进到这里；
    //   但万一有其它路径重入，直接透传原实现，绝不递归。
    if (atomic_load(&g_in_a2))
        return ((id (*)(id, SEL, id, NSError **))g_origCreatePlayer)(self, _cmd, pattern, err);
    atomic_store(&g_in_a2, 1);
    id player = ((id (*)(id, SEL, id, NSError **))g_origCreatePlayer)(self, _cmd, pattern, err);
    if (player) {
        Class cls = object_getClass(player);
        rlog("[A2] createPlayerWithPattern -> player=%p 具体类=%s", player, class_getName(cls));
        swizzle_send_parameters_on(cls);
    } else {
        rlog("[A2] createPlayerWithPattern -> nil (err=%s)",
             err && *err ? [[*err description] UTF8String] : "-");
    }
    atomic_store(&g_in_a2, 0);
    return player;
}

// ★★ A2b：高级播放器 —— 之前"仅记录不挂"，若游戏换用这条路径，
//     我们一条 sendParameters 都收不到（表现为"游戏在震、我们日志全空"）。
static IMP g_origCreateAdvancedPlayer = NULL;
static id hg_createAdvancedPlayerWithPattern(id self, SEL _cmd, id pattern, NSError **err) {
    if (atomic_load(&g_in_a2))
        return ((id (*)(id, SEL, id, NSError **))g_origCreateAdvancedPlayer)(self, _cmd, pattern, err);
    atomic_store(&g_in_a2, 1);
    id player = ((id (*)(id, SEL, id, NSError **))g_origCreateAdvancedPlayer)(self, _cmd, pattern, err);
    if (player) {
        Class cls = object_getClass(player);
        rlog("[A2b] !! createAdvancedPlayerWithPattern -> player=%p 具体类=%s（游戏走了高级路径）",
             player, class_getName(cls));
        swizzle_send_parameters_on(cls);
    } else {
        rlog("[A2b] createAdvancedPlayerWithPattern -> nil (err=%s)",
             err && *err ? [[*err description] UTF8String] : "-");
    }
    atomic_store(&g_in_a2, 0);
    return player;
}

#pragma mark - 控制面（主控线程调用）

// 把一套参数打成一行（[CFG] / [PARAM] 共用，避免格式两处各写一遍）
static void hg_params_line(char *buf, size_t n, const hg_map_params *p) {
    snprintf(buf, n,
             "split=%d minPct=%.3f lpHZ=%.2f trigTh=%.3f trigCd=%.0fms pulseDecay=%.3f gripBleed=%.2f dt=%.6f",
             p->split, p->min_pct, p->lp_hz, p->trig_th,
             (double)p->trig_cd_us / 1000.0, p->pulse_decay, p->grip_bleed, p->dt_s);
}

// ★★ **唯一的运行时控制接口**（PlayCover 可调）：
//     key ∈ split | minpct | lphz | trigth | trigcd | pulsedecay | gripbleed | isolate
//       · isolate = 1 我们接管（默认） / 0 官方直通（我们的马达静默）
//       · 其余键 = 映射参数（钳制见 hg_map_apply_key）
//    ★ 立即生效（双缓冲原子发布）；无需重启游戏、无需任何文件或脚本。
void hg_haptics_set(const char *key, double value) {
    if (key == NULL) return;

    if (!strcmp(key, "isolate")) {
        int on = (value != 0.0);
        atomic_store(&g_isolate, on);
        rlog("[PARAM] isolate=%d（%s）", on, on ? "我们接管" : "官方直通");
        return;
    }

    int cur = (int)atomic_load_explicit(&g_pidx, memory_order_relaxed);
    hg_map_params np = g_pbuf[cur];                     // 以当前生效的为底
    if (!hg_map_apply_key(&np, key, value)) {
        rlog("[PARAM] !! 未知参数键: %s", key);
        return;
    }
    g_pbuf[1 - cur] = np;                               // ① 填【非当前】那块
    atomic_store_explicit(&g_pidx, 1 - cur, memory_order_release);   // ② 再发布索引

    char line[192];
    hg_params_line(line, sizeof line, &np);
    rlog("[PARAM] %s=%g → %s", key, value, line);
}

int hg_out_batches(void) {
    return atomic_load(&g_feedBatches);        // ★ 新数据源（sink 两路）的帧数
}

int hg_out_isolate(void) {
    return atomic_load(&g_isolate);
}

// ★ 上游静默超过 1.2s 且还有未结算的段 → 强制结算
//   （原来只在"连续 12 批静音"时结算；游戏常常发几个零就停 → 事件永远不落 [EVT]）
void hg_out_settle_evt_if_idle(void) {
    uint64_t lb = atomic_load(&g_lastBatchUs);
    if (lb && (now_us() - lb) > 1200000ull && !atomic_exchange(&evBusy, 1)) {
        if (evBatches > 0) {
            char tbuf[16]; time_t sec = (time_t)evStart;
            struct tm tmr; localtime_r(&sec, &tmr);
            strftime(tbuf, sizeof tbuf, "%H:%M:%S", &tmr);
            rlog("[EVT] 起点%s len=%.2fs 输入峰=%.2f 均=%.2f 批数=%d 握把峰=%.2f 扳机峰=%.2f [静默结算]",
                 tbuf, evLast - evStart, evPeak, evSum / evBatches,
                 evBatches, evPeakH, evPeakT);
            evBatches = 0; evEndRun = 0;
        }
        atomic_store(&evBusy, 0);
    }
}

#pragma mark - 安装 / 初始化

void hg_out_init(int stage) {
    g_stage = stage;

    // ★ 参数初值 = `hg_map.h` 默认值（= 用户验收那组，逐字段相同）；运行时由
    //   `hg_haptics_set(key, value)` 改 —— 不再有控制文件 / 环境变量 / 脚本（STATE §103）。
    hg_map_params p0 = hg_map_defaults();
    g_pbuf[0] = p0;
    g_pbuf[1] = p0;
    g_mstate  = hg_map_state_new();
    atomic_store_explicit(&g_pidx, 0, memory_order_release);

    char line[192];
    hg_params_line(line, sizeof line, &p0);
    // ★ 把"上游静默判据"也打进横幅 —— 它是**对齐官方**的常量（AkMotionSink 的续期量 0.1s），
    //   而且是 ASCII 金丝雀（`idleEnd=100ms`），换版本时一眼能确认生效。
    size_t n = strlen(line);
    snprintf(line + n, sizeof line - n, " idleEnd=%llums",
             (unsigned long long)(HG_IDLE_END_US / 1000));
    rlog("[CFG] 双通道分配（sink 两路 → 4 马达）+ 最低强度拉伸 stage=%d", g_stage);
    rlog("[CFG] 生效参数（默认值）: %s", line);
    rlog("[CFG] 调参：代码接口 hg_haptics_set(key, value)"
         " —— key ∈ split|minpct|lphz|trigth|trigcd|pulsedecay|gripbleed|isolate（立即生效）");

    // 预分配参数池（音频线程零分配）
    for (int i = 0; i < 4; i++)
        g_paramPool[i] = [[CHHapticDynamicParameter alloc] initWithParameterID:@"HapticIntensityControl"
                                                                         value:0.0 relativeTime:0];
    for (int i = 0; i < 4; i++)
        g_paramArr[i] = [[NSArray alloc] initWithObjects:g_paramPool[i], nil];
}

void hg_out_install(void) {
    // A1
    {
        Class c = NSClassFromString(@"GCDeviceHaptics");
        SEL sel = sel_registerName("createEngineWithLocality:");
        Method m = c ? class_getInstanceMethod(c, sel) : NULL;
        if (m) {
            g_origCreateEngine = method_getImplementation(m);
            method_setImplementation(m, (IMP)hg_createEngineWithLocality);
            rlog("[A1] 已挂 GCDeviceHaptics createEngineWithLocality:");
        } else {
            rlog("[A1] !! 挂不上（类或方法缺失）");
        }
    }
    // A2（为了拿到 player 的具体类，再挂 A3）
    {
        Class c = NSClassFromString(@"CHHapticEngine");
        SEL sel = sel_registerName("createPlayerWithPattern:error:");
        Method m = c ? class_getInstanceMethod(c, sel) : NULL;
        if (m) {
            g_origCreatePlayer = method_getImplementation(m);
            method_setImplementation(m, (IMP)hg_createPlayerWithPattern);
            rlog("[A2] 已挂 CHHapticEngine createPlayerWithPattern:error:");
        } else {
            rlog("[A2] !! 挂不上（类或方法缺失）");
        }
        // ★ 高级播放器：以前"仅记录不挂"→ 游戏若走这条，我们一条数据都收不到。现在真挂。
        SEL sel2 = sel_registerName("createAdvancedPlayerWithPattern:error:");
        Method m2 = c ? class_getInstanceMethod(c, sel2) : NULL;
        if (m2) {
            g_origCreateAdvancedPlayer = method_getImplementation(m2);
            method_setImplementation(m2, (IMP)hg_createAdvancedPlayerWithPattern);
            rlog("[A2] 已挂 CHHapticEngine createAdvancedPlayerWithPattern:error:");
        } else {
            rlog("[A2] 无 createAdvancedPlayerWithPattern:error:");
        }
    }
}