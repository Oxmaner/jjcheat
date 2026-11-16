//
//  JJMetalGrabber.m
//  JJCheat —— Metal 抓帧（1.1.44）
//
//  实测：这游戏不走 presentDrawable 家族（三个变体都 hook 上了，调用次数却停在 65），
//  但 CAMetalLayer -nextDrawable 每帧都在调。所以：
//    第 N 帧 nextDrawable 拿到 drawable → 记住它的 IOSurface（CFRetain）
//    第 N+1 帧 nextDrawable 之前 → 读这个 IOSurface（此时内容已渲染完、还没被复用）
//  好处：不依赖 present、不往渲染线程里塞 blit、拿到的就是游戏画面（不含 HUD）。
//
//  【1.1.44 架构变更】
//   - hook 本身迁到 Tweak.x 的 `%hook CAMetalLayer`（%orig 自动处理原实现），
//     本文件不再有 method_setImplementation / 全类表遍历，也不再遍历 present 家族。
//     本游戏实测 present 计数冻结在 65~78，那段代码纯属启动开销与误伤风险。
//   - pending surface 全部走 gSurfLock：JJMetalSetCaptureEnabled 在主线程、
//     nextDrawable 在渲染线程，1.1.43 之前两边无锁并发，关插件时可能 UAF。
//   - 按需读帧：上一帧还没被上层取走就不再做 14MB 拷贝，读帧间隔 1.0→1.5s。
//

#import "JJMetalGrabber.h"
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <QuartzCore/CAMetalLayer.h>
#import <IOSurface/IOSurface.h>
#import <os/lock.h>

static NSData *gFrame = nil;
static int gFrameW = 0;
static int gFrameH = 0;
static CFTimeInterval gFrameTs = 0;
static os_unfair_lock gLock = OS_UNFAIR_LOCK_INIT;

static int gNextDrawableCount = 0;
static int gCaptureCount = 0;
static int gCaptureFail = 0;
static int gSurfaceMiss = 0;

/* 抓帧总开关：默认关。待机（只挂悬浮球）和插件关闭时真的不读帧。 */
static volatile BOOL gCaptureEnabled = NO;
/* 1 = 上一帧已被上层消费，渲染线程可以再读一帧；0 = 新帧还在缓存里没被取走。
   旧版按固定频率硬读，JS 还没空处理就又拷一张 14MB，纯烧渲染线程。 */
static volatile int gFrameConsumed = 1;

/* 读一帧 = 14MB memcpy + 350 万次 32 位 R/B 交换，跑在游戏渲染调用栈里。
   真机 process 实际 2~3 秒才一次，1.5s 一帧足够，别再 0.2s/1.0s 硬刷。 */
static CFTimeInterval gLastReadTs = 0;
static const CFTimeInterval kJJReadInterval = 1.5;

/* pending surface 的所有访问都必须经过这把锁 */
static os_unfair_lock gSurfLock = OS_UNFAIR_LOCK_INIT;
static IOSurfaceRef gPendingSurface = NULL;
static int gPendingW = 0;
static int gPendingH = 0;

/* 老版本 Unity 的 drawable 自身直接实现了 -iosurface（私有 selector），
   补一个局部协议后用括号语法调用，替代 methodForSelector + 函数指针强转。
   不给 NSObject 加分类：那会污染进程内所有对象的方法解析。
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

#pragma mark - IOSurface 读取

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

static void JJReadSurface(IOSurfaceRef s, int w, int h) {
    if (!gCaptureEnabled || !s || w <= 0 || h <= 0) return;
    if (IOSurfaceLock(s, kIOSurfaceLockReadOnly, NULL) != KERN_SUCCESS) {
        gCaptureFail++;
        return;
    }

    size_t bpr = IOSurfaceGetBytesPerRow(s);
    void *base = IOSurfaceGetBaseAddress(s);
    if (!base) {
        IOSurfaceUnlock(s, kIOSurfaceLockReadOnly, NULL);
        gCaptureFail++;
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

    /* IOSurface 是 BGRA，转 RGBA。
       用 32 位整字一次交换 R/B，比逐字节循环少 2/3 的内存访问：
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
    os_unfair_lock_unlock(&gLock);
    gCaptureCount++;
    gFrameConsumed = 0;
}

#pragma mark - Logos hook 的两个钩子（由 Tweak.x 调用）

/** %orig 之前：把上一帧的 surface 读掉（或丢弃），立即释放 */
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
    /* 按需读帧 + 时间节流：上一帧没被消费就别再拷 14MB，
       游戏掉帧时也不会因为帧号变化反复触发读回。 */
    if (gFrameConsumed && (now - gLastReadTs >= kJJReadInterval)) {
        JJReadSurface(s, w, h);
        gLastReadTs = now;
    }
    CFRelease(s);
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
    /* 必须无条件放行：上层 tick 被 busy / 退避挡住时不会走到这里，缓存帧可能
       一直过期；若只在「取到有效帧」时才置 1，gFrameConsumed 会永久卡在 0，
       渲染线程再也不读新帧 —— 整个抓帧链路静默死锁。 */
    gFrameConsumed = 1;

    os_unfair_lock_lock(&gLock);
    NSData *d = gFrame;
    int w = gFrameW, h = gFrameH;
    CFTimeInterval ts = gFrameTs;
    os_unfair_lock_unlock(&gLock);

    if (!d.length || w <= 0 || h <= 0) return nil;
    /* 结算页/对方思考时游戏会降帧甚至停渲染，5s 内复用上一张有效帧，
       避免掉进 CALayer 全屏 renderInContext（主线程重活 + 全黑帧）。 */
    if (CACurrentMediaTime() - ts > 5.0) return nil;

    if (outW) *outW = w;
    if (outH) *outH = h;
    return d;
}

uint64_t JJMetalFrameSerial(void) {
    os_unfair_lock_lock(&gLock);
    uint64_t s = (uint64_t)gCaptureCount;
    os_unfair_lock_unlock(&gLock);
    return s;
}

NSString *JJMetalStatus(void) {
    /* 保持 1.1.42 起的日志字段顺序，HANDOFF 的判读基准不用改 */
    return [NSString stringWithFormat:
            @"nextDrawable=%d present=0 captured=%d fail=%d surfaceMiss=%d origMissing=0 enabled=%d",
            gNextDrawableCount, gCaptureCount, gCaptureFail, gSurfaceMiss,
            gCaptureEnabled ? 1 : 0];
}

void JJMetalSetCaptureEnabled(BOOL enabled) {
    gCaptureEnabled = enabled;
    if (!enabled) {
        JJDropPending();
        os_unfair_lock_lock(&gLock);
        gFrame = nil;
        gFrameW = 0;
        gFrameH = 0;
        os_unfair_lock_unlock(&gLock);
        gFrameConsumed = 1;
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
    NSLog(@"[JJCheat] Metal hook(Logos): CAMetalLayer=%@ nextDrawable=%@ present 家族=已移除",
          layerCls ? @"有" : @"没有", exists ? @"可 hook" : @"不可 hook");
}
