//
//  JJPikafish.m
//  JJCheat —— Pikafish 进程内引擎（2.1.52 起）
//
//  历史：2.1.0~2.1.51 是「deb 装一个 pikafish 可执行文件，posix_spawn 起来，
//  走管道」。真机日志证明这条路在 roothide 上走不通——App 沙盒不允许 exec
//  自己容器与 jbroot 下的二进制，四条源位 + 一条容器副本全部 access(X_OK) 失败，
//  一条 spawn 都没发出去。这里改成静态库 + 内存流，引擎跑在 dylib 自己的线程里。
//

#import "JJPikafish.h"
#import "JJPikafishInstaller.h"
#import "JJMoveCodec.h"
#import "JJEngineOptions.h"
#import "JJConfig.h"
#import "jjpika_shim.h"

#import <QuartzCore/QuartzCore.h>   /* CACurrentMediaTime（进度节流用） */
#import <dispatch/dispatch.h>
#import <os/lock.h>
#import <math.h>
#import <unistd.h>
#import <signal.h>
#import <fcntl.h>
#import <execinfo.h>

static NSString *const kPikaLog = @"[JJCheat][Pika]";

/* 2.1.62：崩溃诊断。iOS 的 ReportCrash 在越狱机上常因「Log limit exceeded」
   写不出 .ips；这里在进程内捕获 SIGSEGV/SIGBUS，把 backtrace 直接写进容器
   Documents/JJCheat_crash_bt.txt。dylib 未 strip，符号可直接读。 */
static char sJJCrashPath[1024] = {0};
static void JJFatalSignalHandler(int sig) {
    int fd = open(sJJCrashPath, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd >= 0) {
        char hdr[128];
        int n = snprintf(hdr, sizeof(hdr), "\n=== signal=%d pid=%d ===\n", sig, getpid());
        if (n > 0) (void)write(fd, hdr, (size_t)n);
        void *frames[128];
        int cnt = backtrace(frames, 128);
        backtrace_symbols_fd(frames, cnt, fd);
        close(fd);
    }
    signal(sig, SIG_DFL);
    raise(sig);
}

/* 握手超时：起线程后等 uciok/readyok 的上限。
   首次要 mmap 48MB 权重，冷启动比独立进程时代慢，给足 15s。 */
#define KIKA_HANDSHAKE_TIMEOUT 15.0
/* go 之后 bestmove 的宽限（叠加在 movetime 上） */
#define KIKA_BESTMOVE_GRACE_MS 3000
/* 等引擎线程置位 running 的上限（每 50ms 一次） */
#define KIKA_ENGINE_WAIT_TRIES 120
/* 2.1.61：NSThread 默认栈只有 512KB，uci 握手过得去，但 Pikafish 的
   search<> 递归一进 go movetime 就栈溢出 → 整个 App SIGSEGV（launchd 11）。
   真机 04:39:59 的日志把它钉死：verifyDiff=0 → engine=思考中 → 进程没了。
   显式给引擎线程 16MB 栈（Stockfish 官方建议 ≥8MB）。 */
#define KIKA_ENGINE_STACK_BYTES (16 * 1024 * 1024)

@interface JJPikafish ()
@property (nonatomic, strong) dispatch_queue_t pikaQueue;
@property (nonatomic, assign) JJPikaState state;
@property (nonatomic, assign) BOOL wantRunning;

/* 权重 */
@property (nonatomic, copy) NSString *netPath;

/* 线程存活标记 */
@property (nonatomic, assign) BOOL engineThreadRunning;
@property (nonatomic, assign) BOOL readerRunning;

/* 握手 */
/* 当前已下发到引擎的 Threads。用于判断「用户改了 Threads」这种必须重启的情况 */
@property (nonatomic, assign) NSInteger appliedThreads;
@property (nonatomic, assign) BOOL sawUciok;
@property (nonatomic, assign) BOOL sawReadyok;
@property (nonatomic, assign) NSInteger waitTries;
@property (nonatomic, strong) dispatch_block_t handshakeTimer;

