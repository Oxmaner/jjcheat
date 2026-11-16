//
//  JJMetalGrabber.m
//  JJCheat —— Metal 抓帧
//
//  链路：
//    CAMetalLayer -nextDrawable          ← 只用来确认「这游戏是 Metal」
//    MTLCommandBuffer -presentDrawable:  ← 在 present 之前 blit 读回 texture
//
//  CAMetalDrawable.texture 是 private storage，getBytes: 读不了，必须用
//  blit encoder 拷到 MTLResourceStorageModeShared 的 buffer 再读。
//  我们自己的 command buffer 不调 presentDrawable:，所以不会递归。
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
static BOOL gHooksInstalled = NO;
static IMP gOrigNextDrawable = NULL;
static NSMutableDictionary<NSString *, NSValue *> *gOrigPresentByClass = nil;

#pragma mark - 读回

static void JJMetalCapture(id drawable) {
    if (!drawable) return;
    if ((gPresentCount++ % 8) != 0) return;          // 每 8 帧抓一次，别拖慢游戏

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

#pragma mark - hooks

static void JJPresentDrawable(id self, SEL _cmd, id drawable);

static id JJNextDrawable(id self, SEL _cmd) {
    id d = ((id (*)(id, SEL))gOrigNextDrawable)(self, _cmd);
    if (++gNextDrawableCount == 1) {
        NSLog(@"[JJCheat] CAMetalLayer nextDrawable 命中 → 这游戏是 Metal 渲染");
    }
    return d;
}

/* 找原实现：先查本类记录，再沿父类链找一个「不是我们自己」的实现 */
static IMP JJFindOrigPresent(id self, SEL _cmd) {
    NSString *key = NSStringFromClass([self class]);
    IMP orig = key ? [gOrigPresentByClass[key] pointerValue] : NULL;
    if (orig && orig != (IMP)JJPresentDrawable) return orig;

    Class sup = class_getSuperclass([self class]);
    while (sup) {
        Method m = class_getInstanceMethod(sup, _cmd);
        if (m) {
            IMP imp = method_getImplementation(m);
            if (imp != (IMP)JJPresentDrawable) return imp;
        }
        sup = class_getSuperclass(sup);
    }
    return NULL;
}

static void JJPresentDrawable(id self, SEL _cmd, id drawable) {
    @try {
        JJMetalCapture(drawable);
    } @catch (NSException *e) {
        gCaptureFail++;
    }

    /* 无论如何都要把原始 present 调回去，否则画面直接黑 */
    IMP orig = JJFindOrigPresent(self, _cmd);
    if (orig) {
        ((void (*)(id, SEL, id))orig)(self, _cmd, drawable);
    } else {
        gCaptureFail++;
        if ((gCaptureFail % 200) == 1) {
            NSLog(@"[JJCheat] 警告：presentDrawable: 找不到原实现（%@），本帧未 present",
                  NSStringFromClass([self class]));
        }
    }
}

void JJMetalInstallHooks(void) {
    if (gHooksInstalled) return;
    gHooksInstalled = YES;

    @try {
        void *m = dlopen("/System/Library/Frameworks/Metal.framework/Metal", RTLD_LAZY);
        if (!m) dlopen("/System/Library/PrivateFrameworks/Metal.framework/Metal", RTLD_LAZY);

        gOrigPresentByClass = [NSMutableDictionary dictionary];

        Class layerCls = NSClassFromString(@"CAMetalLayer");
        if (layerCls) {
            Method nm = class_getInstanceMethod(layerCls, @selector(nextDrawable));
            if (nm) {
                gOrigNextDrawable = method_getImplementation(nm);
                method_setImplementation(nm, (IMP)JJNextDrawable);
            }
        }
        NSLog(@"[JJCheat] Metal: CAMetalLayer=%@ nextDrawable=%@",
              layerCls ? @"有" : @"没有", gOrigNextDrawable ? @"已 hook" : @"未 hook");

        /* 只 hook「自己实现了 presentDrawable:」的类（class_copyMethodList 不含继承），
           这样每个类的 orig 一定是它自己的实现，不会查不到。 */
        unsigned int count = 0;
        Class *classes = objc_copyClassList(&count);
        int hooked = 0;
        for (unsigned int i = 0; i < count; i++) {
            Class c = classes[i];
            unsigned int mcount = 0;
            Method *methods = class_copyMethodList(c, &mcount);
            if (!methods) continue;
            for (unsigned int k = 0; k < mcount; k++) {
                if (method_getName(methods[k]) != @selector(presentDrawable:)) continue;
                IMP cur = method_getImplementation(methods[k]);
                if (cur == (IMP)JJPresentDrawable) break;
                NSString *name = NSStringFromClass(c);
                if (!name) break;
                gOrigPresentByClass[name] = [NSValue valueWithPointer:cur];
                method_setImplementation(methods[k], (IMP)JJPresentDrawable);
                hooked++;
                break;
            }
            free(methods);
        }
        if (classes) free(classes);

        NSLog(@"[JJCheat] Metal hook 完成：presentDrawable 类数=%d", hooked);
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
    if (CACurrentMediaTime() - ts > 1.5) return nil;   /* 旧帧丢掉 */

    if (outW) *outW = w;
    if (outH) *outH = h;
    return d;
}

NSString *JJMetalStatus(void) {
    return [NSString stringWithFormat:@"nextDrawable=%d present=%d captured=%d fail=%d",
            gNextDrawableCount, gPresentCount, gCaptureCount, gCaptureFail];
}
