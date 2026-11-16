//
//  JJScreenGrabber.m
//  JJCheat
//

#import "JJScreenGrabber.h"
#import "JJConfig.h"
#import "JJMetalGrabber.h"
#import <IOSurface/IOSurface.h>
#import <QuartzCore/QuartzCore.h>
#import <OpenGLES/ES3/gl.h>
#import <OpenGLES/EAGL.h>
#import <dlfcn.h>
#import <mach/mach.h>
#import <os/lock.h>

/* ---------- CARenderServer 私有 API ---------- */
typedef mach_port_t (*CARenderServerGetServerPort_t)(mach_port_t);
typedef void (*CARenderServerRenderDisplay_t)(mach_port_t, CFStringRef, IOSurfaceRef, int, int);

static CARenderServerGetServerPort_t  s_getServerPort  = NULL;
static CARenderServerRenderDisplay_t  s_renderDisplay  = NULL;
static mach_port_t                    s_serverPort     = MACH_PORT_NULL;
static BOOL                           s_apiResolved    = NO;
static BOOL                           s_apiUsable      = NO;
static int                            s_glHookFrames   = 0;
static int                            s_grabLogCount   = 0;
static int                            s_rsFailStreak   = 0;
static int                            s_blackFrames    = 0;
/* 启动阶段 Metal 还没出帧时，CARenderServer / CALayer 都是主线程重活
   （14MB 位图 + 1284x2778 全屏 renderInContext），roothide 下还必然全黑。
   1.1.44：4Hz tick 下每 250ms 跑一次会把主线程打满，这里限到 1.5s 一次。 */
static CFTimeInterval                 s_lastHeavyFallbackTs = 0;
/* 最近一张内容有效的 Metal 帧：游戏停渲染时短暂复用，避免掉进全屏 CALayer 回退。
   2.0.0 必须带时间戳：1.1.44 这张缓存永久有效，16:00 真机日志里 12 分钟
   都在拿同一张旧图跑模板匹配 → 间歇性卡顿 + 新对局再也识别不出来。 */
static NSData *                       s_lastGoodMetal  = nil;
static int                            s_lastGoodW      = 0;
static int                            s_lastGoodH      = 0;
static CFTimeInterval                 s_lastGoodTs     = 0;

@interface JJScreenGrabber () {
    IOSurfaceRef   _surface;
    int            _surfW;
    int            _surfH;
    NSData        *_glFrame;
    int            _glW;
    int            _glH;
    CFTimeInterval _glFrameTimestamp;
    os_unfair_lock _lock;
}
@property (nonatomic, strong) NSString *activeMethod;
@end

@implementation JJScreenGrabber

+ (instancetype)shared {
    static JJScreenGrabber *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[JJScreenGrabber alloc] init]; });
    return s;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _lock = OS_UNFAIR_LOCK_INIT;
        _activeMethod = @"none";
        [self resolvePrivateAPI];
    }
    return self;
}

- (void)resolvePrivateAPI {
    if (s_apiResolved) return;
    s_apiResolved = YES;

    /* 先在 QuartzCore 这个明确 image 里找，避免 RTLD_DEFAULT 全局符号搜索
       命中别的库同名符号；只有该 image 里没有时才退回全局兜底。 */
    void *qc = dlopen("/System/Library/Frameworks/QuartzCore.framework/QuartzCore", RTLD_LAZY);
    if (qc) {
        s_renderDisplay = (CARenderServerRenderDisplay_t)dlsym(qc, "CARenderServerRenderDisplay");
        s_getServerPort = (CARenderServerGetServerPort_t)dlsym(qc, "CARenderServerGetServerPort");
        if (!s_getServerPort) {
            s_getServerPort = (CARenderServerGetServerPort_t)dlsym(qc, "CARenderServerGetServerPort2");
        }
    }
    if (!s_renderDisplay) {
        s_renderDisplay = (CARenderServerRenderDisplay_t)dlsym(RTLD_DEFAULT, "CARenderServerRenderDisplay");
    }
    if (!s_getServerPort) {
        s_getServerPort = (CARenderServerGetServerPort_t)dlsym(RTLD_DEFAULT, "CARenderServerGetServerPort");
        if (!s_getServerPort) {
            s_getServerPort = (CARenderServerGetServerPort_t)dlsym(RTLD_DEFAULT, "CARenderServerGetServerPort2");
        }
    }

    if (s_renderDisplay && s_getServerPort) {
        s_serverPort = s_getServerPort(MACH_PORT_NULL);
        s_apiUsable = (s_serverPort != MACH_PORT_NULL);
    }
    NSLog(@"[JJCheat] CARenderServer: render=%p port=%p usable=%d",
          s_renderDisplay, (void *)s_serverPort, s_apiUsable);
}