/* 当前搜索 */
@property (nonatomic, copy) NSString *searchingFen;
@property (nonatomic, assign) NSInteger searchingMovetime;
@property (nonatomic, copy) JJPikaResultBlock searchingCb;
@property (nonatomic, strong) NSDictionary *lastInfo;
/* 2.1.79：进度回调节流时间戳（只在 pikaQueue 上读写） */
@property (nonatomic, assign) CFTimeInterval lastProgressTs;
/* 2.1.68：最近一条 `info string`（引擎自述 / NNUE 加载失败原因），HUD 与日志共用 */
@property (nonatomic, copy) NSString *lastEngineNotice;
@property (nonatomic, strong) dispatch_block_t watchdog;

/* 排队的下一个请求（新局面来了先 stop 旧的） */
@property (nonatomic, copy) NSString *pendingFen;
@property (nonatomic, assign) NSInteger pendingMovetime;
@property (nonatomic, copy) JJPikaResultBlock pendingCb;
@end

@implementation JJPikafish

/* getter 与 setter 都手写后 clang 不再合成 ivar，init 里要写 _state */
@synthesize state = _state;

/* 状态用自旋锁保护，**绝不能**用 dispatch_sync 回到 _pikaQueue：
   2.1.50 就是在 start 的 block 里读 self.state（实现是 dispatch_sync(_pikaQueue)），
   串行队列同步等自己 → 死锁 → 主线程被拖住 → 6 秒后被看门狗杀掉。 */
static os_unfair_lock sPikaStateLock = OS_UNFAIR_LOCK_INIT;

+ (instancetype)shared {
    static JJPikafish *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[JJPikafish alloc] init]; });
    return s;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _pikaQueue = dispatch_queue_create("com.fujiang.jjcheat.pikafish", DISPATCH_QUEUE_SERIAL);
        dispatch_set_target_queue(_pikaQueue,
                                  dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0));
        _state = JJPikaStateIdle;
        /* 崩溃诊断：预先算好容器路径，装 SIGSEGV/SIGBUS handler */
        NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                             NSUserDomainMask, YES).firstObject;
        NSString *btPath = [docs stringByAppendingPathComponent:@"JJCheat_crash_bt.txt"];
        strncpy(sJJCrashPath, btPath.fileSystemRepresentation, sizeof(sJJCrashPath) - 1);
        signal(SIGSEGV, JJFatalSignalHandler);
        signal(SIGBUS, JJFatalSignalHandler);
    }
    return self;
}

- (JJPikaState)state {
    os_unfair_lock_lock(&sPikaStateLock);
    JJPikaState st = _state;
    os_unfair_lock_unlock(&sPikaStateLock);
    return st;
}

- (void)setState:(JJPikaState)state {
    os_unfair_lock_lock(&sPikaStateLock);
    _state = state;
    os_unfair_lock_unlock(&sPikaStateLock);
}

- (NSString *)stateText {
    switch (self.state) {
        case JJPikaStateIdle:      return @"未启动";
        case JJPikaStateStarting:  return @"启动中";
        case JJPikaStateReady:     return @"就绪";
        case JJPikaStateSearching: return @"思考中";
        case JJPikaStateDead:      return @"不可用";
    }
}

- (NSString *)netPathInUse { return self.netPath; }

- (BOOL)engineThreadAlive { return jjpika_running() != 0; }

- (BOOL)isReadyOrStarting {
    JJPikaState st = self.state;
    return st == JJPikaStateReady || st == JJPikaStateSearching ||
           st == JJPikaStateStarting;
}

#pragma mark - 生命周期

