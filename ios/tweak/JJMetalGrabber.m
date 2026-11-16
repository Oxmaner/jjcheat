//
//  JJMetalGrabber.m
//  JJCheat —— Metal 抓帧
//
//  实测：这游戏不走 presentDrawable 家族（三个变体都 hook 上了，调用次数却停在 65），
//  但 CAMetalLayer -nextDrawable 每帧都在调。所以改成：
//    第 N 帧 nextDrawable 拿到 drawable → 记住它的 IOSurface（CFRetain）
//    第 N+1 帧 nextDrawable 之前 → 读这个 IOSurface（此时内容已渲染完、还没被复用）
//  好处：不依赖 present、不需要往渲染线程里塞 blit、拿到的就是游戏画面（不含我们的 HUD）。
//

#import "JJMetalGrabber.h"
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <IOSurface/IOSurface.h>
#import <objc/runtime.h>
#import <os/lock.h>
#import <dlfcn.h>

static id<MTLCommandQueue> gQueue = nil;
static NSData *gFrame = nil;
static int gFrameW = 0;
static int gFrameH = 0;
static CFTimeInterval gFrameTs = 0;
static os_unfair_lock gLock = OS_UNFAIR_LOCK_INIT;

static int gNextDrawableCount = 0;
static int gPresentCount = 0;
static int gCaptureCount = 0;
static int gCaptureFail = 0;
static int gOrigMissing = 0;
static int gSurfaceMiss = 0;
static BOOL gHooksInstalled = NO;
static IMP gOrigNextDrawable = NULL;

/* 抓帧按时间节流：读一次 = 14MB 拷贝 + 全帧 BGRA→RGBA，跑在游戏的渲染调用栈里。
   固定 5 fps（覆盖 JJ_SCAN_FPS 的 4 帧需求并留余量），不用「每 N 帧」——
   游戏帧率一变，读数就跟着失控。 */
static CFTimeInterval gLastReadTs = 0;
static const CFTimeInterval kJJReadInterval = 0.20;

/* 只统计 nextDrawable→IOSurface 这条路径出的帧，用来关掉重复的 present blit */
static int gSurfaceReadCount = 0;

/* 上一帧的 drawable surface，等下一次 nextDrawable 时读 */
static IOSurfaceRef gPendingSurface = NULL;
static int gPendingW = 0;
static int gPendingH = 0;

/* key = "类名#selector" -> 原 IMP */
static NSMutableDictionary<NSString *, NSValue *> *gOrigByKey = nil;

static void JJPresentDrawable(id self, SEL _cmd, id d);
static void JJPresentDrawableAtTime(id self, SEL _cmd, id d, double t);
static void JJPresentAfterMinDuration(id self, SEL _cmd, id d, double t);

#pragma mark - IOSurface 读取

static IOSurfaceRef JJDrawableSurface(id drawable) {
    if (!drawable) return NULL;
    SEL sel = @selector(iosurface);

    if ([drawable respondsToSelector:sel]) {
        typedef IOSurfaceRef (*Fn)(id, SEL);
        Fn fn = (Fn)[drawable methodForSelector:sel];
        if (fn) {
            IOSurfaceRef s = fn(drawable, sel);
            if (s) return s;
        }
    }
    id tex = [(id<CAMetalDrawable>)drawable texture];
    if (tex && [tex respondsToSelector:sel]) {
        typedef IOSurfaceRef (*Fn)(id, SEL);
        Fn fn = (Fn)[tex methodForSelector:sel];
        if (fn) return fn(tex, sel);
    }
    return NULL;
}

static void JJReadSurface(IOSurfaceRef s, int w, int h) {
    if (!s || w <= 0 || h <= 0) return;
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
       arm64 小端下 BGRA 内存序 B,G,R,A 读成 uint32 = A<<24|R<<16|G<<8|B。
       NSMutableData 的缓冲区按 16 字节对齐，need 一定是 4 的倍数。 */
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
    gSurfaceReadCount++;
}

#pragma mark - blit 兜底（present 路径真的存在时才有用）