- (void)start {
    [self resolvePrivateAPI];
}

- (void)stop {
    if (_surface) {
        CFRelease(_surface);
        _surface = NULL;
        _surfW = _surfH = 0;
    }
}

- (CGSize)pixelSize {
    UIScreen *sc = [UIScreen mainScreen];
    CGSize s = sc.nativeBounds.size;
    if (s.width <= 0 || s.height <= 0) {
        s = CGSizeMake(sc.bounds.size.width * sc.scale, sc.bounds.size.height * sc.scale);
    }
    return s;
}

- (BOOL)ensureSurface:(int)w height:(int)h {
    if (_surface && _surfW == w && _surfH == h) return YES;
    if (_surface) { CFRelease(_surface); _surface = NULL; }

    NSDictionary *props = @{
        @"IOSurfaceWidth"           : @(w),
        @"IOSurfaceHeight"          : @(h),
        @"IOSurfaceBytesPerElement" : @(4),
        @"IOSurfaceBytesPerRow"     : @(w * 4),
        @"IOSurfaceAllocSize"       : @(w * h * 4),
        @"IOSurfacePixelFormat"     : @((uint32_t)0x42475241), /* 'BGRA' */
        @"IOSurfaceIsGlobal"        : @YES,
    };
    _surface = IOSurfaceCreate((__bridge CFDictionaryRef)props);
    if (!_surface) {
        NSLog(@"[JJCheat] IOSurfaceCreate 失败 (%dx%d)", w, h);
        return NO;
    }
    _surfW = w;
    _surfH = h;
    return YES;
}

/* BGRA -> RGBA 就地交换 R/B */
static void swapRB(uint32_t *p, size_t count) {
    for (size_t i = 0; i < count; i++) {
        uint32_t v = p[i];
        p[i] = (v & 0xFF00FF00u) | ((v & 0x000000FFu) << 16) | ((v >> 16) & 0x000000FFu);
    }
}

- (NSData *)grabViaRenderServerWithWidth:(int *)outW height:(int *)outH {
    if (!s_apiUsable || !s_renderDisplay) return nil;
    CGSize px = [self pixelSize];
    int w = (int)px.width, h = (int)px.height;
    if (w <= 0 || h <= 0) return nil;
    if (![self ensureSurface:w height:h]) return nil;

    s_renderDisplay(s_serverPort, CFSTR("LCD"), _surface, 0, 0);

    if (IOSurfaceLock(_surface, kIOSurfaceLockReadOnly, NULL) != KERN_SUCCESS) return nil;
    size_t bpr = IOSurfaceGetBytesPerRow(_surface);
    void *base = IOSurfaceGetBaseAddress(_surface);
    if (!base) { IOSurfaceUnlock(_surface, kIOSurfaceLockReadOnly, NULL); return nil; }

    size_t need = (size_t)w * h * 4;
    NSMutableData *out = [NSMutableData dataWithLength:need];
    uint8_t *dst = (uint8_t *)out.mutableBytes;
    if (bpr == (size_t)w * 4) {
        memcpy(dst, base, need);
    } else {
        for (int y = 0; y < h; y++) {
            memcpy(dst + (size_t)y * w * 4, (uint8_t *)base + (size_t)y * bpr, (size_t)w * 4);
        }
    }
    IOSurfaceUnlock(_surface, kIOSurfaceLockReadOnly, NULL);

    swapRB((uint32_t *)dst, (size_t)w * h);
    self.activeMethod = @"CARenderServer";
    if (outW) *outW = w;
    if (outH) *outH = h;
    return out;
}

