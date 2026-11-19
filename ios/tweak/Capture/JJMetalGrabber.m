//
//  JJMetalGrabber.m
//  JJCheat —— Metal 抓帧（2.0.0 重构：渲染线程零拷贝）
//
//  实测：这游戏不走 presentDrawable 家族，但 CAMetalLayer -nextDrawable 每帧都调。
//    第 N 帧 nextDrawable 拿到 drawable → 记住它的 IOSurface（CFRetain）
//    第 N+1 帧 nextDrawable 之前 → 读这个 IOSurface（内容已渲染完、还没被复用）
//  好处：不依赖 present、不往渲染线程里塞 blit、拿到的就是游戏画面（不含 HUD）。
//
//  【2.0.0 架构变更：从源头治卡顿】
//   16:00 真机日志显示 1.1.44 全程 frame=0 B、s_lastGoodMetal 永久复用同一张旧图。
//   根因是两层缺陷叠加：
//     ① JJMetalFrameCopy 有 5s 过期，而 tick 被多重退避拖到 6s 才来取 → 恒返回 nil；
//     ② JJScreenGrabber 的缓存帧无时间戳，于是每 6s 拿 12 分钟前的旧帧重跑模板匹配。
//   同时 JJReadSurface 的 14MB memcpy + 350 万次 R/B 交换跑在**游戏渲染调用栈**里，
//   每 1.5s 让游戏掉一次帧 —— 这才是「间歇性卡顿」的物理来源。
//
//   现在：
//     - nextDrawable 只做「取出 pending + dispatch_async」，渲染线程零字节拷贝；
//     - 14MB 读回 + BGRA→RGBA 全部移到专用低优先级串行队列，与游戏帧率彻底解耦；
//     - 读帧与上层处理解耦：固定低频产出新帧，上层用「序号 + 指纹」决定是否跑 JS，
//       上层退避/跳过不再导致读帧链路静默死锁（删掉 1.1.44 的 gFrameConsumed 闸门）；
//     - 帧缓存不再自带过期返回，改由 JJMetalFrameIsFresh 显式判定新鲜度。
//

#import "JJMetalGrabber.h"
#if defined(__ARM_NEON)
#include <arm_neon.h>
#endif
#import "JJConfig.h"
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <QuartzCore/CAMetalLayer.h>
#import <IOSurface/IOSurface.h>
#import <os/lock.h>
#import <stdatomic.h>

#pragma mark - 帧缓存与状态

static NSData *gFrame = nil;
static int gFrameW = 0;
static int gFrameH = 0;
static CFTimeInterval gFrameTs = 0;
static os_unfair_lock gLock = OS_UNFAIR_LOCK_INIT;

static volatile int gNextDrawableCount = 0;   // 仅渲染线程写，日志线程读
static int gCaptureCount = 0;                 // gLock 保护
static int gCaptureFail = 0;                  // gLock 保护
static volatile int gSurfaceMiss = 0;

/* 抓帧总开关：默认关。待机（只挂悬浮球）和插件关闭时真的不读帧。 */
static volatile BOOL gCaptureEnabled = NO;

/* 读帧在独立队列执行；原子标志防止队列里堆积多个 14MB 拷贝任务。
   写 1 只在渲染线程、写 0 只在读帧队列，用 CAS 避免两者交错。 */
static atomic_int gReadBusy = 0;
static CFTimeInterval gLastReadTs = 0;     /* 上次「摘要轮询」派发时刻 */
static CFTimeInterval gLastCopyTs = 0;     /* 上次真正拷出 14MB 的时刻（心跳用） */

/* pending surface 的所有访问都必须经过这把锁：
   JJMetalSetCaptureEnabled 在主线程、nextDrawable 在渲染线程。 */
static os_unfair_lock gSurfLock = OS_UNFAIR_LOCK_INIT;
static IOSurfaceRef gPendingSurface = NULL;
static int gPendingW = 0;
static int gPendingH = 0;

#pragma mark - 2.1.77 棋盘摘要采样（变化驱动抓帧）