static void JJMetalCapture(id drawable) {
    if (!drawable) return;
    int seq = gPresentCount++;
    /* nextDrawable 的 IOSurface 路径已稳定出帧后，present blit 纯属重复劳动：
       又要 GPU→CPU 同步读回 14MB，直接卡住渲染管线。只在 IOSurface 还没出过帧时
       保留它当兜底（某些设备 nextDrawable 拿不到 surface）。 */
    if (gSurfaceReadCount > 3) return;
    if ((seq % 8) != 0) return;

    id<MTLTexture> tex = [(id<CAMetalDrawable>)drawable texture];
    if (!tex) { gCaptureFail++; return; }
    id<MTLDevice> dev = tex.device;
    if (!dev) { gCaptureFail++; return; }

    NSUInteger w = tex.width, h = tex.height;
    if (w == 0 || h == 0 || w > 4096 || h > 4096) { gCaptureFail++; return; }

    if (!gQueue) gQueue = [dev newCommandQueue];
    if (!gQueue) { gCaptureFail++; return; }

    NSUInteger bpr = w * 4;
    id<MTLBuffer> buf = [dev newBufferWithLength:bpr * h options:MTLResourceStorageModeShared];
    if (!buf) { gCaptureFail++; return; }

    id<MTLCommandBuffer> cb = [gQueue commandBuffer];
    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
    if (!blit) { gCaptureFail++; return; }

    [blit copyFromTexture:tex
              sourceSlice:0 sourceLevel:0
             sourceOrigin:MTLOriginMake(0, 0, 0)
               sourceSize:MTLSizeMake(w, h, 1)
                 toBuffer:buf destinationOffset:0
        destinationBytesPerRow:bpr destinationBytesPerImage:bpr * h];
    [blit endEncoding];

    [cb addCompletedHandler:^(id<MTLCommandBuffer> _cb) {
        const uint8_t *src = (const uint8_t *)buf.contents;
        if (!src) { gCaptureFail++; return; }
        NSMutableData *out = [NSMutableData dataWithLength:bpr * h];
        uint8_t *dst = (uint8_t *)out.mutableBytes;
        for (NSUInteger i = 0; i + 3 < bpr * h; i += 4) {
            dst[i] = src[i + 2]; dst[i + 1] = src[i + 1];
            dst[i + 2] = src[i]; dst[i + 3] = src[i + 3];
        }
        os_unfair_lock_lock(&gLock);
        gFrame = out; gFrameW = (int)w; gFrameH = (int)h; gFrameTs = CACurrentMediaTime();
        os_unfair_lock_unlock(&gLock);
        gCaptureCount++;
    }];
    [cb commit];
}

#pragma mark - 原实现查找

static IMP JJFindOrig(id self, SEL _cmd) {
    Class c = [self class];
    NSString *selName = NSStringFromSelector(_cmd);
    while (c) {
        NSString *name = NSStringFromClass(c);
        if (name) {
            NSString *key = [NSString stringWithFormat:@"%@#%@", name, selName];
            NSValue *v = gOrigByKey[key];
            if (v) {
                IMP imp = (IMP)[v pointerValue];
                if (imp && imp != (IMP)JJPresentDrawable &&
                    imp != (IMP)JJPresentDrawableAtTime &&
                    imp != (IMP)JJPresentAfterMinDuration) return imp;
            }
        }
        c = class_getSuperclass(c);
    }
    return NULL;
}

#pragma mark - nextDrawable：核心

static id JJNextDrawable(id self, SEL _cmd) {
    int idx = gNextDrawableCount;
    CFTimeInterval now = CACurrentMediaTime();

    /* 先把上一帧的 surface 读掉（按时间节流，其余只释放）。
       不再用 idx%8：游戏掉帧/锁帧时那个计数会跟着乱，读帧频率不可控。 */
    if (gPendingSurface) {
        if (now - gLastReadTs >= kJJReadInterval) {
            JJReadSurface(gPendingSurface, gPendingW, gPendingH);
            gLastReadTs = now;
        }
        CFRelease(gPendingSurface);
        gPendingSurface = NULL;
    }

    id d = ((id (*)(id, SEL))gOrigNextDrawable)(self, _cmd);
    gNextDrawableCount = idx + 1;
    if (gNextDrawableCount == 1) {
        NSLog(@"[JJCheat] CAMetalLayer nextDrawable 命中 → 这游戏是 Metal 渲染");
    }

    if (d) {
        IOSurfaceRef s = JJDrawableSurface(d);
        if (s) {
            gPendingSurface = (IOSurfaceRef)CFRetain(s);
            gPendingW = (int)IOSurfaceGetWidth(s);
            gPendingH = (int)IOSurfaceGetHeight(s);
        } else {
            gSurfaceMiss++;
        }
    }
    return d;
}

#pragma mark - present 家族（保留，某些版本会走）

static void JJPresentDrawable(id self, SEL _cmd, id d) {
    @try { JJMetalCapture(d); } @catch (NSException *e) { gCaptureFail++; }
    IMP o = JJFindOrig(self, _cmd);
    if (o) ((void (*)(id, SEL, id))o)(self, _cmd, d);
    else if ((gOrigMissing++ % 100) == 1)
        NSLog(@"[JJCheat] present 原实现缺失（%@#presentDrawable:）", NSStringFromClass([self class]));
}