- (void)captureGLContext:(id)context target:(NSUInteger)target {
    EAGLContext *ctx = (EAGLContext *)context;
    if (![ctx isKindOfClass:[EAGLContext class]]) return;
    if ([EAGLContext currentContext] != ctx) {
        [EAGLContext setCurrentContext:ctx];
    }
    GLint vp[4] = {0, 0, 0, 0};
    glGetIntegerv(GL_VIEWPORT, vp);
    int w = vp[2], h = vp[3];
    if (w <= 0 || h <= 0) return;
    size_t need = (size_t)w * h * 4;
    NSMutableData *buf = [NSMutableData dataWithLength:need];
    glPixelStorei(GL_PACK_ALIGNMENT, 1);
    glReadPixels(0, 0, w, h, GL_RGBA, GL_UNSIGNED_BYTE, buf.mutableBytes);
    // OpenGL 原点在左下，翻转成左上
    uint8_t *src = (uint8_t *)buf.mutableBytes;
    NSMutableData *flipped = [NSMutableData dataWithLength:need];
    uint8_t *dst = (uint8_t *)flipped.mutableBytes;
    size_t rowBytes = (size_t)w * 4;
    for (int y = 0; y < h; y++) {
        memcpy(dst + (size_t)y * rowBytes, src + (size_t)(h - 1 - y) * rowBytes, rowBytes);
    }
    os_unfair_lock_lock(&_lock);
    _glFrame = flipped;
    _glW = w; _glH = h;
    _glFrameTimestamp = CACurrentMediaTime();
    os_unfair_lock_unlock(&_lock);

    if ((s_glHookFrames++ % 60) == 0) {
        const uint8_t *p = (const uint8_t *)flipped.bytes;
        size_t c = (size_t)(h / 2) * (size_t)w * 4 + (size_t)(w / 2) * 4;
        int r = -1, g = -1, b = -1;
        if (p && c + 2 < (size_t)need) { r = p[c]; g = p[c + 1]; b = p[c + 2]; }
        NSLog(@"[JJCheat] GL hook 第 %d 帧 %dx%d 中心像素=(%d,%d,%d)", s_glHookFrames, w, h, r, g, b);
    }
}

- (NSData *)grabViaGLCacheWithWidth:(int *)outW height:(int *)outH {
    os_unfair_lock_lock(&_lock);
    NSData *f = _glFrame;
    int w = _glW, h = _glH;
    CFTimeInterval ts = _glFrameTimestamp;
    os_unfair_lock_unlock(&_lock);
    if (!f || w <= 0 || h <= 0) return nil;
    // 超过 1 秒的旧帧丢掉
    if (CACurrentMediaTime() - ts > 1.0) return nil;
    self.activeMethod = @"GL-hook";
    if (outW) *outW = w;
    if (outH) *outH = h;
    return f;
}

- (NSData *)grabViaMetalWithWidth:(int *)outW height:(int *)outH {
    /* 2.0.0：新鲜度硬闸门。1.1.44 让 JJMetalFrameCopy 自带 5s 过期，
       与上层退避叠加后恒返回 nil，再被下面的永久缓存兜住 → 静默死锁。
       现在过期就直接不给帧，上层宁可跳过这一轮也不拿旧图跑 JS。 */
    if (!JJMetalFrameIsFresh()) return nil;
    NSData *d = JJMetalFrameCopy(outW, outH);
    static int s_metalLog = 0;
    if ((s_metalLog++ % 25) == 0) {
        NSLog(@"[JJCheat] Metal 状态 %@ (frame=%d B)", JJMetalStatus(), (int)d.length);
    }
    if (d.length) self.activeMethod = @"Metal";
    return d;
}