/* 为什么改成「摘要驱动」：
   旧逻辑每 JJ_METAL_READ_INTERVAL（1.5s）无条件拷 14MB 出一帧。这 1.5s 就是
   「对方走完到我们看见」的固定延迟下界，用户感知就是「有点滞后」。
   而每帧 14MB 的分配 + memcpy + BGRA→RGBA 逐字交换，代价并不小。
   改成先在 IOSurface 锁内只采 90 个棋盘点（约 810 像素，微秒级），
   摘要没变就整帧丢掉 —— 延迟降到约 0.15s，拷贝次数反而大幅下降。

   采样必须限定在棋盘内：整屏采样会被倒计时数字、落子动画、提示高亮带偏，
   那会退化成「每帧都变」，等于白改。所以需要四角坐标。 */

#define JJ_PEEK_POINTS      90
#define JJ_PEEK_VALUES      (JJ_PEEK_POINTS * 3)

static volatile BOOL gHasCorners = NO;
/* 2.0.0r9：摘要轮询间隔改成可调（抓帧分档）。
   等对方走子时降到 0.35s：对手落子那半秒里棋盘会变 3~5 次，0.15s 的门
   会触发 2~3 次「14MB 拷贝 + 一次 JS 识别」，这就是「对方一落子画面顿一下」。
   轮到我方立刻回到 0.15s，保证建议出得够快。 */
static volatile double gPeekInterval = JJ_METAL_PEEK_INTERVAL;
static os_unfair_lock gCornerLock = OS_UNFAIR_LOCK_INIT;
static float gCornerX[4] = {0};
static float gCornerY[4] = {0};

/* 以下摘要状态只在读帧队列（串行）访问，不需要额外加锁 */
static int32_t gLastDigest[JJ_PEEK_VALUES];
static BOOL gDigestValid = NO;

void JJMetalSetPeekInterval(double seconds) {
    if (seconds < 0.08) seconds = 0.08;    /* 再密就不划算了：识别排队来不及 */
    if (seconds > 1.00) seconds = 1.00;
    gPeekInterval = seconds;
}

void JJMetalSetBoardCorners(NSArray *corners) {
    BOOL ok = NO;
    float xs[4], ys[4];
    if ([corners isKindOfClass:[NSArray class]] && corners.count == 4) {
        ok = YES;
        for (int i = 0; i < 4; i++) {
            id p = corners[i];
            if ([p isKindOfClass:[NSArray class]] && [(NSArray *)p count] >= 2) {
                xs[i] = [[(NSArray *)p objectAtIndex:0] floatValue];
                ys[i] = [[(NSArray *)p objectAtIndex:1] floatValue];
            } else {
                ok = NO;
                break;
            }
        }
    }
    os_unfair_lock_lock(&gCornerLock);
    BOOL wasOn = gHasCorners;
    if (ok) {
        memcpy(gCornerX, xs, sizeof(xs));
        memcpy(gCornerY, ys, sizeof(ys));
    }
    gHasCorners = ok;
    os_unfair_lock_unlock(&gCornerLock);
    /* 角点变了（重新标定 / 分辨率变化）→ 旧摘要没有可比性，强制重出一帧 */
    if (wasOn != ok) gDigestValid = NO;
}

