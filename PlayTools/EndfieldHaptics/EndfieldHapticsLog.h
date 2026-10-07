//
//  haptics_log.h —— 日志底座（供「输出」「修复」「主控」三方共用）
//
//  线程约束：A3 在音频线程上被调用 → 生产者走无锁环形缓冲，消费者（主控线程）落盘。
//
#pragma once
#import <Foundation/Foundation.h>
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>

// 微秒级墙钟（gettimeofday）
uint64_t now_us(void);

// 生产者：任意线程（含音频线程）。无锁、无分配、不阻塞；每行自动加 HH:MM:SS.mmm 时间戳。
void rlog(const char *fmt, ...);

// 把多行描述压成单行 —— NSSet/NSArray 的 description 自带换行，
// 直接打进日志会产生"没有时间戳的残行"，破坏按行/按时间的过滤。
void hg_flat(char *out, size_t n, NSString *s);

// 环形缓冲满而丢弃的行数（全量记录时必须可见，否则"没看到"和"丢了"分不开）
int hg_log_dropped(void);

// 打开日志文件并打启动横幅（依次尝试 HG_HAPTICS_LOG / 容器 Data / tmpdir / /tmp）。
// 返回 NULL = 全部失败 → 调用方直接收摊。
FILE *hg_log_begin(int stage);

// 消费者：把环形缓冲里现有行写到 f 并 flush。
void hg_log_flush(FILE *f);