- (void)start {
    dispatch_async(_pikaQueue, ^{
        self.wantRunning = YES;
        /* 用 jjpika_running() 而不是自己的布尔标记：引擎线程可能已经退出
           但标记还没被主线程处理，那时必须重开，不能误判成「已经起着」。 */
        if (self.engineThreadRunning && jjpika_running()) return;
        JJPikaState cur = self.state;
        if (cur == JJPikaStateReady || cur == JJPikaStateSearching) return;
        [self launchOnQueue];
    });
}

- (void)shutdown {
    dispatch_async(_pikaQueue, ^{
        self.wantRunning = NO;
        self.readerRunning = NO;
        if (self.handshakeTimer) {
            dispatch_block_cancel(self.handshakeTimer);
            self.handshakeTimer = nil;
        }
        if (self.watchdog) {
            dispatch_block_cancel(self.watchdog);
            self.watchdog = nil;
        }
        if (jjpika_running()) {
            NSLog(@"%@ 关闭引擎（quit）", kPikaLog);
            jjpika_stop();
        }
        self.engineThreadRunning = NO;
        self.state = JJPikaStateIdle;
        self.searchingCb = nil;
        self.pendingCb = nil;
        self.searchingFen = nil;
        self.pendingFen = nil;
    });
}

- (void)notifyNewGame {
    dispatch_async(_pikaQueue, ^{
        if (self.state == JJPikaStateReady || self.state == JJPikaStateSearching) {
            NSLog(@"%@ ucinewgame（新对局）", kPikaLog);
            [self writeLine:@"ucinewgame"];
            [self writeLine:@"isready"];
        }
    });
}

#pragma mark - 启动

- (void)launchOnQueue {
    self.state = JJPikaStateStarting;

    /* 已经有一个引擎循环在跑（例如握手中被再次调用）就别再起第二个：
       jjpika_start 内部是全局流，起两个必然互相踩。直接补一次握手即可。 */
    if (jjpika_running()) {
        self.engineThreadRunning = YES;
        [self sendUciWhenRunningOnQueue];
        [self armHandshakeTimeoutOnQueue];
        return;
    }

    NSError *err = nil;
    NSString *net = [JJPikafishInstaller resolveNetPathWithError:&err];
    if (!net.length) {
        NSLog(@"%@ 找不到 NNUE 权重：%@", kPikaLog,
              err.localizedDescription ?: @"unknown");
        self.state = JJPikaStateDead;
        return;
    }
    self.netPath = net;
    NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:net error:nil];
    NSLog(@"%@ 权重就位：%@（%lld 字节），进程内启动", kPikaLog, net,
          (long long)[attr fileSize]);

    self.sawUciok = NO;
    self.sawReadyok = NO;
    self.waitTries = 0;
    self.engineThreadRunning = YES;
    self.readerRunning = YES;

    /* 2.1.61：必须用 initWithTarget + stackSize，detachNewThreadSelector 拿不到
       栈大小设置入口；默认 512KB 栈在第一次 go movetime 搜索时 SIGSEGV。 */
    NSThread *engineThread = [[NSThread alloc] initWithTarget:self
                                                      selector:@selector(engineThreadMain:)
                                                        object:net];
    engineThread.stackSize = KIKA_ENGINE_STACK_BYTES;
    [engineThread start];

    [NSThread detachNewThreadSelector:@selector(readerThreadMain:)
                             toTarget:self
                           withObject:nil];

    [self sendUciWhenRunningOnQueue];
    [self armHandshakeTimeoutOnQueue];
}

/** engine 线程：jjpika_start 阻塞跑引擎主循环，返回即引擎退出 */
- (void)engineThreadMain:(NSString *)net {
    @autoreleasepool {
        NSLog(@"%@ 引擎线程启动（进程内 Pikafish，pid=%d）", kPikaLog, getpid());
        int rc = jjpika_start(net.fileSystemRepresentation);
        NSLog(@"%@ 引擎主循环退出 rc=%d", kPikaLog, rc);
        jjpika_stop();   /* 幂等：确保 reader 也会走到 EOF */
        dispatch_async(_pikaQueue, ^{ [self handleEngineLoopExitOnQueue]; });
    }
}