- (NSData *)grabViaLayerWithWidth:(int *)outW height:(int *)outH {
    UIWindow *win = nil;
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (w.isKeyWindow) { win = w; break; }
    }
    if (!win) win = [UIApplication sharedApplication].windows.firstObject;
    if (!win) return nil;

    CGSize px = [self pixelSize];
    int w = (int)px.width, h = (int)px.height;
    if (w <= 0 || h <= 0) return nil;

    size_t need = (size_t)w * h * 4;
    NSMutableData *out = [NSMutableData dataWithLength:need];
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef cg = CGBitmapContextCreate(out.mutableBytes, w, h, 8, (size_t)w * 4, cs,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(cs);
    if (!cg) return nil;
    UIGraphicsPushContext(cg);
    CGContextTranslateCTM(cg, 0, h);
    CGContextScaleCTM(cg, (CGFloat)w / win.bounds.size.width, -(CGFloat)h / win.bounds.size.height);
    [win.layer renderInContext:cg];
    UIGraphicsPopContext();
    CGContextRelease(cg);

    self.activeMethod = @"CALayer";
    if (outW) *outW = w;
    if (outH) *outH = h;
    return out;
}

/* 抓帧来源 + 一个像素样本（每 20 次打一条，避免刷屏） */
- (void)logGrabSource:(NSString *)src data:(NSData *)d w:(int *)outW h:(int *)outH {
    if ((s_grabLogCount++ % 20) != 0) return;
    int w = outW ? *outW : 0, h = outH ? *outH : 0;
    const uint8_t *p = (const uint8_t *)d.bytes;
    size_t c = (size_t)(h / 2) * (size_t)w * 4 + (size_t)(w / 2) * 4;
    int r = -1, g = -1, b = -1;
    if (p && c + 2 < d.length) { r = p[c]; g = p[c + 1]; b = p[c + 2]; }
    NSLog(@"[JJCheat] 抓帧来源=%@ %dx%d 中心像素=(%d,%d,%d)", src, w, h, r, g, b);
}


/* 抽样判断是不是纯黑帧。
   roothide 下 CARenderServer 会「成功」返回一张全黑图（端口拿到了、长度也对），
   必须验内容，否则永远不会回退到 GL。 */
static BOOL JJFrameIsBlack(NSData *d, int w, int h) {
    if (!d.length || w <= 0 || h <= 0) return YES;
    const uint8_t *p = (const uint8_t *)d.bytes;
    NSUInteger len = d.length;
    int sampled = 0, lit = 0;
    for (int gy = 1; gy <= 8; gy++) {
        for (int gx = 1; gx <= 6; gx++) {
            int x = w * gx / 7;
            int y = h * gy / 9;
            NSUInteger o = ((NSUInteger)y * (NSUInteger)w + (NSUInteger)x) * 4;
            if (o + 2 >= len) continue;
            sampled++;
            if (p[o] > 8 || p[o + 1] > 8 || p[o + 2] > 8) lit++;
        }
    }
    return (sampled > 0 && lit == 0);
}

