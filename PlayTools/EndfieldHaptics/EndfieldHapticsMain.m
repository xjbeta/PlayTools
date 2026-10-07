//
//  haptics_main.m —— 组装入口 + 主控（drain）线程
//
//  构造期：读 stage → 起主控线程（日志 + 控制面）→ 输出侧初始化 → 装钩子（输出 + 修复）
//  主控线程（150ms/tick）：
//    hg_fix_tick()   —— 门① 幂等补装 + 数据源懒装（sink Consume）
//    hg_out_idle_tick() —— 上游静默 ≥0.1s（对齐官方，STATE §104）→ 启动排空器（喂 0 收尾）
//    hg_log_flush()  —— 环形缓冲落盘
//    心跳（每 6s 一行；静默时降到每 30s）：[HB] 计数 + [EVT] 强制结算 + [CTRL] 控制器清单
//
#import <Foundation/Foundation.h>
#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <unistd.h>

#import "EndfieldHapticsLog.h"
#import "EndfieldHapticsOut.h"
#import "EndfieldHapticsFix.h"
#import "../Endfield/EndfieldRuntime.h"

static void *hg_ctl_thread(void *arg) {
    int stage = (int)(intptr_t)arg;
    FILE *f = hg_log_begin(stage);
    if (!f) return NULL;

    for (;;) {
        hg_fix_tick();
        hg_out_idle_tick();            // ★ 上游停发 → 4 马达归零（否则无限时长 player 一直震）

        hg_log_flush(f);

        // ★ 心跳：有活动时每 6s 一行；【静默时降到每 30s】—— 压缩日志
        {
            static int hbTick = 0, hbPrev = 0, hbDropPrev = 0, hbIsoPrev = 1, hbQuiet = 0;
            if (++hbTick >= 40) {
                hbTick = 0;
                int total = hg_out_batches();
                int drop  = hg_log_dropped();
                int iso   = hg_out_isolate();
                BOOL idle = (total == hbPrev && drop == hbDropPrev && iso == hbIsoPrev);
                if (idle && ++hbQuiet < 5) {
                    // 静默期：跳过这一行（每 5 个周期 = 30s 才打一次）
                } else {
                    hbQuiet = 0;
                    rlog("[HB] 累计批=%d 新增=%d 隔离=%d 丢弃=%d",
                         total, total - hbPrev, iso, drop);
                }
                // ★ 丢弃告警必须在更新 hbDropPrev 【之前】判 —— 否则比的是刚写进去的值，永不触发
                if (drop > hbDropPrev)
                    rlog("[HB] !! 日志有丢弃 —— 环形缓冲跟不上，上面这段数据不完整");
                hbPrev = total; hbDropPrev = drop; hbIsoPrev = iso;
                // ★ 上游静默超过 1.2s 且还有未结算的段 → 强制结算
                //   （否则游戏"发几个零就停"的事件永远不落 [EVT]）
                hg_out_settle_evt_if_idle();
                // ★ 心跳里也看一眼控制器数组：断流发生时它变成什么样，是判责关键
                hg_fix_log_ctrl_heartbeat();
            }
        }
        usleep(150 * 1000);
    }
    return NULL;
}

void EndfieldHapticsStart(void) {
    static bool started = false;
    if (started) { return; }
    if (!EndfieldRuntimeIsGame()) { return; }
    started = true;
    int stage = 1;

    pthread_t th;
    pthread_create(&th, NULL, hg_ctl_thread, (void *)(intptr_t)stage);
    pthread_detach(th);
    usleep(50 * 1000);                 // 等日志线程就绪并确定路径

    hg_out_init(stage);                // 输出侧：参数池 + [CFG]

    rlog("=== haptics dylib 已加载 (pid=%d, stage=%d) ===", getpid(), stage);
    rlog("[env] NSHomeDirectory=%s", [NSHomeDirectory() UTF8String]);

    hg_out_install();                  // A1/A2/A2b 钩子
    hg_fix_install();                  // 门①（playerIndex→0）+ 数据源（sink Consume）

    EndfieldRuntimeNote("haptics", true);
    rlog("=== 安装完成，等待震动 ===");
}