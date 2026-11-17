//
//  JJVisionBridge.m
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

#import "JJVisionBridge.h"
#import "JJConfig.h"
#import "JJEngineScript.h"
#import <JavaScriptCore/JavaScriptCore.h>

/* engine.js 的版本标记：每个改过 JS 的版本都要换成该版新增的字面量，
   App 容器里的 engine.js 优先级最高，而装新 deb 不会覆盖它（deb 只写 jbroot
   那份）。启动时自检，缺标记就自动用编进 dylib 的内嵌副本覆盖升级。
   1.1.40 = learnAndRefine；1.1.42 = skipAnalyze；1.1.43 = skipReason；
   1.1.44 = anchorCodes（开局锚定 + 一步棋状态机）；
   2.0.0  = waitingOpponent（红先黑后真实轮次 + 新局重锚 + 超时兜底）；
   2.0.1  = calibRejected（失败的重标定不污染已收敛会话）；
   2.1.0  = pikafishNative（JS 只识别不搜索，搜索交给独立进程 Pikafish）；
   2.1.58 = alignGridToOpening（开局匹配滤波网格对齐）；
   2.1.59 = 对齐 probeL 改盘均值（积分图），空盘/棋盘线不再被当成棋子。 */
static NSString * const kJJEngineFeatureMark = @"pikafishNative2177";

// roothide 适配：jbroot 每次越狱都会换一个随机路径，必须在运行时解析。
// 非 roothide 构建（rootful/rootless）不引这个头，避免多出 libroothide 依赖。
#ifdef THEOS_PACKAGE_SCHEME_ROOTHIDE
#import <roothide.h>
#endif

@interface JJVisionBridge ()
@property (nonatomic, strong) JSContext *ctx;
@property (nonatomic, strong) dispatch_queue_t engineQueue;
@property (nonatomic, strong) JSValue *pixelArray;      // 1.1.44 复用 14MB 像素缓冲
@property (nonatomic, assign) NSUInteger pixelArrayLength;
@property (nonatomic, assign) BOOL loaded;
@property (nonatomic, assign) BOOL busy;
@end

@implementation JJVisionBridge

+ (instancetype)shared {
    static JJVisionBridge *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[JJVisionBridge alloc] init]; });
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

/* 把内嵌副本落到 App 容器：
   - 文件不存在 → 首次释放；
   - 文件存在但缺 kJJEngineFeatureMark → 旧包残留，自动覆盖升级；
   - 文件存在且是新版 → 保持不动（尊重用户热改的参数）。 */