/** reader 线程：把引擎输出行搬到 pikaQueue */
- (void)readerThreadMain:(id)unused {
    @autoreleasepool {
        char buf[4096];
        while (self.readerRunning) {
            int rc = jjpika_recv(buf, (int)sizeof(buf), 500);
            if (rc == 1) {
                NSString *line = [NSString stringWithUTF8String:buf];
                if (!line) line = @"";
                line = [line stringByTrimmingCharactersInSet:
                        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
                if (line.length) {
                    dispatch_async(_pikaQueue, ^{ [self handleLineOnQueue:line]; });
                }
            } else if (rc < 0) {
                break;   /* 引擎已退出且队列取空 */
            }
        }
        NSLog(@"%@ reader 线程结束", kPikaLog);
    }
}

/** 引擎线程起来才发 uci：jjpika_send 在 running=0 时返回 -1，直接丢掉命令 */
- (void)sendUciWhenRunningOnQueue {
    if (self.state != JJPikaStateStarting) return;
    if (jjpika_running()) {
        NSLog(@"%@ 发送 uci", kPikaLog);
        [self writeLine:@"uci"];
        return;
    }
    if (++self.waitTries > KIKA_ENGINE_WAIT_TRIES) {
        NSLog(@"%@ 引擎线程迟迟没起来（%.1fs），放弃本次",
              kPikaLog, KIKA_ENGINE_WAIT_TRIES * 0.05);
        self.engineThreadRunning = NO;
        self.readerRunning = NO;
        self.state = JJPikaStateDead;
        return;
    }
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC), _pikaQueue, ^{
        [weakSelf sendUciWhenRunningOnQueue];
    });
}

- (void)armHandshakeTimeoutOnQueue {
    self.handshakeTimer = dispatch_block_create(0, ^{
        if (self.state != JJPikaStateStarting) return;
        NSLog(@"%@ 握手超时（%.0fs 无 readyok），停止引擎", kPikaLog,
              (double)KIKA_HANDSHAKE_TIMEOUT);
        jjpika_stop();
        self.engineThreadRunning = NO;
        self.readerRunning = NO;
        self.state = JJPikaStateDead;
        /* 排队中的请求必须收到 nil，否则上层 busy 永远不清 */
        JJPikaResultBlock pcb = self.pendingCb;
        self.pendingCb = nil;
        self.pendingFen = nil;
        if (pcb) dispatch_async(dispatch_get_main_queue(), ^{ pcb(nil); });
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                     (int64_t)(KIKA_HANDSHAKE_TIMEOUT * NSEC_PER_SEC)),
                   _pikaQueue, self.handshakeTimer);
}

/** 引擎主循环返回（正常 quit 或异常）—— pikaQueue 上 */
- (void)handleEngineLoopExitOnQueue {
    BOOL unexpected = self.wantRunning;
    self.engineThreadRunning = NO;
    self.readerRunning = NO;
    self.state = unexpected ? JJPikaStateDead : JJPikaStateIdle;
    JJPikaResultBlock cb = self.searchingCb;
    JJPikaResultBlock pcb = self.pendingCb;
    self.searchingCb = nil;
    self.pendingCb = nil;
    self.searchingFen = nil;
    self.pendingFen = nil;
    if (unexpected) NSLog(@"%@ 引擎意外退出（下一轮分析会重新拉起）", kPikaLog);
    if (cb) dispatch_async(dispatch_get_main_queue(), ^{ cb(nil); });
    if (pcb) dispatch_async(dispatch_get_main_queue(), ^{ pcb(nil); });
}

#pragma mark - 管道（内存流）

- (void)writeLine:(NSString *)line {
    if (!line.length) return;
    if (jjpika_send(line.UTF8String) != 0) {
        NSLog(@"%@ 命令未送达（引擎没在跑）：%@", kPikaLog, line);
    }
}

#pragma mark - 选项下发