/* 在棋盘内采 90 点，算 BGR 三元组摘要。只判变化，不必做 BGRA→RGBA 换序。 */
static BOOL JJComputeDigest(const uint8_t *base, size_t bpr, int w, int h, int32_t *out) {
    if (!base || w <= 0 || h <= 0) return NO;
    os_unfair_lock_lock(&gCornerLock);
    if (!gHasCorners) {
        os_unfair_lock_unlock(&gCornerLock);
        return NO;
    }
    float cx[4], cy[4];
    memcpy(cx, gCornerX, sizeof(cx));
    memcpy(cy, gCornerY, sizeof(cy));
    os_unfair_lock_unlock(&gCornerLock);

    for (int r = 0; r < 10; r++) {
        for (int c = 0; c < 9; c++) {
            double u = (double)c / 8.0, v = (double)r / 9.0;
            int x = (int)((1 - u) * (1 - v) * cx[0] + u * (1 - v) * cx[1] +
                          u * v * cx[2] + (1 - u) * v * cx[3]);
            int y = (int)((1 - u) * (1 - v) * cy[0] + u * (1 - v) * cy[1] +
                          u * v * cy[2] + (1 - u) * v * cy[3]);
            int idx = (r * 9 + c) * 3;
            if (x < 2 || y < 2 || x >= w - 2 || y >= h - 2) {
                out[idx] = out[idx + 1] = out[idx + 2] = 0;
                continue;
            }
            int sb = 0, sg = 0, sr = 0;
            for (int dy = -1; dy <= 1; dy++) {
                const uint8_t *row = base + (size_t)(y + dy) * bpr;
                for (int dx = -1; dx <= 1; dx++) {
                    size_t o = (size_t)(x + dx) * 4;   /* BGRA */
                    sb += row[o];
                    sg += row[o + 1];
                    sr += row[o + 2];
                }
            }
            out[idx] = sb / 9;
            out[idx + 1] = sg / 9;
            out[idx + 2] = sr / 9;
        }
    }
    return YES;
}

/* 摘要是否「实质变化」。为什么不是简单累加差：
   全屏亮度轻微漂移会让 270 个值各差 1~2，累加就到 500 了，会假触发；
   而一个棋子移动只影响 2 个点，但每点差值很大（几十）。
   所以按「单点差值」判：2 个点大变（=一次走子），或 1 个点剧变（强信号）。 */
static BOOL JJDigestChanged(const int32_t *cur) {
    if (!gDigestValid) return YES;
    int bigCount = 0, anyMax = 0;
    for (int i = 0; i < JJ_PEEK_POINTS; i++) {
        int d = cur[i * 3] - gLastDigest[i * 3];
        if (d < 0) d = -d;
        int d2 = cur[i * 3 + 1] - gLastDigest[i * 3 + 1];
        if (d2 < 0) d2 = -d2;
        int d3 = cur[i * 3 + 2] - gLastDigest[i * 3 + 2];
        if (d3 < 0) d3 = -d3;
        d += d2 + d3;
        if (d >= JJ_PEEK_POINT_DELTA) bigCount++;
        if (d > anyMax) anyMax = d;
    }
    if (bigCount >= 2) return YES;
    if (anyMax >= JJ_PEEK_POINT_STRONG) return YES;
    return NO;
}

