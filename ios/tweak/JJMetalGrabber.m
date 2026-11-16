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
static CFTimeInterval gLastReadTs = 0;

/* pending surface 的所有访问都必须经过这把锁：
   JJMetalSetCaptureEnabled 在主线程、nextDrawable 在渲染线程。 */
static os_unfair_lock gSurfLock = OS_UNFAIR_LOCK_INIT;
static IOSurfaceRef gPendingSurface = NULL;
static int gPendingW = 0;
static int gPendingH = 0;

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

    /* IOSurface 是 BGRA，转 RGBA。32 位整字一次交换 R/B：
       arm64 小端下 BGRA 内存序 B,G,R,A 读成 uint32 = A<<24|R<<16|G<<8|B。 */
    uint32_t *p32 = (uint32_t *)dst;
    size_t n32 = need / 4;
    for (size_t i = 0; i < n32; i++) {
        uint32_t v = p32[i];
        p32[i] = (v & 0xFF00FF00u) | ((v & 0x000000FFu) << 16) | ((v & 0x00FF0000u) >> 16);
    }

    os_unfair_lock_lock(&gLock);
    gFrame = out;
    gFrameW = w;
    gFrameH = h;
    gFrameTs = CACurrentMediaTime();
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
    /* 与上层是否处理完全解耦：固定低频产出新帧，读帧队列空闲就派发。
       1.1.44 的 gFrameConsumed 让「上层一退避就永久不读帧」，已删除。 */
    int expected = 0;
    if (atomic_compare_exchange_strong(&gReadBusy, &expected, 1) &&
        (now - gLastReadTs >= JJ_METAL_READ_INTERVAL)) {
        gLastReadTs = now;
        dispatch_async(JJReadQueue(), ^{
            JJReadSurface(s, w, h);
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
    }
    NSLog(@"[JJCheat] Metal 抓帧开关=%@", enabled ? @"开" : @"关");
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