/** 把 JJEngineOptions 的引擎侧参数下发一遍。
 *  握手完成时调一次；菜单改参数后调一次（热更新）。
 *  Threads 放在最前：它会 resize_threads()，Hash 需要在新的线程池上分配，
 *  否则刚分配的表会被 resize 清掉一次，白做一遍几十 MB 的清零。 */
- (void)applyOptionsOnQueue {
    JJEngineOptions *o = [JJEngineOptions shared];
    NSArray<NSString *> *lines = [o setoptionLines];
    for (NSString *line in lines) [self writeLine:line];
    NSLog(@"%@ 选项已下发: %@", kPikaLog, [o summary]);
}

/** 运行中热更新：只改不触发线程重建的项。
 *  Threads 变更必须重启引擎（调用方负责确认与 shutdown/start），
 *  这里遇到 Threads 变化会拒绝下发并记一条日志，避免静默崩溃。 */
- (void)applyOptionsHot {
    dispatch_async(_pikaQueue, ^{
        if (self.state != JJPikaStateReady && self.state != JJPikaStateSearching) return;
        JJEngineOptions *o = [JJEngineOptions shared];
        NSInteger liveThreads = self.appliedThreads;
        if (liveThreads != o.threads) {
            NSLog(@"%@ Threads %ld→%ld 需要重启引擎，热更新已跳过（等用户确认后重启）",
                  kPikaLog, (long)liveThreads, (long)o.threads);
        }
        for (NSString *line in [o setoptionLines]) {
            /* Threads 行单独跳过：热改它会重建线程池，正是历史上闪退的成因 */
            if ([line hasPrefix:@"setoption name Threads"]) continue;
            [self writeLine:line];
        }
        self.appliedThreads = o.threads;
        [self writeLine:@"isready"];
        NSLog(@"%@ 选项热更新完成: %@", kPikaLog, [o summary]);
    });
}

/* 2.1.79：搜索进度节流推送。
 *
 * 为什么节流：Pikafish 每层都会吐一批 info，多线路时更密（MultiPV=3 时
 * 一次 go 能有上百行）。每行都刷 HUD 会让主线程一直忙着排版，
 * 反而更卡。150ms 是「肉眼看着在动」与「不浪费主线程」的折中。
 *
 * 为什么放在引擎队列判断而不是主线程：当前时间戳的比较很便宜，
 * 放在产生方判断可以避免把 90% 的行都 dispatch 到主线程再丢掉。 */
- (void)emitProgressIfDue {
    if (!self.onSearchProgress) return;
    if (self.state != JJPikaStateSearching) return;
    CFTimeInterval now = CACurrentMediaTime();
    if (now - self.lastProgressTs < 0.15) return;
    self.lastProgressTs = now;

    NSDictionary *info = self.lastInfo;
    if (!info) return;
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    out[@"depth"] = info[@"depth"] ?: @0;
    out[@"nodes"] = info[@"nodes"] ?: @0;
    out[@"score"] = info[@"score"] ?: @0;
    out[@"mate"] = info[@"mate"] ?: @0;
    out[@"nps"] = info[@"nps"] ?: @0;
    out[@"wdlW"] = info[@"wdlW"] ?: @0;
    out[@"wdlD"] = info[@"wdlD"] ?: @0;
    if (info[@"pv"]) out[@"pv"] = info[@"pv"];
    out[@"searchFen"] = self.searchingFen ?: @"";

    JJPikaProgressBlock cb = self.onSearchProgress;
    dispatch_async(dispatch_get_main_queue(), ^{ cb([out copy]); });
}

#pragma mark - UCI 行处理

