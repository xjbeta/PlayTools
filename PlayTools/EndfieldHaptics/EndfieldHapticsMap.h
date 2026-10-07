//
//  hg_map.h —— 【③ 输出】分配映射纯函数（header-only，单一实现）
//
//  dylib 三大功能的第三块「输出·分配/强度调整」的核心：
//    分配（单路 → 4 locality）+ 强度（最低强度拉伸）。另两块是修复【A】/【B】（haptics_fix.m）。
//
//  ★★ 为什么单独抽一个文件：这套映射以前在 dylib 与离线工具里各有一份手抄实现，已经漂移过，
//    导致归档 CSV 的 `out` 列与硬件实际输出无关（详见 haptics/memory/topics/05-错误记忆.md）。
//    现在两边都 include 本头：dylib 内联编译，离线工具经 builds/libhgmap.dylib 调用
//    ⇒ 漂移在结构上不可能再发生。
//
//  ★ 纯 C：不含 Foundation / ObjC / CoreHaptics ⇒ macabi 的 dylib 与宿主的离线工具
//    能编同一份源码，且离线侧不需要模拟任何对象。
//
//  数学（与改造前的 hg_fanout 逐行等价）：
//    ① 分配（直接作用在【官方原始值 v】上）：
//       握把 = 低通(8Hz) + grip_bleed×残差（grip_bleed=1 ⇒ 握把=完整包络 v）
//       瞬态(残差 ≥ 阈值、去抖) → 左右扳机脉冲
//    ② 最低强度拉伸：out = min_pct + v*(1-min_pct)（★ 只抬非零：v < 0.02 仍输出 0）
//    ③ 四通道钳制到 [0,1]
//    归一化 / 增益均已移除 —— 不要再加回来。
//
//  ★★ grip_bleed（握把瞬态注入量）—— 修"太轻"：旧行为把【两握把都做低通】，削掉的残差
//     又丢给【弱】扳机马达 ⇒ 能量白丢。⇒ grip_bleed=1 时握把 = 低通 + 残差 = v（完整包络），
//     0 时回旧行为。业界依据见 topics/03-输出-分配与强度.md §4.9、topics/08-...prior-art.md §五。
//
#pragma once

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

// ── 编译期常量：每批时长 ──────────────────────────────────────────────
// 由实测决定（N=2 × 5.33ms ≈ 94Hz），**不开放为运行时旋钮**：它是采样事实，不是偏好。
#define HG_MAP_DT_SEC   0.010667f

// ── ★ **不再有控制文件 / 脚本接口**（详见 haptics/STATE.md §103）──────────
//   运行时调参统一走 `hg_haptics_set(key, value)`（声明在 EndfieldHapticsOut.h）。键见 hg_map_apply_key。
//   默认值 = hg_map_defaults()。

// ── 参数 ──────────────────────────────────────────────────────────────
typedef struct {
    int      split;         // 0 = 纯路由 / 1 = 分配映射
    float    min_pct;       // ① 拉伸下限
    float    lp_hz;         // 握把低通截止
    float    trig_th;       // 瞬态阈值
    uint64_t trig_cd_us;    // 去抖（微秒；对外用毫秒）
    float    pulse_decay;   // 脉冲衰减
    float    grip_bleed;    // ★ 握把瞬态注入量：握把 = 低通 + grip_bleed×(v-低通)
                            //   0 = 只低通（旧行为）；1 = 握把拿完整包络（= v）
    float    dt_s;          // = HG_MAP_DT_SEC（放进结构体，便于离线工具显式知道它用了什么）
} hg_map_params;

// ── 状态（每条流一份；dylib 里是文件作用域静态，离线工具是栈上变量）────
//  ★ 每通道一份（0 = 左 / 1 = 右）—— 数据源从"单路"换成 sink 的两路。
typedef struct {
    float    lp[2];            // 握把低通状态（★ 跨批连续，不按段重置 —— 与 dylib 一致）
    float    trig[2];          // 打击脉冲包络
    uint64_t last_trig_us[2];  // 上次触发时刻（微秒）
} hg_map_state;

// ── 默认值 = 用户验收的那组（改动前硬编码值，逐字段相同）──
static inline hg_map_params hg_map_defaults(void) {
    hg_map_params p;
    p.split       = 1;             // ★ 默认 **开**：慢变→握把 / 瞬态→扳机（默认值是唯一来源）
    p.min_pct     = 0.30f;         // 最低强度拉伸下限（STATE §94）
    p.lp_hz       = 8.0f;          // 握把低通截止（03 §4.5 实测定档）
    p.trig_th     = 0.15f;         // 瞬态阈值（03 §4.5 实测定档）
    p.trig_cd_us  = 150000ull;     // 去抖 150 ms
    p.pulse_decay = 0.86f;         // 每批衰减（≈94Hz 下约 325ms 落到 0.01）
    p.grip_bleed  = 1.0f;          // ★ 握把拿完整包络（修"太轻"；0 = 回旧的"只低通"）
    p.dt_s        = HG_MAP_DT_SEC;
    return p;
}

static inline hg_map_state hg_map_state_new(void) {
    hg_map_state s;
    for (int i = 0; i < 2; i++) { s.lp[i] = 0.0f; s.trig[i] = 0.0f; s.last_trig_us[i] = 0; }
    return s;
}