- (NSData *)grabRGBAWithWidth:(int *)outW height:(int *)outH {
    int w = 0, h = 0;
    NSData *d = nil;

    /* ① GL-hook 优先：在进程内读游戏自己的 framebuffer，不受 roothide 沙箱影响 */
    d = [self grabViaGLCacheWithWidth:&w height:&h];
    if (d.length && !JJFrameIsBlack(d, w, h)) {
        if (outW) *outW = w;
        if (outH) *outH = h;
        [self logGrabSource:@"GL-hook" data:d w:outW h:outH];
        return d;
    }
    if (d.length && (s_blackFrames++ % 20) == 0) {
        NSLog(@"[JJCheat] GL-hook 帧全黑（读像素时机不对，或游戏不是 GL 渲染）");
    }

    /* ② Metal：nextDrawable 的 IOSurface（GL 游戏不会走到这里） */
    w = 0; h = 0;
    d = [self grabViaMetalWithWidth:&w height:&h];
    if (d.length && !JJFrameIsBlack(d, w, h)) {
        s_lastGoodMetal = d;
        s_lastGoodW = w;
        s_lastGoodH = h;
        s_lastGoodTs = CACurrentMediaTime();
        if (outW) *outW = w;
        if (outH) *outH = h;
        [self logGrabSource:@"Metal" data:d w:outW h:outH];
        return d;
    }

    /* 复用窗口只有 JJ_FRAME_MAX_AGE 秒。超时就返回 nil，让上层整轮跳过：
       局面静止时本来就不该跑识别，拿一张过期画面反而会误导锚定状态机。
       上层还有帧序号 + 画面指纹双重去重，这里复用也不会造成重复计算。 */
    BOOL goodIsFresh = s_lastGoodMetal.length &&
        (CACurrentMediaTime() - s_lastGoodTs <= JJ_FRAME_MAX_AGE);
    if (goodIsFresh) {
        int cw = s_lastGoodW, ch = s_lastGoodH;
        if (outW) *outW = cw;
        if (outH) *outH = ch;
        [self logGrabSource:@"Metal(缓存)" data:s_lastGoodMetal w:&cw h:&ch];
        return s_lastGoodMetal;
    }
    /* 只要 Metal 曾经出过有效帧，就永远不再走 CARenderServer / CALayer：
       roothide 下前者静默全黑，后者要在主线程全屏 renderInContext（14MB 位图），
       是 1.1.44 之前「间歇性卡顿」最重的一块。缓存过期宁可空一轮等下一张 Metal 帧。
       2.0.1：抓帧开关已开 = Metal 已接管，首帧未到时也直接返回 nil。
       16:39 日志里启动第一帧正是走了 CALayer 全黑回退（中心像素 0,0,0），
       导致首次学习 verifyDiff=32、RGB dump 全 0，白等 10 秒才用真 Metal 帧学成。
       实测开关打开后 0.8s 内 Metal 首帧就到，没必要再碰这两条死路。 */
    if (JJMetalCaptureEnabled() || s_lastGoodMetal.length) return nil;

    /* Metal 从未出过有效帧时才轮到重回退，且 1.5s 内最多一次。 */
    CFTimeInterval fallbackNow = CACurrentMediaTime();
    if (s_lastHeavyFallbackTs && fallbackNow - s_lastHeavyFallbackTs < 1.5) return nil;
    s_lastHeavyFallbackTs = fallbackNow;

    /* ② CARenderServer：Metal 从未成功时才试，roothide 下常常静默返回全黑 */
    w = 0; h = 0;
    d = [self grabViaRenderServerWithWidth:&w height:&h];
    if (d.length && !JJFrameIsBlack(d, w, h)) {
        if (outW) *outW = w;
        if (outH) *outH = h;
        [self logGrabSource:@"CARenderServer" data:d w:outW h:outH];
        return d;
    }
    if (d.length) {
        s_apiUsable = NO;
        if ((s_blackFrames++ % 20) == 0) {
            NSLog(@"[JJCheat] CARenderServer 返回全黑帧（沙箱静默失败）→ 关闭该路");
        }
    }

    /* ③ CALayer 兜底：对 GL/Metal 渲染的游戏基本也是黑的，只能保底给尺寸 */
    w = 0; h = 0;
    d = [self grabViaLayerWithWidth:&w height:&h];
    if (d.length) {
        if (outW) *outW = w;
        if (outH) *outH = h;
        [self logGrabSource:@"CALayer" data:d w:outW h:outH];
    }
    return d;
}

- (void)dealloc {
    if (_surface) CFRelease(_surface);
}

@end