- (void)handleLineOnQueue:(NSString *)line {
    if ([line hasPrefix:@"uciok"]) {
        self.sawUciok = YES;
        /* 2.1.79：选项下发统一走 JJEngineOptions，不再在这里写死字符串。
           历史教训（2.1.60~62）：曾经在这里无条件下发 setoption Threads / EvalFile，
           两者都会触发引擎内部重建 —— Threads.set() 让 threads.clear() 再
           pthread_create；EvalFile 重载 50MB NNUE。iOS 上 pthread 重建不干净
           → worker 悬空 → go 时在 0x0 解引用 SIGSEGV（§25.3 真机证实）。
           现在：Threads 默认 1，只有用户主动改过才下发（见 JJEngineOptions 默认值）；
           EvalFile 一律不发（构造函数已按 argv[0] 目录加载好权重）。 */
        [self applyOptionsOnQueue];
        [self writeLine:@"isready"];
        return;
    }
    if ([line hasPrefix:@"readyok"]) {
        if (self.handshakeTimer) {
            dispatch_block_cancel(self.handshakeTimer);
            self.handshakeTimer = nil;
        }
        if (self.state == JJPikaStateStarting) {
            NSLog(@"%@ 握手完成（uciok=%d），引擎就绪", kPikaLog, self.sawUciok);
        }
        self.sawReadyok = YES;
        self.state = JJPikaStateReady;
        [self flushPendingOnQueue];
        return;
    }
    /* 2.1.68：`info string` 必须排在 `info ` 之前，而且必须打日志。
       引擎的一切自述都走这个前缀 —— `info string NNUE evaluation using ...`、
       `info string Network replica 1: ...`，以及 2.1.68 补丁新加的
       `info string JJ-NNUE FAIL reason=... fileHash=0x... engineHash=0x...`。
       2.1.60~67 把 `info ` 判断放在前面先 return，这些行一条都没进过日志，
       「引擎到底有没有加载上权重」因此一直看不见，白白多绕了几轮。 */
    if ([line hasPrefix:@"info string"]) {
        NSLog(@"%@ 引擎自述: %@", kPikaLog, line);
        self.lastEngineNotice = line;
        return;
    }
    if ([line hasPrefix:@"info "]) {
        self.lastInfo = [self parseInfoLine:line];
        [self emitProgressIfDue];
        return;
    }
    if ([line hasPrefix:@"bestmove"]) {
        [self handleBestmoveOnQueue:line];
        return;
    }
    if ([line hasPrefix:@"id name"]) {
        NSLog(@"%@ 引擎自报: %@", kPikaLog, line);
        return;
    }
    /* 其它可能带错误的行：原样打出来，别静默 */
    if ([line rangeOfString:@"error"].location != NSNotFound ||
        [line rangeOfString:@"Error"].location != NSNotFound ||
        [line rangeOfString:@"NNUE"].location != NSNotFound) {
        NSLog(@"%@ 引擎输出: %@", kPikaLog, line);
        self.lastEngineNotice = line;
    }
}

- (NSDictionary *)parseInfoLine:(NSString *)line {
    NSArray *tok = [line componentsSeparatedByString:@" "];
    NSMutableDictionary *d = self.lastInfo ? [self.lastInfo mutableCopy]
                                             : [NSMutableDictionary dictionary];
    for (NSUInteger i = 1; i + 1 < tok.count; i++) {
        NSString *k = tok[i];
        if ([k isEqualToString:@"depth"]) d[@"depth"] = @([tok[i + 1] integerValue]);
        else if ([k isEqualToString:@"score"]) {
            /* score cp N [lowerbound|upperbound] 或 score mate N */
            if (i + 2 < tok.count && [tok[i + 1] isEqualToString:@"mate"]) {
                d[@"mate"] = @([tok[i + 2] integerValue]);
                d[@"score"] = nil;
            } else if (i + 2 < tok.count) {
                d[@"score"] = @([tok[i + 2] integerValue]);
                d[@"mate"] = nil;
            }
        }
        else if ([k isEqualToString:@"wdl"]) {
            /* wdl W D L（千分数，走子方视角） */
            if (i + 3 < tok.count) {
                d[@"wdlW"] = @([tok[i + 1] integerValue]);
                d[@"wdlD"] = @([tok[i + 2] integerValue]);
                d[@"wdlL"] = @([tok[i + 3] integerValue]);
            }
        }
        else if ([k isEqualToString:@"nodes"]) d[@"nodes"] = @([tok[i + 1] integerValue]);
        else if ([k isEqualToString:@"nps"]) d[@"nps"] = @([tok[i + 1] integerValue]);
        else if ([k isEqualToString:@"pv"]) {
            NSMutableArray *pv = [NSMutableArray array];
            for (NSUInteger j = i + 1; j < tok.count; j++) [pv addObject:tok[j]];
            d[@"pv"] = pv;
        }
    }
    return d;
}

