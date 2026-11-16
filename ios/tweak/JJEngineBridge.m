//
//  JJEngineBridge.m
//  JJCheat
//
//  engine.js 定位（方案 B）：
//    ① App 沙箱内 <容器>/Library/Application Support/JJCheat/engine.js
//       —— App 进程自己的目录，永远可读写，不受 jbroot 随机路径和跨容器沙箱限制，
//          而且可以热改（Filza 直接改这个文件，重启 App 生效）
//    ② roothide 的 jbroot()
//    ③ rootless 的 /var/jb
//    ④ rootful 的 /Library
//    ⑤ 目标 App 的 .app 内（老方案残留，兼容）
//    ⑥ 全部落空 → 用编进 dylib 的内嵌副本（JJEngineScript.c）
//
//  首次载入时会把内嵌副本写进 ① 的位置，之后一直读文件，方便改参数。
//

#import "JJEngineBridge.h"
#import "JJConfig.h"
#import "JJEngineScript.h"
#import <JavaScriptCore/JavaScriptCore.h>

// roothide 适配：jbroot 每次越狱都会换一个随机路径，必须在运行时解析。
// 非 roothide 构建（rootful/rootless）不引这个头，避免多出 libroothide 依赖。
#ifdef THEOS_PACKAGE_SCHEME_ROOTHIDE
#import <roothide.h>
#endif

@interface JJEngineBridge ()
@property (nonatomic, strong) JSContext *ctx;
@property (nonatomic, strong) dispatch_queue_t engineQueue;
@property (nonatomic, assign) BOOL loaded;
@property (nonatomic, assign) BOOL busy;
@end

@implementation JJEngineBridge

+ (instancetype)shared {
    static JJEngineBridge *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[JJEngineBridge alloc] init]; });
    return s;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _engineQueue = dispatch_queue_create("com.fujiang.jjcheat.engine", DISPATCH_QUEUE_SERIAL);
        dispatch_set_target_queue(_engineQueue, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0));
        _loaded = NO;
        _busy = NO;
    }
    return self;
}

/* ============================================================
 *  App 沙箱内的 engine.js 路径
 *  注入后本进程就是 JJ象棋，所以 NSApplicationSupportDirectory /
 *  NSDocumentDirectory 指向的是这个 App 自己的容器 —— 沙箱放行。
 * ============================================================ */
static NSString *JJContainerEnginePath(void) {
    static NSString *cached = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSArray<NSString *> *paths =
            NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES);
        if (paths.count == 0) return;
        NSString *dir = [paths[0] stringByAppendingPathComponent:@"JJCheat"];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:NULL];
        cached = [dir stringByAppendingPathComponent:@"engine.js"];
    });
    return cached;
}

/* 首次运行把内嵌副本落到 App 容器；已经存在就不动（保留用户热改的版本） */
- (BOOL)seedEngineIntoContainer {
    NSString *dst = JJContainerEnginePath();
    if (!dst.length) return NO;
    if ([[NSFileManager defaultManager] fileExistsAtPath:dst]) return YES;

    NSData *data = [NSData dataWithBytes:JJEngineScript length:(NSUInteger)JJEngineScriptLength];
    if (data.length == 0) return NO;

    NSError *err = nil;
    BOOL ok = [data writeToFile:dst options:NSDataWritingAtomic error:&err];
    NSLog(@"[JJCheat] engine.js 释放到容器: %@ ok=%d %@",
          dst, ok, ok ? @"" : (err.localizedDescription ?: @""));
    return ok;
}

