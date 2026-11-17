//
//  JJEngineOptions.m
//  JJCheat —— Pikafish 可调参数
//

#import "JJEngineOptions.h"
#import "JJConfig.h"

NSString *const JJOptKeyThinkMs      = @"JJCheat.thinkMs";        // 与旧键同名，升级不丢
NSString *const JJOptKeyThinkDepth   = @"JJCheat.thinkDepth";
NSString *const JJOptKeyHashMb       = @"JJCheat.hashMb";
NSString *const JJOptKeyThreads      = @"JJCheat.threads";
NSString *const JJOptKeyMultiPV      = @"JJCheat.multiPV";
NSString *const JJOptKeyMoveOverhead = @"JJCheat.moveOverhead";
NSString *const JJOptKeyShowWDL      = @"JJCheat.showWDL";

static NSInteger JJClamp(NSInteger v, NSInteger lo, NSInteger hi) {
    return v < lo ? lo : (v > hi ? hi : v);
}

@interface JJEngineOptions ()
@property (nonatomic, assign, readwrite) NSInteger thinkMs;
@property (nonatomic, assign, readwrite) NSInteger thinkDepth;
@property (nonatomic, assign, readwrite) NSInteger hashMb;
@property (nonatomic, assign, readwrite) NSInteger threads;
@property (nonatomic, assign, readwrite) NSInteger multiPV;
@property (nonatomic, assign, readwrite) NSInteger moveOverhead;
@property (nonatomic, assign, readwrite) BOOL showWDL;
@end

@implementation JJEngineOptions

+ (instancetype)shared {
    static JJEngineOptions *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[JJEngineOptions alloc] init]; });
    return s;
}

- (instancetype)init {
    self = [super init];
    if (self) [self reload];
    return self;
}

- (void)reload {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];

    NSInteger ms = [ud integerForKey:JJOptKeyThinkMs];
    /* 一次性迁移：2.0.x 的 200ms 是给 JS 引擎调的值，Pikafish 吃 NNUE，
       这个时长等于没思考。保持与旧 JJPikafish 一致的迁移语义。 */
    if (![ud boolForKey:JJ_KEY_THINK_MS_V2]) {
        if (ms > 0 && ms <= 250) ms = 0;
        [ud setBool:YES forKey:JJ_KEY_THINK_MS_V2];
        [ud synchronize];
    }
    self.thinkMs = ms > 0 ? JJClamp(ms, JJ_OPT_THINK_MS_MIN, JJ_OPT_THINK_MS_MAX)
                          : JJ_THINK_MS_DEFAULT;

    NSInteger depth = [ud integerForKey:JJOptKeyThinkDepth];
    self.thinkDepth = JJClamp(depth, JJ_OPT_THINK_DEPTH_MIN, JJ_OPT_THINK_DEPTH_MAX);

    NSInteger hash = [ud integerForKey:JJOptKeyHashMb];
    self.hashMb = hash > 0 ? JJClamp(hash, JJ_OPT_HASH_MB_MIN, JJ_OPT_HASH_MB_MAX)
                           : JJ_PIKA_HASH_MB;

    NSInteger th = [ud integerForKey:JJOptKeyThreads];
    /* 默认 1：默认值不动是刻意的 —— 2.1.60~62 就是 setoption Threads 重建
       线程池把 worker 弄悬空、go 时 SIGSEGV。用户主动改才生效。 */
    self.threads = th > 0 ? JJClamp(th, JJ_OPT_THREADS_MIN, JJ_OPT_THREADS_MAX) : 1;

    NSInteger mpv = [ud integerForKey:JJOptKeyMultiPV];
    self.multiPV = mpv > 0 ? JJClamp(mpv, JJ_OPT_MULTIPV_MIN, JJ_OPT_MULTIPV_MAX) : 1;

    NSInteger mo = [ud integerForKey:JJOptKeyMoveOverhead];
    self.moveOverhead = JJClamp(mo, JJ_OPT_MOVE_OVERHEAD_MIN, JJ_OPT_MOVE_OVERHEAD_MAX);

    /* UCI_ShowWDL 默认开：HUD 的胜率就靠它，不比 cp 估算差 */
    self.showWDL = [ud objectForKey:JJOptKeyShowWDL] ? [ud boolForKey:JJOptKeyShowWDL] : YES;
}