- (void)handleBestmoveOnQueue:(NSString *)line {
    if (self.watchdog) {
        dispatch_block_cancel(self.watchdog);
        self.watchdog = nil;
    }
    NSArray *tok = [line componentsSeparatedByString:@" "];
    NSString *mv = tok.count > 1 ? tok[1] : @"";
    if ([mv isEqualToString:@"(none)"]) mv = @"";

    JJPikaResultBlock cb = self.searchingCb;
    NSString *fen = self.searchingFen;
    self.state = JJPikaStateReady;
    self.searchingFen = nil;
    self.searchingCb = nil;

    if (cb) {
        NSDictionary *info = self.lastInfo ?: @{};
        NSMutableDictionary *out = [NSMutableDictionary dictionary];
        out[@"bestmove"] = mv;
        out[@"ponder"] = (tok.count > 3 && [tok[2] isEqualToString:@"ponder"]) ? tok[3] : @"";
        out[@"from"] = @(mv.length >= 4 ? JJSqFromICCS(mv, 0) : -1);
        out[@"to"] = @(mv.length >= 4 ? JJSqFromICCS(mv, 1) : -1);
        out[@"depth"] = info[@"depth"] ?: @0;
        out[@"score"] = info[@"score"] ?: @0;
        out[@"mate"] = info[@"mate"] ?: @0;
        out[@"nodes"] = info[@"nodes"] ?: @0;
        out[@"nps"] = info[@"nps"] ?: @0;
        out[@"pv"] = info[@"pv"] ?: @[];
        /* 胜率：UCI_ShowWDL 的 wdl 千分数（走子方视角）；没有就按 cp 估 */
        NSInteger w = [info[@"wdlW"] integerValue];
        NSInteger dr = [info[@"wdlD"] integerValue];
        if (w + dr > 0) {
            out[@"winrate"] = @((w + dr / 2) / 10.0);
        } else {
            double cp = [info[@"score"] doubleValue];
            double wr = 100.0 * (2.0 / (1.0 + exp(-cp / 200.0)) - 1.0) / 2.0 + 50.0;
            out[@"winrate"] = @(MAX(1.0, MIN(99.0, wr)));
        }
        out[@"searchFen"] = fen ?: @"";
        out[@"engine"] = @"pikafish";
        dispatch_async(dispatch_get_main_queue(), ^{ cb([out copy]); });
    }
    [self flushPendingOnQueue];
}

#pragma mark - 搜索调度

- (void)analyzeFen:(NSString *)fen movetime:(NSInteger)movetime completion:(JJPikaResultBlock)completion {
    if (!fen.length) {
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(nil); });
        return;
    }
    dispatch_async(_pikaQueue, ^{
        self.wantRunning = YES;
        /* 没起 / 死了：先拉起，请求排队（flushPending 在 readyok 后触发） */
        if (!self.engineThreadRunning) {
            [self launchOnQueue];
        }
        if (self.state != JJPikaStateReady && self.state != JJPikaStateSearching) {
            self.pendingFen = fen;
            self.pendingMovetime = movetime;
            self.pendingCb = completion;
            return;
        }
        if (self.state == JJPikaStateSearching) {
            /* 正在搜旧局面：停掉它，结果一到就开新搜索 */
            [self writeLine:@"stop"];
            self.pendingFen = fen;
            self.pendingMovetime = movetime;
            self.pendingCb = completion;
            return;
        }
        [self beginSearchOnQueue:fen movetime:movetime completion:completion];
    });
}

