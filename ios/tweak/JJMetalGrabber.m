//
//  JJMetalGrabber.m
//  JJCheat —— Metal 抓帧
//
//  链路：
//    CAMetalLayer -nextDrawable                    ← 确认「这游戏是 Metal」，同时计数
//    MTLCommandBuffer -presentDrawable:            ← 在 present 之前 blit 读回 texture
//    MTLCommandBuffer -presentDrawable:atTime:     ← iOS 游戏常用（帧率控制）
//    MTLCommandBuffer -presentDrawable:afterMinimumDuration:
//
//  CAMetalDrawable.texture 是 private storage，getBytes: 读不了，必须 blit 到
//  MTLResourceStorageModeShared 的 buffer 再读。我们自己的 command buffer 不调
//  presentDrawable:，所以不会递归。
//

#import "JJMetalGrabber.h"
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
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
static BOOL gHooksInstalled = NO;
static IMP gOrigNextDrawable = NULL;

/* key = "类名#selector" -> 原 IMP（同一个类可能同时实现三个 present 变体） */
static NSMutableDictionary<NSString *, NSValue *> *gOrigByKey = nil;

static void JJPresentDrawable(id self, SEL _cmd, id d);
static void JJPresentDrawableAtTime(id self, SEL _cmd, id d, double t);
static void JJPresentAfterMinDuration(id self, SEL _cmd, id d, double t);

#pragma mark - 读回

static void JJMetalCapture(id drawable) {
    if (!drawable) return;
    if ((gPresentCount++ % 8) != 0) return;          /* 每 8 次 present 抓一帧 */

    id<MTLTexture> tex = [(id<CAMetalDrawable>)drawable texture];
    if (!tex) { gCaptureFail++; return; }
    id<MTLDevice> dev = tex.device;
    if (!dev) { gCaptureFail++; return; }

    NSUInteger w = tex.width, h = tex.height;
    if (w == 0 || h == 0 || w > 4096 || h > 4096) { gCaptureFail++; return; }

    if (!gQueue) gQueue = [dev newCommandQueue];
    if (!gQueue) { gCaptureFail++; return; }

    NSUInteger bpr = w * 4;
    id<MTLBuffer> buf = [dev newBufferWithLength:bpr * h
                                         options:MTLResourceStorageModeShared];
    if (!buf) { gCaptureFail++; return; }

    id<MTLCommandBuffer> cb = [gQueue commandBuffer];
    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
    if (!blit) { gCaptureFail++; return; }

    [blit copyFromTexture:tex
              sourceSlice:0
              sourceLevel:0
             sourceOrigin:MTLOriginMake(0, 0, 0)
               sourceSize:MTLSizeMake(w, h, 1)
                 toBuffer:buf
        destinationOffset:0
   destinationBytesPerRow:bpr
  destinationBytesPerImage:bpr * h];
    [blit endEncoding];

    BOOL bgra = (tex.pixelFormat == MTLPixelFormatBGRA8Unorm ||
                 tex.pixelFormat == MTLPixelFormatBGRA8Unorm_sRGB);

    [cb addCompletedHandler:^(id<MTLCommandBuffer> _cb) {
        const uint8_t *src = (const uint8_t *)buf.contents;
        if (!src) { gCaptureFail++; return; }

        NSMutableData *out = [NSMutableData dataWithLength:bpr * h];
        uint8_t *dst = (uint8_t *)out.mutableBytes;
        if (bgra) {
            for (NSUInteger i = 0; i < bpr * h; i += 4) {
                dst[i]     = src[i + 2];
                dst[i + 1] = src[i + 1];
                dst[i + 2] = src[i];
                dst[i + 3] = src[i + 3];
            }
        } else {
            memcpy(dst, src, bpr * h);
        }

        os_unfair_lock_lock(&gLock);
        gFrame = out;
        gFrameW = (int)w;
        gFrameH = (int)h;
        gFrameTs = CACurrentMediaTime();
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
                    imp != (IMP)JJPresentAfterMinDuration) {
                    return imp;
                }
            }
        }
        c = class_getSuperclass(c);
    }
    return NULL;
}

#pragma mark - hooks

static id JJNextDrawable(id self, SEL _cmd) {
    id d = ((id (*)(id, SEL))gOrigNextDrawable)(self, _cmd);
    if (++gNextDrawableCount == 1) {
        NSLog(@"[JJCheat] CAMetalLayer nextDrawable 命中 → 这游戏是 Metal 渲染");
    }
    return d;
}

static void JJPresentDrawable(id self, SEL _cmd, id d) {
    @try { JJMetalCapture(d); } @catch (NSException *e) { gCaptureFail++; }
    IMP o = JJFindOrig(self, _cmd);
    if (o) ((void (*)(id, SEL, id))o)(self, _cmd, d);
    else if ((gOrigMissing++ % 100) == 1) {
        NSLog(@"[JJCheat] present 原实现缺失（%@#presentDrawable:）", NSStringFromClass([self class]));
    }
}

static void JJPresentDrawableAtTime(id self, SEL _cmd, id d, double t) {
    @try { JJMetalCapture(d); } @catch (NSException *e) { gCaptureFail++; }
    IMP o = JJFindOrig(self, _cmd);
    if (o) ((void (*)(id, SEL, id, double))o)(self, _cmd, d, t);
    else if ((gOrigMissing++ % 100) == 1) {
        NSLog(@"[JJCheat] present 原实现缺失（%@#presentDrawable:atTime:）", NSStringFromClass([self class]));
    }
}

static void JJPresentAfterMinDuration(id self, SEL _cmd, id d, double t) {
    @try { JJMetalCapture(d); } @catch (NSException *e) { gCaptureFail++; }
    IMP o = JJFindOrig(self, _cmd);
    if (o) ((void (*)(id, SEL, id, double))o)(self, _cmd, d, t);
    else if ((gOrigMissing++ % 100) == 1) {
        NSLog(@"[JJCheat] present 原实现缺失（%@#presentDrawable:afterMinimumDuration:）",
              NSStringFromClass([self class]));
    }
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

        NSLog(@"[JJCheat] Metal hook: CAMetalLayer=%@ nextDrawable=%@ "
              @"presentDrawable=%d atTime=%d afterMinDuration=%d",
              layerCls ? @"有" : @"没有",
              gOrigNextDrawable ? @"已 hook" : @"未 hook", c1, c2, c3);
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
    if (CACurrentMediaTime() - ts > 1.5) return nil;

    if (outW) *outW = w;
    if (outH) *outH = h;
    return d;
}

NSString *JJMetalStatus(void) {
    return [NSString stringWithFormat:@"nextDrawable=%d present=%d captured=%d fail=%d origMissing=%d",
            gNextDrawableCount, gPresentCount, gCaptureCount, gCaptureFail, gOrigMissing];
}
