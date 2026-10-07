//
//  haptics_log.m —— 无锁环形缓冲日志（音频线程安全）
//
#import "EndfieldHapticsLog.h"
#include <stdatomic.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/time.h>

#define RING_N    32768   // 全量记 A3（每批一行）需大缓冲；BSS 惰性分配，不占常驻
#define HG_LINE_MAX 256

static char g_ring[RING_N][HG_LINE_MAX];
static _Atomic uint32_t g_head = 0;
static _Atomic uint32_t g_tail = 0;
static char g_log_path[1024] = {0};
// ★ 环形缓冲满导致丢弃的行数 —— 全量记录时必须可见，否则"没看到"和"丢了"分不开
static _Atomic int g_logDropped = 0;

uint64_t now_us(void) {
    struct timeval tv; gettimeofday(&tv, NULL);
    return (uint64_t)tv.tv_sec * 1000000ull + (uint64_t)tv.tv_usec;
}

void hg_flat(char *out, size_t n, NSString *s) {
    if (!s) { snprintf(out, n, "(nil)"); return; }
    const char *u = [s UTF8String];
    size_t j = 0;
    for (size_t i = 0; u[i] && j + 1 < n; i++) {
        char c = u[i];
        out[j++] = (c == '\n' || c == '\r' || c == '\t') ? ' ' : c;
    }
    out[j] = 0;
}

// 生产者：任何线程（含音频线程）。无锁、无分配、不阻塞。
void rlog(const char *fmt, ...) {
    uint32_t h = atomic_load_explicit(&g_head, memory_order_relaxed);
    uint32_t t = atomic_load_explicit(&g_tail, memory_order_acquire);
    if (h - t >= RING_N) {                       // 满则丢弃，绝不阻塞音频线程
        atomic_fetch_add(&g_logDropped, 1);      // ★ 但必须记账，否则遗漏无从察觉
        return;
    }
    char *slot = g_ring[h % RING_N];
    // ★ 每行自动加墙钟时间戳 HH:MM:SS.mmm —— 便于与玩家动作时刻对齐（原来只有 [EVT] 有）
    struct timeval tsv; gettimeofday(&tsv, NULL);
    time_t tsec = (time_t)tsv.tv_sec;
    struct tm tmr; localtime_r(&tsec, &tmr);
    int pre = (int)strftime(slot, 16, "%H:%M:%S.", &tmr);
    pre += snprintf(slot + pre, 6, "%03d ", (int)(tsv.tv_usec / 1000));
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(slot + pre, HG_LINE_MAX - pre, fmt, ap);
    va_end(ap);
    atomic_store_explicit(&g_head, h + 1, memory_order_release);
}

int hg_log_dropped(void) {
    return atomic_load(&g_logDropped);
}

// 消费者：后台线程落盘。
// ★ 沙箱应用写真实 /tmp 会被拒（fopen 返回 NULL）→ 依次尝试多个候选路径。
FILE *hg_log_begin(int stage) {
    FILE *f = NULL;
    char tried[4][1024];
    int n = 0;

    const char *env = getenv("HG_HAPTICS_LOG");
    if (env && *env) snprintf(tried[n++], sizeof(tried[0]), "%s", env);

    NSString *home = NSHomeDirectory();                 // 沙箱内=容器 Data 目录
    if (home) snprintf(tried[n++], sizeof(tried[0]), "%s/haptics_probe.log", [home UTF8String]);

    NSString *tmpd = NSTemporaryDirectory();
    if (tmpd) snprintf(tried[n++], sizeof(tried[0]), "%s/haptics_probe.log", [tmpd UTF8String]);

    snprintf(tried[n++], sizeof(tried[0]), "/tmp/haptics_probe.log");

    for (int i = 0; i < n; i++) {
        f = fopen(tried[i], "w");
        if (f) {
            snprintf(g_log_path, sizeof(g_log_path), "%s", tried[i]);
            break;
        }
    }
    if (!f) return NULL;

    fprintf(f, "=== EndfieldHaptics 启动 stage=%d pid=%d ===\n", stage, getpid());
    fprintf(f, "=== 日志路径: %s ===\n", g_log_path);
    fflush(f);
    return f;
}

void hg_log_flush(FILE *f) {
    if (!f) return;
    uint32_t h = atomic_load_explicit(&g_head, memory_order_acquire);
    uint32_t t = atomic_load_explicit(&g_tail, memory_order_relaxed);
    while (t != h) {
        fputs(g_ring[t % RING_N], f);
        fputc('\n', f);
        t++;
    }
    atomic_store_explicit(&g_tail, t, memory_order_release);
    fflush(f);
}