- (void)beginSearchOnQueue:(NSString *)fen
                  movetime:(NSInteger)movetime
                completion:(JJPikaResultBlock)completion {
    if (self.state != JJPikaStateReady) return;
    self.state = JJPikaStateSearching;
    self.searchingFen = fen;
    self.searchingMovetime = MAX(50, movetime);
    self.searchingCb = completion;
    self.lastInfo = nil;
    [self writeLine:[NSString stringWithFormat:@"position fen %@", fen]];
    /* 2.1.79：深度模式优先。thinkDepth > 0 时用 go depth，否则 go movetime。
       深度模式的看门狗仍按 movetime 估算时长（depth 的耗时不可预测，
       只能给一个宽松上限，超时就当卡死处理）。 */
    NSInteger wantDepth = [JJEngineOptions shared].thinkDepth;
    if (wantDepth > 0) {
        [self writeLine:[NSString stringWithFormat:@"go depth %ld", (long)wantDepth]];
    } else {
        [self writeLine:[NSString stringWithFormat:@"go movetime %ld",
                         (long)self.searchingMovetime]];
    }

    /* 看门狗：movetime + 宽限期仍无 bestmove → 让引擎停下，丢一次结果。
       2.1.76 卡顿修复：旧逻辑在这里 jjpika_stop() + state=Dead，
       下一轮 analyzeFen 走 launchOnQueue() → 重新 mmap 50MB 权重 + 重新 UCI 握手，
       真机上就是 2~4 秒卡死，而且 NNUE 校验慢的话会反复触发、越卡越频繁。
       现在只发 UCI `stop`：引擎线程、权重、置换表全部保活，状态回 Ready。
       只有引擎线程真的退出了（jjpika_running()==0）才标记 Dead 等重新拉起。
       发 stop 后引擎会回 bestmove，handleBestmoveOnQueue 末尾会自动 flush 下一个请求。 */
    __weak typeof(self) weakSelf = self;
    NSInteger mt = self.searchingMovetime;
    self.watchdog = dispatch_block_create(0, ^{
        __strong typeof(weakSelf) self2 = weakSelf;
        if (!self2 || self2.state != JJPikaStateSearching) return;
        JJPikaResultBlock cb = self2.searchingCb;
        self2.searchingCb = nil;
        self2.searchingFen = nil;
        self2.state = JJPikaStateReady;      // 保活：不要回到 Starting/Dead
        [self2 writeLine:@"stop"];
        NSLog(@"%@ 看门狗超时（movetime=%ldms 无 bestmove）→ 发 stop 保活引擎（不重载权重）",
              kPikaLog, (long)mt);
        if (!jjpika_running()) {
            NSLog(@"%@ 引擎线程确实已退出 → Dead，等下一轮重新拉起", kPikaLog);
            self2.state = JJPikaStateDead;
            self2.engineThreadRunning = NO;
            self2.readerRunning = NO;
        }
        if (cb) dispatch_async(dispatch_get_main_queue(), ^{ cb(nil); });
        /* pending 不清：stop 之后 bestmove 到达时 handleBestmoveOnQueue 会 flush 它 */
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                     (int64_t)((mt + KIKA_BESTMOVE_GRACE_MS) * 1000000ull)),
                   _pikaQueue, self.watchdog);
}

- (void)flushPendingOnQueue {
    if (!self.pendingFen.length || self.state != JJPikaStateReady) return;
    NSString *fen = self.pendingFen;
    NSInteger mt = self.pendingMovetime;
    JJPikaResultBlock cb = self.pendingCb;
    self.pendingFen = nil;
    self.pendingMovetime = 0;
    self.pendingCb = nil;
    [self beginSearchOnQueue:fen movetime:mt completion:cb];
}

@end
