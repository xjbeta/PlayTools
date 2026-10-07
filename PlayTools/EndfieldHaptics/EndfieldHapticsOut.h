//
//  haptics_out.h —— 【震动输出】模块对外接口
//
//  只负责「把 sink 的两路（左/右）变成 4 马达输出」：A1/A2/A3 钩子、4 个 locality 引擎/player、
//  最低强度拉伸 / 分配映射（每路慢变→握把、瞬态→该侧扳机）。A3 只做"官方静音"。
//  门①（playerIndex→0）与数据源在 haptics_fix.h —— 两者不要混写。
//
#pragma once
#import <Foundation/Foundation.h>

// ★★ 唯一的运行时控制接口（PlayCover 可调；也可从 PlayTools 其它模块调）：
//     key ∈ split | minpct | lphz | trigth | trigcd | pulsedecay | gripbleed | isolate
//     isolate: 1 = 我们接管（默认） / 0 = 官方直通（我们的马达静默）
//     ★ 立即生效（双缓冲原子发布），无控制文件、无脚本。
void hg_haptics_set(const char *key, double value);

void hg_out_init(int stage);           // 预分配参数池 + [CFG] 横幅（构造期调用一次）
void hg_out_install(void);             // 挂 A1/A2/A2b 钩子（A3 在拿到 player 具体类后自动挂上）
void hg_out_feed2(float vL, float vR, uint64_t t_us, float motorOut[4]);
                                       // ★ 新数据源：sink 两路（左/右）→ 4 马达
                                       //   motorOut（可传 NULL）= 回填 [左握,右握,左扳,右扳]（诊断用）
int  hg_out_batches(void);             // 累计【新数据源】帧数（心跳判据用）
int  hg_out_isolate(void);             // 当前隔离状态（1=我们接管 0=官方直通）
void hg_out_settle_evt_if_idle(void);  // 上游静默 >1.2s → 强制结算未闭合的 [EVT] 段
void hg_out_idle_tick(void);           // ★ 主控线程每 tick：上游静默 ≥0.1s（对齐官方）→ 启动"排空器"（按帧率喂 0，脉冲自然收尾）