static void JJPresentDrawableAtTime(id self, SEL _cmd, id d, double t) {
    @try { JJMetalCapture(d); } @catch (NSException *e) { gCaptureFail++; }
    IMP o = JJFindOrig(self, _cmd);
    if (o) ((void (*)(id, SEL, id, double))o)(self, _cmd, d, t);
    else if ((gOrigMissing++ % 100) == 1)
        NSLog(@"[JJCheat] present 原实现缺失（%@#presentDrawable:atTime:）", NSStringFromClass([self class]));
}

static void JJPresentAfterMinDuration(id self, SEL _cmd, id d, double t) {
    @try { JJMetalCapture(d); } @catch (NSException *e) { gCaptureFail++; }
    IMP o = JJFindOrig(self, _cmd);
    if (o) ((void (*)(id, SEL, id, double))o)(self, _cmd, d, t);
    else if ((gOrigMissing++ % 100) == 1)
        NSLog(@"[JJCheat] present 原实现缺失（%@#presentDrawable:afterMinimumDuration:）",
              NSStringFromClass([self class]));
}

static void JJHookSelOnClass(Class c, SEL sel, IMP newImp, int *counter) {
    unsigned int mcount = 0;
    Method *methods = class_copyMethodList(c, &mcount);
    if (!methods) return;
    for (unsigned int k = 0; k < mcount; k++) {
        if (method_getName(methods[k]) != sel) continue;
        IMP cur = method_getImplementation(methods[k]);
        if (cur == newImp) break;
        NSString *name = NSStringFromClass(c);
        if (!name) break;
        NSString *key = [NSString stringWithFormat:@"%@#%@", name, NSStringFromSelector(sel)];
        gOrigByKey[key] = [NSValue valueWithPointer:cur];
        method_setImplementation(methods[k], newImp);
        if (counter) (*counter)++;
        break;
    }
    free(methods);
}

void JJMetalInstallHooks(void) {
    if (gHooksInstalled) return;
    gHooksInstalled = YES;

    @try {
        if (!gOrigByKey) gOrigByKey = [NSMutableDictionary dictionary];

        void *m = dlopen("/System/Library/Frameworks/Metal.framework/Metal", RTLD_LAZY);
        if (!m) dlopen("/System/Library/PrivateFrameworks/Metal.framework/Metal", RTLD_LAZY);

        Class layerCls = NSClassFromString(@"CAMetalLayer");
        if (layerCls) {
            Method nm = class_getInstanceMethod(layerCls, @selector(nextDrawable));
            if (nm) {
                gOrigNextDrawable = method_getImplementation(nm);
                method_setImplementation(nm, (IMP)JJNextDrawable);
            }
        }

        unsigned int count = 0;
        Class *classes = objc_copyClassList(&count);
        int c1 = 0, c2 = 0, c3 = 0;
        for (unsigned int i = 0; i < count; i++) {
            Class c = classes[i];
            JJHookSelOnClass(c, @selector(presentDrawable:), (IMP)JJPresentDrawable, &c1);
            JJHookSelOnClass(c, @selector(presentDrawable:atTime:), (IMP)JJPresentDrawableAtTime, &c2);
            JJHookSelOnClass(c, @selector(presentDrawable:afterMinimumDuration:),
                             (IMP)JJPresentAfterMinDuration, &c3);
        }
        if (classes) free(classes);

        NSLog(@"[JJCheat] Metal hook: CAMetalLayer=%@ nextDrawable=%@ present 家族=%d/%d/%d"
              @"（抓帧走 nextDrawable 的 IOSurface）",
              layerCls ? @"有" : @"没有", gOrigNextDrawable ? @"已 hook" : @"未 hook", c1, c2, c3);
    } @catch (NSException *e) {
        NSLog(@"[JJCheat] Metal hook 安装异常: %@", e);
    }
}

#pragma mark - 对外

NSData *JJMetalFrameCopy(int *outW, int *outH) {
    os_unfair_lock_lock(&gLock);
    NSData *d = gFrame;
    int w = gFrameW, h = gFrameH;
    CFTimeInterval ts = gFrameTs;
    os_unfair_lock_unlock(&gLock);

    if (!d.length || w <= 0 || h <= 0) return nil;
    /* 结算页/对方思考时游戏会主动降帧甚至停渲染，1.5s 太容易误判「无帧」，
       一误判就掉到 CALayer 全屏 renderInContext（主线程重活 + 拿到全黑帧）。
       放宽到 5s，配合 JJScreenGrabber 的有效帧缓存兜底。 */
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
    return [NSString stringWithFormat:
            @"nextDrawable=%d present=%d captured=%d fail=%d surfaceMiss=%d origMissing=%d",
            gNextDrawableCount, gPresentCount, gCaptureCount, gCaptureFail, gSurfaceMiss, gOrigMissing];
}