- (void)persistInteger:(NSInteger)v forKey:(NSString *)key {
    [[NSUserDefaults standardUserDefaults] setInteger:v forKey:key];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (void)setThinkMs:(NSInteger)v {
    NSInteger c = JJClamp(v <= 0 ? JJ_THINK_MS_DEFAULT : v, JJ_OPT_THINK_MS_MIN, JJ_OPT_THINK_MS_MAX);
    _thinkMs = c;
    [self persistInteger:c forKey:JJOptKeyThinkMs];
}

- (void)setThinkDepth:(NSInteger)v {
    NSInteger c = JJClamp(v, JJ_OPT_THINK_DEPTH_MIN, JJ_OPT_THINK_DEPTH_MAX);
    _thinkDepth = c;
    [self persistInteger:c forKey:JJOptKeyThinkDepth];
}

- (void)setHashMb:(NSInteger)v {
    NSInteger c = JJClamp(v, JJ_OPT_HASH_MB_MIN, JJ_OPT_HASH_MB_MAX);
    _hashMb = c;
    [self persistInteger:c forKey:JJOptKeyHashMb];
}

- (void)setThreads:(NSInteger)v {
    NSInteger c = JJClamp(v, JJ_OPT_THREADS_MIN, JJ_OPT_THREADS_MAX);
    _threads = c;
    [self persistInteger:c forKey:JJOptKeyThreads];
}

- (void)setMultiPV:(NSInteger)v {
    NSInteger c = JJClamp(v, JJ_OPT_MULTIPV_MIN, JJ_OPT_MULTIPV_MAX);
    _multiPV = c;
    [self persistInteger:c forKey:JJOptKeyMultiPV];
}

- (void)setMoveOverhead:(NSInteger)v {
    NSInteger c = JJClamp(v, JJ_OPT_MOVE_OVERHEAD_MIN, JJ_OPT_MOVE_OVERHEAD_MAX);
    _moveOverhead = c;
    [self persistInteger:c forKey:JJOptKeyMoveOverhead];
}

- (void)setShowWDL:(BOOL)v {
    _showWDL = v;
    [[NSUserDefaults standardUserDefaults] setBool:v forKey:JJOptKeyShowWDL];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

/* 只下发引擎侧参数。顺序有讲究：
 *   Threads 放最前 —— 它会 resize_threads()，后面的 Hash 需要在新线程池上分配
 *   （Engine::set_tt_size 会遍历 threads）。反过来先 Hash 再 Threads 不会崩，
 *   但刚分配的表会被 resize 清掉一次，白做一遍 48MB 的清零。 */
- (NSArray<NSString *> *)setoptionLines {
    return @[
        [NSString stringWithFormat:@"setoption name Threads value %ld", (long)self.threads],
        [NSString stringWithFormat:@"setoption name Hash value %ld", (long)self.hashMb],
        [NSString stringWithFormat:@"setoption name MultiPV value %ld", (long)self.multiPV],
        [NSString stringWithFormat:@"setoption name Move Overhead value %ld", (long)self.moveOverhead],
        [NSString stringWithFormat:@"setoption name UCI_ShowWDL value %@",
         self.showWDL ? @"true" : @"false"],
    ];
}

+ (BOOL)requiresEngineRestartForKey:(NSString *)key {
    /* Threads：resize_threads() → threads.clear() + pthread_create。
       真机实测重建不干净时 worker 悬空，go 时在 0x0 解引用 SIGSEGV。 */
    if ([key isEqualToString:JJOptKeyThreads]) return YES;
    /* Hash 不需要重启：set_tt_size 只是 free + alloc，不走线程重建。
       但会有一瞬间的内存峰值，所以 UI 上仍然提示「下一步生效」。 */
    return NO;
}

- (NSString *)summary {
    NSMutableString *s = [NSMutableString string];
    if (self.thinkDepth > 0)
        [s appendFormat:@"深度 %ld", (long)self.thinkDepth];
    else
        [s appendFormat:@"%ld ms", (long)self.thinkMs];
    [s appendFormat:@" · 线程 %ld · 哈希 %ldMB", (long)self.threads, (long)self.hashMb];
    if (self.multiPV > 1) [s appendFormat:@" · 多线 %ld", (long)self.multiPV];
    return s;
}

@end