// ── 单键赋值（带钳制）—— `hg_haptics_set()` 与离线 CLI 的 --params 共用同一套钳制 ──
//   key ∈ minpct | lphz | trigth | trigcd | pulsedecay（trigcd 单位 = 毫秒）
//   返回 1 = 识别并写入；0 = 未知键（调用方自行报错）
//   越界值**钳制**而不是拒绝：宁可让它落在边界上，也不要静默地"这行被吃掉了"。
static inline int hg_map_apply_key(hg_map_params *p, const char *key, double v) {
    if (!strcmp(key, "minpct")) {
        if (v < 0.0)    v = 0.0;
        if (v > 0.95)   v = 0.95;
        p->min_pct = (float)v;
    } else if (!strcmp(key, "lphz")) {
        if (v < 0.5)    v = 0.5;
        if (v > 100.0)  v = 100.0;
        p->lp_hz = (float)v;
    } else if (!strcmp(key, "trigth")) {
        if (v < 0.01)   v = 0.01;
        if (v > 1.0)    v = 1.0;
        p->trig_th = (float)v;
    } else if (!strcmp(key, "trigcd")) {
        if (v < 0.0)    v = 0.0;
        if (v > 2000.0) v = 2000.0;
        p->trig_cd_us = (uint64_t)(v * 1000.0 + 0.5);
    } else if (!strcmp(key, "pulsedecay")) {
        if (v < 0.5)    v = 0.5;
        if (v > 0.99)   v = 0.99;
        p->pulse_decay = (float)v;
    } else if (!strcmp(key, "gripbleed")) {
        if (v < 0.0)    v = 0.0;
        if (v > 1.0)    v = 1.0;
        p->grip_bleed = (float)v;
    } else if (!strcmp(key, "split")) {
        p->split = (v != 0.0) ? 1 : 0;
    } else {
        return 0;
    }
    return 1;
}

// ── ★ 控制文件读取（hg_map_load / *_file_double / *_path_exists）**已删除**（STATE §103）──
//   参数由 `hg_haptics_set(key, value)` 直接改内存并原子发布（见 EndfieldHapticsOut.m）。

// ── 单通道分配（内部）：v → (握把, 扳机)，状态写在 st 的 ch 号通道上 ──────
static inline void hg_map_chan(hg_map_state *st, const hg_map_params *p, int ch,
                               float v, uint64_t t_us, float *grip_raw, float *trig_raw) {
    if (p->split) {
        // ① 分配：慢变（低通）→ 握把；残差（瞬态）打阈值 + 去抖 → 扳机脉冲
        float rc = 1.0f / (2.0f * 3.14159265358979f * p->lp_hz);
        float a  = p->dt_s / (rc + p->dt_s);
        st->lp[ch] += a * (v - st->lp[ch]);
        float resid = v - st->lp[ch];
        if (resid >= p->trig_th && (t_us - st->last_trig_us[ch]) >= p->trig_cd_us) {
            st->last_trig_us[ch] = t_us;
            st->trig[ch] = resid;                       // 起脉冲
        } else {
            st->trig[ch] *= p->pulse_decay;             // 落脉冲
            if (st->trig[ch] < 0.01f) st->trig[ch] = 0.0f;
        }
        // ★ 握把 = 低通 + grip_bleed×残差：grip_bleed=1 ⇒ = v（完整包络，不削峰）
        *grip_raw = st->lp[ch] + p->grip_bleed * resid;
        *trig_raw = st->trig[ch];
    } else {
        *grip_raw = v; *trig_raw = v;                   // 纯路由：同值
    }
}

// ② 最低强度拉伸（★ 只抬非零 ⇒ 静音仍是静音）+ ③ 钳制
static inline float hg_map_stretch(const hg_map_params *p, float raw) {
    float v = raw > 1.0f ? 1.0f : raw;
    if (v < 0.02f) return 0.0f;
    float out = p->min_pct + v * (1.0f - p->min_pct);
    if (out > 1.0f) out = 1.0f;
    if (out < 0.0f) out = 0.0f;
    return out;
}

// ── ★ 核心（双通道）：把左右两路映射成 4 个马达的输出 ──────────────────
//   vL / vR = 本批左 / 右通道的值；motor = [LeftHandle, RightHandle, LeftTrigger, RightTrigger]
//   分配：ch0 低频/strong→左握把、ch1 高频/weak→右握把，瞬态→各自扳机
//   （业界共识见 topics/08-...prior-art.md §五；数据源见 topics/07-...signal-sources.md §8）
//
//   ⚠️ 只允许被【单一线程】调用（每个 state 一份）—— 与改造前的 hg_fanout 同一假设。
static inline void hg_map_step2(hg_map_state *st, const hg_map_params *p,
                                float vL, float vR, uint64_t t_us, float motor[4]) {
    // ★ **不加定标**：官方 motion 值直接进分配（后面照旧钳到 [0,1]）。
    float gripL, trigL, gripR, trigR;
    hg_map_chan(st, p, 0, vL, t_us, &gripL, &trigL);
    hg_map_chan(st, p, 1, vR, t_us, &gripR, &trigR);
    motor[0] = hg_map_stretch(p, gripL);                // Left Handle
    motor[1] = hg_map_stretch(p, gripR);                // Right Handle
    motor[2] = hg_map_stretch(p, trigL);                // Left Trigger
    motor[3] = hg_map_stretch(p, trigR);                // Right Trigger
}