/** 专用读帧队列（QOS_UTILITY：低于游戏渲染，高于纯后台）。只创建一次。 */
static dispatch_queue_t JJReadQueue(void) {
    static dispatch_once_t once;
    static dispatch_queue_t q = NULL;
    dispatch_once(&once, ^{
        q = dispatch_queue_create("com.fujiang.jjcheat.readframe", DISPATCH_QUEUE_SERIAL);
        dispatch_set_target_queue(q, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    });
    return q;
}

/* 老版本 Unity 的 drawable 自身直接实现了 -iosurface（私有 selector）。
   补一个局部协议后用括号语法调用；不给 NSObject 加分类，避免污染全进程方法解析。
   MTLTexture 的 -iosurface 已在 <Metal/MTLTexture.h> 公开声明，无需重复。 */
@protocol JJMetalIOSurfaceProviding <NSObject>
- (nullable IOSurfaceRef)iosurface;
@end

#pragma mark - pending surface（线程安全）

/** 取出并清空 pending，所有权转移给调用者（需自行 CFRelease） */
static IOSurfaceRef JJTakePending(int *outW, int *outH) {
    os_unfair_lock_lock(&gSurfLock);
    IOSurfaceRef s = gPendingSurface;
    gPendingSurface = NULL;
    if (outW) *outW = gPendingW;
    if (outH) *outH = gPendingH;
    gPendingW = 0;
    gPendingH = 0;
    os_unfair_lock_unlock(&gSurfLock);
    return s;
}

/** 记住新一帧的 surface（内部 CFRetain） */
static void JJStorePending(IOSurfaceRef s, int w, int h) {
    os_unfair_lock_lock(&gSurfLock);
    if (gPendingSurface) CFRelease(gPendingSurface);
    gPendingSurface = s ? (IOSurfaceRef)CFRetain(s) : NULL;
    gPendingW = w;
    gPendingH = h;
    os_unfair_lock_unlock(&gSurfLock);
}

static void JJDropPending(void) {
    IOSurfaceRef s = JJTakePending(NULL, NULL);
    if (s) CFRelease(s);
}

#pragma mark - IOSurface 读取（只在 gReadQueue 上执行）

static IOSurfaceRef JJDrawableSurface(id drawable) {
    if (!drawable) return NULL;
    SEL sel = @selector(iosurface);
    if ([drawable respondsToSelector:sel]) {
        IOSurfaceRef s = [(id<JJMetalIOSurfaceProviding>)drawable iosurface];
        if (s) return s;
    }
    /* 标准路径：CAMetalDrawable.texture 是 id<MTLTexture>，SDK 已公开
       @property (nullable, readonly) IOSurfaceRef iosurface，直接用括号语法。 */
    if ([drawable conformsToProtocol:@protocol(CAMetalDrawable)]) {
        id<MTLTexture> tex = [(id<CAMetalDrawable>)drawable texture];
        if (tex) return tex.iosurface;
    }
    return NULL;
}

/** 把一帧 IOSurface 读成 RGBA。调用者持有 s 的所有权，本函数不释放。 */
/* 锁内只采 90 点算摘要，判断这一帧值不值得拷 14MB。
   返回 YES 同时会把当前摘要记为基准（下一步就是真拷）。 */
static BOOL JJPeekChanged(IOSurfaceRef s, int w, int h) {
    if (!s) return NO;
    if (IOSurfaceLock(s, kIOSurfaceLockReadOnly, NULL) != KERN_SUCCESS) return NO;
    size_t bpr = IOSurfaceGetBytesPerRow(s);
    void *base = IOSurfaceGetBaseAddress(s);
    int32_t cur[JJ_PEEK_VALUES];
    BOOL ok = base && JJComputeDigest((const uint8_t *)base, bpr, w, h, cur);
    IOSurfaceUnlock(s, kIOSurfaceLockReadOnly, NULL);
    if (!ok) return YES;              /* 采不到摘要（角点刚失效）→ 宁可多拷一帧 */
    BOOL changed = JJDigestChanged(cur);
    if (changed) {
        memcpy(gLastDigest, cur, sizeof(cur));
        gDigestValid = YES;
    }
    return changed;
}

static void JJReadSurface(IOSurfaceRef s, int w, int h) {
    if (!gCaptureEnabled || !s || w <= 0 || h <= 0) return;
    if (IOSurfaceLock(s, kIOSurfaceLockReadOnly, NULL) != KERN_SUCCESS) {
        os_unfair_lock_lock(&gLock);
        gCaptureFail++;
        os_unfair_lock_unlock(&gLock);
        return;
    }

    size_t bpr = IOSurfaceGetBytesPerRow(s);
    void *base = IOSurfaceGetBaseAddress(s);
    if (!base) {
        IOSurfaceUnlock(s, kIOSurfaceLockReadOnly, NULL);
        os_unfair_lock_lock(&gLock);
        gCaptureFail++;
        os_unfair_lock_unlock(&gLock);
        return;
    }

    size_t rowBytes = (size_t)w * 4;
    size_t need = rowBytes * (size_t)h;
    NSMutableData *out = [NSMutableData dataWithLength:need];
    uint8_t *dst = (uint8_t *)out.mutableBytes;

    if (bpr == rowBytes) {
        memcpy(dst, base, need);
    } else {
        for (int y = 0; y < h; y++) {
            memcpy(dst + (size_t)y * rowBytes, (uint8_t *)base + (size_t)y * bpr, rowBytes);
        }
    }
    IOSurfaceUnlock(s, kIOSurfaceLockReadOnly, NULL);

    /* IOSurface 是 BGRA，转 RGBA（换 R/B 两个字节）。
       2.0.0r9：原来是 350 万次标量位运算，每帧十几毫秒纯烧 CPU。
       改成 NEON 查表置换：一次 16 字节（4 像素），理论上快 8~10 倍；
       尾部不足 16 字节的再用标量补齐。 */
#if defined(__ARM_NEON)
    {
        static const uint8_t kSwapRB[16] = {2,1,0,3,  6,5,4,7,  10,9,8,11,  14,13,12,15};
        const uint8x16_t mask = vld1q_u8(kSwapRB);
        size_t i = 0;
        for (; i + 16 <= need; i += 16) {
            uint8x16_t v = vld1q_u8(dst + i);
            vst1q_u8(dst + i, vqtbl1q_u8(v, mask));
        }
        for (; i + 4 <= need; i += 4) {
            uint8_t b0 = dst[i], r0 = dst[i + 2];
            dst[i] = r0;
            dst[i + 2] = b0;
        }
    }
#else
    uint32_t *p32 = (uint32_t *)dst;
    size_t n32 = need / 4;
    for (size_t i = 0; i < n32; i++) {
        uint32_t v = p32[i];
        p32[i] = (v & 0xFF00FF00u) | ((v & 0x000000FFu) << 16) | ((v & 0x00FF0000u) >> 16);
    }
#endif

    os_unfair_lock_lock(&gLock);
    gFrame = out;
    gFrameW = w;
    gFrameH = h;
    gFrameTs = CACurrentMediaTime();
    gLastCopyTs = gFrameTs;   // 心跳基准：距上次真拷多久
    gCaptureCount++;          // 序号只在「新帧真正就绪」时推进
    os_unfair_lock_unlock(&gLock);
}

#pragma mark - Logos hook 的两个钩子（由 Tweak.x 调用）

/** %orig 之前：取出上一帧 surface，交给读帧队列；渲染线程零拷贝、零循环。 */
void JJMetalBeforeNextDrawable(void) {
    gNextDrawableCount++;
    if (gNextDrawableCount == 1) {
        NSLog(@"[JJCheat] CAMetalLayer nextDrawable 命中 → 这游戏是 Metal 渲染");
    }
    if (!gCaptureEnabled) {
        JJDropPending();
        return;
    }
    int w = 0, h = 0;
    IOSurfaceRef s = JJTakePending(&w, &h);
    if (!s) return;

    CFTimeInterval now = CACurrentMediaTime();
    /* 与上层是否处理完全解耦：读帧队列空闲就派发。
       1.1.44 的 gFrameConsumed 让「上层一退避就永久不读帧」，已删除。

       2.1.77：派发门的两档
         有角点  → JJ_METAL_PEEK_INTERVAL（0.15s）就派一次，但派下去的活只是
                   「锁 surface + 采 90 点算摘要」，摘要没变就整帧丢掉，不拷 14MB。
         无角点  → 退回旧的 JJ_METAL_READ_INTERVAL（1.5s），直接整帧拷。
           未标定阶段（学习棋盘）离不开新鲜帧，这条兜底不能省。 */
    int expected = 0;
    CFTimeInterval gate = gHasCorners ? gPeekInterval : JJ_METAL_READ_INTERVAL;
    if (atomic_compare_exchange_strong(&gReadBusy, &expected, 1) &&
        (now - gLastReadTs >= gate)) {
        gLastReadTs = now;
        const BOOL wantPeek = gHasCorners;
        dispatch_async(JJReadQueue(), ^{
            BOOL needRead = YES;
            if (wantPeek) {
                /* 心跳：画面真的长时间静止时，也要隔一会儿出一帧，
                   否则上层会认为没有可用帧（JJ_FRAME_MAX_AGE = 4s）。 */
                if (gLastCopyTs > 0 && (CACurrentMediaTime() - gLastCopyTs) >= JJ_PEEK_HEARTBEAT)
                    needRead = YES;
                else
                    needRead = JJPeekChanged(s, w, h);
            }
            if (needRead) JJReadSurface(s, w, h);
            CFRelease(s);
            atomic_store(&gReadBusy, 0);
        });
    } else {
        if (expected == 0) atomic_store(&gReadBusy, 0);  // 抢到了但间隔没到，还回去
        CFRelease(s);          // 这一帧不需要读，直接丢弃（渲染线程无开销）
    }
}

/** %orig 之后：记住本次 drawable 的 surface，等下一帧读 */
void JJMetalAfterNextDrawable(id drawable) {
    if (!gCaptureEnabled || !drawable) return;
    IOSurfaceRef s = JJDrawableSurface(drawable);
    if (s) {
        JJStorePending(s, (int)IOSurfaceGetWidth(s), (int)IOSurfaceGetHeight(s));
    } else {
        gSurfaceMiss++;
    }
}

#pragma mark - 对外

NSData *JJMetalFrameCopy(int *outW, int *outH) {
    os_unfair_lock_lock(&gLock);
    NSData *d = gFrame;
    int w = gFrameW, h = gFrameH;
    os_unfair_lock_unlock(&gLock);

    if (!d.length || w <= 0 || h <= 0) return nil;
    if (outW) *outW = w;
    if (outH) *outH = h;
    return d;
}

BOOL JJMetalFrameIsFresh(void) {
    os_unfair_lock_lock(&gLock);
    BOOL has = (gFrame.length > 0 && gFrameW > 0 && gFrameH > 0);
    CFTimeInterval ts = gFrameTs;
    os_unfair_lock_unlock(&gLock);
    return has && (CACurrentMediaTime() - ts <= JJ_FRAME_MAX_AGE);
}

CFTimeInterval JJMetalFrameAge(void) {
    os_unfair_lock_lock(&gLock);
    CFTimeInterval ts = gFrameTs;
    os_unfair_lock_unlock(&gLock);
    return ts > 0 ? (CACurrentMediaTime() - ts) : -1.0;
}

uint64_t JJMetalFrameSerial(void) {
    os_unfair_lock_lock(&gLock);
    uint64_t s = (uint64_t)gCaptureCount;
    os_unfair_lock_unlock(&gLock);
    return s;
}

NSString *JJMetalStatus(void) {
    os_unfair_lock_lock(&gLock);
    int cap = gCaptureCount, fail = gCaptureFail, miss = gSurfaceMiss, nd = gNextDrawableCount;
    os_unfair_lock_unlock(&gLock);
    /* 保持 1.1.42 起的字段顺序，新增 age/readBusy 便于判读 2.0 抓帧链路 */
    return [NSString stringWithFormat:
            @"nextDrawable=%d present=0 captured=%d fail=%d surfaceMiss=%d origMissing=0 enabled=%d age=%.1fs readBusy=%d",
            nd, cap, fail, miss, gCaptureEnabled ? 1 : 0,
            JJMetalFrameAge(), atomic_load(&gReadBusy)];
}

void JJMetalSetCaptureEnabled(BOOL enabled) {
    gCaptureEnabled = enabled;
    if (!enabled) {
        JJDropPending();
        os_unfair_lock_lock(&gLock);
        gFrame = nil;
        gFrameW = 0;
        gFrameH = 0;
        gFrameTs = 0;
        os_unfair_lock_unlock(&gLock);
        gLastReadTs = 0;
    gLastCopyTs = 0;
    gDigestValid = NO;
    }
    NSLog(@"[JJCheat] Metal 抓帧开关=%@", enabled ? @"开" : @"关");
}

BOOL JJMetalCaptureEnabled(void) {
    return gCaptureEnabled ? YES : NO;
}

/** hook 已由 Logos 的 %init 注册；这里只做一次启动诊断。 */
void JJMetalInstallHooks(void) {
    static BOOL logged = NO;
    if (logged) return;
    logged = YES;
    Class layerCls = NSClassFromString(@"CAMetalLayer");
    BOOL exists = layerCls && [layerCls instancesRespondToSelector:@selector(nextDrawable)];
    NSLog(@"[JJCheat] Metal hook(Logos): CAMetalLayer=%@ nextDrawable=%@ present 家族=已移除 读帧=独立队列",
          layerCls ? @"有" : @"没有", exists ? @"可 hook" : @"不可 hook");
}