- (NSString *)locateEngineScript {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray<NSString *> *candidates = [NSMutableArray arrayWithCapacity:6];

    // ① App 沙箱内（主路径）
    NSString *container = JJContainerEnginePath();
    if (container.length) [candidates addObject:container];

    // ② roothide 正统路径：jbroot() -> <jbroot>/Library/Application Support/JJCheat/engine.js
#ifdef THEOS_PACKAGE_SCHEME_ROOTHIDE
    [candidates addObject:jbroot(@"/Library/Application Support/JJCheat/engine.js")];
#endif
    // ③ rootless（Dopamine 等）的固定 /var/jb
    [candidates addObject:JJ_ENGINE_PATH_ROOTLESS];
    // ④ rootful / 未做路径改写的 jbroot 字面量
    [candidates addObject:JJ_ENGINE_PATH];
    // ⑤ 兜底：目标 App 的 .app 里那份（老方案 jjcheat-fix 写的，兼容用）
    NSString *appRes = [[NSBundle mainBundle] pathForResource:@"engine" ofType:@"js"];
    if (appRes.length) [candidates addObject:appRes];

    for (NSString *p in candidates) {
        if (p.length && [fm fileExistsAtPath:p]) {
            NSLog(@"[JJCheat] engine.js 命中: %@", p);
            return p;
        }
        NSLog(@"[JJCheat] engine.js 未命中: %@", p.length ? p : @"(nil)");
    }
    return nil;
}

- (BOOL)loadEngine {
    if (self.loaded) return YES;

    // 先把内嵌副本落到容器（仅当容器里还没有），让 ① 可用
    [self seedEngineIntoContainer];

    NSString *src = nil;
    NSString *path = [self locateEngineScript];
    NSURL *sourceURL = nil;

    if (path) {
        NSError *err = nil;
        src = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:&err];
        if (!src.length) {
            NSLog(@"[JJCheat] 读取 engine.js 失败: %@", err);
        } else {
            sourceURL = [NSURL fileURLWithPath:path];
        }
    }

    // 兜底：文件全都读不到就用内嵌副本，引擎照样能起
    if (!src.length) {
        src = [[NSString alloc] initWithBytes:JJEngineScript
                                       length:(NSUInteger)JJEngineScriptLength
                                     encoding:NSUTF8StringEncoding];
        sourceURL = [NSURL URLWithString:@"jjcheat-embedded://engine.js"];
        NSLog(@"[JJCheat] engine.js 用内嵌副本（%lu 字节）", (unsigned long)JJEngineScriptLength);
    }
    if (!src.length) {
        NSLog(@"[JJCheat] engine.js 不可用（文件与内嵌副本都读不出来）");
        return NO;
    }

    dispatch_sync(self.engineQueue, ^{
        self.ctx = [[JSContext alloc] init];
        __weak typeof(self) weakSelf = self;
        self.ctx.exceptionHandler = ^(JSContext *c, JSValue *ex) {
            NSLog(@"[JJCheat] JS 异常: %@", [ex toString]);
            (void)weakSelf;
        };
        // 给 JS 端一个打日志的口子
        self.ctx[@"__nativeLog"] = ^(JSValue *msg) {
            NSLog(@"[JJCheat/js] %@", [msg toString]);
        };
        [self.ctx evaluateScript:src withSourceURL:sourceURL];
        JSValue *engine = self.ctx[@"JJEngine"];
        self.loaded = !engine.isUndefined && !engine.isNull;
        NSLog(@"[JJCheat] engine.js 加载%@", self.loaded ? @"成功" : @"失败");
    });
    return self.loaded;
}

- (void)setCorners:(NSArray<NSArray<NSNumber *> *> *)corners {
    [self loadEngine];
    dispatch_async(self.engineQueue, ^{
        JSValue *fn = self.ctx[@"JJEngine"][@"setCorners"];
        [fn callWithArguments:@[corners ?: @[]]];
    });
}

- (void)resetWithFen:(NSString *)fen {
    [self loadEngine];
    dispatch_async(self.engineQueue, ^{
        JSValue *fn = self.ctx[@"JJEngine"][@"reset"];
        [fn callWithArguments:@[fen ?: [NSNull null]]];
    });
}

