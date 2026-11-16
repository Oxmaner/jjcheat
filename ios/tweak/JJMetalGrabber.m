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

static id JJNextDrawable(id self, SEL _cmd) {
    id d = ((id (*)(id, SEL))gOrigNextDrawable)(self, _cmd);
    if (++gNextDrawableCount == 1) {
        NSLog(@"[JJCheat] CAMetalLayer nextDrawable 命中 → 这游戏是 Metal 渲染");
    }
    return d;
}

static void JJPresentDrawable(id self, SEL _cmd, id drawable) {
    @try {
        JJMetalCapture(drawable);
    } @catch (NSException *e) {
        gCaptureFail++;
    }
    IMP orig = nil;
    NSString *key = NSStringFromClass([self class]);
    if (key) orig = [gOrigPresentByClass[key] pointerValue];
    if (orig) {
        ((void (*)(id, SEL, id))orig)(self, _cmd, drawable);
    }
}

void JJMetalInstallHooks(void) {
    if (gHooksInstalled) return;
    gHooksInstalled = YES;

    /* Metal framework 可能是懒加载的 */
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

    /* presentDrawable: 定义在若干私有 command buffer 类上，扫一遍全装上 */
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    int hooked = 0;
    for (unsigned int i = 0; i < count; i++) {
        Class c = classes[i];
        Method pm = class_getInstanceMethod(c, @selector(presentDrawable:));
        if (!pm) continue;
        IMP cur = method_getImplementation(pm);
        if (cur == (IMP)JJPresentDrawable) continue;   /* 父类已装 */
        NSString *name = NSStringFromClass(c);
        if (!name) continue;
        gOrigPresentByClass[name] = [NSValue valueWithPointer:cur];
        method_setImplementation(pm, (IMP)JJPresentDrawable);
        hooked++;
    }
    if (classes) free(classes);

    NSLog(@"[JJCheat] Metal hook: nextDrawable=%@ presentDrawable 类数=%d CAMetalLayer=%@",
          gOrigNextDrawable ? @"装" : @"没装", hooked, layerCls ? @"有" : @"没有");
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
