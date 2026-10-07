//
//  haptics_fix.h —— 【门① + 数据源】模块对外接口
//
//  根因 = 系统给 `GCController.playerIndex` 报 -1，游戏匹配不上手柄 ⇒ 不建 sink。
//    ① **门①**：把 `-[GCController playerIndex]` 一律报 0 ⇒ 游戏自己匹配上、自己建 sink。
//    ② **数据源**：挂 `AkMotionSink::Consume`（按指令签名定位，双版本通用），每帧取两路峰值
//       交给输出侧 —— 这是**左右**的来源。
//    旧 P1/P2 补丁 / retrigger / Rewired 接管已删除（详见 haptics/STATE.md §100）。
//    输出侧（4 马达分发）在 haptics_out.h —— 两者不要混写。
//
#pragma once
#import <Foundation/Foundation.h>

void hg_fix_install(void);                 // 装门①（swizzle playerIndex）；幂等
void hg_fix_tick(void);                    // 主控线程每 tick：门① + 数据源 幂等懒装
void hg_fix_on_a1(id gameEngine, int idx); // A1 钩子内调用：现场记录 controllers() 数量
void hg_fix_log_ctrl_heartbeat(void);      // 心跳：[CTRL] 控制器清单（状态变化或每 10 次心跳打一行）