- (void)learnAndRefineWithPixels:(NSData *)rgba
                           width:(int)w
                          height:(int)h
                     baseCorners:(NSArray<NSArray<NSNumber *> *> *)baseCorners
                        callback:(JJEngineResultBlock)callback {
    if (![self loadEngine] || self.busy) {
        if (callback) dispatch_async(dispatch_get_main_queue(), ^{ callback(nil, nil); });
        return;
    }
    self.busy = YES;

    __weak typeof(self) weakSelf = self;
    dispatch_async(self.engineQueue, ^{
        __strong typeof(weakSelf) self2 = weakSelf;
        NSDictionary *result = nil;
        if (self2 && self2.ctx) {
            JSContext *ctx = self2.ctx;
            JSValue *arrVal = [self2 makePixelArray:rgba width:w height:h];
            if (arrVal) {
                JSValue *fn = ctx[@"JJEngine"][@"learnAndRefine"];
                JSValue *cornersVal = baseCorners
                    ? [JSValue valueWithObject:baseCorners inContext:ctx]
                    : [JSValue valueWithNullInContext:ctx];
                JSValue *res = fn && !fn.isUndefined
                    ? [fn callWithArguments:@[arrVal, @(w), @(h), cornersVal]]
                    : nil;
                if (res && !res.isUndefined && !res.isNull) result = [res toDictionary];
            }
        }
        self2.busy = NO;
        if (callback) {
            dispatch_async(dispatch_get_main_queue(), ^{ callback(result, nil); });
        }
    });
}

- (void)processPixels:(NSData *)rgba
                width:(int)w
               height:(int)h
               timeMs:(int)timeMs
             callback:(JJEngineResultBlock)callback {
    if (![self loadEngine]) {
        if (callback) dispatch_async(dispatch_get_main_queue(), ^{ callback(nil, nil); });
        return;
    }
    if (self.busy) {
        /* 必须回调：上层 JJController 靠回调清自己的 busy，直接 return 会让它永久停摆 */
        if (callback) dispatch_async(dispatch_get_main_queue(), ^{ callback(nil, nil); });
        return;
    }
    self.busy = YES;

    __weak typeof(self) weakSelf = self;
    dispatch_async(self.engineQueue, ^{
        __strong typeof(weakSelf) self2 = weakSelf;
        if (!self2 || !self2.ctx) { self2.busy = NO; return; }
        JSContext *ctx = self2.ctx;
        JSValue *arrVal = [self2 makePixelArray:rgba width:w height:h];
        NSDictionary *result = nil;
        if (arrVal) {
            JSValue *fn = ctx[@"JJEngine"][@"process"];
            JSValue *opts = [JSValue valueWithNewObjectInContext:ctx];
            opts[@"timeMs"] = @(timeMs);
            opts[@"maxDiff"] = @(1);
            JSValue *res = [fn callWithArguments:@[arrVal, @(w), @(h), opts]];
            if (res && !res.isUndefined && !res.isNull) {
                result = [res toDictionary];
            }
        }
        self2.busy = NO;
        if (callback) {
            dispatch_async(dispatch_get_main_queue(), ^{ callback(result, nil); });
        }
    });
}

- (JSValue *)makePixelArray:(NSData *)rgba width:(int)w height:(int)h {
    JSContext *ctx = self.ctx;
    if (!ctx) return nil;
    NSUInteger need = (NSUInteger)w * (NSUInteger)h * 4;
    if (rgba.length < need) return nil;

    JSGlobalContextRef gc = ctx.JSGlobalContextRef;
    JSValueRef ex = NULL;
    JSObjectRef typed = JSObjectMakeTypedArray(gc, kJSTypedArrayTypeUint8ClampedArray, need, &ex);
    if (!typed || ex) return nil;
    void *bytes = JSObjectGetTypedArrayBytesPtr(gc, typed, NULL);
    if (!bytes) return nil;
    memcpy(bytes, rgba.bytes, need);
    return [JSValue valueWithJSValueRef:typed inContext:ctx];
}

- (NSArray<NSArray<NSNumber *> *> *)gridPoints {
    if (![self loadEngine]) return @[];
    __block NSArray *out = @[];
    dispatch_sync(self.engineQueue, ^{
        JSValue *fn = self.ctx[@"JJEngine"][@"gridPoints"];
        JSValue *res = [fn callWithArguments:@[]];
        NSArray *a = res ? [res toArray] : nil;
        if (a) out = a;
    });
    return out;
}

- (NSString *)currentFen {
    if (![self loadEngine]) return @"";
    __block NSString *out = @"";
    dispatch_sync(self.engineQueue, ^{
        JSValue *fn = self.ctx[@"JJEngine"][@"currentFen"];
        JSValue *res = [fn callWithArguments:@[]];
        if (res && res.isString) out = [res toString];
    });
    return out;
}

@end