- (BOOL)seedEngineIntoContainer {
    NSString *dst = JJContainerEnginePath();
    if (!dst.length) return NO;

    NSData *embedded = [NSData dataWithBytes:JJEngineScript length:(NSUInteger)JJEngineScriptLength];
    if (embedded.length == 0) return NO;

    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL needWrite = NO;
    NSString *reason = nil;
    if (![fm fileExistsAtPath:dst]) {
        needWrite = YES;
        reason = @"首次释放到容器";
    } else {
        NSString *old = [NSString stringWithContentsOfFile:dst encoding:NSUTF8StringEncoding error:nil];
        if (old.length == 0 || [old rangeOfString:kJJEngineFeatureMark].location == NSNotFound) {
            needWrite = YES;
            reason = @"旧版残留自动升级";
        }
    }
    if (!needWrite) return YES;

    NSError *err = nil;
    BOOL ok = [embedded writeToFile:dst options:NSDataWritingAtomic error:&err];
    NSLog(@"[JJCheat] engine.js %@: %@ ok=%d %lu 字节 %@",
          reason, dst, ok, (unsigned long)embedded.length,
          ok ? @"" : (err.localizedDescription ?: @""));
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

    // 先把内嵌副本落到容器（不存在则释放，旧版残留则覆盖升级），让 ① 可用
    [self seedEngineIntoContainer];

    NSString *src = nil;
    NSString *path = [self locateEngineScript];
    NSURL *sourceURL = nil;
    NSString *origin = @"内嵌副本";

    if (path) {
        NSError *err = nil;
        src = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:&err];
        if (!src.length) {
            NSLog(@"[JJCheat] 读取 engine.js 失败: %@", err);
        } else if ([src rangeOfString:kJJEngineFeatureMark].location == NSNotFound) {
            /* 双保险：容器覆盖失败（沙箱只读等）时旧脚本也不能进 JSContext */
            NSLog(@"[JJCheat] engine.js 缺关键接口 %@（旧包残留？），改用内嵌副本",
                  kJJEngineFeatureMark);
            src = nil;
        } else {
            sourceURL = [NSURL fileURLWithPath:path];
            origin = path.lastPathComponent ?: @"磁盘文件";
        }
    }

    // 兜底：文件全都读不到（或版本过旧）就用内嵌副本，引擎照样能起
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

    /* 开机一条版本指纹：大小 + 关键接口有没有 + 实际来源，日志里一眼可判 */
    NSLog(@"[JJCheat] engine.js 版本: %lu 字节, %@=%@, 来源=%@",
          (unsigned long)[src lengthOfBytesUsingEncoding:NSUTF8StringEncoding],
          kJJEngineFeatureMark,
          [src rangeOfString:kJJEngineFeatureMark].location == NSNotFound ? @"缺" : @"有",
          origin);

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
                        callback:(JJVisionResultBlock)callback {
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
                if (!fn || fn.isUndefined) {
                    /* 旧版 engine.js 没有这个接口，原来会静默返回 nil，
                       日志一片空白、学习永远不完成，必须留一条明确报错。 */
                    NSLog(@"[JJCheat] JS 接口缺失: JJEngine.%@（engine.js 是旧版，学习无法进行）",
                          kJJEngineFeatureMark);
                } else {
                    JSValue *cornersVal = baseCorners
                        ? [JSValue valueWithObject:baseCorners inContext:ctx]
                        : [JSValue valueWithNullInContext:ctx];
                    JSValue *res = [fn callWithArguments:@[arrVal, @(w), @(h), cornersVal]];
                    if (res && !res.isUndefined && !res.isNull) result = [res toDictionary];
                }
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
             callback:(JJVisionResultBlock)callback {
    if (![self loadEngine]) {
        if (callback) dispatch_async(dispatch_get_main_queue(), ^{ callback(nil, nil); });
        return;
    }
    if (self.busy) {
        /* 必须回调：上层 JJGameController 靠回调清自己的 busy，直接 return 会让它永久停摆 */
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
            /* 1.1.44：真机 tweak 就是实时模式。旧版没传 live，JS 侧的
               「低置信度沿用上一帧」会把走子起点填回旧棋子，一步棋永远认不出；
               现在识别结果原样交给锚定状态机过滤，不再靠沿用机制挡抖动。 */
            opts[@"live"] = @YES;
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

    /* 1.1.44：旧版每次 process 都新建 14MB typed array，用完立刻交给 GC，
       真机上就是持续的 14MB 分配/回收 + 内存压力。engineQueue 是串行队列，
       JS 侧 process 同步执行完才返回，所以这块缓冲可以安全复用。 */
    JSValue *arr = self.pixelArray;
    if (!arr || self.pixelArrayLength != need) {
        JSGlobalContextRef gc = ctx.JSGlobalContextRef;
        JSValueRef ex = NULL;
        JSObjectRef typed = JSObjectMakeTypedArray(gc, kJSTypedArrayTypeUint8ClampedArray, need, &ex);
        if (!typed || ex) return nil;
        arr = [JSValue valueWithJSValueRef:typed inContext:ctx];
        self.pixelArray = arr;
        self.pixelArrayLength = need;
    }
    JSGlobalContextRef gc2 = ctx.JSGlobalContextRef;
    JSValueRef arrRef = arr.JSValueRef;
    void *bytes = JSObjectGetTypedArrayBytesPtr(gc2, (JSObjectRef)arrRef, NULL);
    if (!bytes) return nil;
    memcpy(bytes, rgba.bytes, need);
    return arr;
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
